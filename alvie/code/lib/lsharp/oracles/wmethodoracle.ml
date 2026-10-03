(*
  Equivalence oracle based on the W-method (Chow 1978; Vasilevskii 1973).

  Given a hypothesis H with n states and an assumed bound of k extra states on
  the system under learning, the oracle runs the test suite

      P . Sigma^{<=k} . W

  where
    - P is the transition cover of H: a shortest access word for every state,
      and every access word extended by every input;
    - Sigma^{<=k} is every input word of length at most k;
    - W is a characterisation set: for every pair of states of H, some word of W
      leads to different outputs.

  If the SUL is deterministic, has at most n + k states, and H passes every
  test, the SUL is equivalent to H. This is a guarantee, unlike random
  sampling, but it is only as good as k: a SUL whose behaviour needs more than
  k states beyond H is not detected. Passing [~max_tests] cuts the suite short
  and gives the guarantee up, which is logged as a warning.

  Tests run shortest first, so the counterexample returned is a short one.
  Duplicate test words are skipped. Passing tests are not recorded in the
  observation tree; only the counterexample is.
*)
open Core

open Elttype
open Mealy
open Observationtree
open Sul
open Showableint

module WMethodOracle (I : EltType) (O : EltType) (S : SUL with type input_t = I.t and type output_t = O.t) = struct
  module IIOMealy = Mealy (ShowableInt) (I) (O)
  module IIOObservationTree = ObservationTree (ShowableInt) (I) (O)

  type stats_t = {
    mutable outputquery_cnt : int;
    mutable equivquery_cnt : int;
    mutable sul_reset_cnt : int;
    mutable sul_step_cnt : int;
    mutable sul_step_dry_cnt : int;
    mutable tests_run : int;
    mutable tests_len_sum : int;
    mutable tests_len_sqsum : int;
  }

  type t = {
    mutable last_state : int;
    extra_states : int;
    max_tests : int option;
    stats : stats_t;
  }

  let make ?(extra_states = 1) ?max_tests () : t =
    if extra_states < 0 then invalid_arg "WMethodOracle.make: extra_states must not be negative";
    {
      last_state = 0;
      extra_states;
      max_tests;
      stats = {
        outputquery_cnt = 0; equivquery_cnt = 0; sul_reset_cnt = 0; sul_step_cnt = 0; sul_step_dry_cnt = 0;
        tests_run = 0; tests_len_sum = 0; tests_len_sqsum = 0;
      };
    }

  let get_stats (oracle : t) =
    let n = Float.of_int oracle.stats.tests_run in
    let ex = Float.of_int oracle.stats.tests_len_sum in
    let ex2 = Float.of_int oracle.stats.tests_len_sqsum in
    let avg, var = if Float.(n = 0.) then 0., 0. else ex /. n, (ex2 -. ((ex ** 2.) /. n)) /. n in
    ( oracle.stats.outputquery_cnt, oracle.stats.equivquery_cnt, oracle.stats.sul_reset_cnt,
      oracle.stats.sul_step_cnt, oracle.stats.sul_step_dry_cnt, avg, var )

  let pre_with_stats (oracle : t) =
    oracle.stats.sul_reset_cnt <- oracle.stats.sul_reset_cnt + 1;
    S.pre

  let step_with_stats ?dry_output (oracle : t) =
    (match dry_output with
     | None -> oracle.stats.sul_step_cnt <- oracle.stats.sul_step_cnt + 1
     | Some _ -> oracle.stats.sul_step_dry_cnt <- oracle.stats.sul_step_dry_cnt + 1);
    S.step ?dry_output

  (* Executes [i] on the SUL, recording the observation in the tree. *)
  let ot_updater (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (start_ot_state : int) (i : I.t) :
    IIOObservationTree.t * O.t * int =
    match IIOObservationTree.transition ot (start_ot_state, i) with
    | Some (o_ot, next_state) ->
      let o_sul = step_with_stats ~dry_output:o_ot oracle sul i in
      ot, o_sul, next_state
    | None ->
      let o_sul = step_with_stats oracle sul i in
      oracle.last_state <- oracle.last_state + 1;
      IIOObservationTree.update ot start_ot_state i o_sul oracle.last_state, o_sul, oracle.last_state

  let output_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (il : I.t list) :
    IIOObservationTree.t * (I.t * O.t) list =
    oracle.stats.outputquery_cnt <- oracle.stats.outputquery_cnt + 1;
    pre_with_stats oracle sul;
    let ot', iol, _ =
      List.fold il ~init:(ot, [], ot.s0) ~f:(fun (ot_acc, ol_acc, prev_ot_state) i ->
        let ot_acc', o_ot, next_state = ot_updater oracle ot_acc sul prev_ot_state i in
        ot_acc', ol_acc @ [ (i, o_ot) ], next_state)
    in
    S.post sul;
    ot', iol

  (* --- Test suite construction, on the hypothesis only --- *)

  let hyp_transition hyp s i =
    match IIOMealy.transition hyp (s, i) with
    | Some r -> r
    | None -> failwith (sprintf "WMethodOracle: the hypothesis has no transition from state %d on %s" s (I.show i))

  (* Outputs of [hyp] along [word], starting in [s]. *)
  let outputs hyp s word =
    List.rev
      (snd
         (List.fold word ~init:(s, []) ~f:(fun (s, acc) i ->
            let o, s' = hyp_transition hyp s i in
            s', o :: acc)))

  (* A shortest access word for every state reachable from the initial one. *)
  let access_words hyp alphabet =
    let access = Hashtbl.create (module Int) in
    let queue = Queue.create () in
    Hashtbl.set access ~key:hyp.IIOMealy.s0 ~data:[];
    Queue.enqueue queue hyp.IIOMealy.s0;
    while not (Queue.is_empty queue) do
      let s = Queue.dequeue_exn queue in
      List.iter alphabet ~f:(fun i ->
        let _, s' = hyp_transition hyp s i in
        if not (Hashtbl.mem access s') then (
          Hashtbl.set access ~key:s' ~data:(Hashtbl.find_exn access s @ [ i ]);
          Queue.enqueue queue s'))
    done;
    access

  (* A shortest word on which states [a] and [b] of [hyp] give different outputs. *)
  let distinguish hyp alphabet a b =
    let seen = Hash_set.Poly.create () in
    let queue = Queue.create () in
    Queue.enqueue queue (a, b, []);
    Hash_set.add seen (a, b);
    let result = ref None in
    while Option.is_none !result && not (Queue.is_empty queue) do
      let a, b, rev_path = Queue.dequeue_exn queue in
      List.iter alphabet ~f:(fun i ->
        if Option.is_none !result then (
          let oa, a' = hyp_transition hyp a i and ob, b' = hyp_transition hyp b i in
          if not (O.equal oa ob) then result := Some (List.rev (i :: rev_path))
          else if not (Hash_set.mem seen (a', b')) then (
            Hash_set.add seen (a', b');
            Queue.enqueue queue (a', b', i :: rev_path))))
    done;
    !result

  (* A set of words that separates every pair of states of [hyp]. *)
  let characterisation_set hyp alphabet states =
    let separates w a b = not (List.equal O.equal (outputs hyp a w) (outputs hyp b w)) in
    let w_set = ref [] in
    List.iteri states ~f:(fun n a ->
      List.iter (List.drop states (n + 1)) ~f:(fun b ->
        if not (List.exists !w_set ~f:(fun w -> separates w a b)) then
          Option.iter (distinguish hyp alphabet a b) ~f:(fun w -> w_set := !w_set @ [ w ])));
    match !w_set with [] -> [ [] ] | w -> List.stable_sort w ~compare:(fun x y -> Int.compare (List.length x) (List.length y))

  let rec words_of_length alphabet = function
    | 0 -> [ [] ]
    | n -> List.concat_map (words_of_length alphabet (n - 1)) ~f:(fun w -> List.map alphabet ~f:(fun i -> w @ [ i ]))

  (* Runs one test word on the SUL against the hypothesis. Returns the shortest
     failing prefix, if any. Passing tests are not recorded in the observation
     tree: there can be tens of thousands of them, and L# needs only the
     counterexample. *)
  let run_test (oracle : t) (sul : S.t) (hyp : IIOMealy.t) (word : I.t list) : I.t list option =
    pre_with_stats oracle sul;
    let rec go hyp_state executed = function
      | [] -> None
      | i :: rest ->
        let o = step_with_stats oracle sul i in
        let o_hyp, next_hyp_state = hyp_transition hyp hyp_state i in
        if O.equal o o_hyp then go next_hyp_state (i :: executed) rest
        else (
          Logs.debug (fun m ->
            m "(W) cex: %s; hypothesis: %s, SUL: %s" (List.to_string ~f:I.show (List.rev (i :: executed)))
              (O.show o_hyp) (O.show o));
          Some (List.rev (i :: executed)))
    in
    let result = go hyp.IIOMealy.s0 [] word in
    S.post sul;
    result

  (* Records a counterexample run in the observation tree. *)
  let record (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (word : I.t list) : IIOObservationTree.t =
    pre_with_stats oracle sul;
    let ot', _ =
      List.fold word ~init:(ot, ot.s0) ~f:(fun (ot_acc, state) i ->
        let ot_acc', _, next_state = ot_updater oracle ot_acc sul state i in
        ot_acc', next_state)
    in
    S.post sul;
    ot'

  exception Found
  exception Budget_exhausted

  let equiv_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (hyp : IIOMealy.t) =
    oracle.stats.equivquery_cnt <- oracle.stats.equivquery_cnt + 1;
    let alphabet = Set.to_list (IIOMealy.input_alphabet hyp) in
    let states = Set.to_list hyp.states in
    let access = access_words hyp alphabet in
    let cover =
      List.concat_map states ~f:(fun s ->
        match Hashtbl.find access s with
        | None -> []
        | Some p -> p :: List.map alphabet ~f:(fun i -> p @ [ i ]))
    in
    let key w = String.concat ~sep:"\000" (List.map w ~f:I.show) in
    let cover =
      let seen = Hash_set.create (module String) in
      List.filter cover ~f:(fun w -> Hash_set.strict_add seen (key w) |> Result.is_ok)
      |> List.stable_sort ~compare:(fun x y -> Int.compare (List.length x) (List.length y))
    in
    let w_set = characterisation_set hyp alphabet states in
    Logs.debug (fun m ->
      m "(W) hypothesis: %d states; |P| = %d, |W| = %d, extra states: %d" (List.length states) (List.length cover)
        (List.length w_set) oracle.extra_states);
    Logs.debug (fun m ->
      m "(W) P = %s; W = %s" (String.concat ~sep:" | " (List.map cover ~f:(fun w -> List.to_string ~f:I.show w)))
        (String.concat ~sep:" | " (List.map w_set ~f:(fun w -> List.to_string ~f:I.show w))));
    let tested = Hash_set.create (module String) in
    let result = ref None and tests = ref 0 in
    (try
       for extra = 0 to oracle.extra_states do
         let middles = words_of_length alphabet extra in
         Logs.debug (fun m -> m "(W) round %d: %d middle words" extra (List.length middles));
         List.iter cover ~f:(fun p ->
           List.iter middles ~f:(fun mid ->
             List.iter w_set ~f:(fun w ->
               let word = p @ mid @ w in
               if Hash_set.strict_add tested (key word) |> Result.is_ok then (
                 (match oracle.max_tests with Some limit when !tests >= limit -> raise Budget_exhausted | _ -> ());
                 incr tests;
                 Logs.debug (fun m -> m "(W) test %d: %s" !tests (List.to_string ~f:I.show word));
                 let len = List.length word in
                 oracle.stats.tests_run <- oracle.stats.tests_run + 1;
                 oracle.stats.tests_len_sum <- oracle.stats.tests_len_sum + len;
                 oracle.stats.tests_len_sqsum <- oracle.stats.tests_len_sqsum + (len * len);
                 match run_test oracle sul hyp word with
                 | None -> ()
                 | Some cex ->
                   result := Some cex;
                   raise Found))))
       done
     with
     | Found -> ()
     | Budget_exhausted ->
       Logs.warn (fun m ->
         m "(W) test budget exhausted after %d tests: the equivalence check is not exhaustive for %d extra states"
           !tests oracle.extra_states));
    Logs.debug (fun m -> m "(W) ran %d tests" !tests);
    match !result with Some cex -> `Cex (record oracle ot sul cex, cex) | None -> `Equivalent
end
