open Core
open Sancus

open Enclave
open Sancus.Output_internal
open Attacklib

let spec_parse_or_fail spec =
  match Testdl.Parser.parse_spec spec with
  | Result.Ok r -> r
  | Result.Error e -> failwith e

let attack_trace_parse_or_fail trace =
  match Testdl.Parser.parse_attack_trace trace with
  | Result.Ok r -> r
  | Result.Error e -> failwith (sprintf "Failure in parsing attack sequence: %s" e)

(* This is the configuration for tests *)
let tmpdir = "../../tmp"
let specdir = "../../spec-lib/"
let sancus_core_gap_dir = "../../sancus-core-gap"
let sancus_master_key = "cafe"
let orig_commit = "ef753b6"
let last_commit = "bf89c0b"

(* This runs the simulator on input_str and returns the list of outputs *)
let exec_sim ~tmpdir ~enclave_spec_fn ~attacker_spec_fn ~sancus_core_gap_dir ~sancus_master_key ~commit ~secret ~input_str ~ignore_interrupts =
  Random.init 0;
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Debug);
  let cwd = Sys_unix.getcwd () in
  Logs.debug (fun m -> m "Current directory: %s" cwd);
  (* Create tmpdir if not present *)
  (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
  let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
  (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
  (* Basic sanity checks on the repo *)
  assert (Sys_unix.file_exists_exn sancus_core_gap_dir);
  assert (Sys_unix.is_directory_exn sancus_core_gap_dir);
  (* We are now ready to load the specs *)
  let enclave_spec_str = In_channel.read_all enclave_spec_fn in
  let attacker_spec_str = In_channel.read_all attacker_spec_fn in
  Logs.debug (fun m -> m "Enclave spec: %s" enclave_spec_str);
  Logs.debug (fun m -> m "Attacker spec: %s" attacker_spec_str);
  let spec_w_secret = spec_parse_or_fail (enclave_spec_str ^ " " ^ attacker_spec_str) in
  (* Fill in the secret *)
  let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = spec_w_secret in
  let enclave = Enclave.expand_secret secret enclave in
  let open Testdl in
  let complete_spec = (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) in
  let spec_dfa = Inputgen.build_spec_dfa complete_spec in
  (* Pasrse the enclave and fill in the secret *)
  let input_sequence_w_secret = attack_trace_parse_or_fail input_str in
  let open Input in
  let input_sequence = List.map input_sequence_w_secret ~f:(fun i ->
    match i with
    | (IEnclave a) -> IEnclave (Enclave.atom_expand_secret secret a)
    | _ -> i
  ) in
  (* initialize the interface with the processor's implementation *)
  let sul =
    Sancus.Verilog.make
      ~workingdir:cwd
      ~tmpdir:tmpdir
      ~basename:"generic"
      ~verilog_compile: (cwd ^ "/../scripts/verilog_compile")
      ~get_symbolpos: (cwd ^ "/../scripts/get_symbolpos.sh")
      ~pmem_elf:"pmem.elf"
      ~pmem_script:(cwd ^ "/../scripts/build_pmem")
      ~simulate_script:(cwd ^ "/../scripts/simulate")
      ~submitfile:(cwd ^ "/../src/submit.f")
      ~sancus_repo:sancus_core_gap_dir
      ~sancus_master_key:sancus_master_key
      ~commit:commit
      ~templatefile:(cwd ^ "/../src/generic_template.s43")
      ~filledfile:"generic.s43"
      ~dumpfile:"tb_openMSP430.vcd"
      ~initial_spec:spec_dfa
      ~ignore_interrupts:ignore_interrupts () in
        List.fold input_sequence ~init:[] ~f:(fun acc i -> let o = Sancus.Verilog.step sul i in acc @ [o])

(* Testable element_t *)
(*
  We compare elements using their payload ( *EXCLUDING* k, which is there just for humans looking at the trace!).gie
  Since we want to mimick attackers, payloads s.t. both are PM are trivially equal.
*)
let equal_public_payload_t p p' = (equal_mode_t p.mode PM && equal_mode_t p.mode PM) || Bool.(=) p.gie p'.gie && p.umem_val = p'.umem_val && p.reg_val = p'.reg_val && p.timerA_counter = p'.timerA_counter && equal_mode_t p.mode p'.mode
let equal_public_element_t e e' =
  match e, e' with
  | OMaybeDiverge, OMaybeDiverge | OIllegal, OIllegal | OReset, OReset | OSilent, OSilent | OUnsupported, OUnsupported -> true
  | OJmpOut p, OJmpOut p' | OReti p, OReti p' | OTime p, OTime p' -> equal_public_payload_t p p'
  | OJmpOut_Handle (p, p'), OJmpOut_Handle (p'', p''') -> equal_public_payload_t p p'' && equal_public_payload_t p' p'''
  | OTime_Handle (_, p), OTime_Handle (_, p') -> equal_public_payload_t p p'
  | _ -> false

let element_t_testable = Alcotest.testable pp_element_t equal_public_element_t

let exec ?(ignore_illegal=false) ?(n=1) ?(encl_spec_name="enclave-complete") ~att_spec_name ~input_str ~ignore_interrupts ~commit ~expected () =
  let enclave_spec_fn = specdir ^ "/" ^ encl_spec_name ^ ".etdl" in
  let attacker_spec_fn = specdir ^ "/" ^ att_spec_name ^ ".atdl" in
  List.iter expected ~f:(fun (secret, expected_out) ->
    let get_actual r = List.drop r (List.length r - n) in
    let drop_illegal r = if ignore_illegal then List.take_while r ~f:(fun (e, _, _) -> not (List.mem e OIllegal ~equal:equal_element_t)) else r in
    let res = get_actual (drop_illegal (exec_sim ~tmpdir ~enclave_spec_fn ~attacker_spec_fn ~sancus_core_gap_dir ~sancus_master_key ~secret:secret ~commit ~input_str ~ignore_interrupts)) in
    Alcotest.(check (list (list element_t_testable))) (sprintf "exec: ignore_interrupts: %b; attacker: %s; commit: %s; secret: %s" ignore_interrupts att_spec_name commit secret) expected_out (List.map res ~f:fst3)
  )

let () =
  let open Alcotest in
    run "verilog" [
      "example", [
        test_case "(bugged enclave) w/o interrupts, example" `Slow (exec ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave" ~input_str:input_attacker_encl ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_attacker_encl0); ("1", output_attacker_encl1)]);
        test_case "(bugged enclave) w interrupts, example" `Slow (exec ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave" ~input_str:input_attacker_encl ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_attacker_encl0); ("1", output_attacker_encl1)]);
      ];
      "b1", [
        test_case "(original commit) w/o interrupts, b1 + encl" `Slow (exec ~att_spec_name:"b1" ~input_str:input_b1_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b1_encl_noint); ("1", output_b1_encl_noint)]);
        test_case "(original commit) w interrupts, b1 + encl" `Slow (exec ~att_spec_name:"b1" ~input_str:input_b1_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b1_encl0_int_orig); ("1", output_b1_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b1 + encl" `Slow (exec ~att_spec_name:"b1" ~input_str:input_b1_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b1_encl_noint); ("1", output_b1_encl_noint)]);
        test_case "(last commit) w interrupts, b1 + encl" `Slow (exec ~att_spec_name:"b1" ~input_str:input_b1_encl_int ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b1_encl_int_last); ("1", output_b1_encl_int_last)]);
      ];
      "b2", [
        test_case "(original commit) w/o interrupts, b2 + encl" `Slow (exec ~att_spec_name:"b2" ~input_str:input_b2_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b2_encl_noint); ("1", output_b2_encl_noint)]);
        test_case "(original commit) w interrupts, b2 + encl" `Slow (exec ~att_spec_name:"b2" ~input_str:input_b2_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b2_encl0_int_orig); ("1", output_b2_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b2 + encl" `Slow (exec ~att_spec_name:"b2" ~input_str:input_b2_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b2_encl_noint); ("1", output_b2_encl_noint)]);
        test_case "(last commit) w interrupts, b2 + encl" `Slow (exec ~att_spec_name:"b2" ~input_str:input_b2_encl_int ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b2_encl_int_last); ("1", output_b2_encl_int_last)]);
      ];
      "b3", [
        test_case "(original commit) w/o interrupts, b3 + encl" `Slow (exec ~att_spec_name:"b3" ~input_str:input_b3_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b3_encl_noint); ("1", output_b3_encl_noint)]);
        test_case "(original commit) w interrupts, b3 + encl" `Slow (exec ~att_spec_name:"b3" ~input_str:input_b3_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b3_encl0_int_orig); ("1", output_b3_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b3 + encl" `Slow (exec ~att_spec_name:"b3" ~input_str:input_b3_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b3_encl_noint); ("1", output_b3_encl_noint)]);
        test_case "(last commit) w interrupts, b3 + encl" `Slow (exec ~att_spec_name:"b3" ~input_str:input_b3_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b3_encl_int_last); ("1", output_b3_encl_int_last)]);
      ];
      "b4", [
        test_case "(original commit) w/o interrupts, b4 + encl" `Slow (exec ~att_spec_name:"b4" ~input_str:input_b4_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b4_encl_noint); ("1", output_b4_encl_noint)]);
        test_case "(original commit) w interrupts, b4 + encl" `Slow (exec ~att_spec_name:"b4" ~input_str:input_b4_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b4_encl0_int_orig); ("1", output_b4_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b4 + encl" `Slow (exec ~att_spec_name:"b4" ~input_str:input_b4_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b4_encl_noint); ("1", output_b4_encl_noint)]);
        test_case "(last commit) w interrupts, b4 + encl" `Slow (exec ~att_spec_name:"b4" ~input_str:input_b4_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b4_encl_int_last); ("1", output_b4_encl_int_last)]);
      ];
      "b6", [
        test_case "(original commit) w/o interrupts, b6 + encl" `Slow (exec ~att_spec_name:"b6" ~input_str:input_b6_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b6_encl_noint); ("1", output_b6_encl_noint)]);
        test_case "(original commit) w interrupts, b6 + encl" `Slow (exec ~att_spec_name:"b6" ~input_str:input_b6_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b6_encl0_int_orig); ("1", output_b6_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b6 + encl" `Slow (exec ~att_spec_name:"b6" ~input_str:input_b6_encl_noint_last ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b6_encl_noint_last); ("1", output_b6_encl_noint_last)]);
        test_case "(last commit -- also *WITNESS of b8*) w interrupts, b6 + encl" `Slow (exec ~att_spec_name:"b6" ~input_str:input_b6_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b6_encl0_int_last); ("1", output_b6_encl1_int_last)]);
      ];
      "b7", [
        test_case "(original commit) w/o interrupts, b7 + encl" `Slow (exec ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b7_encl_noint); ("1", output_b7_encl_noint)]);
        test_case "(original commit) w interrupts, b7 + encl" `Slow (exec ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b7_encl0_int_orig); ("1", output_b7_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b7 + encl" `Slow (exec ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b7_encl_noint_last); ("1", output_b7_encl_noint_last)]);
        test_case "(last commit) w interrupts, b7 + encl" `Slow (exec ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b7_encl_int_last); ("1", output_b7_encl_int_last)]);
      ];
      "b8", [
        test_case "(original commit) w/o interrupts, b8 + encl" `Slow (exec ~att_spec_name:"b8" ~input_str:input_b8_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b8_encl_noint); ("1", output_b8_encl_noint)]);
        test_case "(original commit) w interrupts, b8 + encl" `Slow (exec ~att_spec_name:"b8" ~input_str:input_b8_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b8_encl0_int_orig); ("1", output_b8_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b8 + encl" `Slow (exec ~att_spec_name:"b8" ~input_str:input_b8_encl_noint_last ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b8_encl_noint_last); ("1", output_b8_encl_noint_last)]);
        test_case "(last commit) w interrupts, b8 + encl" `Slow (exec ~att_spec_name:"b8" ~input_str:input_b8_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b8_encl0_int_last); ("1", output_b8_encl1_int_last)]);
      ];
      "b9", [
        test_case "(original commit) w/o interrupts, b9 + encl" `Slow (exec ~att_spec_name:"b9" ~input_str:input_b9_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_b9_encl_noint); ("1", output_b9_encl_noint)]);
        test_case "(original commit) w interrupts, b9 + encl" `Slow (exec ~att_spec_name:"b9" ~input_str:input_b9_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_b9_encl0_int_orig); ("1", output_b9_encl1_int_orig)]);
        test_case "(last commit) w/o interrupts, b9 + encl" `Slow (exec ~att_spec_name:"b9" ~input_str:input_b9_encl_noint_last ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_b9_encl_noint_last); ("1", output_b9_encl_noint_last)]);
        test_case "(last commit -- vulnerable) w interrupts, b9 + encl" `Slow (exec ~att_spec_name:"b9" ~input_str:input_b9_encl_int_last ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_b9_encl0_int_last); ("1", output_b9_encl1_int_last)]);
      ];
      "new anomaly", [
        test_case "(original commit) w/o interrupts, new anomaly + encl" `Slow (exec ~att_spec_name:"a" ~input_str:input_a_encl_noint ~ignore_interrupts:true ~commit:orig_commit ~expected:[("0", output_a_encl_noint); ("1", output_a_encl_noint)]);
        test_case "(original commit) w interrupts, new anomaly + encl" `Slow (exec ~n:2 ~att_spec_name:"a" ~input_str:input_a_encl_int ~ignore_interrupts:false ~commit:orig_commit ~expected:[("0", output_a_encl0_int); ("1", output_a_encl1_int)]);
        test_case "(bugged, last_commit) w/o interrupts, new anomaly + encl" `Slow (exec ~att_spec_name:"a" ~input_str:input_a_encl_noint ~ignore_interrupts:true ~commit:last_commit ~expected:[("0", output_a_encl_noint); ("1", output_a_encl_noint)]);
        test_case "(bugged, last_commit) w interrupts, new anomaly + encl" `Slow (exec ~n:2 ~att_spec_name:"a" ~input_str:input_a_encl_int ~ignore_interrupts:false ~commit:last_commit ~expected:[("0", output_a_encl0_int); ("1", output_a_encl1_int)]);
      ];
    ]
