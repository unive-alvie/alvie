open! Core
open Vaultlink

(* The learner functors accept the symbol module. *)
module _ : Learninglib.Elttype.EltType = Symbol

let example =
  {|(* The design-document example. *)
values {
  me    = "op-4471";
  my_pw = "hunter-tempest-19";
  bad   = "not-my-password";
};

inputs {
  HELLO    = "HELLO";
  ID_SELF  = "ID {me}";
  PASS_OK  = "PASS {my_pw}";
  PASS_BAD = "PASS {bad}";
  AUDIT    = "AUDIT";
  OPEN     = "OPEN";
  READ     = "READ";
  CLOSE    = "CLOSE";
};

observe {
  "OK"                        -> OK;
  "ERR"                       -> ERR;
  "DATA vault={v} contents=*" -> DATA(v);
  _                           -> OTHER;
};

session {
  HELLO; (ID_SELF | PASS_OK | PASS_BAD | AUDIT | OPEN | READ | CLOSE)*
};
|}

let parse_ok src =
  match Vtdl.parse_result src with
  | Ok spec -> spec
  | Error e -> Alcotest.failf "unexpected parse error: %s" (Vtdl.error_message e)

(* Checks that [src] is rejected at [line] with a message containing [fragment]. *)
let parse_error ~line ~fragment src =
  match Vtdl.parse_result src with
  | Ok _ -> Alcotest.failf "expected an error mentioning %S" fragment
  | Error ((pos, msg) as e) ->
    if not (String.is_substring msg ~substring:fragment) then
      Alcotest.failf "expected %S in: %s" fragment (Vtdl.error_message e);
    Alcotest.(check int) ("line of: " ^ msg) line pos.line

(* A minimal valid specification with the given sections spliced in. *)
let spec ?(values = "") ?(inputs = {|A = "A"; B = "B";|}) ?(observe = {|_ -> X;|}) ?(session = "(A | B)*") () =
  Printf.sprintf "%sinputs {\n%s\n};\nobserve {\n%s\n};\nsession {\n%s\n};\n" values inputs observe session

(* --- Parser --- *)

let test_example () =
  let s = parse_ok example in
  Alcotest.(check (list (pair string string))) "values"
    [ "me", "op-4471"; "my_pw", "hunter-tempest-19"; "bad", "not-my-password" ] s.values;
  Alcotest.(check (option string)) "ID_SELF command" (Some "ID op-4471")
    (List.Assoc.find s.inputs ~equal:String.equal "ID_SELF");
  Alcotest.(check (option string)) "PASS_OK command" (Some "PASS hunter-tempest-19")
    (List.Assoc.find s.inputs ~equal:String.equal "PASS_OK");
  Alcotest.(check int) "inputs" 8 (List.length s.inputs);
  Alcotest.(check int) "rules" 4 (List.length s.observe);
  Alcotest.(check (list string)) "no warnings" [] (Vtdl.warnings s)

let test_values_optional () =
  let s = parse_ok (spec ()) in
  Alcotest.(check (list (pair string string))) "inputs" [ "A", "A"; "B", "B" ] s.inputs

let test_nested_comments () =
  ignore (parse_ok ("(* outer (* inner *) still outer *)\n" ^ spec ()) : Vtdl.t)

let test_trailing_semicolon () =
  ignore (parse_ok (spec ~session:"A; (B;)*;" ()) : Vtdl.t)

