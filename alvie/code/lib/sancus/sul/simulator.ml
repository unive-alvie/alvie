(*
  The Sancus backend (Alvie_backend.Backend.S): it generates the program of a test from the programs of the sections
  that Core gives, runs it on a target, and turns the trace of the input's instructions into observations. Verilog
  is its adapter to the learner.

  The target is where the program runs (target): the Verilog testbench of sancus-core-gap, simulated with
  Verilator, whose trace is its VCD dump (analyse_dump); or another target given by a plugin that reuses this
  backend, such as the FPGA board of ALVIE/Sancus-FPGA (Sancus_fpga). Everything else does not depend on the target:
  the program of a step (fill_template), its build (build_program), the bookkeeping, re-entries, and the
  observations of the instructions found (Step_analysis).
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


let dbg_str () = match Logs.level () with | Some Logs.Debug -> "" | _ -> ">/dev/null 2>/dev/null"

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

(*
  Compiling the simulator takes most of the setup time of a SUL, and experiments compile the same
  processor over and over. Compiled simulators are kept in a cache directory (ALVIE_SIM_CACHE, by
  default <tmpdir>/simv-cache; ALVIE_SIM_CACHE=0 disables it), indexed by a digest of everything the
  compilation depends on: the processor sources as configured in r_tmpdir, the stimulus, the
  compilation script, the Verilator version and the tracing option. A lock makes concurrent runs
  needing the same simulator compile it once.
*)
let with_simulator_cache ~tmpdir ~workingdir ~r_tmpdir ~basename ~verilog_compile ~submitfile compile =
  match Sys.getenv "ALVIE_SIM_CACHE" with
  | Some ("0" | "") -> compile ()
  | cache_dir ->
    let cache_dir = Option.value cache_dir ~default:(tmpdir ^ "/simv-cache") in
    let rec files dir =
      List.concat_map (List.sort ~compare:String.compare (Sys_unix.ls_dir dir)) ~f:(fun f ->
        let path = dir ^ "/" ^ f in
        if Sys_unix.is_directory_exn path then files path else [ path ]) in
    let core = r_tmpdir ^ "/sancus-core-gap/core" in
    let sources = files (core ^ "/rtl") @ files (core ^ "/bench") in
    let verilator_version = In_channel.input_all (Core_unix.open_process_in "verilator --version 2>&1") in
    let digest = Md5.digest_string (String.concat ~sep:"\000" (
      [ verilator_version; Option.value (Sys.getenv "ALVIE_FULL_TRACE") ~default:"";
        In_channel.read_all (workingdir ^ "/../src/" ^ basename ^ ".v");
        In_channel.read_all verilog_compile; In_channel.read_all submitfile ]
      @ List.concat_map sources ~f:(fun f -> [ String.chop_prefix_exn f ~prefix:core; In_channel.read_all f ]))) in
    let cached = cache_dir ^ "/" ^ Md5.to_hex digest ^ ".simv" in
    let simv_dir = r_tmpdir ^ "/sancus-core-gap/obj_dir" in
    Core_unix.mkdir_p cache_dir;
    let lock = Core_unix.openfile (cached ^ ".lock") ~mode:[ O_CREAT; O_RDWR ] ~perm:0o644 in
    Exn.protect ~finally:(fun () -> Core_unix.close lock) ~f:(fun () ->
      Core_unix.flock_blocking lock Core_unix.Flock_command.lock_exclusive;
      if Sys_unix.file_exists_exn cached then (
        Logs.debug (fun m -> m "Reusing the compiled simulator %s" cached);
        Core_unix.mkdir_p simv_dir;
        Out_channel.write_all (simv_dir ^ "/simv") ~data:(In_channel.read_all cached);
        Core_unix.chmod (simv_dir ^ "/simv") ~perm:0o755;
        0)
      else
        let res = compile () in
        if res = 0 then (
          Out_channel.write_all (cached ^ ".tmp") ~data:(In_channel.read_all (simv_dir ^ "/simv"));
          Core_unix.rename ~src:(cached ^ ".tmp") ~dst:cached);
        res)

let make ~sancus_repo ~sancus_master_key ~commit ~workingdir ~tmpdir ~basename ~verilog_compile ~get_symbolpos ~pmem_script ~simulate_script ~submitfile ~templatefile ~pmem_elf ~filledfile ~dumpfile ~ignore_interrupts ?(sim_cycle_ratio = 500) ?(collapse_reentries = true) ?(target = Verilator) () =
  Sys_unix.chdir workingdir;
  (* Create tmpdir and a temporary dir inside tmpdir *)
  (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
  let r_tmpdir = Core_unix.mkdtemp (tmpdir ^ "/") in
  Logs.debug (fun m -> m "Chosen temporary directory: %s" r_tmpdir);
  let cloned_repo = r_tmpdir ^ "/sancus-core-gap" in
  (match target with
   | Verilator ->
     (* Clone Sancus so a submodule source retains a valid Git directory. A local clone hard-links the objects, which
        fails when the temporary directory is on another file system than the checkout (e.g., --tmpdir /tmp, or a
        Docker bind mount): then the objects are copied instead. *)
     Logs.debug (fun m -> m "Cloning: %s => %s/sancus-core-gap" sancus_repo r_tmpdir);
     let clone mode = Sys_unix.command (Format.sprintf "git clone %s %s %s %s"
         mode (Filename.quote sancus_repo) (Filename.quote cloned_repo) (dbg_str ())) = 0 in
     if not (clone "--local") then (
       Logs.debug (fun m -> m "The local clone failed, copying the objects instead");
       ignore (Sys_unix.command (Format.sprintf "rm -rf %s" (Filename.quote cloned_repo)));
       if not (clone "--no-hardlinks") then
         failwith (Format.sprintf "Could not clone Sancus repository from %s into %s. Check that it is a git checkout (git submodule update --init sancus-core-gap) and that --tmpdir is writable; --debug shows the git output."
           sancus_repo r_tmpdir));
     (* The clone is needed until the end of the run (the simulator is compiled in it), and not after: the VCD dump
        and the programs are outside it *)
     Stdlib.at_exit (fun () -> ignore (Sys_unix.command (Format.sprintf "rm -rf %s" (Filename.quote cloned_repo))));
     (* Use the required commit *)
     Logs.debug (fun m -> m "Checking out the required commit: %s" commit);
     if Sys_unix.command (Format.sprintf "cd %s; git checkout %s %s"
         (Filename.quote cloned_repo) (Filename.quote commit) (dbg_str ())) <> 0 then
       failwith (Format.sprintf "Could not check out Sancus commit %s from %s. Check the commit name; a shallow checkout misses older commits: run git -C %s fetch --unshallow (CI: actions/checkout with fetch-depth: 0)."
         commit sancus_repo (Filename.quote sancus_repo));
     (* Create the config file -- note that the minimum size for the key seems to be 20 bytes *)
     Logs.debug (fun m -> m "Configuring Sancus with key: %s" sancus_master_key);
     let security = Int.max 20 (4 * String.length sancus_master_key) in
     assert (Sys_unix.command (Format.sprintf "%s/../scripts/build_config.sh \"%s/sancus-core-gap/\" %d %s %s" workingdir r_tmpdir security sancus_master_key (dbg_str ())) = 0)
   | Other _ ->
     (* Another target runs no simulator: building the programs (build_pmem) needs only the memory sizes and the
        templates of the linker script and of the definitions of the commit, read from the repository without a
        clone (the configuration of build_config.sh is for the simulated processor) *)
     List.iter [ "core/rtl/verilog/openMSP430_defines.v"; "core/sim/rtl_sim/bin/template.x"; "core/sim/rtl_sim/bin/template_defs.asm" ]
       ~f:(fun path ->
         let dst = cloned_repo ^ "/" ^ path in
         Core_unix.mkdir_p (Filename.dirname dst);
         if Sys_unix.command (Format.sprintf "git -C %s show %s > %s %s" (Filename.quote sancus_repo)
             (Filename.quote (commit ^ ":" ^ path)) (Filename.quote dst)
             (match Logs.level () with Some Logs.Debug -> "" | _ -> "2>/dev/null")) <> 0 then
           failwith (Format.sprintf "Could not read %s of Sancus commit %s from %s. Check the commit name, and that %s is a git checkout (git submodule update --init sancus-core-gap); a shallow checkout misses older commits: run git -C %s fetch --unshallow."
             path commit sancus_repo sancus_repo (Filename.quote sancus_repo))));
  (* Load the submit.f file *)
  let submitfile_filled = r_tmpdir ^ "/submit.f" in
  let submit_template = In_channel.read_all submitfile in
  let submit_filled =
    String.substr_replace_all submit_template ~pattern:"{{tmp_dir}}" ~with_:r_tmpdir in
      Out_channel.write_all submitfile_filled ~data:submit_filled;
  (* Compile the Verilog testbench beforehand (or reuse a previous compilation of the same sources); other targets
     need no simulator *)
  let res = match target with
    | Other _ -> 0
    | Verilator ->
      let compile () = Sys_unix.command (Format.sprintf "%s \"%s\" %s %s %s" verilog_compile r_tmpdir basename submitfile_filled ">/dev/null 2>/dev/null") in
      Prof.time "sul.compile_simulator" (fun () ->
        with_simulator_cache ~tmpdir ~workingdir ~r_tmpdir ~basename ~verilog_compile ~submitfile compile) in
  if res <> 0 then
    failwith (Format.sprintf "Error: %s returned %d." verilog_compile res)
  else (
    (* If compilation went well, build the configuration and return it *)
    ref (make_cfg_t
      ~workingdir
      ~tmpdir:r_tmpdir
      ~basename
      ~get_symbolpos
      ~pmem_script
      ~simulate_script
      ~templatefile
      ~pmem_elf:(r_tmpdir ^ "/" ^ pmem_elf)
      ~filledfile:(r_tmpdir ^ "/" ^ filledfile)
      ~dumpfile:(r_tmpdir ^ "/" ^ dumpfile)
      ~sim_cycle_ratio
      ~input_history:[]
      ~output_history:[]
      ~left_labels:[]
      (* ~last_time:0  *)
      ~last_inst_number:0
      ~ignore_interrupts:ignore_interrupts
      ~collapse_reentries
      ~reentries:[]
      ~spec_key:""
      ~target
      ())
  )

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

let addr_of_label_script cfg l =
  (* Logs.debug (fun p -> p "Verilog.addr_of_label %s %s" cfg.pmem_elf l); *)
  Prof.time "sul.addr_of_label(script)" @@ fun () ->
  Int.of_string ("0x" ^ (String.substr_replace_all ~pattern:"\n" ~with_:"" (Shexp_process.eval Shexp_process.(pipe (run "bash" [cfg.get_symbolpos; cfg.pmem_elf; l]) read_all))))

(*
  Symbols of the last built pmem.elf: name -> list of addresses.
  Reading the whole table with a single nm invocation avoids spawning a shell per label lookup.
  It must be invalidated whenever pmem.elf is rebuilt (see run_simulator).
*)
let symtab : (string * int list String.Table.t) option ref = ref None

let invalidate_symtab () = symtab := None

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
  (* Missing or ambiguous symbols: fall back to the original lookup, to preserve its exact behaviour *)
  | _ -> addr_of_label_script cfg l

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

(*
  Native version of scripts/ihex2mem.tcl: converts the IHEX file produced by build_pmem into the
  Verilog MEMH file loaded by the simulator, reproducing the output of the Tcl script exactly.
*)
let ihex2mem ~ihex ~out ~mem_size =
  (* Tcl's [string range s first last], with the clamping behaviour of out-of-range indices *)
  let string_range str first last =
    let first = Int.max first 0 and last = Int.min last (String.length str - 1) in
    if first > last then "" else String.sub str ~pos:first ~len:(last - first + 1) in
  let hex2dec v = Int.of_string ("0x" ^ v) in
  let num_word = (mem_size / 2) - 1 in
  let mem_arr = Array.create ~len:(num_word + 1) "0000" in
  let mem_offset = 65536 - mem_size in
  In_channel.with_file ihex ~f:(fun ic ->
    In_channel.iter_lines ic ~f:(fun line ->
      let byte_count = hex2dec (string_range line 1 2) in
      let start_addr = hex2dec (string_range line 3 6) - mem_offset in
      if String.equal (string_range line 7 8) "00" then (
        let i = ref 0 in
        while !i < byte_count * 2 do
          let mem_msb = string_range line (!i + 11) (!i + 12) in
          let mem_lsb = string_range line (!i + 9) (!i + 10) in
          (* Tcl's integer division rounds towards negative infinity *)
          let addr = Int.( /% ) (start_addr + (!i / 2)) 2 in
          if addr >= 0 && addr <= num_word then mem_arr.(addr) <- mem_msb ^ mem_lsb;
          i := !i + 4
        done)));
  let buf = Buffer.create ((num_word + 1) * 6) in
  Array.iteri mem_arr ~f:(fun i v ->
    if i % 16 = 0 then Buffer.add_string buf (sprintf "\n@%04x " i);
    (* i.e., sprintf " %2s" v *)
    Buffer.add_char buf ' ';
    for _ = String.length v to 1 do Buffer.add_char buf ' ' done;
    Buffer.add_string buf v);
  Buffer.add_string buf "\n\n";
  Out_channel.write_all out ~data:(Buffer.contents buf)

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

(* Runs prog (looked up in PATH) with args, without a shell; returns its exit code and standard output *)
let run_process ?working_dir prog args =
  let p = Core_unix.create_process_env ?working_dir ~prog ~args ~env:(`Extend []) () in
  Core_unix.close p.stdin;
  let stdout = In_channel.input_all (Core_unix.in_channel_of_descr p.stdout) in
  let stderr = In_channel.input_all (Core_unix.in_channel_of_descr p.stderr) in
  Core_unix.close p.stdout; Core_unix.close p.stderr;
  let code = match Core_unix.waitpid p.pid with
    | Ok () -> 0
    | Error (`Exit_non_zero n) -> n
    | Error (`Signal _) -> 128 in
  if code <> 0 then Logs.debug (fun m -> m "%s exited with %d: %s" prog code stderr);
  code, stdout

let toolchain_prefix = lazy (if Sys_unix.command "command -v msp430-gcc >/dev/null 2>&1" = 0 then "msp430" else "msp430-elf")

(*
  Same as scripts/build_pmem --no-mem once its setup has been done in cfg.tmpdir (and outside of debug
  mode, where the scripts also produce assembly listings): assemble, link and convert the program by
  running the tools directly, instead of through two shell scripts.
*)
let build_pmem (cfg : cfg_t) =
  let setup_done = Sys_unix.file_exists_exn (cfg.tmpdir ^ "/.build_pmem_setup_done") in
  match Logs.level () with
  | Some Logs.Debug -> Sys_unix.command (Format.sprintf "%s \"%s\" %s --no-mem %s" cfg.pmem_script cfg.tmpdir cfg.basename (dbg_str ()))
  | _ when not setup_done -> Sys_unix.command (Format.sprintf "%s \"%s\" %s --no-mem %s" cfg.pmem_script cfg.tmpdir cfg.basename (dbg_str ()))
  | _ ->
    let pfx = Lazy.force toolchain_prefix and t = cfg.tmpdir in
    Out_channel.write_all (t ^ "/pmem.s43") ~data:(In_channel.read_all (t ^ "/" ^ cfg.basename ^ ".s43"));
    let secret = Option.value (Sys.getenv "__SECRET") ~default:"" in
    (* As in asm2ihex.sh, failures of the single tools do not make the build fail *)
    ignore (run_process (pfx ^ "-as") [ "-I"; "../../src/gap-attacks"; "-I"; t; "--defsym"; "__SECRET=" ^ secret; t ^ "/pmem.s43"; "-o"; t ^ "/pmem.o" ]);
    ignore (run_process (pfx ^ "-ld") [ "-T"; t ^ "/pmem.x"; t ^ "/pmem.o"; "-o"; t ^ "/pmem.elf" ]);
    ignore (run_process (pfx ^ "-objcopy") [ "-O"; "ihex"; t ^ "/pmem.elf"; t ^ "/pmem.ihex" ]);
    0

(* Same as scripts/simulate, running the simulator directly: 0 on success, 1 if the stimulus did not
   complete, 2 on timeout, 3 on any other failure *)
let simulate (cfg : cfg_t) =
  match Logs.level () with
  | Some Logs.Debug -> Sys_unix.command (Format.sprintf "%s \"%s\" %s %s" cfg.simulate_script cfg.tmpdir cfg.basename (dbg_str ()))
  | _ ->
    let _, out = run_process ~working_dir:cfg.tmpdir "sancus-core-gap/obj_dir/simv" [] in
    if String.is_substring out ~substring:"SIMULATION FAILED" then
      (if String.is_substring out ~substring:"the verilog stimulus didn't complete" then 1
       else if String.is_substring out ~substring:"simulation Timeout" then 2
       else 3)
    else 0

let run_simulator (cfg : cfg_t) =
  (* Call build_pmem to compile and link the code *)
  invalidate_symtab ();
  let res = Prof.time "sul.build_pmem" (fun () -> build_pmem cfg) in
  if res <> 0 then
    failwith (Format.sprintf "Error: %s returned %d." cfg.pmem_script res)
  else (
    Prof.time "sul.ihex2mem" (fun () ->
      let mem = cfg.tmpdir ^ "/" ^ cfg.basename ^ ".mem" in
      ihex2mem ~ihex:(cfg.tmpdir ^ "/pmem.ihex") ~out:mem ~mem_size:(pmem_size cfg);
      (* The simulator loads pmem.mem (scripts/simulate copies it) *)
      Out_channel.write_all (cfg.tmpdir ^ "/pmem.mem") ~data:(In_channel.read_all mem));
    (* Invoke the simulator *)
    let res = Prof.time "sul.simulate" (fun () -> simulate cfg) in
    (* (match Logs.level () with | Some Logs.Debug -> assert (Sys_unix.command (Format.sprintf "cp %s %s" cfg.dumpfile cfg.workingdir) = 0) | _ -> ()); *)
    if res = 1 then
      failwith "Simulator: Stimulus did not complete!"
    (* else if res = 2 then
      Result.Error (Output_internal.OMaybeDiverge) *)
    else if res = 3 then
      failwith "Simulator: Unexpected error :("
    else
      (* If res = 2, simulation diverged and we signal it! *)
      Result.Ok (res = 2, Prof.time "sul.vcd_parse" (fun () -> Vcd.vcd ~signals:analysed_signals cfg.dumpfile)))

(* Builds the program of the step (cfg.filledfile) into cfg.pmem_elf, for another target than the simulator *)
let build_program (cfg : cfg_t) =
  invalidate_symtab ();
  (* build_pmem does not fail when the assembler or the linker does: without the old ELF file, a failed build is
     not taken for the program of the step *)
  (try Core_unix.unlink cfg.pmem_elf with Core_unix.Unix_error _ -> ());
  let res = Prof.time "sul.build_pmem" (fun () -> build_pmem cfg) in
  if res <> 0 then failwith (Format.sprintf "Error: %s returned %d." cfg.pmem_script res);
  if not (Sys_unix.file_exists_exn cfg.pmem_elf) then
    failwith (Format.sprintf "Could not assemble or link the program of the step (%s): --debug shows the assembler and linker output." cfg.filledfile)

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
  (* Run the program on the target: the result finds the instructions of given labels in the trace *)
  let trace = match cfg'.target with
    | Verilator -> Result.map (run_simulator cfg') ~f:(fun (diverges, d) labels -> analyse_dump diverges cfg' labels d)
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
