(*
  The step of the Sancus backend (Alvie_backend.Backend.S), whatever the target: it generates the program of a test
  from the programs of the sections that Core gives, runs it on a target, and turns the trace of the input's
  instructions into observations. Simulator adds the target that runs the Verilog testbench of sancus-core-gap
  with Verilator (with the Unix library); this module runs anywhere OCaml runs, also in a browser, where the target
  is the testbench compiled to WebAssembly.

  The target is where the program runs (target): the simulator (Verilator, see Simulator), or another target given
  by a plugin that reuses this backend, such as the FPGA board of ALVIE/Sancus-FPGA (Sancus_fpga) or the simulator in
  WebAssembly. Everything else does not depend on the target: the program of a step (fill_template), its build
  (assemble_native), the bookkeeping, re-entries, and the observations of the instructions found (Step_analysis).
*)
open! Core

open Common

open Attacker
open Enclave

type input_t = Input.t [@@deriving ord,sexp]
type output_t = Output_internal.t [@@deriving ord,sexp]
type label_t = string*string [@@deriving sexp,ord]

(*
  Where the programs run: the simulator, or another target, given by how it runs a step. run cfg runs the program
  of the step in cfg (its source is cfg.filledfile; build_program builds it) and returns the function that finds
  the instructions of given labels in the trace. boot is code that every program of the target runs first, after
  each reset (the marker [@inst_boot] of the template; the simulator runs none). The configuration is the parameter, so that the target can be
  one of its fields.
*)
type 'cfg target =
  | Verilator
  | Other of { name : string; boot : string list; run : 'cfg -> (label_t list -> Step_analysis.found) }

let show_mode m = match m with `PM -> "PM" | `UM -> "UM"

let show_e_state e = match e with `NO_SM -> "NO_SM" | `OTHER -> "OTHER" | `RETI -> "RETI" | `PP_JMPOUT -> "PP_JMPOUT" | `HANDLE -> "HANDLE"

type cfg_t = {
  (* These first fields contains file and script-related parameters *)
  workingdir : string;
  tmpdir : string;
  basename : string;
  get_symbolpos : string;
  pmem_script : string;
  simulate_script : string;
  templatefile : string;
  (* These files are in the tmp directory *)
  pmem_elf : string;
  filledfile : string;
  dumpfile : string;
  (* This is the parameter to convert "absolute" time into cycles *)
  sim_cycle_ratio : int;
  (* The inputs and outputs of the test so far, to recognise repeated re-entries *)
  input_history : input_t list;
  output_history : output_t list;
  (* Finally, we also keep track of the instructions we still need to analyze *)
  left_labels : label_t list;
  (* last_time : int; *)
  last_inst_number : int;
  ignore_interrupts : bool;
  (* If set, a re-entry segment that repeats the previous one is collapsed (see collapse_repeated_reentry) *)
  collapse_reentries : bool;
  (* The configurations at the re-entry points of the current run, most recent first *)
  reentries : cfg_t list;
  (* Where the test is in the spec after the last input (Generator.key) *)
  spec_key : string;
  (* Not compared, and shown by name only *)
  target : (cfg_t target [@sexp.opaque]) [@compare fun _ _ -> 0];
} [@@deriving ord,sexp,make]

type t = cfg_t ref

let clone s = ref { !s with last_inst_number = !s.last_inst_number}

(* What a target that is not given as Other runs: the simulator, which Simulator sets when it is linked *)
let verilator_run : (cfg_t -> label_t list -> Step_analysis.found) ref =
  ref (fun _ -> failwith "Sancus: this build of ALVIE has no Verilator simulator (Simulator is not linked)")

(* The address of a label that the table of symbols misses: the toolchain's nm, which Simulator sets *)
let addr_of_label_fallback : (cfg_t -> string -> int) ref =
  ref (fun _ l -> failwithf "addr_of_label: the program has no label %s" l ())

(*
  The program of a test: the programs of the sections that Core gives (Alvie_backend.Backend.step), compiled into the
  testbench's template. The input's occurrence is labelled, so that analyse_dump finds its instructions: the
  other atoms run too, but are not analysed.
*)
let fill_template template_code (cfg : cfg_t) (step : Alvie_backend.Backend.step) =
  (* FIXME: this is very bad, but that's the easiest thing; We need to reset the index after each experiment *)
  Common.reset_last_used_idx ();
  let program name convert =
    let prog = Option.value (List.Assoc.find step.programs ~equal:String.equal name) ~default:[] in
    List.mapi prog ~f:(fun position v ->
        let a = Result.ok_or_failwith (convert v) in
        if String.equal step.section name && position = step.position then Label a else NoLabel a) in
  let enclave = program "enclave" Atom_value.to_enclave in
  let isr = program "isr" Atom_value.to_attacker and prepare = program "prepare" Atom_value.to_attacker
  and cleanup = program "cleanup" Atom_value.to_attacker in
  let enclave_labels, enclave_code = Enclave.compile (Enclave.C_Enclave enclave) in
  Logs.debug (fun p -> p "Enclave labels: %s" ([%derive.show: (string*string) list] enclave_labels));
  Logs.debug (fun p -> p "Enclave code: %s" ([%derive.show: string list] enclave_code));
  let attacker_labels, isr_code, prepare_code, cleanup_code =
    Attacker.compile ~ignore_interrupts:cfg.ignore_interrupts (C_ISR isr, C_Prepare prepare, C_Cleanup cleanup) in
  let code = match cfg.target with
    | Other { boot = _ :: _ as boot; _ } -> String.substr_replace_all template_code ~pattern:"; [@inst_boot]" ~with_:(String.concat ~sep:"\n\t" boot)
    | Verilator | Other _ -> template_code in
  let code = String.substr_replace_all code ~pattern:"; [@inst_isr]" ~with_:(String.concat ~sep:"\n\t" isr_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_pre]" ~with_:(String.concat ~sep:"\n\t" prepare_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_post]" ~with_:(String.concat ~sep:"\n\t" cleanup_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_victim]" ~with_:(String.concat ~sep:"\n\t" enclave_code) in
    attacker_labels @ enclave_labels, code

(*
  Symbols of the last built pmem.elf: name -> list of addresses.
  Reading the whole table with a single nm invocation avoids spawning a shell per label lookup.
  It must be invalidated whenever pmem.elf is rebuilt (see run_simulator).
*)
let symtab : (string * int list String.Table.t) option ref = ref None

(* Whether symtab comes from Msp430_asm: there is then no ELF file of the step to fall back to *)
let symtab_native = ref false

let invalidate_symtab () = symtab := None; symtab_native := false

(*
  The symbols nm would list for a 32-bit little-endian ELF file, i.e., defined symbols that are
  neither section nor file symbols, as (name, value) pairs.
*)
let elf_symbols (elf : string) : (string * int) list =
  let b = In_channel.read_all elf in
  let u8 o = Char.to_int b.[o] in
  let u16 o = u8 o lor (u8 (o + 1) lsl 8) in
  let u32 o = u16 o lor (u16 (o + 2) lsl 16) in
  if String.length b < 52 || not (String.equal (String.prefix b 4) "\x7fELF") || u8 4 <> 1 || u8 5 <> 1 then
    failwithf "elf_symbols: %s is not a 32-bit little-endian ELF file" elf ();
  let shoff = u32 32 and shentsize = u16 46 and shnum = u16 48 in
  let section k = shoff + (k * shentsize) in
  List.concat_map (List.init shnum ~f:Fn.id) ~f:(fun k ->
    let sh = section k in
    (* SHT_SYMTAB *)
    if u32 (sh + 4) <> 2 then []
    else
      let off = u32 (sh + 16) and size = u32 (sh + 20) and entsize = u32 (sh + 36) in
      let strtab = u32 (section (u32 (sh + 24)) + 16) in
      let name_at o = let e = String.index_from_exn b o '\000' in String.sub b ~pos:o ~len:(e - o) in
      List.filter_map (List.init (size / entsize) ~f:Fn.id) ~f:(fun j ->
        let st = off + (j * entsize) in
        let name = name_at (strtab + u32 st) and value = u32 (st + 4) in
        let typ = u8 (st + 12) land 0xf and shndx = u16 (st + 14) in
        (* Skip undefined, section (STT_SECTION) and file (STT_FILE) symbols, as nm does *)
        if String.is_empty name || shndx = 0 || typ = 3 || typ = 4 then None else Some (name, value)))

let load_symtab elf =
  let tbl = String.Table.create () in
  List.iter (elf_symbols elf) ~f:(fun (name, value) -> Hashtbl.add_multi tbl ~key:name ~data:value);
  tbl

let addr_of_label cfg l =
  let tbl = match !symtab with
    | Some (elf, tbl) when String.equal elf cfg.pmem_elf -> tbl
    | _ -> let tbl = Prof.time "sul.load_symtab" (fun () -> load_symtab cfg.pmem_elf) in symtab := Some (cfg.pmem_elf, tbl); tbl in
  match Hashtbl.find tbl l with
  | Some [ addr ] -> addr
  | _ when !symtab_native -> failwithf "addr_of_label: the program has no label %s" l ()
  (* Missing or ambiguous symbols: fall back to the original lookup, to preserve its exact behaviour *)
  | _ -> !addr_of_label_fallback cfg l

(* The only signals analyse_dump looks at: parsing just these is much cheaper than parsing the whole dump *)
(* Each signal is listed with its alternative names: internal signals are copied to the top level of
   the testbench (see generic.v), the original names are used when every signal is traced *)
let sig_pc = [ "TOP.tb_openMSP430.inst_pc[15:0]" ]
let sig_irq = [ "TOP.tb_openMSP430.alvie_irq"; "TOP.tb_openMSP430.msp_debug_0.irq" ]
let sig_inst_number = [ "TOP.tb_openMSP430.inst_number[31:0]" ]
let sig_sm_executing = [ "TOP.tb_openMSP430.alvie_sm_executing"; "TOP.tb_openMSP430.dut.frontend_0.sm_executing" ]
let sig_e_state = [ "TOP.tb_openMSP430.alvie_e_state[4:0]"; "TOP.tb_openMSP430.dut.e_state[4:0]" ]
let sig_r4 = [ "TOP.tb_openMSP430.r4[15:0]" ]
let sig_gie = [ "TOP.tb_openMSP430.gie" ]
let sig_timerA = [ "TOP.tb_openMSP430.alvie_timerA_tar[15:0]"; "TOP.tb_openMSP430.timerA_0.tar[15:0]" ]
let sig_umem = [ "TOP.tb_openMSP430.mem250[15:0]" ]
let analysed_signals = List.concat [ sig_pc; sig_irq; sig_inst_number; sig_sm_executing; sig_e_state; sig_r4; sig_gie; sig_timerA; sig_umem ]

(* The program memory size, as computed by build_pmem in <tmpdir>/pmem.sh *)
let pmem_size cfg =
  let conf = In_channel.read_lines (cfg.tmpdir ^ "/pmem.sh") in
  match List.find_map conf ~f:(fun l -> String.chop_prefix (String.strip l) ~prefix:"pmemsize=") with
  | Some v -> Int.of_string (String.strip v)
  | None -> failwith "Could not find pmemsize in pmem.sh"

let get_signal dump names =
  match List.find names ~f:(fun n -> Vcd.has_signal dump n) with
  | Some n -> Vcd.get_signal dump n
  | None -> Vcd.get_signal dump (List.last_exn names)

(*
  The program of the step built by Msp430_asm instead of the toolchain (unless ALVIE_ASM=toolchain): once build_pmem
  has prepared the tmpdir (its first build, with the toolchain, writes pmem_defs.asm and pmem.x), each program is
  assembled in microseconds. The symbols of the program become symtab, and the image is kept for the targets that load
  it themselves (native_sections). A program that Msp430_asm does not accept is built by the toolchain, with a warning.
*)
let native_asm () = match Sys.getenv "ALVIE_ASM" with Some "toolchain" -> false | _ -> true

let text_origins : int String.Table.t = String.Table.create ()

(* The origin of .text in the tmpdir's pmem.x (the program memory) *)
let text_origin (cfg : cfg_t) =
  Hashtbl.find_or_add text_origins cfg.tmpdir ~default:(fun () ->
      let x = In_channel.read_all (cfg.tmpdir ^ "/pmem.x") in
      let re = Str.regexp "text[ \t]*(rx)[ \t]*:[ \t]*ORIGIN[ \t]*=[ \t]*\\([0-9a-fA-Fx]+\\)" in
      ignore (Str.search_forward re x 0);
      Int.of_string (Str.matched_group 1 x))

let last_image : (string * Msp430_asm.image) option ref = ref None

let assemble_native (cfg : cfg_t) : Msp430_asm.image option =
  if not (native_asm ()) || not (Stdlib.Sys.file_exists (cfg.tmpdir ^ "/.build_pmem_setup_done")) then None
  else
    match Prof.time "sul.msp430_asm" (fun () ->
        Msp430_asm.assemble ~read_include:(fun f -> In_channel.read_all (cfg.tmpdir ^ "/" ^ f))
          ~text_origin:(text_origin cfg) ~vectors_origin:0xffe0 (In_channel.read_all cfg.filledfile)) with
    | img ->
      let tbl = String.Table.create () in
      List.iter img.symbols ~f:(fun (name, value) -> Hashtbl.add_multi tbl ~key:name ~data:value);
      symtab := Some (cfg.pmem_elf, tbl);
      symtab_native := true;
      last_image := Some (cfg.tmpdir, img);
      Some img
    | exception Msp430_asm.Error m ->
      Logs.warn (fun p -> p "The assembler of ALVIE does not accept the program of the step (%s): it is built by the toolchain." m);
      last_image := None;
      None

(* The program memory and the vectors of the last program built for cfg by Msp430_asm, as their bytes (little-endian) *)
let native_sections (cfg : cfg_t) =
  match !last_image with
  | Some (dir, img) when String.equal dir cfg.tmpdir -> Some (Msp430_asm.section_bytes img ".text", Msp430_asm.section_bytes img ".vectors")
  | _ -> None

let analyse_dump (diverges : bool) (cfg : cfg_t) (labels : (string * string) list) (dump : Vcd.vcd_t) : Step_analysis.found =
  Prof.time "sul.analyse_dump" @@ fun () ->
  (* let labels = List.dedup_and_sort labels ~compare:[%derive.ord: string*string] in *)
  (* Find the interesting points in the code, using the labels *)
  Logs.debug (fun p -> p "Verilog.analyse_dump: labels: %s" ([%derive.show: (string*string) list] labels));
  let annot_pcs = List.map labels ~f:(fun (s, e) -> addr_of_label cfg s, addr_of_label cfg e) in
  let labels_and_pcs = List.zip_exn labels annot_pcs in
  let pc_to_label (s, e) = fst (List.find_exn labels_and_pcs ~f:(fun (_, (s', e')) -> s = s' && e = e')) in
  let pc_map = get_signal dump sig_pc in
  let irq_map = get_signal dump sig_irq in
  let inst_number_map = get_signal dump sig_inst_number in
  let sm_executing_map = get_signal dump sig_sm_executing in
  let e_state_map = get_signal dump sig_e_state in
  let r4_map = get_signal dump sig_r4 in
  let gie_map = get_signal dump sig_gie in
  let timerA_map = get_signal dump sig_timerA in
  (* let pmem_map = Vcd.get_signal dump "TOP.tb_openMSP430.mem240[15:0]" in *)
  let umem_map = get_signal dump sig_umem in
  (* Logs.debug (fun m -> m "reg_map : [%s]\n" (List.to_string (Map.to_alist r4_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v)));
  Logs.debug (fun m -> m "gie_map : [%s]\n" (List.to_string (Map.to_alist gie_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v)));
  Logs.debug (fun m -> m "timerA_map : [%s]\n" (List.to_string (Map.to_alist timerA_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  (* Logs.debug (fun m -> m "pmem_map : [%s]\n" (List.to_string (Map.to_alist pmem_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  (* Logs.debug (fun m -> m "umem_map : [%s]\n" (List.to_string (Map.to_alist umem_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  let time_and_pc_map = Map.fold ~init:(Int.Map.empty, String.Set.empty)
    pc_map.tv
    ~f:(fun ~key:time ~data:raw_data (acc_tpm, seen) ->
      (* Logs.debug (fun m -> m "Verilog.analyse_dump: time: %d; raw_data: %s; pc: %x; irq: %s; inst_num: %d" time raw_data (Int.of_string ("0b" ^ raw_data)) (Vcd.Signal.at_time irq_map time) (Int.of_string ("0b" ^ Vcd.Signal.at_time inst_number_map time))); *)
      if not (String.equal raw_data "x") &&
        List.exists annot_pcs ~f:(fun (s, e) -> let pc = Int.of_string ("0b" ^ raw_data) in pc >= s && pc < e) &&
        not (String.equal (Vcd.Signal.at_time irq_map time) "1") &&
        (* FIXME: find a better way to do this *)
        Int.of_string ("0b" ^ Vcd.Signal.at_time inst_number_map time) >= cfg.last_inst_number &&
        (* time >= cfg.last_time && *)
        not (Set.mem seen raw_data)
      then
          (Map.add_exn acc_tpm ~key:time ~data:raw_data, Set.add seen raw_data)
      else
        (acc_tpm, seen)
    ) |> fst in
  (* if Map.length time_and_pc_map >= 1000 then (* An arbitrary limit! *)
    cfg.last_inst_number, [], [Output_internal.OMaybeDiverge]
  else *)
  (
  Logs.debug (fun m -> m "time_and_pc_map: %s"
    (Map.fold time_and_pc_map ~init:"" ~f:(fun ~key ~data acc -> sprintf "%s; (%d -> %X)" acc key (Int.of_string ("0b" ^ data))))
  );
  let cand_inst_numbers = List.map (Map.to_alist time_and_pc_map) ~f:(fun (ct, _) -> Int.of_string ("0b" ^ Vcd.Signal.at_time inst_number_map ct)) in
  (*
    If the e_state after an inst_number is 0x10 (SM_IRQ_REGS) we are handling an interrupt in PM!
    If the e_state after an inst_number is 0x02 (IRQ_0) we are handling an interrupt in UM!
    If that's the case, we keep instructions up to inst_number and inst_number+1 and discard all the rest
  *)
  (* inst_cfg returns the pair (timin, inst_number) for the given inst_number *)
  (* first_time.(n) is the first time at which inst_number takes value n *)
  let first_time = Map.fold inst_number_map.tv ~init:Int.Map.empty ~f:(fun ~key:time ~data acc ->
    if String.equal data "x" then acc
    else
      let n = Int.of_string ("0b" ^ data) in
      if Map.mem acc n then acc else Map.set acc ~key:n ~data:time) in
  let inst_cfg inst_number = Option.map (Map.find first_time inst_number) ~f:(fun t -> (t, ())) in
  let raw_pc_of_inst_num inst_number = match inst_cfg inst_number with Some (t, _) -> Vcd.Signal.at_time pc_map t | None -> failwith "Should never happen!" in
  (* seen_pcs collects actually seen pcs for left_labels calculation, i.e., we exclude IRQ pcs! *)
  let seen_pcs, inst_numbers = List.fold_until cand_inst_numbers ~init:([], []) ~f:(fun (acc_seen, acc_in) curr_inst_number ->
    let next_inst_number = curr_inst_number + 1 in
    (match inst_cfg next_inst_number with
    | None -> Continue ((raw_pc_of_inst_num curr_inst_number)::acc_seen, curr_inst_number::acc_in)
    | Some (after_last_inst_time, _) ->
        if Int.of_string("0b" ^ Vcd.Signal.at_time e_state_map after_last_inst_time) = 0x10 then
          Stop ((raw_pc_of_inst_num curr_inst_number)::acc_seen, next_inst_number::curr_inst_number::acc_in)
        else
          Continue ((raw_pc_of_inst_num curr_inst_number)::acc_seen, curr_inst_number::acc_in)
    )
  ) ~finish:(fun r -> r) in
  List.iter annot_pcs ~f:(fun apc -> Logs.debug (fun p -> p "Verilog.analyse_dump: annot_pcs -> lbl: (0x%x, 0x%x) -> %s" (fst apc) (snd apc) ([%derive.show: (string*string)] (pc_to_label apc))));
  let left_labels' = List.map (List.filter annot_pcs ~f:(fun (s, e) -> Option.is_none (List.find seen_pcs ~f:(fun raw_pc -> let pc = Int.of_string ("0b" ^ raw_pc) in pc >= s && pc < e)))) ~f:pc_to_label in
  Logs.debug (fun p -> p "Verilog.analyse_dump: left_labels: %s" (Sexp.to_string (List.sexp_of_t sexp_of_label_t left_labels')));
  let inst_numbers = List.dedup_and_sort ~compare:Int.compare inst_numbers in
  Logs.debug (fun m -> m "inst_numbers: %s" (List.to_string inst_numbers ~f:(fun el -> sprintf "%d" el)));
  (* Since after divergence, nothing different than th subsequence of actions causing the infinite loop can be executed, when inst_numbers is empty we can have two cases:
          - if diverges holds, then the given input was "illegal" (i.e., not in the looping sequence)
          - otherwise, we are in an unsupported case and we can output OUnsupported (see Step_analysis.observations) *)
  if List.is_empty inst_numbers then Step_analysis.Nothing { diverges }
  else
  (
    let word_of_bin s : Common.word_t = Int.of_string ("0b" ^ s) in
    let last_inst_number, instructions = List.fold
      inst_numbers
      ~init:(cfg.last_inst_number, [])
      ~f:(fun (lin, acc) inst_number ->
        (* The below min_elt_exn should never fail, since inst_numbers is not empty here *)
        let (ref_time_begin, _) = Option.value_exn (inst_cfg inst_number) in
        let end_config = inst_cfg (inst_number + 1) in
        let compute_cpu_mode t = if String.equal (Vcd.Signal.at_time sm_executing_map t) "0" then Output_internal.UM else Output_internal.PM in
        match end_config with
        | None ->
          Logs.debug (fun m -> m "Verilog.analyse_dump: folding over inst_numbers and found a RESET, outputting OReset.");
          lin, acc @ [ `Reset ]
        | Some (ref_time_end, _) ->
            (* Extract the list of all elements from e_state_map whose keys are >= ref_time_begin and < ref_time_end *)
            let e_status = List.map (Map.to_alist (Map.subrange e_state_map.tv ~lower_bound:(Incl ref_time_begin) ~upper_bound:(Excl ref_time_end))) ~f:snd in
            (* Extract the values of registers and memory, as the last value before ref_time_end *)
            let last_before (m : string Int.Map.t) t = snd (Option.value_exn (Map.closest_key m `Less_than t)) in
            let reg_val = last_before r4_map.tv ref_time_end in
            let gie_val = last_before gie_map.tv ref_time_end in
            let umem_val = last_before umem_map.tv ref_time_end in
            (* let pmem_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys pmem_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in *)
            let timerA_val = last_before timerA_map.tv ref_time_end in
            let k = (ref_time_end - ref_time_begin) / cfg.sim_cycle_ratio in
            let lin' = inst_number in
            Logs.debug (fun m -> m "===== cfg.last_inst_number %d, lin %d, lin' %d\n" cfg.last_inst_number lin lin');
            let instruction : Step_analysis.instruction = {
              mode_s = compute_cpu_mode ref_time_begin; mode_e = compute_cpu_mode ref_time_end;
              e_states = List.map e_status ~f:word_of_bin; gie = Bool.of_string_hum gie_val;
              r4 = word_of_bin reg_val; umem = word_of_bin umem_val; timerA = word_of_bin timerA_val; k } in
            lin', acc @ [ `Instruction instruction ]
        ) in
    Step_analysis.Instructions { last_inst_number; left_labels = left_labels'; instructions }
  )
)