let test_errors () =
  parse_error ~line:2 ~fragment:"unknown value 'me'" (spec ~inputs:{|A = "ID {me}";|} ());
  parse_error ~line:2 ~fragment:"must be upper case" (spec ~inputs:{|hello = "HELLO";|} ());
  parse_error ~line:2 ~fragment:"declared twice" (spec ~inputs:{|A = "A"; A = "B";|} ());
  parse_error ~line:2 ~fragment:"transport meta-command" (spec ~inputs:{|RESET = "X";|} ());
  parse_error ~line:2 ~fragment:"transport meta-command" (spec ~inputs:{|A = "reset now";|} ());
  parse_error ~line:6 ~fragment:"catch-all" (spec ~observe:{|"OK" -> OK;|} ());
  parse_error ~line:5 ~fragment:"never used" (spec ~observe:{|_ -> X; "OK" -> OK;|} ());
  parse_error ~line:5 ~fragment:"not captured" (spec ~observe:{|"DATA *" -> DATA(v); _ -> X;|} ());
  parse_error ~line:5 ~fragment:"two wildcards" (spec ~observe:{|"{a}*" -> X(a); _ -> X;|} ());
  parse_error ~line:5 ~fragment:"appears twice" (spec ~observe:{|"{a} {a}" -> X(a); _ -> X;|} ());
  parse_error ~line:5 ~fragment:"reserved" (spec ~observe:{|_ -> ILLEGAL;|} ());
  parse_error ~line:8 ~fragment:"'C' is not declared" (spec ~session:"A; C" ());
  parse_error ~line:2 ~fragment:"unterminated string" (spec ~inputs:"A = \"A;\nB = \"B\";" ());
  parse_error ~line:1 ~fragment:"expected section 'inputs'" "observe { _ -> X; };";
  parse_error ~line:9 ~fragment:"expected ';' after section 'session'" (String.drop_suffix (spec ()) 2)

let test_warnings () =
  let s = parse_ok (spec ~session:"A*" ()) in
  Alcotest.(check (list string)) "unused input"
    [ "input 'B' never appears in 'session', so it is never sent" ] (Vtdl.warnings s)

(* --- Observables --- *)

let classify src line = Observe.classify (parse_ok src).observe line

let test_observe_example () =
  let c = classify example in
  Alcotest.(check (option string)) "OK" (Some "OK") (c "OK");
  Alcotest.(check (option string)) "ERR" (Some "ERR") (c "ERR");
  Alcotest.(check (option string)) "DATA" (Some "DATA(op-4471)") (c "DATA vault=op-4471 contents=personal-note:ledger-page-88");
  Alcotest.(check (option string)) "whole line only" (Some "OTHER") (c "OK bye");
  Alcotest.(check (option string)) "catch-all" (Some "OTHER") (c "ERR unknown-command")

let test_observe_first_match () =
  let c = classify (spec ~observe:{|"ERR*" -> ERR; "ERR unknown" -> UNKNOWN; _ -> X;|} ()) in
  Alcotest.(check (option string)) "earlier rule wins" (Some "ERR") (c "ERR unknown")

let test_observe_wildcards () =
  let c = classify (spec ~observe:{|"A*" -> STAR; "B{x}" -> CAP(x); _ -> X;|} ()) in
  Alcotest.(check (option string)) "* matches empty" (Some "STAR") (c "A");
  Alcotest.(check (option string)) "capture is non-empty" (Some "X") (c "B");
  Alcotest.(check (option string)) "capture" (Some "CAP(yz)") (c "Byz");
  let c = classify (spec ~observe:{|"{a}={b}" -> KV(b, a); _ -> X;|} ()) in
  Alcotest.(check (option string)) "argument order" (Some "KV(v=w,k)") (c "k=v=w")

(* --- Session derivatives --- *)

let allows_after src prefix x =
  let r = List.fold prefix ~init:(parse_ok src).session ~f:(fun r i -> Session.derive i r) in
  Session.allows r x

let test_session () =
  let a = allows_after example in
  Alcotest.(check bool) "HELLO first" true (a [] "HELLO");
  Alcotest.(check bool) "nothing else first" false (a [] "OPEN");
  Alcotest.(check bool) "anything after HELLO" true (a [ "HELLO" ] "OPEN");
  Alcotest.(check bool) "repeatable" true (a [ "HELLO"; "AUDIT"; "AUDIT" ] "ID_SELF");
  Alcotest.(check bool) "HELLO only once" false (a [ "HELLO" ] "HELLO");
  let a = allows_after (spec ~session:"A; (B | eps); A" ()) in
  Alcotest.(check bool) "optional taken" true (a [ "A" ] "B");
  Alcotest.(check bool) "optional skipped" true (a [ "A" ] "A");
  Alcotest.(check bool) "finished" false (a [ "A"; "A" ] "A")

