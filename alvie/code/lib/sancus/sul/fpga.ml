open! Core

open Inputgen
open Common

open Attacker
open Enclave

type input_t = Input.t [@@deriving ord,sexp]
type output_t = Output_internal.t [@@deriving ord,sexp]
type label_t = string*string [@@deriving sexp,ord]


let dbg_str () = match Logs.level () with | Some Logs.Debug -> "" | _ -> ">/dev/null 2>/dev/null"

(* ── Persistent Python daemon channels (one FPGA session at a time) ──────── *)
(* fpga_daemon holds (stdin_oc, stdout_ic) for fpga_daemon.py *)
let fpga_daemon : (Stdlib.out_channel * Stdlib.in_channel) option ref = ref None

let show_mode m = match m with `PM -> "PM" | `UM -> "UM"

let show_e_state e = match e with `NO_SM -> "NO_SM" | `OTHER -> "OTHER" | `RETI -> "RETI" | `PP_JMPOUT -> "PP_JMPOUT" | `HANDLE -> "HANDLE"

type trace_entry = {
  pc : int;
  inst_number : int;
  irq : int;
  sm_executing : int;
  e_state : int;
  r4 : int;
  gie : int;
  timerA : int;
  umem : int;
}

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
  (* This field describes the attack *)
  initial_spec : spec_dfa;
  (* This is the parameter to convert "absolute" time into cycles *)
  sim_cycle_ratio : int;
  (* The following fields collect the history of actions of each portion of code, i.e., enclave/isr/prepare/cleanup *)
  enclave_history : Enclave.t;
  ca_history : Attacker.t;
  (* Since the above fields don't collect the outputs and the actual interleaving of actions, we also keep overall I/O histories *)
  input_history : input_t list;
  output_history : output_t list;
  (* Finally, we also keep track of the instructions we still need to analyze *)
  left_labels : label_t list;
  (* last_time : int; *)
  last_inst_number : int;
  ignore_interrupts : bool;
} [@@deriving ord,sexp,make]

type t = cfg_t ref

let clone s = ref { !s with last_inst_number = !s.last_inst_number}

let make ~sancus_repo ~sancus_master_key:_ ~commit:_ ~workingdir ~tmpdir ~basename ~verilog_compile:_ ~get_symbolpos ~pmem_script ~simulate_script ~submitfile:_ ~templatefile ~pmem_elf ~filledfile ~dumpfile ~initial_spec ~ignore_interrupts ?(sim_cycle_ratio = 500) () =
  let fpga_port = Option.value (Sys.getenv "FPGA_PORT") ~default:"/dev/ttyUSB1" in
  Sys_unix.chdir workingdir;
  (* Create tmpdir and a temporary dir inside tmpdir *)
  (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
  let r_tmpdir = Core_unix.mkdtemp (tmpdir ^ "/") in
  Logs.debug (fun m -> m "Chosen temporary directory: %s" r_tmpdir);
  (* Program the FPGA if FPGA_TCL is set; skip if already programmed *)
  (match Sys.getenv "FPGA_TCL" with
  | Some tcl_path ->
      let tcl_dir = Filename.dirname tcl_path in
      let tcl_file = Filename.basename tcl_path in
      Logs.debug (fun m -> m "Programming FPGA with: %s" tcl_path);
      assert (Sys_unix.command (Format.sprintf "cd \"%s\" && vivado -mode batch -source %s %s" tcl_dir tcl_file (dbg_str ())) = 0)
  | None -> Logs.debug (fun m -> m "FPGA_TCL not set, skipping FPGA programming (assuming already programmed)"));
  (* Run once-per-session FPGA build setup (pmem.h, linker script) using the live checkout *)
  assert (Sys_unix.command (Format.sprintf "%s/../scripts/setup_fpga.sh \"%s\" \"%s\" %s" workingdir r_tmpdir sancus_repo (dbg_str ())) = 0);
  (* Spawn the persistent Python daemon that holds the serial port open at 5 Mbaud *)
  let daemon_cmd = Format.sprintf "python3 %s/../scripts/fpga_daemon.py %s" workingdir fpga_port in
  Logs.debug (fun m -> m "Spawning FPGA daemon: %s" daemon_cmd);
  let (daemon_ic, daemon_oc) = Caml_unix.open_process daemon_cmd in
  (match Stdlib.input_line daemon_ic with
  | "READY" -> Logs.debug (fun m -> m "FPGA daemon ready on port %s" fpga_port)
  | line    -> failwith (Format.sprintf "FPGA daemon failed to start: %s" line));
  fpga_daemon := Some (daemon_oc, daemon_ic);
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
    ~initial_spec
    ~sim_cycle_ratio
    ~enclave_history:(C_Enclave [])
    ~ca_history:(C_ISR [], C_Prepare [], C_Cleanup [])
    ~input_history:[]
    ~output_history:[]
    ~left_labels:[]
    ~last_inst_number:0
    ~ignore_interrupts:ignore_interrupts
    ())

let update_cfg mode curr_spec_dfa_mode cfg i =
  let ctor a = match mode with `Label -> Label a | `NoLabel -> NoLabel a in
  let open Attacker in
  let _attack_update (C_ISR isr, C_Prepare prepare, C_Cleanup cleanup) mode i =
    let a () = (match i with | Input.IAttacker a -> [ ctor a ] | _ -> []) in
      match mode with
      | `Enclave | `Invalid | `Finished -> (C_ISR isr, C_Prepare prepare, C_Cleanup cleanup)
      | `ISR_toPM | `ISR_toUM -> (C_ISR (isr @ a ()), C_Prepare prepare, C_Cleanup cleanup)
      | `Prepare -> (C_ISR isr, C_Prepare (prepare @ a ()), C_Cleanup cleanup)
      | `Cleanup -> (C_ISR isr, C_Prepare prepare, C_Cleanup (cleanup @ a ())) in
  let _enclave_update (Enclave.C_Enclave enclave_history) mode i =
    let e () = (match i with | Input.IEnclave e -> [ ctor e ] | _ -> []) in
      match mode with
      | `Enclave -> Enclave.C_Enclave (enclave_history @ e ())
      | `ISR_toPM | `ISR_toUM | `Prepare | `Cleanup | `Invalid | `Finished -> Enclave.C_Enclave enclave_history in
  let res = { cfg with
      input_history = cfg.input_history @ [i];
      enclave_history = (_enclave_update cfg.enclave_history curr_spec_dfa_mode i);
      ca_history = (_attack_update cfg.ca_history curr_spec_dfa_mode i);
  } in
  res

let fill_template template_code (cfg : cfg_t) =
  (* Compile the "high-level" actions into actual code *)
  Common.reset_last_used_idx (); (* FIXME: this is very bad, but that's the easiest thing; We need to reset the index after each experiment *)
  let full_history = Inputgen.intersperse_lists cfg.input_history cfg.output_history in
  let relevant_enclave (Enclave.C_Enclave eh) =
    let last_encl_segment = List.take_while
      (List.rev full_history)
      ~f:(fun io ->
        match io with
        | Inputgen.Out (ol, _, _) when List.exists ol ~f:(fun o -> match o with | OJmpIn _ -> true | _ -> false)
            -> false
        | _ -> true) in
    let curr_encl_segment = List.take_while
      (List.rev full_history)
      ~f:(fun io ->
        match io with
        | Inputgen.Out (ol, _, _) when List.exists ol ~f:(fun o -> match o with | OJmpIn _ | OReti _ -> true | _ ->    false)
            -> false
        | _ -> true) in
    (* If the two segments are the same, it means we've never interrupted the enclave so return the last part of eh *)
    if List.equal Poly.equal last_encl_segment curr_encl_segment then
      (
        let filt = List.rev (List.filter_map last_encl_segment ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None)) in
        let filt_len = List.length filt in
        let res = (List.drop eh (List.length eh - filt_len)) in
        Logs.debug (fun p -> p "eh   enclave: %s" ([%derive.show: Enclave.atom_t annot list] eh));
        Logs.debug (fun p -> p "res  enclave: %s" ([%derive.show: Enclave.atom_t annot list] res));
        Logs.debug (fun p -> p "filt enclave: %s" ([%derive.show: Enclave.atom_t list] filt));
        assert(List.for_all2_exn res filt ~f:(fun (NoLabel e | Label e) f -> Enclave.equal_atom_t e f));
        Enclave.C_Enclave res
      )
    else
      (
      let filt_last = List.filter_map last_encl_segment ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None) in
      let filt_last_len = List.length filt_last in
      let res_last = (List.drop eh (List.length eh - filt_last_len)) in
      let last_encl_segment = List.take_while
        (List.rev last_encl_segment)
        ~f:(fun io ->
          match io with
          | Inputgen.Out (ol, _, _) when List.exists ol ~f:(fun o -> match o with | OJmpIn _ | OReti _ -> true | _ -> false)
              -> false
          | _ -> true) in
      let filt_last = (List.filter_map last_encl_segment ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None)) in
      let filt_curr = List.rev (List.filter_map curr_encl_segment ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None)) in
      let filt_last_len = List.length filt_last in
      let filt_curr_len = List.length filt_curr in
      let res = (List.take res_last filt_last_len) @ (List.drop eh (List.length eh - filt_curr_len)) in
      Logs.debug (fun p -> p "eh   enclave: %s" ([%derive.show: Enclave.atom_t annot list] eh));
      Logs.debug (fun p -> p "res  enclave: %s" ([%derive.show: Enclave.atom_t annot list] res));
      Logs.debug (fun p -> p "filt last enclave: %s" ([%derive.show: Enclave.atom_t list] filt_last));
      Logs.debug (fun p -> p "filt curr enclave: %s" ([%derive.show: Enclave.atom_t list] filt_curr));
      assert(List.for_all2_exn res (filt_last @ filt_curr) ~f:(fun (NoLabel e | Label e) f -> Enclave.equal_atom_t e f));
      let completing_suffix = List.drop_while
        (List.rev full_history)
        ~f:(fun io ->
          match io with
          | Inputgen.Out (ol, _, _) when List.exists ol ~f:(fun o -> match o with | OJmpOut _ | OJmpOut_Handle _ -> true | _ -> false)
              -> false
          | _ -> true) in
      let completing_suffix = List.rev (List.take_while
        completing_suffix
        ~f:(fun io ->
          match io with
          | Inputgen.Out (ol, _, _) when List.exists ol ~f:(fun o -> match o with | OJmpIn _ -> true | _ -> false)
              -> false
          | _ -> true)) in
      Logs.debug (fun p -> p "completing_suffix: %s" ([%derive.show: observable_t list] completing_suffix));
      let completing_suffix_filt = List.filter_map completing_suffix ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None) in
      let completing_suffix_res = List.map ~f:(fun a -> NoLabel a) (List.drop completing_suffix_filt (List.length res)) in
      Enclave.C_Enclave (res @ completing_suffix_res)
    ) in
  let relevant_isr al =
    let curr_isr = List.rev (List.take_while (List.rev al) ~f:(fun a -> match a with NoLabel Attacker.CReti | NoLabel (Attacker.CJmpIn _) -> false | _ -> true)) in
    Logs.debug (fun p -> p "Curr ISR: %s" ([%derive.show: Attacker.atom_t annot list] curr_isr));
    let first_isr = List.rev (List.fold_until al ~init:[] ~f:(fun acc_isr a -> match a with Label Attacker.CReti | NoLabel Attacker.CReti | Label (Attacker.CJmpIn _) | NoLabel (Attacker.CJmpIn _) -> Stop (a::acc_isr) | _ -> Continue (a::acc_isr)) ~finish:(fun isr -> isr)) in
    Logs.debug (fun p -> p "First ISR: %s" ([%derive.show: Attacker.atom_t annot list] first_isr));
    let actual_isr = curr_isr @ List.drop first_isr (List.length curr_isr) in
        actual_isr in
  let relevant_cleanup al =
    if List.is_empty al then []
    else
    (
      List.rev (List.take_while (List.rev (List.drop_last_exn al)) ~f:(function (Label Attacker.CReti | NoLabel Attacker.CReti | Label (Attacker.CJmpIn _) | NoLabel (Attacker.CJmpIn _)) -> false | _ -> true))@[List.last_exn al]
    )
  in
  let enclave_labels, enclave_code = Enclave.compile (relevant_enclave cfg.enclave_history) in
  Logs.debug (fun p -> p "Enclave labels: %s" ([%derive.show: (string*string) list] enclave_labels));
  Logs.debug (fun p -> p "Enclave code: %s" ([%derive.show: string list] enclave_code));
  let (C_ISR ai_list, C_Prepare ap_list, C_Cleanup ac_list) = cfg.ca_history in
  let attacker_labels, isr_code, prepare_code, cleanup_code = Attacker.compile ~ignore_interrupts:cfg.ignore_interrupts (C_ISR (relevant_isr ai_list), C_Prepare ap_list, C_Cleanup (relevant_cleanup ac_list)) in
  let code = String.substr_replace_all template_code ~pattern:"; [@inst_isr]" ~with_:(String.concat ~sep:"\n\t" isr_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_pre]" ~with_:(String.concat ~sep:"\n\t" prepare_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_post]" ~with_:(String.concat ~sep:"\n\t" cleanup_code) in
  let code = String.substr_replace_all code ~pattern:"; [@inst_victim]" ~with_:(String.concat ~sep:"\n\t" enclave_code) in
    attacker_labels @ enclave_labels, code

let addr_of_label cfg l =
  Int.of_string ("0x" ^ (String.substr_replace_all ~pattern:"\n" ~with_:"" (Shexp_process.eval Shexp_process.(pipe (run "bash" [cfg.get_symbolpos; cfg.pmem_elf; l]) read_all))))

let ms_since t0 =
  let open Int63 in
  to_float (Time_now.nanoseconds_since_unix_epoch () - t0) /. 1_000_000.0

let run_fpga_script (cfg : cfg_t) =
  (* Use lightweight per-step script: msp430-as + msp430-ld only *)
  let build_pmem_fpga = Format.sprintf "%s/../scripts/build_pmem_fpga" cfg.workingdir in
  let t0 = Time_now.nanoseconds_since_unix_epoch () in
  let res = Sys_unix.command (Format.sprintf "%s \"%s\" %s %s" build_pmem_fpga cfg.tmpdir cfg.basename (dbg_str ())) in
  Logs.info (fun m -> m "[PERF] build_pmem_fpga: %.1f ms" (ms_since t0));
  if res <> 0 then
    failwith (Format.sprintf "Error: build_pmem_fpga returned %d." res)
  else (
    let (daemon_oc, daemon_ic) = match !fpga_daemon with Some ch -> ch | None -> failwith "FPGA daemon not running" in
    let query breakpoint =
      Logs.debug (fun m -> m "FPGA daemon query: elf=%s bp=%d" cfg.pmem_elf breakpoint);
      let tq = Time_now.nanoseconds_since_unix_epoch () in
      (* Send request to daemon: "elf_path inst_number\n" *)
      Stdlib.output_string daemon_oc (Format.sprintf "%s %d\n" cfg.pmem_elf breakpoint);
      Stdlib.flush daemon_oc;
      (* Read response lines until "DONE" *)
      let rec collect acc =
        let line = Stdlib.input_line daemon_ic in
        if String.equal line "DONE" then List.rev acc
        else collect (line :: acc)
      in
      let lines = collect [] in
      Logs.info (fun m -> m "[PERF] run_fpga: %.1f ms" (ms_since tq));
      Logs.debug (fun m -> m "FPGA daemon response (%d lines)" (List.length lines));
      match lines with
      | ["DIVERGED"] -> None
      | _ ->
          let entries = List.filter_map lines ~f:(fun line ->
            match String.split (String.strip line) ~on:' ' with
            | [pc_s; inst_num_s; irq_s; sm_s; e_state_s; r4_s; gie_s; timerA_s; umem_s] ->
                (try Some {
                  pc = Int.of_string pc_s;
                  inst_number = Int.of_string inst_num_s;
                  irq = Int.of_string irq_s;
                  sm_executing = Int.of_string sm_s;
                  e_state = Int.of_string e_state_s;
                  r4 = Int.of_string r4_s;
                  gie = Int.of_string gie_s;
                  timerA = Int.of_string timerA_s;
                  umem = Int.of_string umem_s;
                } with _ -> None)
            | _ -> None
          ) in
          (* Daemon sends entries newest-first; reverse to get chronological order *)
          Some (List.rev entries)
    in
    let breakpoint = cfg.last_inst_number + 1 in
    match query breakpoint with
    | Some entries -> Result.Ok (false, entries)
    | None ->
        (* The CPU reset before inst last+1 was decoded (e.g. end_of_test cleanup reset).
           Re-query at last_inst_number to capture the window that ended there, which
           may contain the labeled instructions we need. Not a semantic divergence. *)
        Logs.debug (fun m -> m "FPGA DIVERGED at bp=%d; retrying at bp=%d" breakpoint cfg.last_inst_number);
        (match query (Int.max 1 cfg.last_inst_number) with
        | Some entries -> Result.Ok (false, entries)
        | None -> Result.Ok (true, []))
  )

let output_of_signals
  ~(cpu_mode_s : Output_internal.mode_t)
  ~(cpu_mode_e : Output_internal.mode_t)
  ~(e_states : string list)
  ~(gie_val : string)
  ~(reg_val : string)
  ~(umem_val : string)
  ~(k : int)
  ~(timerA_val : string): [< `Out of Output_internal.element_t | `OHandle of Output_internal.payload_t] =
  let word_of_bin s : word_t = Int.of_string s in
  let e_states = List.map e_states ~f:word_of_bin in
  let compute_e_state =
    (if List.for_all e_states ~f:(fun e_state -> e_state <= 0x0F) then
      `NO_SM
    else
      (* The FPGA Sancus hardware emits one or more 0x13 (SM interrupt save)
         states between 0x10 (SM_IRQ_REGS) and 0x11 (SM_IRQ exit).
         Collapse extra 0x13s so HANDLE is recognised regardless of count. *)
      let rec _compute_e_state e_states = (match e_states with
        | [] -> `OTHER
        | 0x12::0x14::_ | 0x12::_ -> `RETI
        | 0x10::0x11::_ -> `HANDLE
        | 0x10::0x13::rest -> _compute_e_state (0x10::rest)
        | _::e_states_rest -> _compute_e_state e_states_rest
      ) in _compute_e_state e_states
    ) in
  let payload : Output_internal.payload_t = {
    k = k;
    gie = Bool.of_string_hum gie_val;
    reg_val = (word_of_bin reg_val % 8);
    umem_val = word_of_bin umem_val;
    timerA_counter = word_of_bin timerA_val;
    mode = cpu_mode_e
  } in
  match cpu_mode_s, cpu_mode_e, compute_e_state with
  | PM, PM, `NO_SM -> `Out (Output_internal.OTime payload)
  | UM, PM, `NO_SM -> `Out (Output_internal.OJmpIn payload)
  | UM, _, `RETI  -> `Out (Output_internal.OReti payload)
  | PM, UM, `NO_SM -> `Out (Output_internal.OJmpOut payload)
  | _, UM, `HANDLE  -> `OHandle payload
  | UM, UM, _ -> `Out (Output_internal.OTime payload)
  | PM, UM, `OTHER -> failwith "output_of_signals: found `PM, `UM, `OTHER. It may be a bug!"
  | UM, PM, `OTHER -> failwith "output_of_signals: found `UM, `PM, `OTHER. It may be a bug!"
  | PM, PM, `OTHER -> failwith "output_of_signals: found `PM, `PM, `OTHER. It may be a bug!"
  | PM, PM, `HANDLE -> failwith "output_of_signals: found `PM, `PM, `HANDLE. It may be a bug!"
  | UM, PM, `HANDLE -> failwith "output_of_signals: found `UM, `PM, `HANDLE. It may be a bug!"
  | PM, UM, `RETI -> failwith "output_of_signals: found `PM, `UM, `RETI. It may be a bug!"
  | PM, PM, `RETI -> failwith "output_of_signals: found `PM, `PM, `RETI. It may be a bug!"

let analyse_trace (diverges : bool) (cfg : cfg_t) (labels : (string * string) list) (trace : trace_entry list) : int * (string * string) list * Output_internal.element_t list =
  Logs.debug (fun p -> p "Fpga.analyse_trace: labels: %s" ([%derive.show: (string*string) list] labels));
  (* Run nm once and cache all symbol addresses to avoid O(N²) shell invocations *)
  let nm_output = Shexp_process.eval Shexp_process.(pipe (run "nm" [cfg.pmem_elf]) read_all) in
  let sym_table = List.fold (String.split_lines nm_output) ~init:String.Map.empty
    ~f:(fun acc line ->
      match String.split (String.strip line) ~on:' ' with
      | [addr; _; name] -> Map.set acc ~key:name ~data:addr
      | _ -> acc
    ) in
  let addr_of_label_fast l =
    match Map.find sym_table l with
    | Some addr -> Int.of_string ("0x" ^ String.strip addr)
    | None -> addr_of_label cfg l  (* fallback to subprocess *)
  in
  let annot_pcs = List.map labels ~f:(fun (s, e) -> addr_of_label_fast s, addr_of_label_fast e) in
  let pc_to_label (s, e) = List.find_exn labels ~f:(fun (s', e') -> s = addr_of_label_fast s' && e = addr_of_label_fast e') in

  let compute_cpu_mode e = if e.sm_executing = 0 then Output_internal.UM else Output_internal.PM in
  (* Return the first clock cycle of instruction n, or None if not in trace *)
  let first_cycle_of n = List.find trace ~f:(fun e -> e.inst_number = n) in
  (* Return all clock cycles of instruction n *)
  let all_cycles_of n = List.filter trace ~f:(fun e -> e.inst_number = n) in

  (* Truncate at the br #0xffff crash sentinel (PC=0xFFFF).
     This address is architecturally unreachable as a valid decoded instruction on MSP430
     (odd address, inside the interrupt vector table) so it only appears as the result
     of the deliberate end-of-test crash.  Stopping here removes:
       - the crash instruction itself
       - any glitch entries the Sancus/reset pipeline emits after puc_rst fires
       - second-run entries
     All of which would otherwise corrupt last_inst_number. *)
  let trace = List.take_while trace ~f:(fun entry -> entry.pc <> 0xFFFF) in

  (* Keep only the first clock cycle per inst_number that hits an annotated PC *)
  let matched_entries = List.filter_mapi trace ~f:(fun idx entry ->
    let is_annotated = List.exists annot_pcs ~f:(fun (s, e) -> entry.pc >= s && entry.pc < e) in
    if is_annotated && entry.irq <> 1 && entry.inst_number >= cfg.last_inst_number then
      Some (idx, entry)
    else
      None
  ) in

  (* Deduplicate by exact PC: keep the first occurrence of each PC.
     Multi-instruction label ranges (e.g. sancus_enable) have many distinct PCs and all
     are preserved; last_inst_number will be set to the last one seen in the window. *)
  let unique_matched_entries =
    List.fold matched_entries ~init:[] ~f:(fun acc (idx, entry) ->
      if List.exists acc ~f:(fun (_, e) -> e.pc = entry.pc) then acc
      else acc @ [(idx, entry)]
    ) in

  let seen_pcs, filtered_matched_entries =
    List.fold_until unique_matched_entries ~init:([], [])
      ~f:(fun (acc_seen, acc_entries) (idx, entry) ->
        (* Check the first cycle of the *next* instruction for SM_IRQ_REGS (0x10) *)
        match first_cycle_of (entry.inst_number + 1) with
        | Some next_e when next_e.e_state = 0x10 ->
            Stop (entry.pc :: acc_seen, acc_entries @ [(idx, entry); (idx, next_e)])
        | _ ->
            Continue (entry.pc :: acc_seen, acc_entries @ [(idx, entry)])
      ) ~finish:(fun r -> r) in

  let left_labels' = List.map (List.filter annot_pcs ~f:(fun (s, e) ->
    not (List.exists seen_pcs ~f:(fun seen_pc -> seen_pc >= s && seen_pc < e))
  )) ~f:pc_to_label in

  let inst_numbers = List.map filtered_matched_entries ~f:(fun (_, entry) -> entry.inst_number) in
  Logs.debug (fun m -> m "inst_numbers: %s" (List.to_string inst_numbers ~f:(fun el -> sprintf "%d" el)));

  if List.is_empty inst_numbers && diverges then
    cfg.last_inst_number, [], [Output_internal.OMaybeDiverge]
  else if List.is_empty inst_numbers && not diverges then
    (
      Logs.debug (fun p -> p "FIXME: Could not find the instruction in the trace, returning Unsupported");
      cfg.last_inst_number, [], [Output_internal.OUnsupported]
    )
  else
    (
      let last_inst_number, res = List.fold
        filtered_matched_entries
        ~init:(cfg.last_inst_number, [])
        ~f:(fun (_lin, acc) (_, entry) ->
          (* cpu_mode_s: mode at start of this instruction (first captured clock cycle) *)
          let cpu_mode_s = compute_cpu_mode entry in
          (* cpu_mode_e: mode at start of the next instruction.
             If the next instruction is outside the 10-cycle window we fall back to cpu_mode_s
             (mode unchanged). True CPU resets are signalled via DIVERGED in run_fpga_script. *)
          let cpu_mode_e = match first_cycle_of (entry.inst_number + 1) with
            | Some next_e -> compute_cpu_mode next_e
            | None -> cpu_mode_s
          in
          (* e_status: all e_state values across the full instruction *)
          let inst_cycles = all_cycles_of entry.inst_number in
          let e_status = List.map inst_cycles ~f:(fun e -> sprintf "%d" e.e_state) in
          let reg_val = sprintf "%d" entry.r4 in
          let gie_val = if entry.gie = 1 then "true" else "false" in
          let umem_val = sprintf "%d" entry.umem in
          let timerA_val = sprintf "%d" entry.timerA in
          (* k: number of clock cycles for this instruction *)
          let k = Int.max 1 (List.length inst_cycles) in
          let lin' = entry.inst_number in
          lin', acc @ [ output_of_signals ~cpu_mode_s ~cpu_mode_e ~e_states:e_status ~gie_val ~reg_val ~umem_val ~k ~timerA_val ]
        ) in

      let int_o_equal o o' = match o, o' with `OHandle k, `OHandle k' -> Output_internal.equal_payload_t k k' | `Out o, `Out o' -> Output_internal.equal_element_t o o' | _ -> false in
      let int_o_show o = match o with `OHandle k -> sprintf "`OHandle %s" (Output_internal.show_payload_t k) | `Out o -> sprintf "`Out %s" (Output_internal.show_element_t o) in
      if List.mem res (`Out Output_internal.OReset) ~equal:int_o_equal then
        cfg.last_inst_number, [], [Output_internal.OReset]
      else
        (
          Logs.debug (fun p -> p "Fpga.analyse_trace: complete out: %s" (List.to_string ~f:int_o_show res));
          let merge_int_obs o o' =
            let open Output_internal in
            match o, o' with
              | `Out (OJmpOut k), `Out (OJmpOut k') -> Some (`Out (OJmpOut (merge_payload ~older:k ~newer:k')))
              | `Out (OReti k), `Out (OReti k') -> Some (`Out (OReti (merge_payload ~older:k ~newer:k')))
              | `OHandle k, `OHandle k' -> Some (`OHandle (merge_payload ~older:k ~newer:k'))
              | `Out (OTime k), `Out (OTime k') -> Some (`Out (OTime (merge_payload ~older:k ~newer:k')))
              | `Out (OSilent), `Out (OSilent) -> Some (`Out (OSilent))
              | _, _ -> None
            in
          let last, packed_no_last = List.foldi
            (List.drop res 1)
            ~init:(List.hd_exn res, [])
            ~f:(fun idx (curr_kind, acc_packed) o ->
              if List.length res = idx + 1 then
                (o, acc_packed @ [curr_kind])
              else
                match merge_int_obs curr_kind o with
                | Some kind -> (kind, acc_packed)
                | None -> (o, acc_packed @ [curr_kind])) in
          let packed = packed_no_last @ [last] in
          Logs.debug (fun p -> p "Fpga.analyse_trace: packed out: %s" (List.to_string ~f:int_o_show packed));
          let composed =
            let open Output_internal in
            List.foldi
              packed
              ~init:[]
              ~f:(fun i acc_composite curr ->
                let prev, next = List.nth packed (i-1), List.nth packed (i+1) in
                match prev, curr, next with
                  | _, `Out (OJmpOut k), Some (`OHandle h) -> acc_composite @ [OJmpOut_Handle (k, h)]
                  | _, `Out (OTime k), Some (`OHandle h) -> acc_composite @ [OTime_Handle (k, h)]
                  | Some (`Out (OJmpOut _)), `OHandle _, _ | Some (`Out (OTime _)), `OHandle _, _ -> acc_composite
                  | _, `Out ao, _ -> acc_composite @ [ao]
                  | _, `OHandle p, _-> acc_composite @ [OTime_Handle ({ p with k = 0; mode = PM }, p)]
              ) in
          let no_silent = List.drop_while (List.drop_last_exn composed) ~f:(Output_internal.equal_element_t OSilent) @ [List.last_exn composed] in
          let last_ns = List.last_exn no_silent in
          match last_ns with
          | OJmpOut_Handle _ | OTime_Handle _ | OSilent -> last_inst_number, left_labels', no_silent
          | _ -> last_inst_number, [], no_silent
        )
    )

let pre (cfg : t) =
  (match Logs.level () with
  | Some Logs.App -> (Format.printf "\x1B[1;33m.\x1B[0m"); Out_channel.flush stdout | _ -> ()
  );
  cfg := {
    !cfg with
      initial_spec = { !cfg.initial_spec with current = !cfg.initial_spec.spec };
      enclave_history = C_Enclave [];
      ca_history = (C_ISR [], C_Prepare [], C_Cleanup []);
      input_history = [];
      output_history = [];
      left_labels = [];
      last_inst_number = 0;
  }

let step ?(silent=false) ?(dry_output : output_t option) cfg i : output_t =
  ignore (Sys_unix.command (Format.sprintf "rm -Rf \"%s/*\"" !cfg.tmpdir));
  Logs.debug (fun m -> m "\x1B[31mFpga.step: Invoked with %s\x1B[0m" (Sexp.to_string (Input.sexp_of_t i)));
  if not silent then
  (match Logs.level () with
    | Some Logs.App -> Format.printf "[%s" (match i with
      | INoInput -> "\x1B[33m" ^ "_" ^ "\x1B[0m"
      | IAttacker Attacker.CRst -> "\x1B[1;31m" ^ "•" ^ "\x1B[0m"
      | IAttacker Attacker.CRstNZ -> "\x1B[1;31m" ^ "Z" ^ "\x1B[0m"
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
      | IAttacker (Attacker.CReti) -> "\x1B[35m" ^ "R" ^ "\x1B[0m"
      ); Out_channel.flush stdout
     | _ -> ()
  ) else ();
  Logs.debug (fun m -> m "Fpga.step: Input history: %s" (Sexp.to_string_mach (List.sexp_of_t Input.sexp_of_t !cfg.input_history)));
  Logs.debug (fun m -> m "Fpga.step: Output history: %s" (Sexp.to_string_mach (List.sexp_of_t Output_internal.sexp_of_t !cfg.output_history)));
  let curr_spec_dfa, matchable = Inputgen.matchable !cfg.initial_spec i !cfg.input_history !cfg.output_history in
  Logs.debug (fun m -> m "Fpga.step: Mode: %s" (Inputgen.mode_show curr_spec_dfa.mode));
  Logs.debug (fun m -> m "Fpga.step: Input: %s" (Input.show i));
  let cfg' = update_cfg `Label curr_spec_dfa.mode !cfg i in
  let last_inst_number, left_labels, out = (if not matchable then
    (
      Logs.debug (fun m -> m "Fpga.step: %s not matchable in %s, outputting OIllegal (default)." (Input.show i) (Inputgen.mode_show curr_spec_dfa.mode));
      cfg'.last_inst_number, [], Output_internal.default
    )
  else if
    List.mem ~equal:(fun (o, _, _) (o', _, _) -> List.equal Output_internal.equal_element_t o o') cfg'.output_history ([Output_internal.OMaybeDiverge], [], 0) ||
    List.mem ~equal:Input.equal cfg'.input_history Input.INoInput ||
    List.mem ~equal:Output_internal.equal cfg'.output_history Output_internal.default then
    (
      Logs.debug (fun m -> m "Fpga.step: cannot continue since we got empty input, illegal action or halt previously!");
      cfg'.last_inst_number, [], Output_internal.default
    )
  else
    (
      let template_code = In_channel.read_all cfg'.templatefile in
      let labels, code = fill_template template_code cfg' in
        Logs.debug (fun m -> m "filledfile: %s" cfg'.filledfile);
        Out_channel.write_all cfg'.filledfile ~data:code;
        let force_no_dry () =
          let t, ll, e = match run_fpga_script cfg' with
            | Error o -> cfg'.last_inst_number, [], [o]
            | Ok (diverges, tr) ->
                let l_last_inst_number, l_left_labels, l_out = analyse_trace diverges cfg' labels tr in
                match List.find l_out ~f:(fun el -> match el with Output_internal.OReti _ -> true | _ -> false) with
                | None -> l_last_inst_number, cfg'.left_labels @ l_left_labels, l_out
                | Some _ ->
                  analyse_trace diverges cfg' (cfg'.left_labels @ labels) tr in (t, ll, (e, ll, t))
        in
        match dry_output with
        | None -> force_no_dry ()
        | Some (ol, ll, lt) ->
          (match List.last ol with
            | None -> force_no_dry ()
            | Some _ -> lt, ll, (ol, ll, lt)
          )
    )
  ) in
  let cfg'_nolbl = update_cfg `NoLabel curr_spec_dfa.mode !cfg i in
  cfg := { cfg'_nolbl with last_inst_number = last_inst_number; left_labels = left_labels; output_history = cfg'.output_history @ [ out ] };
  if List.mem (fst3 out) OReset ~equal:Output_internal.equal_element_t then pre cfg else ();
  if not silent then
  (match Logs.level () with
  | Some Logs.App ->
      let render_output_t o = (match o with
        | Output_internal.OIllegal -> "\x1B[33m" ^ "†" ^ "\x1B[0m"
        | Output_internal.OUnsupported -> "\x1B[33m" ^ "?" ^ "\x1B[0m"
        | Output_internal.OReset -> "\x1B[1;31m" ^ "•" ^ "\x1B[0m"
        | Output_internal.OMaybeDiverge -> "\x1B[1;31m" ^ "∞" ^ "\x1B[0m"
        | Output_internal.OJmpIn _ -> "\x1B[1;34m" ^ "i" ^ "\x1B[0m"
        | Output_internal.OSilent -> "\x1B[1;34m" ^ "s" ^ "\x1B[0m"
        | Output_internal.OJmpOut _ -> "\x1B[1;32m" ^ "o" ^ "\x1B[0m"
        | Output_internal.OTime _ -> "\x1B[1;32m" ^ "t" ^ "\x1B[0m"
        | Output_internal.OTime_Handle _ -> "\x1B[1;35m" ^ "th" ^ "\x1B[0m"
        | Output_internal.OJmpOut_Handle _ -> "\x1B[1;35m" ^ "oh" ^ "\x1B[0m"
        | Output_internal.OReti _ -> "\x1B[1;35m" ^ "r" ^ "\x1B[0m"
      ) in
      Format.printf "%s]" (List.fold (fst3 out) ~init:"" ~f:(fun acc o -> acc ^ render_output_t o));
    ; Out_channel.flush stdout
   | _ -> ()
  ) else ();
  out

let post _ = ()