(* mkdir -p, with the standard library *)
let rec mkdir_p dir =
  if not (Stdlib.Sys.file_exists dir) then (
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdir_p parent;
    try Stdlib.Sys.mkdir dir 0o755 with Sys_error _ when Stdlib.Sys.file_exists dir -> ())

let pre (cfg : t) =
  (match Logs.level () with
  | Some Logs.App -> (Format.printf "\x1B[1;33m.\x1B[0m"); Out_channel.flush stdout | _ -> ()
  );
  cfg := {
    !cfg with
      input_history = [];
      output_history = [];
      left_labels = [];
      (* last_time = 0; *)
      last_inst_number = 0;
      reentries = [];
  }

(* True if the output is a reti that resumes a (previously interrupted) enclave *)
let is_reentry ((ol, _, _) : output_t) =
  List.exists ol ~f:(function Output_internal.OReti p -> Output_internal.equal_mode_t p.mode PM | _ -> false)

(*
  An attacker that can resume an enclave with reti more than once (e.g., B3 on unpatched Sancus) can
  repeat the same piece of enclave execution indefinitely: traces are only bounded by the simulation
  timeout and, since each repetition makes the trace longer, they would make every repetition
  look like a new state. We call re-entry segment the part of a trace between two re-entries (see
  is_reentry), and identify the configuration after a segment with the one after an identical
  segment immediately preceding it, i.e., u x x behaves as u x, when
  - the two segments have the same inputs and outputs, and
  - the input generator is in the same place in the spec after each of them (Generator.key).
  This is done by restoring the configuration reached after the first segment.
*)
let collapse_repeated_reentry (cfg : cfg_t) : cfg_t =
  if not cfg.collapse_reentries then cfg
  else
    match cfg.reentries with
    | r1 :: r0 :: _ ->
      let segment (a : cfg_t) (b : cfg_t) =
        let from = List.length a.input_history and len = List.length b.input_history - List.length a.input_history in
        List.sub b.input_history ~pos:from ~len, List.sub b.output_history ~pos:from ~len in
      let (i1, o1), (i2, o2) = segment r0 r1, segment r1 cfg in
      if List.equal Input.equal i1 i2 && List.equal Output_internal.equal o1 o2 && String.equal r1.spec_key cfg.spec_key then (
        Logs.debug (fun m -> m "Verilog: collapsing a repeated re-entry segment of %d steps" (List.length i2));
        Prof.count "sul.collapsed_reentry";
        (* r1 was saved before being pushed: keep the stack as it is now, i.e., r1 :: r0 :: ... *)
        { r1 with reentries = cfg.reentries })
      else { cfg with reentries = cfg :: cfg.reentries }
    | _ -> { cfg with reentries = cfg :: cfg.reentries }

