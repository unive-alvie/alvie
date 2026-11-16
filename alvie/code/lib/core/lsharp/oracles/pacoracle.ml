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
    stats : stats_t;
    (* With workers (other systems, each with its own backend), the tests of an equivalence query run in as many
       processes, the test i with the random state of (round, i): see equiv_query_parallel *)
    workers : S.t list;
  }

  let start_time = Time_now.nanoseconds_since_unix_epoch ()

  let make ?(round_limit) ?(epsilon = Defaults.pac_epsilon) ?(delta = Defaults.pac_delta) ?(workers = []) ~next_input () : t =
    {
      workers;
      round_limit=round_limit;
      last_state = 0;
      round = 0;
      epsilon=epsilon;
      delta=delta;
      next_input=next_input;
      stats = make_stats_t ~outputquery_cnt:0 ~equivquery_cnt:0 ~sul_reset_cnt:0 ~sul_step_cnt:0 ~sul_step_dry_cnt:0 ~equivquery_len_avg:0 ~equivquery_len_sigmasq:0 ~equivquery_k:0 ~equivquery_samples:0
    }

  let set_last_state (oracle : t) n = oracle.last_state <- n

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
            Logs.info (fun m -> m "(PAC) counterexample of length %d: %s\n  SUL output:        %s\n  hypothesis output: %s\n  inputs (sexp): %s"
              (sz + 1) (List.to_string ~f:I.show (is @ [new_i])) (O.show o) (O.show o_hyp)
              (Sexp.to_string_mach (List.sexp_of_t I.sexp_of_t (is @ [new_i]))));
            S.post sul;
            `Cex (ot', is@[new_i], sz+1) (* We found a counter example! *)
        | Some (o_hyp, s_hyp) ->
            Logs.debug (fun m -> m "(PAC) equiv_query: candidate cex: %s; outs_hyp/sul: %s" (List.to_string ~f:I.show (is@[new_i])) (List.to_string ~f:O.show (os@[o_hyp])));
            sample_and_run oracle ot' sul hyp s_hyp next_state (is@[new_i]) (os@[o_hyp])

  (*
    Returns `Equivalent if the hypothesis is equivalent to the hidden automaton, `Cex counter_example otherwise.

    This is implemented following the ideas from Angluin's 1987's paper on sampling oracles.
  *)
  (*
    The tests of an equivalence query in parallel (prototype). Worker c runs, in a process of its own, the tests
    c, c + n, c + 2n, ... (n workers), each with the random state of (round, test), until it finds a counterexample
    or runs out of tests. The counterexample is the one of the lowest test: the result does not depend on n. It is
    replayed on sul, so that the tree has it, and the statistics of the workers are added to the oracle's.
  *)
  let equiv_query_parallel (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (hyp : IIOMealy.t) (r : int) =
    let n = List.length oracle.workers in
    let round = oracle.round in
    let run_worker c (w : S.t) =
      let s0 = oracle.stats in
      let before = (s0.sul_reset_cnt, s0.sul_step_cnt, s0.sul_step_dry_cnt, s0.equivquery_samples) in
      let rec go i =
        if i >= r then None
        else (
          Random.init (Hashtbl.hash (round, i));
          pre_with_stats oracle w;
          oracle.stats.equivquery_samples <- oracle.stats.equivquery_samples + 1;
          match sample_and_run oracle ot w hyp hyp.s0 ot.s0 [] [] with
          | `Cex (_, is, _) -> Some (i, is)
          | `Equivalent _ -> S.post w; go (i + n)) in
      let found = go c in
      let a, b, d, e = before in
      (found, (oracle.stats.sul_reset_cnt - a, oracle.stats.sul_step_cnt - b, oracle.stats.sul_step_dry_cnt - d, oracle.stats.equivquery_samples - e)) in
    let children = List.mapi oracle.workers ~f:(fun c w ->
        let rd, wr = Core_unix.pipe () in
        match Core_unix.fork () with
        | `In_the_child ->
          Core_unix.close rd;
          let result = (try Ok (run_worker c w) with e -> Error (Exn.to_string e)) in
          let oc = Core_unix.out_channel_of_descr wr in
          Stdlib.Marshal.to_channel oc (result : ((int * I.t list) option * (int * int * int * int), string) Result.t) [];
          Stdlib.flush oc;
          Core_unix.exit_immediately 0
        | `In_the_parent pid -> Core_unix.close wr; (pid, rd)) in
    let results = List.map children ~f:(fun (pid, rd) ->
        let ic = Core_unix.in_channel_of_descr rd in
        let (res : ((int * I.t list) option * (int * int * int * int), string) Result.t) = Stdlib.Marshal.from_channel ic in
        Stdlib.close_in ic;
        ignore (Core_unix.waitpid pid);
        match res with Ok x -> x | Error m -> failwithf "PAC worker failed: %s" m ()) in
    List.iter results ~f:(fun (_, (a, b, d, e)) ->
        oracle.stats.sul_reset_cnt <- oracle.stats.sul_reset_cnt + a;
        oracle.stats.sul_step_cnt <- oracle.stats.sul_step_cnt + b;
        oracle.stats.sul_step_dry_cnt <- oracle.stats.sul_step_dry_cnt + d;
        oracle.stats.equivquery_samples <- oracle.stats.equivquery_samples + e);
    match List.filter_map results ~f:fst |> List.min_elt ~compare:(fun (i, _) (j, _) -> Int.compare i j) with
    | None -> `Equivalent
    | Some (_, is) ->
      (* the tree gets the counterexample from sul, which the workers' trees had *)
      let ot', _ = output_query oracle ot sul is in
      `Cex (ot', is)

  let equiv_query (oracle : t) (ot : IIOObservationTree.t) (sul : S.t) (hyp : IIOMealy.t) =
    oracle.stats.equivquery_cnt <- oracle.stats.equivquery_cnt + 1;
    let do_reset () = S.post sul; pre_with_stats oracle sul in
    (* This is the number of samples we need at this round *)
    match oracle.round_limit with
    | Some rl when oracle.round > rl -> `Equivalent
    | _ ->
      (let r = ref (Float.to_int (Float.round_up ((1.0 /. oracle.epsilon) *. (log (1.0 /. oracle.delta) +. ((log 2.0) *. (Float.of_int(oracle.round) +. 1.0)))))) in
        oracle.round <- oracle.round + 1;
        Logs.info (fun m -> m "[%.1fs] (PAC) equivalence query #%d: hypothesis with %d states, %d samples to draw (so far: %d samples, %d output queries, %d resets, %d SUL steps, %d dry steps)"
          (Float.of_int63 Int63.(Time_now.nanoseconds_since_unix_epoch () - start_time) /. 1e9) oracle.round (Set.length hyp.states) !r oracle.stats.equivquery_samples oracle.stats.outputquery_cnt oracle.stats.sul_reset_cnt oracle.stats.sul_step_cnt oracle.stats.sul_step_dry_cnt);
        Logs.debug (fun m -> m "(PAC) equiv_query (eps: %f, delta: %f): samples: %d, round #%d, sampling %d paths" oracle.epsilon oracle.delta oracle.stats.equivquery_samples oracle.round !r);
        if not (List.is_empty oracle.workers) then equiv_query_parallel oracle ot sul hyp !r else
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
