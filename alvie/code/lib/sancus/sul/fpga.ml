(*
  The FPGA target of the Sancus backend (Simulator.target): runs the program of a step on an openMSP430/Sancus
  board (an Arty S7 programmed with an instrumented image, see docs/sancus/fpga.md) instead of simulating it.

  A query sends the program memory and the interrupt vectors of pmem.elf with a breakpoint, an instruction number,
  over the serial port; the board runs the program from reset and sends back a trace of the 50 clock cycles from the
  start of that instruction (window). The breakpoint is the first instruction the step has not analysed yet
  (last_inst_number + 1). If no trace comes, the program reset or stopped before that instruction: the query is
  retried at the last instruction analysed, whose window may still hold the step's instructions; if that fails too,
  the step diverged.

  The serial port is opened once per process and port, and shared by the copies of a backend (clone): each query
  holds an exclusive lock (flock) on it, so that queries of different copies, or of different processes, do not mix.
  A query sends the whole program, so the board keeps no state of a test between queries.
*)
open! Core

external serial_open : string -> int -> Core_unix.File_descr.t = "caml_alvie_serial_open"
external serial_flush_input : Core_unix.File_descr.t -> unit = "caml_alvie_serial_flush_input" [@@noalloc]

let baud_rate = 5_000_000

(* The trace of a query: window entries of entry_size bytes *)
let window = 50
let entry_size = 16

(* How long to wait for the next bytes of a trace *)
let read_timeout = 2.0

(* The FTDI driver waits up to its latency timer (16 ms by default) before handing over bytes: with more than 1 ms,
   each query waits for it *)
let check_latency_timer port =
  let file = sprintf "/sys/bus/usb-serial/devices/%s/latency_timer" (Filename.basename port) in
  match Sys_unix.file_exists file with
  | `Yes ->
    let latency = String.strip (In_channel.read_all file) in
    if not (String.equal latency "1") then
      failwithf "The latency timer of %s is %s ms, and the FPGA target needs 1 ms: run echo 1 | sudo tee %s, or add a udev rule (see docs/sancus/fpga.md)."
        port latency file ()
  | `No | `Unknown ->
    Logs.warn (fun m -> m "Could not read the latency timer of %s (%s): if it is not 1 ms, every query waits for it." port file)

let ports : Core_unix.File_descr.t String.Table.t = String.Table.create ()

let () =
  Stdlib.at_exit (fun () ->
    Hashtbl.iter ports ~f:(fun fd -> try Core_unix.close fd with _ -> ());
    Hashtbl.clear ports)

(* Opens the serial port, once per process *)
let connect ~port =
  match Hashtbl.find ports port with
  | Some fd -> fd
  | None ->
    (match Sys_unix.file_exists port with
     | `Yes -> ()
     | `No | `Unknown ->
       failwithf "The serial port %s of the FPGA does not exist: check that the board is connected and the value of --fpga-port (the board's UART is usually the second port of its USB device, e.g. /dev/ttyUSB1)." port ());
    check_latency_timer port;
    let fd = try serial_open port baud_rate with Failure m ->
      failwithf "%s. Check that your user can open it (e.g., is in the group dialout)." m () in
    Hashtbl.set ports ~key:port ~data:fd;
    Logs.debug (fun m -> m "Fpga: serial port %s open" port);
    fd

(* The sections .text and .vectors of an ELF file of the MSP430, with their 16-bit words in big-endian order *)
let elf_sections elf =
  let b = In_channel.read_all elf in
  let u8 o = Char.to_int b.[o] in
  let u16 o = u8 o lor (u8 (o + 1) lsl 8) in
  let u32 o = u16 o lor (u16 (o + 2) lsl 16) in
  if String.length b < 52 || not (String.equal (String.prefix b 4) "\x7fELF") || u8 4 <> 1 || u8 5 <> 1 then
    failwithf "Fpga: %s is not a 32-bit little-endian ELF file" elf ();
  let shoff = u32 32 and shentsize = u16 46 and shnum = u16 48 and shstrndx = u16 50 in
  let header k = shoff + (k * shentsize) in
  let names = u32 (header shstrndx + 16) in
  let name_at o = let e = String.index_from_exn b o '\000' in String.sub b ~pos:o ~len:(e - o) in
  let section name =
    match List.find (List.init shnum ~f:Fn.id) ~f:(fun k -> String.equal (name_at (names + u32 (header k))) name) with
    | None -> failwithf "Fpga: %s has no section %s" elf name ()
    | Some k -> String.sub b ~pos:(u32 (header k + 16)) ~len:(u32 (header k + 20)) in
  let swap_bytes s =
    String.init (String.length s + (String.length s % 2)) ~f:(fun i ->
      let j = i lxor 1 in
      if j < String.length s then s.[j] else '\000') in
  swap_bytes (section ".text"), swap_bytes (section ".vectors")