(* The Sancus input of a step: enclave atoms are victim inputs, the others the attacker's *)
let input_of_step (step : Alvie_backend.Backend.step) : Input.t =
  if String.equal step.section "enclave" then Input.IEnclave (Result.ok_or_failwith (Atom_value.to_enclave step.atom))
  else Input.IAttacker (Result.ok_or_failwith (Atom_value.to_attacker step.atom))

let print_input ~silent (i : Input.t) =
  if not silent then
  (match Logs.level () with
    | Some Logs.App -> Format.printf "[%s" (match i with
      (* NoInput is yellow *)
      | INoInput -> "\x1B[33m" ^ "_" ^ "\x1B[0m"
      (* Stuff that is exceptional, in red *)
      | IAttacker Attacker.CRst -> "\x1B[1;31m" ^ "•" ^ "\x1B[0m"
      | IAttacker Attacker.CRstNZ -> "\x1B[1;31m" ^ "Z" ^ "\x1B[0m"
      (* Stuff by the attacker, is blue *)
      | IAttacker (Attacker.CJmpIn _) -> "\x1B[34m" ^ "I" ^ "\x1B[0m"
      | IAttacker (Attacker.CCreateEncl _) -> "\x1B[34m" ^ "C" ^ "\x1B[0m"
      | IAttacker (Attacker.CTimerEnable _) -> "\x1B[34m" ^ "T" ^ "\x1B[0m"
      | IAttacker (Attacker.CStartCounting _) -> "\x1B[34m" ^ "SC" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst I_NOP) -> "\x1B[34m" ^ "N" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst I_DINT) -> "\x1B[34m" ^ "D" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_MOV _)) -> "\x1B[34m" ^ "M" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_ADD _)) -> "\x1B[34m" ^ "A" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_JMP _)) -> "\x1B[34m" ^ "JMP" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_JNZ _)) -> "\x1B[34m" ^ "JNZ" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_JZ _)) -> "\x1B[34m" ^ "JZ" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_PUSH _)) -> "\x1B[34m" ^ "P" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_NAMED _)) -> "\x1B[34m" ^ "NAMED" ^ "\x1B[0m"
      | IAttacker (Attacker.CInst (I_CMP _)) -> "\x1B[34m" ^ "=" ^ "\x1B[0m"
      | IAttacker (Attacker.CIfZ _) -> "\x1B[34m" ^ "IfZ" ^ "\x1B[0m"
      (* Stuff by the enclave, is green *)
      | IEnclave (Enclave.CInst I_NOP) -> "\x1B[32m" ^ "N" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst I_DINT) -> "\x1B[32m" ^ "D" ^ "\x1B[0m"
      | IEnclave (Enclave.CUbr) -> "\x1B[32m" ^ "U" ^ "\x1B[0m"
      | IEnclave (Enclave.CRst) -> "\x1B[32m" ^ "•" ^ "\x1B[0m"
      | IEnclave (Enclave.CBalancedIfZ _) -> "\x1B[32m" ^ "BIfZ" ^ "\x1B[0m"
      | IEnclave (Enclave.CIfZ _) -> "\x1B[32m" ^ "IfZ" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_MOV _)) -> "\x1B[32m" ^ "M" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_ADD _)) -> "\x1B[32m" ^ "A" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_CMP _)) -> "\x1B[32m" ^ "=" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_JMP _)) -> "\x1B[32m" ^ "JMP" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_JNZ _)) -> "\x1B[32m" ^ "JNZ" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_JZ _)) -> "\x1B[32m" ^ "JZ" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_PUSH _)) -> "\x1B[32m" ^ "P" ^ "\x1B[0m"
      | IEnclave (Enclave.CInst (I_NAMED _)) -> "\x1B[32m" ^ "NAMED" ^ "\x1B[0m"
      (* Reti is special, let it be magenta *)
      | IAttacker (Attacker.CReti) -> "\x1B[35m" ^ "R" ^ "\x1B[0m"
      ); Out_channel.flush stdout
     | _ -> ()
  ) else ()

