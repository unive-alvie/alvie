open Core

open Elttype
open Mealy
open Observationtree
open Sul
open Showableint

module PACOracle (I : EltType) (O : EltType) (S : SUL with type input_t = I.t and type output_t = O.t) =
struct
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
    mutable equivquery_k : int;
  } [@@deriving make]

  type t = {
    mutable last_state : int;
    mutable round : int;
    round_limit : int option;
    epsilon : float;
    delta : float;
    next_input : IIOMealy.t -> I.t list -> O.t list -> [`Next of I.t | `Stop];
    stats : stats_t
  }

  let make ?(round_limit) ?(epsilon = 0.001) ?(delta = 0.001) ~next_input () : t =
    {
      round_limit=round_limit;
      last_state = 0;
      round = 0;
      epsilon=epsilon;
      delta=delta;
      next_input=next_input;
      stats = make_stats_t ~outputquery_cnt:0 ~equivquery_cnt:0 ~sul_reset_cnt:0 ~sul_step_cnt:0 ~sul_step_dry_cnt:0 ~equivquery_len_avg:0 ~equivquery_len_sigmasq:0 ~equivquery_k:0 ~equivquery_samples:0
    }

  let get_stats (oracle : t) =
    let k = Float.of_int oracle.stats.equivquery_k in
    let ex = Float.of_int oracle.stats.equivquery_len_avg in
    let ex2 = Float.of_int oracle.stats.equivquery_len_sigmasq in
    let n = Float.of_int oracle.stats.equivquery_samples in
    (
      oracle.stats.outputquery_cnt,
      oracle.stats.equivquery_cnt,
      oracle.stats.sul_reset_cnt,
      oracle.stats.sul_step_cnt,
      oracle.stats.sul_step_dry_cnt,
      k +. (ex /. n),
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
        Logs.debug (fun p -> p "(PAC) ot_updater - non-determinism check skipped!");
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

  (* Given the sequence [il], resets [sul] using [pre], executes the prescribed steps and returns the result. *)
  let output_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (il : I.t list) : IIOObservationTree.t * (I.t * O.t) list =
    Prof.time "oracle.output_query" @@ fun () ->
    oracle.stats.outputquery_cnt <- oracle.stats.outputquery_cnt + 1;
    pre_with_stats oracle sul;
    let ot', rev_iol, _ = List.fold il
      ~init:(ot, [], ot.s0)
      ~f:(fun (ot_acc, rev_ol_acc, prev_ot_state) i ->
        let ot_acc', o_ot, next_state = ot_updater oracle ot_acc sul prev_ot_state i in
          (ot_acc', (i, o_ot) :: rev_ol_acc, next_state)
      ) in
    S.post sul;
    (ot', List.rev rev_iol)

  let rec sample_and_run
    (oracle : t)
    (ot : IIOObservationTree.t)
    (sul : S.t)
    (hyp : IIOMealy.t)
    (prev_state : int)
    (prev_ot_state : int)
    is
    os =
      let new_i = Prof.time "oracle.next_input" (fun () -> oracle.next_input ot is os) in
      let sz = List.length is in
      match new_i with
      | `Stop ->
        (* This counterexample ends here, no cex found! *)
        `Equivalent sz
      | `Next new_i ->
        let ot', o, next_state = Prof.time "oracle.ot_updater" (fun () -> ot_updater oracle ot sul prev_ot_state new_i) in
        let o_hyp_opt = IIOMealy.transition hyp (prev_state, new_i) in
        match o_hyp_opt with
        | None ->
            failwith (Format.sprintf "equiv_query - this may be a bug: %d -- %s/?? --> ?? in hyp!"
              prev_state (Sexp.to_string (I.sexp_of_t new_i)))
        | Some (o_hyp, _) when not (O.equal o o_hyp) ->
            S.post sul;
            `Cex (ot', is@[new_i], sz+1) (* We found a counter example! *)
        | Some (o_hyp, s_hyp) ->
            Logs.debug (fun m -> m "(PAC) equiv_query: candidate cex: %s; outs_hyp/sul: %s" (List.to_string ~f:I.show (is@[new_i])) (List.to_string ~f:O.show (os@[o_hyp])));
            sample_and_run oracle ot' sul hyp s_hyp next_state (is@[new_i]) (os@[o_hyp])

  (*
    Returns `Equivalent if the hypothesis is equivalent to the hidden automaton, `Cex counter_example otherwise.

    This is implemented following the ideas from Angluin's 1987's paper on sampling oracles.
  *)
  let equiv_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (hyp : IIOMealy.t) =
    oracle.stats.equivquery_cnt <- oracle.stats.equivquery_cnt + 1;
    let do_reset () = S.post sul; pre_with_stats oracle sul in
    (* This is the number of samples we need at this round *)
    match oracle.round_limit with
    | Some rl when oracle.round > rl -> `Equivalent
    | _ ->
      (let r = ref (Float.to_int (Float.round_up ((1.0 /. oracle.epsilon) *. (log (1.0 /. oracle.delta) +. ((log 2.0) *. (Float.of_int(oracle.round) +. 1.0)))))) in
        oracle.round <- oracle.round + 1;
        Logs.debug (fun m -> m "(PAC) equiv_query (eps: %f, delta: %f): samples: %d, round #%d, sampling %d paths" oracle.epsilon oracle.delta oracle.stats.equivquery_samples oracle.round !r);
        let result = ref `Equivalent in
        let first = ref true in
        let upd first len =
          (if !first then oracle.stats.equivquery_k <- len; first := false);
          oracle.stats.equivquery_len_avg <- oracle.stats.equivquery_len_avg + (len - oracle.stats.equivquery_k);
          oracle.stats.equivquery_len_sigmasq <- oracle.stats.equivquery_len_sigmasq + (Int.pow (len - oracle.stats.equivquery_k) 2) in
        while Poly.equal !result `Equivalent && !r > 0  do
          do_reset ();
          oracle.stats.equivquery_samples <- oracle.stats.equivquery_samples + 1;
          match sample_and_run oracle ot sul hyp hyp.s0 ot.s0 [] [] with
          | `Cex (cex_i, cex_o, len) ->
              result := `Cex (cex_i, cex_o);
              upd first len;
          | `Equivalent len ->
              result := `Equivalent;
              upd first len;
              r := !r - 1
        done;
        !result)
end