let test_session_constructors () =
  Alcotest.(check bool) "eps*" true (Session.equal (Session.star Session.eps) Session.eps);
  Alcotest.(check bool) "seq with empty" true (Session.is_empty (Session.seq (Session.sym "A") Session.empty));
  Alcotest.(check bool) "derivative of a symbol" true (Session.is_empty (Session.derive "B" (Session.sym "A")))


(* --- Models --- *)

let model_a = {|digraph model {
  rankdir=LR;
  __start [shape=point]; __start -> 0;
  0 [shape=circle];
  1 [shape=circle];
  0 -> 1 [label="HELLO / OK"];
  0 -> 0 [label="OPEN / ERR"];
  1 -> 1 [label="OPEN / ERR"];
  1 -> 1 [label="HELLO / ERR"];
}
|}

let model_b = String.substr_replace_all model_a ~pattern:"1 -> 1 [label=\"OPEN / ERR\"]" ~with_:"1 -> 1 [label=\"OPEN / OK\"]"

let test_dot_round_trip () =
  let m = Model.of_dot model_a in
  Alcotest.(check int) "states" 2 (Set.length m.states);
  Alcotest.(check int) "transitions" 4 (Map.length m.transition);
  let again = Model.of_dot (Model.to_dot m) in
  Alcotest.(check string) "stable" (Model.to_dot m) (Model.to_dot again)

let test_dot_escaping () =
  let tricky = {|DATA(a "quoted" \ path)|} in
  let m =
    Model.M.make ~states:(Model.M.SSet.of_list [ 0 ]) ~s0:0 ~input_alphabet:(Model.M.ISet.of_list [ "READ" ])
      ~transition:(Model.M.TransitionMap.of_alist_exn [ (0, "READ"), (tricky, 0) ])
  in
  let back = Model.of_dot (Model.to_dot m) in
  Alcotest.(check (list (pair string string))) "output survives"
    [ "READ", tricky ] (List.map (Model.edges back) ~f:(fun (_, i, o, _) -> i, o))

let test_dot_errors () =
  let rejects text =
    match Model.of_dot text with
    | exception Model.Parse_error _ -> ()
    | _ -> Alcotest.failf "expected a parse error for %S" text
  in
  let graph body = "digraph model {\n" ^ body ^ "\n}\n" in
  rejects (graph "0 -> 1 [color=red];");
  rejects (graph "0 -> 1 [label=\"no separator\"];");
  rejects (graph "x -> 1 [label=\"A / B\"];");
  rejects (graph "0 -> 1 [label=\"A / B\"];\n0 -> 2 [label=\"A / C\"];");
  rejects (graph "something else entirely");
  rejects "0 -> 1 [label=\"A / B\"];";
  rejects "digraph model { 0 -> 1 [label=\"A / B\"]; }"

let test_drop_illegal () =
  let m = Model.of_dot (model_a ^ "") in
  let with_illegal = Model.of_dot (String.substr_replace_all model_a ~pattern:"1 -> 1 [label=\"HELLO / ERR\"]" ~with_:"1 -> 2 [label=\"HELLO / ILLEGAL\"]") in
  Alcotest.(check int) "before" 3 (Set.length with_illegal.states);
  let cleaned = Model.drop_illegal with_illegal in
  Alcotest.(check int) "unreachable state removed" 2 (Set.length cleaned.states);
  Alcotest.(check int) "illegal transition removed" 3 (Map.length cleaned.transition);
  Alcotest.(check int) "legal models unchanged" 4 (Map.length (Model.drop_illegal m).transition)

let test_differences () =
  let a = Model.of_dot model_a and b = Model.of_dot model_b in
  Alcotest.(check int) "equal models" 0 (List.length (Model.differences a a));
  match Model.differences a b with
  | [ d ] ->
    Alcotest.(check (list string)) "shortest sequence" [ "HELLO"; "OPEN" ] d.inputs;
    Alcotest.(check (list string)) "left" [ "OK"; "ERR" ] d.left;
    Alcotest.(check (list string)) "right" [ "OK"; "OK" ] d.right
  | ds -> Alcotest.failf "expected exactly one difference, got %d" (List.length ds)