let print_output ~silent (out : output_t) =
  if not silent then
  (match Logs.level () with
  | Some Logs.App ->
      let render_output_t o = (match o with
        (* Illegal is yellow *)
        (* | Output_internal.OTimeout -> "\x1B[33m" ^ "⏲" ^ "\x1B[0m" *)
        | Output_internal.OIllegal -> "\x1B[33m" ^ "†" ^ "\x1B[0m"
        | Output_internal.OUnsupported -> "\x1B[33m" ^ "?" ^ "\x1B[0m"
        (* Stuff that cannot be recovered in red *)
        | Output_internal.OReset -> "\x1B[1;31m" ^ "•" ^ "\x1B[0m"
        | Output_internal.OMaybeDiverge -> "\x1B[1;31m" ^ "∞" ^ "\x1B[0m"
        (* Stuff caused by the attacker, is blue *)
        | Output_internal.OJmpIn _ -> "\x1B[1;34m" ^ "i" ^ "\x1B[0m"
        | Output_internal.OSilent -> "\x1B[1;34m" ^ "s" ^ "\x1B[0m"
        (* Stuff caused by the enclave, is green *)
        | Output_internal.OJmpOut _ -> "\x1B[1;32m" ^ "o" ^ "\x1B[0m"
        | Output_internal.OTime _ -> "\x1B[1;32m" ^ "t" ^ "\x1B[0m"
        (* Reti is special, let it be magenta *)
        | Output_internal.OTime_Handle _ -> "\x1B[1;35m" ^ "th" ^ "\x1B[0m"
        | Output_internal.OJmpOut_Handle _ -> "\x1B[1;35m" ^ "oh" ^ "\x1B[0m"
        | Output_internal.OReti _ -> "\x1B[1;35m" ^ "r" ^ "\x1B[0m"
        (* | Output_internal.OReti_Time _ -> "\x1B[1;35m" ^ "rt" ^ "\x1B[0m"
        | Output_internal.OReti_JmpOut _ -> "\x1B[1;35m" ^ "ro" ^ "\x1B[0m" *)
      ) in
      Format.printf "%s]" (List.fold (fst3 out) ~init:"" ~f:(fun acc o -> acc ^ render_output_t o));
    ; Out_channel.flush stdout
   | _ -> ()
  ) else ()