(* 0xff, then the program memory, the vectors and the breakpoint, each length and number in 16 bits little-endian *)
let payload ~pmem ~vectors ~breakpoint =
  let buf = Buffer.create (String.length pmem + String.length vectors + 7) in
  let u16 n = Buffer.add_char buf (Char.of_int_exn (n land 0xff)); Buffer.add_char buf (Char.of_int_exn ((n lsr 8) land 0xff)) in
  Buffer.add_char buf '\xff';
  u16 (String.length pmem); Buffer.add_string buf pmem;
  u16 (String.length vectors); Buffer.add_string buf vectors;
  u16 breakpoint;
  Buffer.contents buf

(* One clock cycle of the trace *)
type entry = {
  pc : int;
  inst_number : int;
  irq : int;
  sm_executing : int;
  e_state : int;
  r4 : int;
  gie : int;
  timerA : int;
  umem : int;
} [@@deriving sexp_of]

(* The board sends the cycles of the window from the last one *)
let entries_of_raw raw =
  List.rev (List.init window ~f:(fun i ->
    let b o = Char.to_int raw.[(i * entry_size) + o] in
    { pc = (b 0 lsl 8) lor b 1;
      irq = b 2 land 1;
      sm_executing = b 3 land 1;
      gie = b 4 land 1;
      inst_number = (b 5 lsl 24) lor (b 6 lsl 16) lor (b 7 lsl 8) lor b 8;
      e_state = b 9 land 0x1f;
      r4 = (b 10 lsl 8) lor b 11;
      timerA = (b 12 lsl 8) lor b 13;
      umem = (b 14 lsl 8) lor b 15 }))

