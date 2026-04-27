open! Core

open Inputgen
open Common

open Attacker
open Enclave

type input_t = Input.t [@@deriving ord,sexp]
type output_t = Output_internal.t [@@deriving ord,sexp]
type label_t = string*string [@@deriving sexp,ord]


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

let make ~sancus_repo ~sancus_master_key ~commit ~workingdir ~tmpdir ~basename ~verilog_compile ~get_symbolpos ~pmem_script ~simulate_script ~submitfile ~templatefile ~pmem_elf ~filledfile ~dumpfile ~initial_spec ~ignore_interrupts ?(sim_cycle_ratio = 500) () =
  Sys_unix.chdir workingdir;
  (* Create tmpdir and a temporary dir inside tmpdir *)
  (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
  let r_tmpdir = Core_unix.mkdtemp (tmpdir ^ "/") in
  Logs.debug (fun m -> m "Chosen temporary directory: %s" r_tmpdir);
  (* Copy the sancus-core-gap in the directory *)
  Logs.debug (fun m -> m "Copying: %s => %s/sancus-core-gap" sancus_repo r_tmpdir);
  assert (Sys_unix.command (Format.sprintf "cp -a %s %s/sancus-core-gap" sancus_repo r_tmpdir) = 0);
  (* Use the required commit *)
  Logs.debug (fun m -> m "Checking out the required commit: %s" commit);
  assert (Sys_unix.command (Format.sprintf "cd %s/sancus-core-gap; git checkout %s %s" r_tmpdir commit (dbg_str ())) = 0);
  (* Create the config file -- note that the minimum size for the key seems to be 20 bytes *)
  Logs.debug (fun m -> m "Configuring Sancus with key: %s" sancus_master_key);
  let security = Int.max 20 (4 * String.length sancus_master_key) in
  assert (Sys_unix.command (Format.sprintf "%s/../scripts/build_config.sh \"%s/sancus-core-gap/\" %d %s %s" workingdir r_tmpdir security sancus_master_key (dbg_str ())) = 0);
  (* Load the submit.f file *)
  let submitfile_filled = r_tmpdir ^ "/submit.f" in
  let submit_template = In_channel.read_all submitfile in
  let submit_filled =
    String.substr_replace_all submit_template ~pattern:"{{tmp_dir}}" ~with_:r_tmpdir in
      Out_channel.write_all submitfile_filled ~data:submit_filled;
  (* Compile the Verilog testbench beforehand *)
  let res = Sys_unix.command (Format.sprintf "%s \"%s\" %s %s %s" verilog_compile r_tmpdir basename submitfile_filled ">/dev/null 2>/dev/null") in
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
      ~initial_spec
      ~sim_cycle_ratio
      ~enclave_history:(C_Enclave [])
      ~ca_history:(C_ISR [], C_Prepare [], C_Cleanup [])
      ~input_history:[]
      ~output_history:[]
      ~left_labels:[]
      (* ~last_time:0  *)
      ~last_inst_number:0
      ~ignore_interrupts:ignore_interrupts
      ())
  )

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
  (* Logs.debug (fun m -> m "\x1B[31m[Before] Verilog.update_cfg: %s\x1B[0m" (List.to_string ~f:Input.show cfg.input_history)); *)
  let res = { cfg with
      input_history = cfg.input_history @ [i];
      enclave_history = (_enclave_update cfg.enclave_history curr_spec_dfa_mode i);
      ca_history = (_attack_update cfg.ca_history curr_spec_dfa_mode i);
  } in
  (* Logs.debug (fun m -> m "\x1B[31m[After] Verilog.update_cfg: %s\x1B[0m" (List.to_string ~f:Input.show res.input_history)); *)
  res

