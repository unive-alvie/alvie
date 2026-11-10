(*
  tt_attack_fpga: the attack traces of tt_attack, replayed on an FPGA board (ALVIE/Sancus-FPGA: the Sancus backend
  with the board as its target).

  It needs the board, so it is not part of CI: see docs/sancus/fpga.md. It runs the cases of tt_attack for the Sancus
  commit of the image on the board, ef753b6 or bf89c0b, which the image says (an image that does not say it: the
  commit is ALVIE_FPGA_COMMIT). The serial port is ALVIE_FPGA_PORT (default /dev/ttyUSB1). Run it from alvie/code:
  dune exec test/attack_fpga.exe.

  The expected observations are the simulator's (Attacklib), compared as tt_attack compares them: the board must
  observe what the simulator observes. The cases of "cleanup re-entry" are not here.
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
let orig_commit = "ef753b6"
let last_commit = "bf89c0b"
let port = Option.value (Sys.getenv "ALVIE_FPGA_PORT") ~default:"/dev/ttyUSB1"

(* The commit of the image on the board *)
let image_commit =
  match Sancus_fpga.Fpga.identify (Sancus_fpga.Fpga.connect ~port) with
  | Some id -> id.sancus_commit
  | None ->
    match Sys.getenv "ALVIE_FPGA_COMMIT" with
    | Some c -> c
    | None -> failwith "The image on the board does not say which Sancus commit it runs: give it with ALVIE_FPGA_COMMIT"

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
      ~ignore_interrupts ~target:(Sancus_fpga.Fpga.target ~port ~sancus:sancus_core_gap_dir ~commit:image_commit) () in
  List.fold input_sequence ~init:[] ~f:(fun acc i -> acc @ [ Verilog.step sul i ])

(* As tt_attack's comparison: k is not compared (on the board, the window bounds it), and payloads in PM are equal *)
let equal_public_payload_t p p' =
  (equal_mode_t p.mode PM && equal_mode_t p'.mode PM)
  || Bool.(=) p.gie p'.gie && p.umem_val = p'.umem_val && p.reg_val = p'.reg_val && p.timerA_counter = p'.timerA_counter && equal_mode_t p.mode p'.mode

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

let () =
  let open Alcotest in
  if not (List.mem [ orig_commit; last_commit ] image_commit ~equal:String.equal) then
    failwithf "The image on the board runs Sancus %s: tt_attack_fpga has cases for %s and %s only" image_commit orig_commit last_commit ();
  (* The cases of tt_attack for commit, only if it is the image's *)
  let case ~commit name ?ignore_illegal ?n ?encl_spec_name ~att_spec_name ~input_str ~ignore_interrupts expected =
    if String.equal commit image_commit then
      [ test_case name `Slow (exec ?ignore_illegal ?n ?encl_spec_name ~att_spec_name ~input_str ~ignore_interrupts ~expected) ]
    else [] in
  let orig = case ~commit:orig_commit and last = case ~commit:last_commit in
  let both o = [ ("0", o); ("1", o) ] in
  let example ~commit = List.concat [
    case ~commit "(bugged enclave) w/o interrupts, example" ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave"
      ~input_str:input_attacker_encl ~ignore_interrupts:true [ ("0", output_attacker_encl0); ("1", output_attacker_encl1) ];
    case ~commit "(bugged enclave) w interrupts, example" ~att_spec_name:"example/attacker" ~encl_spec_name:"example/enclave"
      ~input_str:input_attacker_encl ~ignore_interrupts:false [ ("0", output_attacker_encl0); ("1", output_attacker_encl1) ];
  ] in
  run ("fpga " ^ image_commit) [
    "example", example ~commit:orig_commit @ example ~commit:last_commit;
    "b1", List.concat [
      orig "(original commit) w/o interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_noint ~ignore_interrupts:true (both output_b1_encl_noint);
      orig "(original commit) w interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_int ~ignore_interrupts:false
        [ ("0", output_b1_encl0_int_orig); ("1", output_b1_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_noint ~ignore_interrupts:true (both output_b1_encl_noint);
      last "(last commit) w interrupts, b1 + encl" ~att_spec_name:"b1" ~input_str:input_b1_encl_int ~ignore_interrupts:false (both output_b1_encl_int_last);
    ];
    "b2", List.concat [
      orig "(original commit) w/o interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_noint ~ignore_interrupts:true (both output_b2_encl_noint);
      orig "(original commit) w interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_int ~ignore_interrupts:false
        [ ("0", output_b2_encl0_int_orig); ("1", output_b2_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_noint ~ignore_interrupts:true (both output_b2_encl_noint);
      last "(last commit) w interrupts, b2 + encl" ~att_spec_name:"b2" ~input_str:input_b2_encl_int ~ignore_interrupts:false (both output_b2_encl_int_last);
    ];
    "b3", List.concat [
      orig "(original commit) w/o interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_noint ~ignore_interrupts:true (both output_b3_encl_noint);
      orig "(original commit) w interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_int ~ignore_interrupts:false
        [ ("0", output_b3_encl0_int_orig); ("1", output_b3_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_noint ~ignore_interrupts:true (both output_b3_encl_noint);
      last "(last commit) w interrupts, b3 + encl" ~att_spec_name:"b3" ~input_str:input_b3_encl_int_last ~ignore_interrupts:false (both output_b3_encl_int_last);
    ];
    "b4", List.concat [
      orig "(original commit) w/o interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_noint ~ignore_interrupts:true (both output_b4_encl_noint);
      orig "(original commit) w interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_int ~ignore_interrupts:false
        [ ("0", output_b4_encl0_int_orig); ("1", output_b4_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_noint ~ignore_interrupts:true (both output_b4_encl_noint);
      last "(last commit) w interrupts, b4 + encl" ~att_spec_name:"b4" ~input_str:input_b4_encl_int_last ~ignore_interrupts:false (both output_b4_encl_int_last);
    ];
    "b6", List.concat [
      orig "(original commit) w/o interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_noint ~ignore_interrupts:true (both output_b6_encl_noint);
      orig "(original commit) w interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_int ~ignore_interrupts:false
        [ ("0", output_b6_encl0_int_orig); ("1", output_b6_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_noint_last ~ignore_interrupts:true (both output_b6_encl_noint_last);
      last "(last commit -- also *WITNESS of b8*) w interrupts, b6 + encl" ~att_spec_name:"b6" ~input_str:input_b6_encl_int_last ~ignore_interrupts:false
        [ ("0", output_b6_encl0_int_last); ("1", output_b6_encl1_int_last) ];
    ];
    "b7", List.concat [
      orig "(original commit) w/o interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_noint ~ignore_interrupts:true
        (both output_b7_encl_noint);
      orig "(original commit) w interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_int ~ignore_interrupts:false
        [ ("0", output_b7_encl0_int_orig); ("1", output_b7_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_noint ~ignore_interrupts:true
        (both output_b7_encl_noint_last);
      last "(last commit) w interrupts, b7 + encl" ~ignore_illegal:true ~att_spec_name:"b7" ~input_str:input_b7_encl_int_last ~ignore_interrupts:false
        (both output_b7_encl_int_last);
    ];
    "b8", List.concat [
      orig "(original commit) w/o interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_noint ~ignore_interrupts:true (both output_b8_encl_noint);
      orig "(original commit) w interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_int ~ignore_interrupts:false
        [ ("0", output_b8_encl0_int_orig); ("1", output_b8_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_noint_last ~ignore_interrupts:true (both output_b8_encl_noint_last);
      last "(last commit) w interrupts, b8 + encl" ~att_spec_name:"b8" ~input_str:input_b8_encl_int_last ~ignore_interrupts:false
        [ ("0", output_b8_encl0_int_last); ("1", output_b8_encl1_int_last) ];
    ];
    "b9", List.concat [
      orig "(original commit) w/o interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_noint ~ignore_interrupts:true (both output_b9_encl_noint);
      orig "(original commit) w interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_int ~ignore_interrupts:false
        [ ("0", output_b9_encl0_int_orig); ("1", output_b9_encl1_int_orig) ];
      last "(last commit) w/o interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_noint_last ~ignore_interrupts:true (both output_b9_encl_noint_last);
      last "(last commit -- vulnerable) w interrupts, b9 + encl" ~att_spec_name:"b9" ~input_str:input_b9_encl_int_last ~ignore_interrupts:false
        [ ("0", output_b9_encl0_int_last); ("1", output_b9_encl1_int_last) ];
    ];
    "new anomaly", List.concat [
      orig "(original commit) w/o interrupts, new anomaly + encl" ~att_spec_name:"a" ~input_str:input_a_encl_noint ~ignore_interrupts:true (both output_a_encl_noint);
      orig "(original commit) w interrupts, new anomaly + encl" ~n:2 ~att_spec_name:"a" ~input_str:input_a_encl_int ~ignore_interrupts:false
        [ ("0", output_a_encl0_int); ("1", output_a_encl1_int) ];
      last "(bugged, last_commit) w/o interrupts, new anomaly + encl" ~att_spec_name:"a" ~input_str:input_a_encl_noint ~ignore_interrupts:true (both output_a_encl_noint);
      last "(bugged, last_commit) w interrupts, new anomaly + encl" ~n:2 ~att_spec_name:"a" ~input_str:input_a_encl_int ~ignore_interrupts:false
        [ ("0", output_a_encl0_int); ("1", output_a_encl1_int) ];
    ];
  ]
