(*
  The Sancus backend on the Verilog testbench of sancus-core-gap, simulated with Verilator: Step (included) and the
  target that clones the processor, compiles the testbench (or reuses a compilation, see with_simulator_cache),
  builds the programs with the toolchain when the assembler of ALVIE does not accept them, and runs the simulator,
  whose trace is its VCD dump (Step.analyse_dump). It needs the Unix library; Step runs anywhere.
*)
open! Core

include Step

let dbg_str () = match Logs.level () with | Some Logs.Debug -> "" | _ -> ">/dev/null 2>/dev/null"

(*
  Compiling the simulator takes most of the setup time of a SUL, and experiments compile the same
  processor over and over. Compiled simulators are kept in a cache directory (ALVIE_SIM_CACHE, by
  default <tmpdir>/simv-cache; ALVIE_SIM_CACHE=0 disables it), indexed by a digest of everything the
  compilation depends on: the processor sources as configured in r_tmpdir, ALVIE's testbench
  (alvie/bench), the stimulus, the compilation script, the Verilator version and the tracing option. A lock makes concurrent runs
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
      @ List.concat_map sources ~f:(fun f -> [ String.chop_prefix_exn f ~prefix:core; In_channel.read_all f ])
      (* ALVIE's testbench, which submit.f compiles before the one of sancus-core-gap *)
      @ List.concat_map (files (workingdir ^ "/../bench")) ~f:(fun f -> [ f; In_channel.read_all f ]))) in
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

let addr_of_label_script cfg l =
  (* Logs.debug (fun p -> p "Verilog.addr_of_label %s %s" cfg.pmem_elf l); *)
  Prof.time "sul.addr_of_label(script)" @@ fun () ->
  Int.of_string ("0x" ^ (String.substr_replace_all ~pattern:"\n" ~with_:"" (Shexp_process.eval Shexp_process.(pipe (run "bash" [cfg.get_symbolpos; cfg.pmem_elf; l]) read_all))))

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
  running the tools directly, instead of through two shell scripts. Without ~ihex, the program is not converted to
  IHEX (only the simulator loads it).
*)
let build_pmem ?(ihex = true) (cfg : cfg_t) =
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
    if ihex then ignore (run_process (pfx ^ "-objcopy") [ "-O"; "ihex"; t ^ "/pmem.elf"; t ^ "/pmem.ihex" ]);
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
  let native = assemble_native cfg in
  let res = match native with Some _ -> 0 | None -> Prof.time "sul.build_pmem" (fun () -> build_pmem cfg) in
  if res <> 0 then
    failwith (Format.sprintf "Error: %s returned %d." cfg.pmem_script res)
  else (
    Prof.time "sul.ihex2mem" (fun () ->
      let mem = cfg.tmpdir ^ "/" ^ cfg.basename ^ ".mem" in
      (match native with
       | Some img -> Out_channel.write_all mem ~data:(Msp430_asm.mem_file ~mem_size:(pmem_size cfg) img)
       | None -> ihex2mem ~ihex:(cfg.tmpdir ^ "/pmem.ihex") ~out:mem ~mem_size:(pmem_size cfg));
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
let rec build_program (cfg : cfg_t) =
  invalidate_symtab ();
  if Option.is_none (assemble_native cfg) then build_program_toolchain cfg

and build_program_toolchain (cfg : cfg_t) =
  (* build_pmem does not fail when the assembler or the linker does: without the old ELF file, a failed build is
     not taken for the program of the step *)
  (try Core_unix.unlink cfg.pmem_elf with Core_unix.Unix_error _ -> ());
  let res = Prof.time "sul.build_pmem" (fun () -> build_pmem ~ihex:false cfg) in
  if res <> 0 then failwith (Format.sprintf "Error: %s returned %d." cfg.pmem_script res);
  if not (Sys_unix.file_exists_exn cfg.pmem_elf) then
    failwith (Format.sprintf "Could not assemble or link the program of the step (%s): --debug shows the assembler and linker output." cfg.filledfile)

(* Step runs these for the target Verilator and for the labels missing from the table of symbols *)
let () =
  verilator_run := (fun cfg ->
      match run_simulator cfg with
      | Ok (diverges, d) -> fun labels -> analyse_dump diverges cfg labels d
      | Error (o : Output_internal.element_t) -> fun _ -> failwithf "Simulator: %s" (Output_internal.show_element_t o) ());
  addr_of_label_fallback := addr_of_label_script
