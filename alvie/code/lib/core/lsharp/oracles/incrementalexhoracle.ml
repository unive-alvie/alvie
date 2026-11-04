open Core

open Elttype
open Mealy
open Observationtree
open Sul
open Showableint

module IncrementalExhOracle (I : EltType) (O : EltType) (S : SUL with type input_t = I.t and type output_t = O.t) =
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
    q : (S.t * IIOObservationTree.t * I.t list * O.t list * int * int) Queue.t;
    next_options : I.t list -> O.t list -> [`Next of I.t | `Stop ] list;
    stop_cond : [`Next of I.t | `Stop] list -> I.t list -> O.t list -> bool;
    stats : stats_t
  }

  let make ~next_options ~stop_cond () : t =
    {
      last_state = 0;
      next_options=next_options;
      stop_cond=stop_cond;
      q=Queue.create ();
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
    S.step ~silent:false ?dry_output

  let ot_updater (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (start_ot_state : int) (i : I.t) :
  IIOObservationTree.t * O.t * int
  =
    match IIOObservationTree.transition ot (start_ot_state, i) with
    | Some (o_ot, next_state) ->
        (* With the dry_output argument, step avoids (if possible) running i and returns o_ot as-is. Internal structures of SUL are nonetheless updated as if i was executed! *)
        let o_sul = step_with_stats ~dry_output:o_ot oracle sul i in
        Logs.debug (fun p -> p "(Pre) ot_updater - non-determinism check skipped!");
        (ot, o_sul, next_state)
    | None ->
        let o_sul = step_with_stats oracle sul i in
        oracle.last_state <- oracle.last_state + 1;
        (IIOObservationTree.update ot start_ot_state i o_sul oracle.last_state, o_sul, oracle.last_state)

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
  *)
  let equiv_query
    (oracle : t)
    (ot : IIOObservationTree.t)
    (sul : S.t)
    (hyp : IIOMealy.t) : [> `Cex of IIOObservationTree.t * I.t list | `Equivalent ] =
    let cloner obj = Obj.obj (Obj.dup (Obj.repr obj)) in
    let do_reset sul = S.post sul; S.pre sul in
    oracle.stats.equivquery_cnt <- oracle.stats.equivquery_cnt + 1;
    Logs.debug (fun m -> m "(Pre) equiv_query started");
    (* let q = Queue.create () in *)
    let sul' = cloner sul in
    do_reset sul';
    Queue.enqueue oracle.q (sul', ot, [], [], hyp.s0, ot.s0);
    let gen_input = ref `Equivalent in
    while not (Queue.is_empty oracle.q) do
      let sul, ot, is, os, prev_hyp_state, prev_ot_state = Queue.dequeue_exn oracle.q in
      let available = oracle.next_options is os in
      (* If we finished, check if this is a counterexample *)
      if oracle.stop_cond available is os then
        ()
        (* printf "(Pre) No cex: %s" (List.to_string is ~f:I.show) *)
        (* We finished the path without a counterexample, go on! *)
      else
        List.iter available ~f:(fun new_i ->
          match !gen_input with
          | `Cex _ -> ()
          | _ ->
            (match new_i with
            | `Stop -> failwith (sprintf "<<<<< `Stop: this is an error!")
            | `Next new_i -> (
                let sul = cloner sul in
                let ot', o, next_ot_state = ot_updater oracle ot sul prev_ot_state new_i in
                let o_hyp_opt = IIOMealy.transition hyp (prev_hyp_state, new_i) in
                match o_hyp_opt with
                | None ->
                    failwith (sprintf "<<<<< Outputs differ: this is an error!")
                | Some (o_hyp, _) when not (O.equal o o_hyp) ->
                    S.post sul;
                    printf "(Pre) Cex found: %s\n" (List.to_string is ~f:I.show);
                    Out_channel.flush stdout;
                    gen_input := `Cex (ot', is@[new_i]) (* We found a counter example! *)
                | Some (o_hyp, next_hyp_state) ->
                    Queue.enqueue oracle.q (sul, ot', is@[new_i], os@[o_hyp], next_hyp_state, next_ot_state)
              ))
        )
    done;
    !gen_input
end