let test_differences_partial () =
  (* An input one model lacks (forbidden by its session) is not a difference. *)
  let a = Model.of_dot model_a in
  let smaller = Model.of_dot "digraph model {\n0 -> 1 [label=\"HELLO / OK\"];\n1 -> 1 [label=\"OPEN / ERR\"];\n}\n" in
  Alcotest.(check int) "smaller has transitions" 2 (Map.length smaller.transition);
  Alcotest.(check int) "no difference" 0 (List.length (Model.differences a smaller))

let test_renumber () =
  (* States 7 and 3 are reached in the order OPEN-first, so they become 1 and 2 in input order. *)
  let m = Model.of_dot "digraph model {\n__start -> 9;\n9 -> 7 [label=\"HELLO / OK\"];\n9 -> 3 [label=\"AUDIT / OK\"];\n7 -> 9 [label=\"OPEN / ERR\"];\n3 -> 3 [label=\"OPEN / ERR\"];\n40 -> 40 [label=\"OPEN / ERR\"];\n}\n" in
  let r = Model.renumber m in
  Alcotest.(check int) "initial state" 0 r.s0;
  Alcotest.(check int) "unreachable state dropped" 3 (Set.length r.states);
  Alcotest.(check (list (list string))) "edges"
    [ [ "0"; "AUDIT"; "OK"; "1" ]; [ "0"; "HELLO"; "OK"; "2" ]; [ "1"; "OPEN"; "ERR"; "1" ]; [ "2"; "OPEN"; "ERR"; "0" ] ]
    (List.map (Model.edges r) ~f:(fun (s, i, o, s') -> [ Int.to_string s; i; o; Int.to_string s' ]));
  Alcotest.(check string) "idempotent" (Model.to_dot r) (Model.to_dot (Model.renumber r))

(* --- W-method oracle, on an in-memory system --- *)

module Mem = struct
  type t = { step : int -> string -> string * int; mutable state : int }
  type input_t = string
  type output_t = string

  let clone t = { t with state = t.state }
  let pre t = t.state <- 0
  let step ?silent:(_ = false) ?dry_output:(_ : string option) t i =
    let o, s = t.step t.state i in
    t.state <- s;
    o
  let post _ = ()
end

module Wm = Learninglib.Wmethodoracle.WMethodOracle (Symbol) (Symbol) (Mem)
module LWm = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (Mem) (Learninglib.Wmethodoracle.WMethodOracle)

(* Answers y on the third consecutive a and x otherwise: three states, but the
   third is only reachable, and distinguishable, with a word of length three. *)
let third_a state i =
  match i, state with
  | "a", 0 -> "x", 1
  | "a", 1 -> "x", 2
  | "a", _ -> "y", 2
  | _ -> "x", 0

let learn_third_a ?max_tests extra_states =
  let sul = { Mem.step = third_a; state = 0 } in
  let oracle = Wm.make ~extra_states ?max_tests () in
  let learned = LWm.lsharp_run oracle sul [ "a"; "b" ] in
  learned, Wm.get_stats oracle

let test_wmethod_finds_hidden_state () =
  let learned, _ = learn_third_a 2 in
  Alcotest.(check int) "states" 3 (Set.length learned.states);
  match Model.M.transition_all learned learned.s0 [ "a"; "a"; "a" ] with
  | Some (o, _) -> Alcotest.(check string) "third a" "y" o
  | None -> Alcotest.fail "no transition"

let test_wmethod_bound () =
  (* Needs a test of length three; with one extra state the longest test has length two. *)
  let learned, _ = learn_third_a 1 in
  Alcotest.(check int) "bound too small: the extra state stays hidden" 1 (Set.length learned.states)

let test_wmethod_budget () =
  let learned, _ = learn_third_a ~max_tests:3 2 in
  Alcotest.(check int) "budget too small: nothing found" 1 (Set.length learned.states)

(* A session-like system: the first input must be a, the second b, then b and c
   are allowed; anything else is refused and every later answer is "dead".
   After b, c, b, b the system answers "boom". The refusal sink and the state
   after a look alike until the inputs that tell them apart are tried, which
   is where a hypothesis can wrongly merge them. *)
