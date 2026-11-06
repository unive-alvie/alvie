(*
  tt_attack_fpga: the attack traces of tt_attack, replayed on an FPGA board (ALVIE/Sancus-FPGA: the Sancus backend
  with the board as its target).

  It needs the board, so it is not part of CI: see docs/sancus/fpga.md. The board must run the image
  inst_number_50_ef753b6 (the commit these expectations are for); the serial port is ALVIE_FPGA_PORT (default
  /dev/ttyUSB1). Run it from alvie/code: dune exec test/attack_fpga.exe.

  The expected observations are the simulator's (Attacklib), except the cases below, each for a reason of the
  hardware. reg_val is not compared: r4 carries over between queries on the board (the data memory is not cleared
  between runs), so it depends on the previous test.
*)
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

let tmpdir = "../../tmp"
let specdir = "../../spec-lib/"
let sancus_core_gap_dir = "../../sancus-core-gap"
let sancus_master_key = "cafe"
let image_commit = "ef753b6"
let port = Option.value (Sys.getenv "ALVIE_FPGA_PORT") ~default:"/dev/ttyUSB1"

(* Runs input_str on the board and returns the list of outputs *)
let exec_fpga ~enclave_spec_fn ~attacker_spec_fn ~secret ~input_str ~ignore_interrupts =
  Random.init 0;
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Debug);
  let cwd = Sys_unix.getcwd () in
  Core_unix.mkdir_p tmpdir;
  let spec_w_secret = spec_parse_or_fail (In_channel.read_all enclave_spec_fn ^ " " ^ In_channel.read_all attacker_spec_fn) in
  let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = spec_w_secret in
  let enclave = Enclave.expand_secret secret enclave in
  let complete_spec = Testdl.(Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) in
  let input_sequence = List.map (attack_trace_parse_or_fail input_str) ~f:(function
    | Input.IEnclave a -> Input.IEnclave (Enclave.atom_expand_secret secret a)
    | i -> i) in
  let sul =
    Verilog.make
      ~workingdir:cwd ~tmpdir ~basename:"generic"
      ~verilog_compile:(cwd ^ "/../scripts/verilog_compile")
      ~get_symbolpos:(cwd ^ "/../scripts/get_symbolpos.sh")
      ~pmem_elf:"pmem.elf"
      ~pmem_script:(cwd ^ "/../scripts/build_pmem")
      ~simulate_script:(cwd ^ "/../scripts/simulate")
      ~submitfile:(cwd ^ "/../src/submit.f")
      ~sancus_repo:sancus_core_gap_dir ~sancus_master_key ~commit:image_commit
      ~templatefile:(cwd ^ "/../src/generic_template.s43")
      ~filledfile:"generic.s43" ~dumpfile:"tb_openMSP430.vcd"
      ~spec:(Generic_inputgen.spec_of_test_spec complete_spec)
      ~ignore_interrupts ~target:(Sancus_fpga.Fpga.target ~port) () in
  List.fold input_sequence ~init:[] ~f:(fun acc i -> acc @ [ Verilog.step sul i ])

