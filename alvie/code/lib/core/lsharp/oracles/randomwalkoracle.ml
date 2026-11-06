open Core

open Elttype
open Mealy
open Observationtree
open Sul
open Showableint

module RandomWalkOracle (I : EltType) (O : EltType) (S : SUL with type input_t = I.t and type output_t = O.t) = struct
  module IIOMealy = Mealy (ShowableInt) (I) (O)
  module IIOObservationTree = ObservationTree (ShowableInt) (I) (O)

  type stats_t = {
    mutable outputquery_cnt : int;
    mutable equivquery_cnt : int;
    mutable sul_reset_cnt : int;
    mutable sul_step_cnt : int;
    mutable sul_step_dry_cnt : int;
    mutable equivquery_samples : int;
    mutable equivquery_len_avg : int;
    mutable equivquery_len_sigmasq : int;
  } [@@deriving make]

  type t = {
    mutable last_state : int;
    step_limit : int;
    reset_prob : float;
    next_input : IIOMealy.t -> I.t list -> O.t list -> I.t;
    stats : stats_t
  }

  type i_t = I.t
  type o_t = O.t
  type s_t = S.t
  type ot_t = IIOObservationTree.t
  type m_t = IIOMealy.t

  let make ?(step_limit = 10000) ?(reset_prob = 0.09) ~next_input () : t =
    {
      last_state = 0;
      step_limit=step_limit;
      reset_prob=reset_prob;
      next_input=next_input;
      stats = make_stats_t ~outputquery_cnt:0 ~equivquery_cnt:0 ~sul_reset_cnt:0 ~sul_step_cnt:0 ~sul_step_dry_cnt:0 ~equivquery_len_avg:0 ~equivquery_len_sigmasq:0 ~equivquery_samples:0
    }

  let get_stats (oracle : t) =
    let ex = Float.of_int oracle.stats.equivquery_len_avg in
    let ex2 = Float.of_int oracle.stats.equivquery_len_sigmasq in
    let n = Float.of_int oracle.stats.equivquery_samples in
    (
      oracle.stats.outputquery_cnt,
      oracle.stats.equivquery_cnt,
      oracle.stats.sul_reset_cnt,
      oracle.stats.sul_step_cnt,
      oracle.stats.sul_step_dry_cnt,
      (ex /. n),
      (ex2 -. ((ex**2.0) /. n)) /. n
    )

  let pre_with_stats (oracle : t) =
    oracle.stats.sul_reset_cnt <- oracle.stats.sul_reset_cnt + 1;
    S.pre

  let step_with_stats ?dry_output (oracle : t) =
    (match dry_output with
    | None -> oracle.stats.sul_step_cnt <- oracle.stats.sul_step_cnt + 1
    | Some _ -> oracle.stats.sul_step_dry_cnt <- oracle.stats.sul_step_dry_cnt + 1;
    );
    S.step ?dry_output

  let ot_updater (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (start_ot_state : int) (i : I.t) :
  IIOObservationTree.t * O.t * int
  =
    match IIOObservationTree.transition ot (start_ot_state, i) with
    | Some (o_ot, next_state) ->
        let o_sul = step_with_stats ~dry_output:o_ot oracle sul i in
        Logs.debug (fun p -> p "(RW) ot_updater - non-determinism check skipped!");
        (* if not (O.equal o_ot o_sul) then
          failwith (Format.sprintf
            "ot_updater - non-determinism: %d -- %s/out --> _ with out = %s in ot, and out = %s in sul."
            start_ot_state
            (Sexp.to_string (I.sexp_of_t i))
            (Sexp.to_string (O.sexp_of_t o_ot))
            (Sexp.to_string (O.sexp_of_t o_sul))
          )
        else (); *)
        (ot, o_sul, next_state)
    | None ->
        let o_sul = step_with_stats oracle sul i in
        oracle.last_state <- oracle.last_state + 1;
        (* Logs.debug (fun m -> m "ot_updater - updating ot with: %d -- %s/%s --> %d"
        start_ot_state
        (Sexp.to_string (I.sexp_of_t i))
        (Sexp.to_string (O.sexp_of_t o_sul))
        oracle.last_state
        ); *)
        (IIOObservationTree.update ot start_ot_state i o_sul oracle.last_state, o_sul, oracle.last_state)

  (* let is_legal (oracle : t) (ot : IIOObservationTree.t) (il : I.t list) (i : I.t) : bool =
    let ol = snd (List.fold
      il
      ~init:(ot.s0, [])
      ~f:(fun (s_prec, ol) i ->
        match IIOObservationTree.transition ot (s_prec, i) with
        | None -> failwith "Randomwalkoracle.is_legal: unexpected None result in ot.transition."
        | Some (o, s_next) -> (s_next, ol@[ o ]))) in
      oracle.matchable i il ol *)

  (* Given the sequence [il], resets [sul] using [pre], executes the prescribed steps and returns the result. *)
  let output_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (il : I.t list) : IIOObservationTree.t * (I.t * O.t) list =
    oracle.stats.outputquery_cnt <- oracle.stats.outputquery_cnt + 1;
    pre_with_stats oracle sul;
    let ot', iol, _ = List.fold il
      ~init:(ot, [], ot.s0)
      ~f:(fun (ot_acc, ol_acc, prev_ot_state) i ->
        let ot_acc', o_ot, next_state = ot_updater oracle ot_acc sul prev_ot_state i in
          (ot_acc', ol_acc @ [(i, o_ot)], next_state)
      ) in
    S.post sul;
    (ot', iol)

  (*
    Returns `Equivalent if the hypothesis is equivalent to the hidden automaton, `Cex counter_example otherwise.

    This is inspired by the RandomWalk Oracle from the AALpy library, with the addition of the next_input generator from above.
  *)
  let equiv_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (hyp : IIOMealy.t) =
    oracle.stats.equivquery_cnt <- oracle.stats.equivquery_cnt + 1;
    let do_reset () = S.post sul; pre_with_stats oracle sul in
    let rec _equiv_query
      (ot : IIOObservationTree.t)
      (num_steps : int)
      (prev_state : int)
      (prev_ot_state : int)
      is
      os =
      Logs.debug (fun m -> m "(RW) equiv_query: num_steps: %d, limit: %d" num_steps oracle.step_limit);
      if Int.(>=) num_steps oracle.step_limit then `Equivalent
      else (
        (* Resets the SUL with probability reset_prob OR if the last observable is the default (which is usually the case on invalid configs!) *)
        if Float.(<) (Random.float_range 0.0 1.0) oracle.reset_prob ||
          (Option.equal I.equal (List.last is) (Some I.default) && Option.equal O.equal (List.last os) (Some O.default)) then
        (* if Float.(<=) (Random.float_range 0.0 1.0) oracle.reset_prob then *)
          (
            Logs.debug (fun m -> m "(RW) equiv_query: sul reset! (reset_probl: %f)" oracle.reset_prob);
            Format.printf "("; Out_channel.flush stdout;
            do_reset ();
            Format.printf ")"; Out_channel.flush stdout;
            oracle.stats.equivquery_samples <- oracle.stats.equivquery_samples + 1;
            oracle.stats.equivquery_len_avg <- oracle.stats.equivquery_len_avg + List.length is;
            oracle.stats.equivquery_len_sigmasq <- oracle.stats.equivquery_len_sigmasq + Int.pow (List.length is) 2;
            _equiv_query ot (num_steps+1) hyp.s0 ot.s0 [] []
          )
        else (
          (* Logs.debug (fun m -> m "equiv_query: start oracle.next_input"); *)
          let new_i = oracle.next_input hyp is os in
          (* Logs.debug (fun m -> m "equiv_query: end oracle.next_input"); *)
          (* Compare ot with the SUL and update it if needed -- the result holds for both the ot and the SUL *)
          (* Logs.debug (fun m -> m "equiv_query: start ot_updater"); *)
          let ot', o, next_state = ot_updater oracle ot sul prev_ot_state new_i in
          (* Logs.debug (fun m -> m "equiv_query: end ot_updater"); *)
          (* Now work on the hypothesis, we have a few cases *)
          let o_hyp_opt = IIOMealy.transition hyp (prev_state, new_i) in
            match o_hyp_opt with
            | None ->
                (* Logs.debug (fun m ->
                  IIOMealy.Dot.fprint_graph Format.str_formatter (IIOMealy.dot_of_t hyp);
                  let ds = Format.flush_str_formatter () in
                  m "%s" ds); *)
                failwith (Format.sprintf "(RW) equiv_query - this may be a bug: %d -- %s/?? --> ?? in hyp!"
                  prev_state (Sexp.to_string (I.sexp_of_t new_i)))
            | Some (o_hyp, _) when not (O.equal o o_hyp) ->
                Logs.debug (fun m -> m "(RW) equiv_query: cex found: %s; o_hyp: %s; o_sul: %s" (List.to_string ~f:I.show (is@[new_i])) (O.show o_hyp) (O.show o));
                S.post sul;
                `Cex (ot', is@[new_i]) (* We found a counter example! *)
            | Some (o_hyp, s_hyp) ->
                Logs.debug (fun m -> m "(RW) equiv_query: candidate cex: %s; outs_hyp/sul: %s" (List.to_string ~f:I.show (is@[new_i])) (List.to_string ~f:O.show (os@[o_hyp])));
                _equiv_query ot' (num_steps+1) s_hyp next_state (is@[new_i]) (os@[o_hyp]))
      ) in
      do_reset ();
      _equiv_query ot 0 hyp.s0 ot.s0 [] []
end