let session_like state i =
  (* states: 0 start, 1 after a, 2 after ab, 3 after abc, 4 after abcb, 5 sink *)
  match state, i with
  | 5, _ -> "dead", 5
  | 0, "a" -> "ok", 1
  | 1, "b" -> "ok", 2
  | 2, "b" -> "ok", 2
  | 2, "c" -> "ok", 3
  | 3, "b" -> "ok", 4
  | 4, "b" -> "boom", 4
  | 4, "c" -> "ok", 3
  | 3, "c" -> "ok", 3
  | _ -> "dead", 5

let run_word step word =
  let _, outs =
    List.fold word ~init:(0, []) ~f:(fun (s, acc) i ->
      let o, s' = step s i in
      s', o :: acc)
  in
  List.rev outs

let test_wmethod_refusal_sink () =
  let sul = { Mem.step = session_like; state = 0 } in
  let oracle = Wm.make ~extra_states:2 () in
  let alphabet = [ "a"; "b"; "c" ] in
  let learned = LWm.lsharp_run oracle sul alphabet in
  (* The learned model must agree with the system on every word up to length 7. *)
  let rec words n = if n = 0 then [ [] ] else List.concat_map (words (n - 1)) ~f:(fun w -> List.map alphabet ~f:(fun i -> w @ [ i ])) in
  List.iter (List.concat_map (List.range 1 8) ~f:words) ~f:(fun w ->
    let expected = run_word session_like w in
    let got =
      List.mapi w ~f:(fun n _ ->
        match Model.M.transition_all learned learned.s0 (List.take w (n + 1)) with
        | Some (o, _) -> o
        | None -> "?")
    in
    if not (List.equal String.equal expected got) then
      Alcotest.failf "word %s: expected %s, learned %s" (String.concat ~sep:" " w) (String.concat ~sep:" " expected) (String.concat ~sep:" " got))

let test_wmethod_counts_tests () =
  (* The statistics report the resets spent on the tests. *)
  let _, (_, _, resets, _, _, _, _) = learn_third_a 2 in
  Alcotest.(check bool) "tests were run" true (resets > 0)

let () =
  Alcotest.run "vaultlink"
    [ ( "vtdl",
        [ Alcotest.test_case "design example" `Quick test_example;
          Alcotest.test_case "values section is optional" `Quick test_values_optional;
          Alcotest.test_case "nested comments" `Quick test_nested_comments;
          Alcotest.test_case "trailing semicolons" `Quick test_trailing_semicolon;
          Alcotest.test_case "error messages and positions" `Quick test_errors;
          Alcotest.test_case "warnings" `Quick test_warnings ] );
      ( "observe",
        [ Alcotest.test_case "design example" `Quick test_observe_example;
          Alcotest.test_case "first match wins" `Quick test_observe_first_match;
          Alcotest.test_case "wildcards and captures" `Quick test_observe_wildcards ] );
      ( "model",
        [ Alcotest.test_case "DOT round trip" `Quick test_dot_round_trip;
          Alcotest.test_case "DOT escaping" `Quick test_dot_escaping;
          Alcotest.test_case "DOT errors" `Quick test_dot_errors;
          Alcotest.test_case "drop ILLEGAL" `Quick test_drop_illegal;
          Alcotest.test_case "differences" `Quick test_differences;
          Alcotest.test_case "partial models" `Quick test_differences_partial;
          Alcotest.test_case "renumber states" `Quick test_renumber ] );
      ( "wmethod",
        [ Alcotest.test_case "finds a hidden state" `Quick test_wmethod_finds_hidden_state;
          Alcotest.test_case "respects the extra-state bound" `Quick test_wmethod_bound;
          Alcotest.test_case "test budget" `Quick test_wmethod_budget;
          Alcotest.test_case "refusal sink is not merged with a live state" `Quick test_wmethod_refusal_sink;
          Alcotest.test_case "reports statistics" `Quick test_wmethod_counts_tests ] );
      ( "session",
        [ Alcotest.test_case "allowed inputs" `Quick test_session;
          Alcotest.test_case "smart constructors" `Quick test_session_constructors ] ) ]
