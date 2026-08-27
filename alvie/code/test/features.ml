open Core

open Sancus
open Common
open Attacker
open Enclave

module OT = Learninglib.Observationtree.ObservationTree
  (Learninglib.Showableint.ShowableInt)
  (Input)
  (Output_internal)

let valid_spec = {|
enclave { nop; cmp ?, r4 };
isr { timer_enable 1; reti };
prepare { create <enc_s, enc_e, data_s, data_e>; jin enc_s };
cleanup { nop };
|}

let payload mode =
  { Output_internal.k = 1; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode }

let output element : Output_internal.t = ([element], [], 0)

let parse_spec_exn source =
  match Testdl.Parser.parse_spec source with
  | Ok spec -> spec
  | Error message -> failwith message

let test_parse_complete_spec () =
  let Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup = parse_spec_exn valid_spec in
  Alcotest.(check bool) "enclave is nonempty" false (Enclave.is_empty enclave);
  Alcotest.(check bool) "isr is nonempty" false (Attacker.is_empty isr);
  Alcotest.(check bool) "prepare is nonempty" false (Attacker.is_empty prepare);
  Alcotest.(check bool) "cleanup is nonempty" false (Attacker.is_empty cleanup)

let test_reject_invalid_spec () =
  let invalid = {|
enclave { mov #1, r15 };
isr { eps };
prepare { eps };
cleanup { eps };
|} in
  Alcotest.(check bool) "r15 is outside the TestDL register range" true
    (Result.is_error (Testdl.Parser.parse_spec invalid))

let test_parse_attack_trace () =
  let trace = "att: timer_enable 3; enc: cmp ?, r4; att: reti" in
  match Testdl.Parser.parse_attack_trace trace with
  | Error message -> Alcotest.fail message
  | Ok inputs ->
    Alcotest.(check int) "three inputs" 3 (List.length inputs);
    Alcotest.(check string) "first input" "(IAttacker (CTimerEnable #0x3))" (Input.show (List.hd_exn inputs));
    Alcotest.(check string) "last input" "(IAttacker CReti)" (Input.show (List.last_exn inputs))

let test_parse_language_operators () =
  let source = {|
enclave { (nop | add #1, r4)*; balanced_ifz (nop; mov #1, r4); ifz (nop) (dint) };
isr { ifz (timer_enable 1) (reti); reti };
prepare { create <enc_s, enc_e, data_s, data_e>; jin enc_s };
cleanup { nop };
|} in
  let Enclave enclave, ISR isr, _, _ = parse_spec_exn source in
  Alcotest.(check bool) "compound enclave language is nonempty" false (Enclave.is_empty enclave);
  Alcotest.(check bool) "conditional attacker language is nonempty" false (Attacker.is_empty isr)

let test_reject_invalid_attack_trace () =
  Alcotest.(check bool) "negative timer is rejected" true
    (Result.is_error (Testdl.Parser.parse_attack_trace "att: timer_enable -1"))

let test_enclave_secret_expansion () =
  let original = Enclave.Atom (Enclave.CInst (I_CMP (S_SECRET, D_R (R 4)))) in
  let expanded = Enclave.expand_secret "42" original in
  Alcotest.(check bool) "original has a secret" true (Enclave.has_secret original);
  Alcotest.(check bool) "expanded form has no secret" false (Enclave.has_secret expanded);
  Alcotest.(check string) "expanded atom"
    "(Enclave.Enclave.Atom (CInst cmp #42, r4))"
    (Enclave.show_body_t expanded)

let test_nested_secret_expansion () =
  let original = Enclave.Atom (Enclave.CIfZ
    ([Enclave.CInst (I_MOV (S_SECRET, D_R (R 4)))],
     [Enclave.CBalancedIfZ [I_ADD (S_SECRET, D_R (R 4))]])) in
  let expanded = Enclave.expand_secret "7" original in
  Alcotest.(check bool) "nested secret is detected" true (Enclave.has_secret original);
  Alcotest.(check bool) "nested secret is expanded" false (Enclave.has_secret expanded);
  Alcotest.(check bool) "expanded nested action" true
    (match expanded with
     | Enclave.Atom (Enclave.CIfZ
         ([Enclave.CInst (I_MOV (S_IMM "7", D_R (R 4)))],
          [Enclave.CBalancedIfZ [I_ADD (S_IMM "7", D_R (R 4))]])) -> true
     | _ -> false)

let test_instruction_cycles () =
  Alcotest.(check int) "immediate to register" 2
    (cycles_of_inst (I_MOV (S_IMM "42", D_R (R 4))));
  Alcotest.(check int) "immediate to memory" 5
    (cycles_of_inst (I_MOV (S_IMM "42", D_AMP_MEM "unprot_mem")));
  Alcotest.(check int) "push from memory" 5
    (cycles_of_inst (I_PUSH (S_AMP "unprot_mem")))

let test_attacker_compilation () =
  let attacker = (Attacker.C_ISR [NoLabel (Attacker.CTimerEnable 3)], Attacker.C_Prepare [], Attacker.C_Cleanup []) in
  let _, enabled, _, _ = Attacker.compile ~ignore_interrupts:false attacker in
  let _, disabled, _, _ = Attacker.compile ~ignore_interrupts:true attacker in
  Alcotest.(check bool) "normal timer setup enables interrupts" true
    (List.mem enabled "mov #0x212, &tactl_val" ~equal:String.equal);
  Alcotest.(check bool) "ignore-interrupts timer setup does not enable them" true
    (List.mem disabled "mov #0x214, &tactl_val" ~equal:String.equal);
  Alcotest.(check bool) "timer value is preserved" true
    (List.mem enabled "mov #3, &TACCR0" ~equal:String.equal)

let test_start_counting_compilation () =
  let attacker = (Attacker.C_ISR [], Attacker.C_Prepare [NoLabel (Attacker.CStartCounting 5)], Attacker.C_Cleanup []) in
  let _, _, prepare, _ = Attacker.compile ~ignore_interrupts:false attacker in
  Alcotest.(check bool) "counter compensates for jump-in timing" true
    (List.mem prepare "mov #3, &TACCR0" ~equal:String.equal);
  Alcotest.(check bool) "counter does not schedule an interrupt" true
    (List.mem prepare "mov #0x214, &tactl_val" ~equal:String.equal)

let test_enclave_compilation_labels () =
  Common.reset_last_used_idx ();
  let labels, assembly = Enclave.compile (Enclave.C_Enclave [Label (Enclave.CInst I_NOP)]) in
  Alcotest.(check (list (pair string string))) "instruction labels" ["S_0", "E_0"] labels;
  Alcotest.(check bool) "assembled nop" true (List.mem assembly "nop" ~equal:String.equal)

let test_balanced_ifz_compilation () =
  Common.reset_last_used_idx ();
  let _, assembly = Enclave.compile (Enclave.C_Enclave [NoLabel
    (Enclave.CBalancedIfZ [I_NOP; I_MOV (S_IMM "1", D_R (R 4))])]) in
  Alcotest.(check int) "padding plus branch body emits four nops" 4
    (List.count assembly ~f:(String.equal "nop"));
  Alcotest.(check bool) "branch body is preserved" true
    (List.mem assembly "mov #1, r4" ~equal:String.equal)

let test_derivatives () =
  let nop = Attacker.CInst I_NOP in
  let body = Attacker.Seq (Attacker.Atom nop, Attacker.Atom Attacker.CReti) in
  let after_nop = Attacker.derive body nop in
  Alcotest.(check bool) "remaining reti is accepted" false (Attacker.is_empty (Attacker.derive after_nop Attacker.CReti));
  Alcotest.(check bool) "wrong action is rejected" true (Attacker.is_empty (Attacker.derive after_nop nop))

let test_star_derivatives () =
  let nop = Attacker.CInst I_NOP in
  let repeated = Attacker.Star (Attacker.Atom nop) in
  let after_one = Attacker.derive repeated nop in
  Alcotest.(check bool) "star accepts the first repetition" false (Attacker.is_empty after_one);
  Alcotest.(check bool) "star accepts the second repetition" false
    (Attacker.is_empty (Attacker.derive after_one nop));
  Alcotest.(check bool) "star rejects a different action" true
    (Attacker.is_empty (Attacker.derive repeated Attacker.CReti))

let test_enclave_derivatives () =
  let nop = Enclave.CInst I_NOP in
  let cmp = Enclave.CInst (I_CMP (S_IMM "0", D_R (R 4))) in
  let body = Enclave.Seq (Enclave.Atom nop, Enclave.Atom cmp) in
  let after_nop = Enclave.derive body nop in
  Alcotest.(check bool) "enclave accepts remaining comparison" false
    (Enclave.is_empty (Enclave.derive after_nop cmp));
  Alcotest.(check bool) "enclave rejects a repeated nop" true
    (Enclave.is_empty (Enclave.derive after_nop nop))

let test_input_generation_follows_sections () =
  let spec = Inputgen.build_spec_dfa (parse_spec_exn valid_spec) in
  let _, first = Inputgen.get_options spec [] [] in
  let create = Input.IAttacker (Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e")) in
  Alcotest.(check bool) "prepare starts with create" true (List.mem first (`Next create) ~equal:Poly.equal);
  let _, second = Inputgen.get_options spec [create] [output (OTime (payload UM))] in
  let jmp_in = Input.IAttacker (Attacker.CJmpIn "enc_s") in
  Alcotest.(check bool) "create is followed by jump-in" true (List.mem second (`Next jmp_in) ~equal:Poly.equal);
  let _, enclave_options = Inputgen.get_options spec [create; jmp_in]
    [output (OTime (payload UM)); output (OJmpIn (payload PM))] in
  Alcotest.(check bool) "jump-in enters enclave section" true
    (List.mem enclave_options (`Next (Input.IEnclave (Enclave.CInst I_NOP))) ~equal:Poly.equal)

let test_input_generation_rejects_wrong_mode () =
  let spec = Inputgen.build_spec_dfa (parse_spec_exn valid_spec) in
  let _, accepted = Inputgen.matchable spec (Input.IEnclave (Enclave.CInst I_NOP)) [] [] in
  Alcotest.(check bool) "enclave action is not valid during prepare" false accepted

let test_input_generation_tracks_interrupts () =
  let spec = Inputgen.build_spec_dfa (parse_spec_exn valid_spec) in
  let create = Input.IAttacker (Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e")) in
  let jmp_in = Input.IAttacker (Attacker.CJmpIn "enc_s") in
  let nop = Input.IEnclave (Enclave.CInst I_NOP) in
  let timer = Input.IAttacker (Attacker.CTimerEnable 1) in
  let reti = Input.IAttacker Attacker.CReti in
  let inputs = [create; jmp_in; nop] in
  let outputs = [output (OTime (payload UM)); output (OJmpIn (payload PM)); output (OTime_Handle (payload PM, payload PM))] in
  let _, isr_options = Inputgen.get_options spec inputs outputs in
  Alcotest.(check bool) "interrupt enters the ISR language" true
    (List.mem isr_options (`Next timer) ~equal:Poly.equal);
  let _, reti_options = Inputgen.get_options spec (inputs @ [timer])
    (outputs @ [output (OTime (payload PM))]) in
  Alcotest.(check bool) "ISR advances to reti" true
    (List.mem reti_options (`Next reti) ~equal:Poly.equal);
  let _, enclave_options = Inputgen.get_options spec (inputs @ [timer; reti])
    (outputs @ [output (OTime (payload PM)); output (OReti (payload PM))]) in
  Alcotest.(check bool) "reti resumes the interrupted enclave" true
    (List.mem enclave_options (`Next (Input.IEnclave (Enclave.CInst (I_CMP (S_SECRET, D_R (R 4)))))) ~equal:Poly.equal)

let test_input_generation_stops_after_illegal_output () =
  let spec = Inputgen.build_spec_dfa (parse_spec_exn valid_spec) in
  let create = Input.IAttacker (Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e")) in
  let _, options = Inputgen.get_options spec [create] [output OIllegal] in
  Alcotest.(check (list string)) "illegal output stops generation" ["`Stop"]
    (List.map options ~f:(function `Stop -> "`Stop" | `Next input -> Input.show input))

let test_observation_tree_access_and_apartness () =
  let timer = Input.IAttacker (Attacker.CTimerEnable 1) in
  let reti = Input.IAttacker Attacker.CReti in
  let states = OT.SSet.of_list [0; 1; 2; 3; 4; 5; 6] in
  let alphabet = OT.ISet.of_list [timer; reti] in
  let transition = OT.TransitionMap.of_alist_exn [
    ((0, timer), (output OSilent, 1));
    ((0, reti), (output OSilent, 2));
    ((1, timer), (output OSilent, 3));
    ((1, reti), (output (OReset), 4));
    ((2, timer), (output OSilent, 5));
    ((2, reti), (output OSilent, 6));
  ] in
  let tree = OT.make ~states ~s0:0 ~input_alphabet:alphabet ~transition in
  Alcotest.(check (list string)) "access sequence to state 1"
    [Input.show timer] (List.map (OT.access tree 1) ~f:Input.show);
  match OT.apart_with_witness tree 1 2 with
  | `NotApart -> Alcotest.fail "states should be distinguished by reti"
  | `Apart witness ->
    Alcotest.(check (list string)) "apartness witness"
      [Input.show reti] (List.map witness ~f:Input.show)

let test_observation_round_trip () =
  let open Ltscomparator in
  let observation = Obs.Obs.make
    (Obs.InputExt.of_input (Input.IAttacker (Attacker.CTimerEnable 2)))
    (Obs.OutputExt.of_output (OTime (payload PM))) in
  Alcotest.(check bool) "serialized observation parses back" true
    (Obs.Obs.equal observation (Obs.Obs.parse (Obs.Obs.show observation)));
  Alcotest.(check bool) "privileged timing is silent" true (Obs.Obs.is_silent observation)

let test_input_sexp_round_trip () =
  let input = Input.IAttacker (Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e")) in
  let restored = Input.t_of_sexp (Sexp.of_string (Sexp.to_string (Input.sexp_of_t input))) in
  Alcotest.(check string) "serialized input parses back" (Input.show input) (Input.show restored)

let test_payload_merge () =
  let older = { (payload PM) with k = 3; umem_val = 1 } in
  let newer = { (payload UM) with k = 4; umem_val = 2; reg_val = 7 } in
  let merged = Output_internal.merge_payload ~older ~newer in
  Alcotest.(check int) "cycle counts are added" 7 merged.k;
  Alcotest.(check int) "new payload data is retained" 2 merged.umem_val;
  Alcotest.(check int) "new register value is retained" 7 merged.reg_val;
  Alcotest.(check string) "new mode is retained" "UM" (Output_internal.show_mode_t merged.mode)

let () =
  Alcotest.run "ALVIE isolated features" [
    "TestDL parsing", [
      Alcotest.test_case "parse complete specification" `Quick test_parse_complete_spec;
      Alcotest.test_case "reject invalid register" `Quick test_reject_invalid_spec;
      Alcotest.test_case "parse mixed attack trace" `Quick test_parse_attack_trace;
      Alcotest.test_case "parse language operators" `Quick test_parse_language_operators;
      Alcotest.test_case "reject invalid attack trace" `Quick test_reject_invalid_attack_trace;
    ];
    "Specification semantics", [
      Alcotest.test_case "expand secret values" `Quick test_enclave_secret_expansion;
      Alcotest.test_case "expand nested secret values" `Quick test_nested_secret_expansion;
      Alcotest.test_case "calculate instruction cycles" `Quick test_instruction_cycles;
      Alcotest.test_case "compile timer configuration" `Quick test_attacker_compilation;
      Alcotest.test_case "compile timer counting" `Quick test_start_counting_compilation;
      Alcotest.test_case "emit enclave labels" `Quick test_enclave_compilation_labels;
      Alcotest.test_case "compile balanced branch" `Quick test_balanced_ifz_compilation;
      Alcotest.test_case "derive attacker languages" `Quick test_derivatives;
      Alcotest.test_case "derive starred attacker language" `Quick test_star_derivatives;
      Alcotest.test_case "derive enclave language" `Quick test_enclave_derivatives;
    ];
    "Input generation", [
      Alcotest.test_case "follow TestDL sections" `Quick test_input_generation_follows_sections;
      Alcotest.test_case "reject action in wrong section" `Quick test_input_generation_rejects_wrong_mode;
      Alcotest.test_case "track interrupts and reti" `Quick test_input_generation_tracks_interrupts;
      Alcotest.test_case "stop after illegal output" `Quick test_input_generation_stops_after_illegal_output;
    ];
    "Models and observations", [
      Alcotest.test_case "compute access and apartness" `Quick test_observation_tree_access_and_apartness;
      Alcotest.test_case "round-trip observations" `Quick test_observation_round_trip;
      Alcotest.test_case "round-trip inputs" `Quick test_input_sexp_round_trip;
      Alcotest.test_case "merge timing payloads" `Quick test_payload_merge;
    ];
  ]