(* As tt_attack's comparison (k is not compared, payloads in PM are equal), without reg_val *)
let equal_public_payload_t p p' =
  (equal_mode_t p.mode PM && equal_mode_t p'.mode PM)
  || Bool.(=) p.gie p'.gie && p.umem_val = p'.umem_val && p.timerA_counter = p'.timerA_counter && equal_mode_t p.mode p'.mode

let equal_public_element_t e e' =
  match e, e' with
  | OMaybeDiverge, OMaybeDiverge | OIllegal, OIllegal | OReset, OReset | OSilent, OSilent | OUnsupported, OUnsupported -> true
  | OJmpOut p, OJmpOut p' | OReti p, OReti p' | OTime p, OTime p' -> equal_public_payload_t p p'
  | OJmpOut_Handle (p, p'), OJmpOut_Handle (p'', p''') -> equal_public_payload_t p p'' && equal_public_payload_t p' p'''
  | OTime_Handle (_, p), OTime_Handle (_, p') -> equal_public_payload_t p p'
  | _ -> false

let element_t_testable = Alcotest.testable pp_element_t equal_public_element_t

let exec ?(ignore_illegal = false) ?(n = 1) ?(encl_spec_name = "enclave-complete") ~att_spec_name ~input_str ~ignore_interrupts ~expected () =
  let enclave_spec_fn = specdir ^ "/" ^ encl_spec_name ^ ".etdl" in
  let attacker_spec_fn = specdir ^ "/" ^ att_spec_name ^ ".atdl" in
  List.iter expected ~f:(fun (secret, expected_out) ->
    let get_actual r = List.drop r (List.length r - n) in
    let drop_illegal r =
      if ignore_illegal then List.take_while r ~f:(fun (e, _, _) -> not (List.mem e OIllegal ~equal:equal_element_t)) else r in
    let res = get_actual (drop_illegal (exec_fpga ~enclave_spec_fn ~attacker_spec_fn ~secret ~input_str ~ignore_interrupts)) in
    Alcotest.(check (list (list element_t_testable)))
      (sprintf "exec on the FPGA: ignore_interrupts: %b; attacker: %s; secret: %s" ignore_interrupts att_spec_name secret)
      expected_out (List.map res ~f:fst3))

(* ── The cases where the board differs from the simulator ─────────────────── *)

(* b3, b4: cycle counts and timerA differ at the boundary of the window *)
let output_b3_encl_noint = [ [ OTime { k = 19; gie = false; umem_val = 0; reg_val = 1; timerA_counter = 4; mode = UM } ] ]
let output_b3_encl_int = [ [ OJmpOut { k = 2; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM } ] ]
let output_b4_encl_noint = [ [ OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 1; timerA_counter = 0; mode = UM } ] ]
let output_b4_encl_int = [ [ OJmpOut { k = 2; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM } ] ]

(* b7 with interrupts: dint is effective on ef753b6, so for secret 0 the interrupt comes during enc:jmp and the enclave
   jumps out with gie cleared; for secret 1 the interrupt is taken inside the enclave and handled. That difference
   between the secrets is the b7 vulnerability. *)
let output_b7_encl0_int = [ [ OJmpOut { k = 3; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 5; mode = UM } ] ]
let output_b7_encl1_int = [
  [ OTime_Handle (
      { k = 4; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 8; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = UM }) ] ]

(* b9: the reset happens after the window closes, so the board reports the last instruction it saw; with interrupts,
   secret 1 takes and handles the interrupt where secret 0 does not *)
let output_b9_encl_noint = [ [ OTime { k = 6; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 3; mode = PM } ] ]
let output_b9_encl0_int = output_b9_encl_noint
let output_b9_encl1_int = [
  [ OTime_Handle (
      { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 8; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 2; mode = UM }) ] ]

(* The new anomaly: the divergence happens after the window closes *)
let output_a_encl_noint = [ [ OUnsupported ] ]
let output_a_encl_int = [
  [ OTime { k = 14; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM };
    OReti { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM } ];
  [ OUnsupported ] ]

let () =
  let open Alcotest in
  let case name ?ignore_illegal ?n ?encl_spec_name ~att_spec_name ~input_str ~ignore_interrupts expected =
    test_case name `Slow (exec ?ignore_illegal ?n ?encl_spec_name ~att_spec_name ~input_str ~ignore_interrupts ~expected) in
  let both o = [ ("0", o); ("1", o) ] in
  run "fpga" [
    "example", [
      case "(bugged enclave) w/o interrupts, example" ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave"
        ~input_str:input_attacker_encl ~ignore_interrupts:true [ ("0", output_attacker_encl0); ("1", output_attacker_encl1) ];
      case "(bugged enclave) w interrupts, example" ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave"
        ~input_str:input_attacker_encl ~ignore_interrupts:false [ ("0", output_attacker_encl0); ("1", output_attacker_encl1) ];
    ];
    "b1", [
      case "w/o interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_noint ~ignore_interrupts:true (both output_b1_encl_noint);
      case "w interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_int ~ignore_interrupts:false
        [ ("0", output_b1_encl0_int_orig); ("1", output_b1_encl1_int_orig) ];
    ];
    "b2", [
      case "w/o interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_noint ~ignore_interrupts:true (both output_b2_encl_noint);
      case "w interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_int ~ignore_interrupts:false
        [ ("0", output_b2_encl0_int_orig); ("1", output_b2_encl1_int_orig) ];
    ];
    "b3", [
      case "w/o interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_noint ~ignore_interrupts:true (both output_b3_encl_noint);
      case "w interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_int ~ignore_interrupts:false (both output_b3_encl_int);
    ];
    "b4", [
      case "w/o interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_noint ~ignore_interrupts:true (both output_b4_encl_noint);
      case "w interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_int ~ignore_interrupts:false (both output_b4_encl_int);
    ];
    "b6", [
      case "w/o interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_noint ~ignore_interrupts:true (both output_b6_encl_noint);
      case "w interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_int ~ignore_interrupts:false
        [ ("0", output_b6_encl0_int_orig); ("1", output_b6_encl1_int_orig) ];
    ];
    "b7", [
      case "w/o interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_noint ~ignore_interrupts:true
        (both output_b7_encl_noint);
      case "w interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_int ~ignore_interrupts:false
        [ ("0", output_b7_encl0_int); ("1", output_b7_encl1_int) ];
    ];
    "b8", [
      case "w/o interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_noint ~ignore_interrupts:true (both output_b8_encl_noint);
      case "w interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_int ~ignore_interrupts:false
        [ ("0", output_b8_encl0_int_orig); ("1", output_b8_encl1_int_orig) ];
    ];
    "b9", [
      case "w/o interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_noint ~ignore_interrupts:true (both output_b9_encl_noint);
      case "w interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_int ~ignore_interrupts:false
        [ ("0", output_b9_encl0_int); ("1", output_b9_encl1_int) ];
    ];
    "new anomaly", [
      case "w/o interrupts, new anomaly + encl" ~att_spec_name:"a" ~input_str:input_a_encl_noint ~ignore_interrupts:true (both output_a_encl_noint);
      case "w interrupts, new anomaly + encl" ~n:2 ~att_spec_name:"a" ~input_str:input_a_encl_int ~ignore_interrupts:false (both output_a_encl_int);
    ];
  ]