let fill_template template_code (cfg : cfg_t) =
  (* Compile the "high-level" actions into actual code *)
  Common.reset_last_used_idx (); (* FIXME: this is very bad, but that's the easiest thing; We need to reset the index after each experiment *)
  (* enclave, isr and cleanup sections are may be re-entered more than once w/o a reset *)
  (*
    - enclave: re-entered upon reti and jmpin.
    In the both cases we do not want to "compile" the pre-existing code, so we remove from enclave_history all the instructions that appear *before* the last JmpIn and those that appear *after* the last reti (if any) in the full I/O history (i.e., intersperse_lists input output)
  *)
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
      (* Otherwise, i have last_encl_segment e1 ... en IRQ ... reti ... IRQ ... reti en+1 en+2 ... and what we want to write is:
        e1 ... en en+1 ..., so take last_encl_segment until the first reti, drop all attackers actions and to the result concat curr_encl_segment
      *)
      let filt_last = List.filter_map last_encl_segment ~f:(fun io -> match io with In (Input.IEnclave i) -> Some i | _ -> None) in
      let filt_last_len = List.length filt_last in
      (* this is in the form e1 ... en .. en+1 en+2 ... en+k en+1 en+2 ... en+k' but labelled *)
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
      (* extract just e1 ... en labelled and concat the part corresponding to filt_curr to it *)
      let res = (List.take res_last filt_last_len) @ (List.drop eh (List.length eh - filt_curr_len)) in
      Logs.debug (fun p -> p "eh   enclave: %s" ([%derive.show: Enclave.atom_t annot list] eh));
      Logs.debug (fun p -> p "res  enclave: %s" ([%derive.show: Enclave.atom_t annot list] res));
      Logs.debug (fun p -> p "filt last enclave: %s" ([%derive.show: Enclave.atom_t list] filt_last));
      Logs.debug (fun p -> p "filt curr enclave: %s" ([%derive.show: Enclave.atom_t list] filt_curr));
      assert(List.for_all2_exn res (filt_last @ filt_curr) ~f:(fun (NoLabel e | Label e) f -> Enclave.equal_atom_t e f));
      (* if an enclave has already been completed once, we need to complete res with the "missing" actions.Logs
        For that, we look for the last jmpout in eh and go backwards completing the code.
      *)
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
  (* - ISR: We assume all sections to be executed from their beginning and just once; ISR special since multiple interrupts may occur, so this function extracts just the actions from the last reti (excluded) *)
  let relevant_isr al =
    (* Notice that the call to relevant_isr is done only on the portion of the history of the isr *)
    (* Extract the part of the ISR since the last unlabelled reti/jmpin (excl.). The only labelled reti/jmpin is kept. *)
    let curr_isr = List.rev (List.take_while (List.rev al) ~f:(fun a -> match a with NoLabel Attacker.CReti | NoLabel (Attacker.CJmpIn _) -> false | _ -> true)) in
    Logs.debug (fun p -> p "Curr ISR: %s" ([%derive.show: Attacker.atom_t annot list] curr_isr));
    (* Extract the first ISR, by keeping all observables until the first reti (included!)*)
    let first_isr = List.rev (List.fold_until al ~init:[] ~f:(fun acc_isr a -> match a with Label Attacker.CReti | NoLabel Attacker.CReti | Label (Attacker.CJmpIn _) | NoLabel (Attacker.CJmpIn _) -> Stop (a::acc_isr) | _ -> Continue (a::acc_isr)) ~finish:(fun isr -> isr)) in
    Logs.debug (fun p -> p "First ISR: %s" ([%derive.show: Attacker.atom_t annot list] first_isr));
    (* The actual ISR is obtained by stiching together the current ISR and the part of the first ISR that has not been "given" yet. If curr_isr and first_isr coincide (i.e., no reti has ever been issued), we just keep curr_isr *)
    let actual_isr = curr_isr @ List.drop first_isr (List.length curr_isr) in
        (* Logs.debug (fun p -> p "ISR: %s" ([%derive.show: Attacker.atom_t annot list] actual_isr)); *)
        actual_isr in
  (* - Cleanup: when exiting with a jmpout more than once! --- FIXME: this is a hack *)
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
    (* Logs.debug (fun m -> m "filled: %s" code); *)
    attacker_labels @ enclave_labels, code

let addr_of_label cfg l =
  (* Logs.debug (fun p -> p "Verilog.addr_of_label %s %s" cfg.pmem_elf l); *)
  Int.of_string ("0x" ^ (String.substr_replace_all ~pattern:"\n" ~with_:"" (Shexp_process.eval Shexp_process.(pipe (run "sh" [cfg.get_symbolpos; cfg.pmem_elf; l]) read_all))))

let run_simulator (cfg : cfg_t) =
  (* Call build_pmem to compile and link the code *)
  let res = Sys_unix.command (Format.sprintf "%s \"%s\" %s %s" cfg.pmem_script cfg.tmpdir cfg.basename (dbg_str ())) in
  if res <> 0 then
    failwith (Format.sprintf "Error: %s returned %d." cfg.pmem_script res)
  else (
    (* Invoke the simulator *)
    let res = Sys_unix.command (Format.sprintf "%s \"%s\" %s %s" cfg.simulate_script cfg.tmpdir cfg.basename (dbg_str ())) in
    (* (match Logs.level () with | Some Logs.Debug -> assert (Sys_unix.command (Format.sprintf "cp %s %s" cfg.dumpfile cfg.workingdir) = 0) | _ -> ()); *)
    if res = 1 then
      failwith "Simulator: Stimulus did not complete!"
    (* else if res = 2 then
      Result.Error (Output_internal.OMaybeDiverge) *)
    else if res = 3 then
      failwith "Simulator: Unexpected error :("
    else
      (* If res = 2, simulation diverged and we signal it! *)
      Result.Ok (res = 2, Vcd.vcd cfg.dumpfile))

let output_of_signals
  ~(cpu_mode_s : Output_internal.mode_t)
  ~(cpu_mode_e : Output_internal.mode_t)
  ~(e_states : string list)
  ~(gie_val : string)
  ~(reg_val : string)
  ~(umem_val : string)
  (* ~(pmem_val : string)  *)
  ~(k : int)
  ~(timerA_val : string): [< `Out of Output_internal.element_t | `OHandle of Output_internal.payload_t] =
  (* e_state mapping:
      0x00 - 0x0F -> non-SM
      0x10        -> SM_IRQ_REGS
      0x11        -> SM_IRQ_WAIT
      0x12        -> SM_RETI_REGS
      0x13        -> SM_IRQ_PAD
      0x14        -> SM_RETI_PAD
  *)
  let word_of_bin s : word_t = Int.of_string ("0b" ^ s) in
  let e_states = List.map e_states ~f:word_of_bin in
  let compute_e_state =
    (* Logs.debug (fun p -> p "output_of_signals.compute_e_state: e_states: %s" (List.to_string ~f:(sprintf "%#x") e_states)); *)
    (if List.for_all e_states ~f:(fun e_state -> e_state <= 0x0F) then
      `NO_SM
    else
      let rec _compute_e_state e_states = (match e_states with
        | [] -> `OTHER
        | 0x12::0x14::_ | 0x12::_ -> `RETI
        (* | 0x14::_ -> `PP_JMPOUT *)
        | 0x10::0x13::0x11::_ | 0x10::0x11::_ -> `HANDLE
        | _::e_states_rest -> _compute_e_state e_states_rest
      ) in _compute_e_state e_states
    ) in
  let payload : Output_internal.payload_t = {
    k = k;
    gie = Bool.of_string_hum gie_val;
    reg_val = (word_of_bin reg_val % 8); (* We limit the register to 3 bits to avoid useless looping *)
    (* pmem_val = word_of_bin pmem_val; *)
    umem_val = word_of_bin umem_val;
    timerA_counter = word_of_bin timerA_val;
    mode = cpu_mode_e
  } in
  (*Logs.debug (fun m -> m "%s, %s, %s" (show_mode cpu_mode_s) (show_mode cpu_mode_e) (show_e_state compute_e_state)) *)
  match cpu_mode_s, cpu_mode_e, compute_e_state with
  | PM, PM, `NO_SM -> `Out (Output_internal.OTime payload)
  | UM, PM, `NO_SM -> `Out (Output_internal.OJmpIn payload)
  | UM, _, `RETI  -> `Out (Output_internal.OReti payload) (* ! FIXME: this is actually a RETI? *)
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

let analyse_dump (diverges : bool) (cfg : cfg_t) (labels : (string * string) list) (dump : Vcd.vcd_t) : int * (string * string) list * Output_internal.element_t list =
  (* let labels = List.dedup_and_sort labels ~compare:[%derive.ord: string*string] in *)
  (* Find the interesting points in the code, using the labels *)
  Logs.debug (fun p -> p "Verilog.analyse_dump: labels: %s" ([%derive.show: (string*string) list] labels));
  let annot_pcs = List.map labels ~f:(fun (s, e) -> addr_of_label cfg s, addr_of_label cfg e) in
  let pc_to_label (s, e) = List.find_exn labels ~f:(fun (s', e') -> s = addr_of_label cfg s' && e = addr_of_label cfg e') in
  let pc_map = Vcd.get_signal dump "TOP.tb_openMSP430.inst_pc[15:0]" in
  let irq_map = Vcd.get_signal dump "TOP.tb_openMSP430.msp_debug_0.irq" in
  let inst_number_map = Vcd.get_signal dump "TOP.tb_openMSP430.inst_number[31:0]" in
  let sm_executing_map = Vcd.get_signal dump "TOP.tb_openMSP430.dut.frontend_0.sm_executing" in
  let e_state_map = Vcd.get_signal dump "TOP.tb_openMSP430.dut.e_state[4:0]" in
  let r4_map = Vcd.get_signal dump "TOP.tb_openMSP430.r4[15:0]" in
  let gie_map = Vcd.get_signal dump "TOP.tb_openMSP430.gie" in
  let timerA_map = Vcd.get_signal dump "TOP.tb_openMSP430.timerA_0.tar[15:0]" in
  (* let pmem_map = Vcd.get_signal dump "TOP.tb_openMSP430.mem240[15:0]" in *)
  let umem_map = Vcd.get_signal dump "TOP.tb_openMSP430.mem250[15:0]" in
  (* Logs.debug (fun m -> m "reg_map : [%s]\n" (List.to_string (Map.to_alist r4_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v)));
  Logs.debug (fun m -> m "gie_map : [%s]\n" (List.to_string (Map.to_alist gie_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v)));
  Logs.debug (fun m -> m "timerA_map : [%s]\n" (List.to_string (Map.to_alist timerA_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  (* Logs.debug (fun m -> m "pmem_map : [%s]\n" (List.to_string (Map.to_alist pmem_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  (* Logs.debug (fun m -> m "umem_map : [%s]\n" (List.to_string (Map.to_alist umem_map.tv) ~f:(fun (k, v) -> sprintf "%d, %s;" k v))); *)
  let time_and_pc_map = Map.fold ~init:Int.Map.empty
    pc_map.tv
    ~f:(fun ~key:time ~data:raw_data acc_tpm ->
      (* Logs.debug (fun m -> m "Verilog.analyse_dump: time: %d; raw_data: %s; pc: %x; irq: %s; inst_num: %d" time raw_data (Int.of_string ("0b" ^ raw_data)) (Vcd.Signal.at_time irq_map time) (Int.of_string ("0b" ^ Vcd.Signal.at_time inst_number_map time))); *)
      if not (String.equal raw_data "x") &&
        List.exists annot_pcs ~f:(fun (s, e) -> let pc = Int.of_string ("0b" ^ raw_data) in pc >= s && pc < e) &&
        not (String.equal (Vcd.Signal.at_time irq_map time) "1") &&
        (* FIXME: find a better way to do this *)
        Int.of_string ("0b" ^ Vcd.Signal.at_time inst_number_map time) >= cfg.last_inst_number &&
        (* time >= cfg.last_time && *)
        not (Map.exists acc_tpm ~f:(fun data' -> String.equal raw_data data'))
      then
          Map.add_exn acc_tpm ~key:time ~data:raw_data
      else
        acc_tpm
    ) in
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
  let inst_cfg inst_number = Map.min_elt (Map.filter inst_number_map.tv ~f:(fun data -> not (String.equal data "x") && Int.of_string("0b" ^ data) = inst_number)) in
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
          - otherwise, we are in an unsupported case and we can output OUnsupported *)
  if List.is_empty inst_numbers && diverges then
  (
    cfg.last_inst_number, [], [Output_internal.OMaybeDiverge]
  )
  else if List.is_empty inst_numbers && not diverges then
  (
    Logs.debug (fun p -> p "FIXME: Could not find the instruction in the vcd file, please check your specification. The cause is usually an unsupported action, e.g., a jump from an enclave to another, an interrupt in unprotected mode, ... --- Returning Unsupported");
    cfg.last_inst_number, [], [Output_internal.OUnsupported]
  )
  else
  (
    let last_inst_number, res = List.fold
      inst_numbers
      ~init:(cfg.last_inst_number, [])
      ~f:(fun (lin, acc) inst_number ->
        (* The below min_elt_exn should never fail, since inst_numbers is not empty here *)
        let (ref_time_begin, _) = Map.min_elt_exn (Map.filter inst_number_map.tv ~f:(fun data -> not (String.equal data "x") && Int.of_string("0b" ^ data) = inst_number)) in
        let end_config = Map.min_elt (Map.filter inst_number_map.tv ~f:(fun data -> not (String.equal data "x") && Int.of_string("0b" ^ data) = inst_number + 1)) in
        let compute_cpu_mode t = if String.equal (Vcd.Signal.at_time sm_executing_map t) "0" then Output_internal.UM else Output_internal.PM in
        match end_config with
        | None ->
          Logs.debug (fun m -> m "Verilog.analyse_dump: folding over inst_numbers and found a RESET, outputting OReset.");
          lin, acc @ [ `Out Output_internal.OReset ]
        | Some (ref_time_end, _) ->
            (* Extract the list of all elements from e_state_map whose keys are >= ref_time_begin and < ref_time_end *)
            let e_status = List.map (Map.to_alist (Map.filter_keys e_state_map.tv ~f:(fun key -> key >= ref_time_begin && key < ref_time_end))) ~f:snd in
            (* Extract the values of registers and memory, as the last value before ref_time_end *)
            let reg_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys r4_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in
            let gie_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys gie_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in
            let umem_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys umem_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in
            (* let pmem_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys pmem_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in *)
            let timerA_val = List.last_exn (List.map (Map.to_alist (Map.filter_keys timerA_map.tv ~f:(fun key -> key < ref_time_end))) ~f:snd) in
            let k = (ref_time_end - ref_time_begin) / cfg.sim_cycle_ratio in
            let lin' = inst_number in
            Logs.debug (fun m -> m "===== cfg.last_inst_number %d, lin %d, lin' %d\n" cfg.last_inst_number lin lin');
            (* Process the results into an actual output *)
            lin', acc @ [ output_of_signals ~cpu_mode_s:(compute_cpu_mode ref_time_begin) ~cpu_mode_e:(compute_cpu_mode ref_time_end) ~e_states:e_status ~gie_val:gie_val ~reg_val:reg_val ~umem_val:umem_val (* ~pmem_val:pmem_val *) ~k:k ~timerA_val:timerA_val]
        ) in
      (*
      For each pair of labels we have an output.
        - If a Reset or a Exception is in the list, just return such element
        - Otherwise:
          + If the list has length 1, it means that the original action was a single instruction (CInst, CReti for attackers or any instruction for enclaves), and we just need to extract this single element;
          + If the length is >1 then the original action was something different (CJmpIn, CCreateEnclave, CTimerEnable):
              * CJmpIn: we expect the sequence to be OSilent ... OSilent OJmpIn: just return OJmpIn
              * CTimerEnable/CCreateEnclave: this will be a sequence OSilent ... OSilent : return OSilent
              * CJmpOut: we sum the timings of the instructions composing it into k and return CJmpOut k
          Overall: we can always return the last observable of the res list (if any)
      *)
      let int_o_equal o o' = match o, o' with `OHandle k, `OHandle k' -> Output_internal.equal_payload_t k k' | `Out o, `Out o' -> Output_internal.equal_element_t o o' | _ -> false in
      let int_o_show o = match o with `OHandle k -> sprintf "`OHandle %s" (Output_internal.show_payload_t k) | `Out o -> sprintf "`Out %s" (Output_internal.show_element_t o) in
      if List.mem res (`Out Output_internal.OReset) ~equal:int_o_equal then
        cfg.last_inst_number, [], [Output_internal.OReset]
      else
        (
          (*
            res is a list of observables, ideally one for each instruction.
            We now "pack together" observables of the same kind, updating their field
          *)
          Logs.debug (fun p -> p "Verilog.analyse_dump: complete out: %s" (List.to_string ~f:int_o_show res));
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
          Logs.debug (fun p -> p "Verilog.analyse_dump: packed out: %s" (List.to_string ~f:int_o_show packed));
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
                  (* Note: Handle detected right after a reti, it means that we are in PM, so treat it like a OTime_Handle with 0 cycles in PM *)
                  (* | _, `OHandle _, _-> failwith "Verilog.analyse_dump: unexpected OHandle while composing observables." *)
              ) in
          (* Logs.debug (fun p -> p "Verilog.analyse_dump: composed out: %s" (Output_internal.show composed)); *)
          let no_silent = List.drop_while (List.drop_last_exn composed) ~f:(Output_internal.equal_element_t OSilent) @ [List.last_exn composed] in
          (* Logs.debug (fun p -> p "Verilog.analyse_dump: no_silent out: %s" (Output_internal.show no_silent)); *)
          (* We now collect the labels that were expected but were not found in the execution *)
          (* it is important to clear left_labels each time, except when dealing with interrupts (i.e., during a Handle, and after it until a Reti!) *)
          let last_ns = List.last_exn no_silent in
          match last_ns with
          | OJmpOut_Handle _ | OTime_Handle _ | OSilent -> last_inst_number, left_labels', no_silent
          | _ -> last_inst_number, [], no_silent
        )
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
      (* last_time = 0; *)
      last_inst_number = 0;
  }

let step ?(silent=false) ?(dry_output : output_t option) cfg i : output_t =
  ignore (Sys_unix.command (Format.sprintf "rm -Rf \"%s/*\"" !cfg.tmpdir));
  Logs.debug (fun m -> m "\x1B[31mVerilog.step: Invoked with %s\x1B[0m" (Sexp.to_string (Input.sexp_of_t i)));
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
  ) else ();
  (* Check if the history of inputs + the new one is "legal" according to the spec.
     If not, return Exception/Reset depending on whether the mode was inside the enclave or not. *)
  Logs.debug (fun m -> m "Verilog.step: Input history: %s" (Sexp.to_string_mach (List.sexp_of_t Input.sexp_of_t !cfg.input_history)));
  Logs.debug (fun m -> m "Verilog.step: Output history: %s" (Sexp.to_string_mach (List.sexp_of_t Output_internal.sexp_of_t !cfg.output_history)));
  let curr_spec_dfa, matchable = Inputgen.matchable !cfg.initial_spec i !cfg.input_history !cfg.output_history in
  Logs.debug (fun m -> m "Verilog.step: Mode: %s" (Inputgen.mode_show curr_spec_dfa.mode));
  Logs.debug (fun m -> m "Verilog.step: Input: %s" (Input.show i));
  (* (Partial) update of the configuration *)
  let cfg' = update_cfg `Label curr_spec_dfa.mode !cfg i in
  let last_inst_number, left_labels, out = (if not matchable then
    (
      Logs.debug (fun m -> m "Verilog.step: %s not matchable in %s, outputting OIllegal (default)." (Input.show i) (Inputgen.mode_show curr_spec_dfa.mode));
      cfg'.last_inst_number, [], Output_internal.default
      (* failwith "Verilog.step: I got an illegal input!" *)
    )
  else if
    List.mem ~equal:(fun (o, _, _) (o', _, _) -> List.equal Output_internal.equal_element_t o o') cfg'.output_history ([Output_internal.OMaybeDiverge], [], 0) ||
    List.mem ~equal:Input.equal cfg'.input_history Input.INoInput ||
    List.mem ~equal:Output_internal.equal cfg'.output_history Output_internal.default then
    (
      Logs.debug (fun m -> m "Verilog.step: cannot continue since we got empty input, illegal action or halt previously!");
      cfg'.last_inst_number, [], Output_internal.default
    )
  else
    (
      (* Logs.debug (fun m -> m "Verilog.step: input matched, running Verilog."); *)
      (* Read the template file, fill it with the new code and write it to the filled file *)
      let template_code = In_channel.read_all cfg'.templatefile in
      let labels, code = fill_template template_code cfg' in
        Logs.debug (fun m -> m "filledfile: %s" cfg'.filledfile);
        Out_channel.write_all cfg'.filledfile ~data:code;
        (* Now, if dry_output is None, run the simulator and collect results; Otherwise return dry_output directly *)
        (* If the output is one of those for which left_labels might not be empty, ignore the directive! *)
        (* Dry is used only if the output we expect empties the contents of left_labels: *)
        (* let open Output_internal in *)
        let force_no_dry () =
          let t, ll, e = match run_simulator cfg' with
            | Error o -> cfg'.last_inst_number, [], [o]
            | Ok (diverges, d) ->
                let l_last_inst_number, l_left_labels, l_out = analyse_dump diverges cfg' labels d in
                (* If we observed a reti, we need to re-perform the analysis on left_labels, otherwise we are done! *)
                match List.find l_out ~f:(fun el -> match el with Output_internal.OReti _ -> true | _ -> false) with
                | None -> l_last_inst_number, cfg'.left_labels @ l_left_labels, l_out
                | Some _ ->
                  (* Logs.debug (fun p -> p "Reti found: re-launching: ll: %s; l: %s" ([%derive.show: (string*string) list] cfg'.left_labels) ([%derive.show: (string*string) list] labels)); *)
                  analyse_dump diverges cfg' (cfg'.left_labels @ labels) d in (t, ll, (e, ll, t))
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
  (* If we observe a reset, this is special and we should behave as if a pre () was issued by the learning algorithm *)
  if List.mem (fst3 out) OReset ~equal:Output_internal.equal_element_t then pre cfg else ();
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
  ) else ();
  out

let post _ = ()
