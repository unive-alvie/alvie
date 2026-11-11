(* Tests of the W-method equivalence oracle on small in-memory systems.

   They depend only on the learning library, so this suite can live next to the
   oracle wherever the oracle goes. *)
open! Core

(* Strings as inputs and outputs. *)
module Str = struct
  module T = struct
    type t = string [@@deriving equal, compare, sexp, hash]
  end

  include T
  include Comparator.Make (T)

  let pp fmt s = Format.pp_print_string fmt s
  let show s = s
  let default = ""
end

module _ : Learninglib.Elttype.EltType = Str

module Mealy = Learninglib.Mealy.Mealy (Learninglib.Showableint.ShowableInt) (Str) (Str)

(* A system given by a transition function; [state] is its current state. *)
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

module Wm = Learninglib.Wmethodoracle.WMethodOracle (Str) (Str) (Mem)
module LWm = Learninglib.Lsharp.LSharp (Str) (Str) (Mem) (Learninglib.Wmethodoracle.WMethodOracle)

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

let test_finds_hidden_state () =
  let learned, _ = learn_third_a 2 in
  Alcotest.(check int) "states" 3 (Set.length learned.states);
  match Mealy.transition_all learned learned.s0 [ "a"; "a"; "a" ] with
  | Some (o, _) -> Alcotest.(check string) "third a" "y" o
  | None -> Alcotest.fail "no transition"

let test_bound () =
  (* Needs a test of length three; with one extra state the longest test has length two. *)
  let learned, _ = learn_third_a 1 in
  Alcotest.(check int) "bound too small: the extra state stays hidden" 1 (Set.length learned.states)

let test_budget () =
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

let test_refusal_sink () =
  let sul = { Mem.step = session_like; state = 0 } in
  let oracle = Wm.make ~extra_states:2 () in
  let alphabet = [ "a"; "b"; "c" ] in
  let learned = LWm.lsharp_run oracle sul alphabet in
  (* The learned model must agree with the system on every word up to length 7. *)
  let rec words n =
    if n = 0 then [ [] ] else List.concat_map (words (n - 1)) ~f:(fun w -> List.map alphabet ~f:(fun i -> w @ [ i ]))
  in
  List.iter
    (List.concat_map (List.range 1 8) ~f:words)
    ~f:(fun w ->
      let expected = run_word session_like w in
      let got =
        List.mapi w ~f:(fun n _ ->
          match Mealy.transition_all learned learned.s0 (List.take w (n + 1)) with
          | Some (o, _) -> o
          | None -> "?")
      in
      if not (List.equal String.equal expected got) then
        Alcotest.failf "word %s: expected %s, learned %s" (String.concat ~sep:" " w) (String.concat ~sep:" " expected)
          (String.concat ~sep:" " got))

let test_counts_tests () =
  (* The statistics report the resets spent on the tests. *)
  let _, (_, _, resets, _, _, _, _) = learn_third_a 2 in
  Alcotest.(check bool) "tests were run" true (resets > 0)

let test_rejects_negative_bound () =
  match Wm.make ~extra_states:(-1) () with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument"

let () =
  Alcotest.run "wmethod"
    [ ( "wmethod",
        [ Alcotest.test_case "finds a hidden state" `Quick test_finds_hidden_state;
          Alcotest.test_case "respects the extra-state bound" `Quick test_bound;
          Alcotest.test_case "test budget" `Quick test_budget;
          Alcotest.test_case "refusal sink is not merged with a live state" `Quick test_refusal_sink;
          Alcotest.test_case "reports statistics" `Quick test_counts_tests;
          Alcotest.test_case "rejects a negative bound" `Quick test_rejects_negative_bound ] ) ]