(* The configuration after a step whose output is out (run or restored). The key of the place in the spec is
   computed only at re-entries, where collapse_repeated_reentry compares it: it is costly *)
let finish cfg (cfg' : cfg_t) (step : Alvie_backend.Backend.step) (out : output_t) =
  let (_, left_labels, last_inst_number) = out in
  cfg := { cfg' with last_inst_number; left_labels; output_history = cfg'.output_history @ [ out ] };
  if is_reentry out then (
    cfg := { !cfg with spec_key = Lazy.force step.key };
    cfg := collapse_repeated_reentry !cfg);
  (* A reset starts the test again: the simulation restarts from the initial state *)
  if List.mem (fst3 out) OReset ~equal:Output_internal.equal_element_t then pre cfg

(*
  With ALVIE_DUMP_PROGRAMS=dir, every program built goes to dir/programs/<md5>.s43 (once), with the configuration it is
  built with (its includes, pmem.x and pmem.sh) in dir/configs/<md5>/: the corpus of test/asm (tt_asm_golden record).
  The first line of a program names its configuration.
*)
let dump_program (cfg : cfg_t) code =
  match Sys.getenv "ALVIE_DUMP_PROGRAMS" with
  | None | Some "" -> ()
  | Some dir ->
    let files = [ "pmem_defs.asm"; "sancus_macros.asm"; "pmem.x"; "pmem.sh" ] in
    if List.for_all files ~f:(fun f -> Stdlib.Sys.file_exists (cfg.tmpdir ^ "/" ^ f)) then (
      let contents = List.map files ~f:(fun f -> (f, In_channel.read_all (cfg.tmpdir ^ "/" ^ f))) in
      let config = Md5.to_hex (Md5.digest_string (String.concat (List.map contents ~f:snd))) in
      let cdir = dir ^ "/configs/" ^ config in
      if not (Stdlib.Sys.file_exists cdir) then (
        mkdir_p cdir;
        List.iter contents ~f:(fun (f, c) -> Out_channel.write_all (cdir ^ "/" ^ f) ~data:c));
      let data = sprintf "; config %s\n%s" config code in
      mkdir_p (dir ^ "/programs");
      let file = dir ^ "/programs/" ^ Md5.to_hex (Md5.digest_string data) ^ ".s43" in
      if not (Stdlib.Sys.file_exists file) then Out_channel.write_all file ~data)

let run cfg (step : Alvie_backend.Backend.step) : output_t =
  Prof.time "sul.step(real)" @@ fun () ->
  let i = input_of_step step in
  Logs.debug (fun m -> m "\x1B[31mSimulator.step: %s (%s, position %d)\x1B[0m" (Input.show i) step.section step.position);
  print_input ~silent:step.silent i;
  let cfg' = { !cfg with input_history = !cfg.input_history @ [ i ] } in
  let template_code = In_channel.read_all cfg'.templatefile in
  let labels, code = Prof.time "sul.fill_template" (fun () -> fill_template template_code cfg' step) in
  Logs.debug (fun m -> m "filledfile: %s" cfg'.filledfile);
  Out_channel.write_all cfg'.filledfile ~data:code;
  dump_program cfg' code;
  (* Run the program on the target: the result finds the instructions of given labels in the trace *)
  let trace = match cfg'.target with
    | Verilator -> Ok (!verilator_run cfg')
    | Other { run; _ } -> Ok (run cfg') in
  let last_inst_number, left_labels, elements = match trace with
    | Error o -> cfg'.last_inst_number, [], [o]
    | Ok find ->
      let analyse labels = Step_analysis.observations ~last_inst_number:cfg'.last_inst_number (find labels) in
      let l_last_inst_number, l_left_labels, l_out = analyse labels in
      (* If we observed a reti, we need to re-perform the analysis on left_labels, otherwise we are done! *)
      match List.find l_out ~f:(fun el -> match el with Output_internal.OReti _ -> true | _ -> false) with
      | None -> l_last_inst_number, cfg'.left_labels @ l_left_labels, l_out
      | Some _ -> analyse (cfg'.left_labels @ labels) in
  let out = (elements, left_labels, last_inst_number) in
  finish cfg cfg' step out;
  print_output ~silent:step.silent out;
  out

let restore cfg (step : Alvie_backend.Backend.step) (out : output_t) =
  Prof.time "sul.step(dry)" @@ fun () ->
  let i = input_of_step step in
  print_input ~silent:step.silent i;
  let cfg' = { !cfg with input_history = !cfg.input_history @ [ i ] } in
  finish cfg cfg' step out;
  print_output ~silent:step.silent out

let post _ = ()