(* The trace of the window from breakpoint, or None if the board sends none in time *)
let query fd ~pmem ~vectors ~breakpoint =
  if breakpoint > 0xFFFF then
    failwithf "Fpga: the test is too long for the board, whose breakpoints are 16-bit instruction numbers (%d)" breakpoint ();
  let data = payload ~pmem ~vectors ~breakpoint in
  let size = window * entry_size in
  let raw = Bytes.create size in
  Core_unix.flock_blocking fd Core_unix.Flock_command.lock_exclusive;
  Exn.protect ~finally:(fun () -> ignore (Core_unix.flock fd Core_unix.Flock_command.unlock : bool)) ~f:(fun () ->
    serial_flush_input fd;
    let rec write_all pos =
      if pos < String.length data then
        write_all (pos + Core_unix.single_write_substring fd ~buf:data ~pos ~len:(String.length data - pos)) in
    write_all 0;
    let rec read_all pos =
      if pos >= size then true
      else
        match Core_unix.select ~read:[ fd ] ~write:[] ~except:[] ~timeout:(`After (Time_ns.Span.of_sec read_timeout)) () with
        | { read = []; _ } -> false
        | _ ->
          let n = Core_unix.read fd ~buf:raw ~pos ~len:(size - pos) in
          n > 0 && read_all (pos + n) in
    if read_all 0 then Some (entries_of_raw (Bytes.to_string raw)) else None)

(*
  Runs pmem.elf up to the first instruction not analysed yet and returns its trace, and whether the step diverged.
  When the program reset or stopped before that instruction (e.g., the reset of the cleanup at the end of a test),
  the window that ends there may still hold the step's instructions: the query is retried at the last instruction
  analysed.
*)
let run ~port ~elf ~last_inst_number =
  let fd = connect ~port in
  let pmem, vectors = elf_sections elf in
  let q breakpoint = Prof.time "sul.fpga_query" (fun () -> query fd ~pmem ~vectors ~breakpoint) in
  match q (last_inst_number + 1) with
  | Some trace -> (false, trace)
  | None ->
    Logs.debug (fun m -> m "Fpga: no trace at breakpoint %d, retrying at %d" (last_inst_number + 1) last_inst_number);
    Prof.count "sul.fpga_retry";
    (match q (Int.max 1 last_inst_number) with
     | Some trace -> (false, trace)
     | None -> Prof.count "sul.fpga_diverged"; (true, []))

(*
  The instructions of the labelled code in the trace (Step_analysis.found). The FPGA reads them differently from the
  simulator's VCD dump:
  - an instruction's cycles are those with its inst_number; k is their count, so the window bounds it (50);
  - r4, gie and umem are read at the first cycle of the next instruction, after the instruction's writes commit
    (a store is visible in its own observation); timerA, a free-running counter, at the last cycle of the
    instruction;
  - when the next instruction is not in the window, the mode does not change: the end of the window and a reset
    cannot be told apart here (a reset makes the query fail, see run);
  - the trace stops at the crash sentinel of the end of a test (pc 0xFFFF, unreachable as an instruction).
*)
let analyse ~diverges ~addr_of_label ~last_inst_number (labels : Step_analysis.label list) (trace : entry list) : Step_analysis.found =
  let annot_pcs = List.map labels ~f:(fun (s, e) -> addr_of_label s, addr_of_label e) in
  let labels_and_pcs = List.zip_exn labels annot_pcs in
  let pc_to_label pcs = fst (List.find_exn labels_and_pcs ~f:(fun (_, pcs') -> Tuple2.equal ~eq1:Int.equal ~eq2:Int.equal pcs pcs')) in
  (* The cycles of an instruction are looked up in the whole window, the instructions to analyse only up to the
     sentinel *)
  let cycles_of n = List.filter trace ~f:(fun e -> e.inst_number = n) in
  let first_cycle_of n = List.hd (cycles_of n) in
  let trace = List.take_while trace ~f:(fun e -> e.pc <> 0xFFFF) in
  let annotated pc = List.exists annot_pcs ~f:(fun (s, e) -> pc >= s && pc < e) in
  (* The first cycle of each instruction of the labelled code, once per pc, excluding interrupts *)
  let matched = List.fold trace ~init:[] ~f:(fun acc e ->
    if annotated e.pc && e.irq <> 1 && e.inst_number >= last_inst_number && not (List.exists acc ~f:(fun e' -> e'.pc = e.pc))
    then e :: acc else acc) |> List.rev in
  (* If the e_state after an instruction is 0x10 (SM_IRQ_REGS), an interrupt is handled in PM: keep the instruction
     and the next one, and discard the rest *)
  let seen_pcs, matched = List.fold_until matched ~init:([], []) ~finish:Fn.id ~f:(fun (seen, acc) e ->
    match first_cycle_of (e.inst_number + 1) with
    | Some next when next.e_state = 0x10 -> Stop (e.pc :: seen, acc @ [ e; next ])
    | _ -> Continue (e.pc :: seen, acc @ [ e ])) in
  let left_labels = List.filter annot_pcs ~f:(fun (s, e) -> not (List.exists seen_pcs ~f:(fun pc -> pc >= s && pc < e)))
                    |> List.map ~f:pc_to_label in
  Logs.debug (fun m -> m "Fpga.analyse: instructions %s" (List.to_string matched ~f:(fun e -> Int.to_string e.inst_number)));
  if List.is_empty matched then Step_analysis.Nothing { diverges }
  else
    let mode e = if e.sm_executing = 0 then Output_internal.UM else Output_internal.PM in
    let instruction e : Step_analysis.instruction =
      let cycles = cycles_of e.inst_number in
      let last_cycle = Option.value (List.last cycles) ~default:e in
      let next = first_cycle_of (e.inst_number + 1) in
      let state = Option.value next ~default:last_cycle in
      { mode_s = mode e;
        mode_e = Option.value_map next ~f:mode ~default:(mode e);
        e_states = List.remove_consecutive_duplicates (List.map cycles ~f:(fun c -> c.e_state)) ~equal:Int.equal;
        gie = state.gie = 1;
        r4 = state.r4;
        umem = state.umem;
        timerA = last_cycle.timerA;
        k = Int.max 1 (List.length cycles) } in
    Instructions {
      last_inst_number = (List.last_exn matched).inst_number;
      left_labels;
      instructions = List.map matched ~f:(fun e -> `Instruction (instruction e));
    }
