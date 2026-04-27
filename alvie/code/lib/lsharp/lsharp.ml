(*
  This module implements a variant of the L# algorithm proposed in:
  - A New Approach for Active Automata Learning Based on Apartness
*)
open Core

open Mealy
open Elttype
open Observationtree
open Sul
open Oracle

open Showableint

module LSharp
  (I : EltType)
  (O : EltType)
  (S : SUL with type input_t = I.t and type output_t = O.t)
  (OR : Oracle) =
struct
  (* Mealy automaton with int states *)
  module IIOMealy = Mealy (ShowableInt) (I) (O)
  module IIOObservationTree = ObservationTree (ShowableInt) (I) (O)

  module IOSOracle = OR (I) (O) (S)

  module F2BMap = Int.Map
  type f2b_map_t = (int list) F2BMap.t

  (* let show_rule s = match Logs.level () with | Some Logs.Info -> Format.printf "%s" s; Out_channel.flush stdout | _ -> () *)

  let build_hypothesis
    (ot : IIOObservationTree.t)
    (basis : Int.Set.t)
    (_ : I.t list)
    (f2b : f2b_map_t) : IIOMealy.t =
    let h_states : Int.Set.t = basis in
    let h_q0 : int = 0 in
    let h_input_alphabet : IIOMealy.ISet.t = ot.input_alphabet in
    (* We need to build the transition function: we should "warp" the frontier back into the basis states using the given f2b *)
    let h_transition = List.fold
      (List.cartesian_product (Set.to_list basis) (Set.to_list h_input_alphabet))
      ~init:IIOMealy.TransitionMap.empty
      ~f:(fun tr_acc (q, i) ->
          match IIOObservationTree.transition ot (q, i) with
          | Some (o, succ) when (Set.mem basis succ) ->
              (* Add this transition to the hypothesis *)
              Map.add_exn tr_acc ~key:(q, i) ~data:(o, succ)
          | Some (o, succ) ->
              (match Map.find f2b succ with
              | None -> failwith "build_hypothesis: missing a frontier state"
              | Some [b_succ] ->
                  Map.add_exn tr_acc ~key:(q, i) ~data:(o, b_succ)
              | _ -> failwith "build_hypothesis: multiple candidates from a single frontier state")
          | None -> failwith "build_hypothesis: the basis is not complete, this is a bug :("
        ) in
      IIOMealy.make ~states:h_states ~s0:h_q0 ~input_alphabet:h_input_alphabet ~transition:h_transition

  (*
    Returns `Consistent if there exists a functional simulation from ot to hyp; otherwise returns a witness leading to the conflict.
  *)
  let check_consistency (ot : IIOObservationTree.t) (hyp : IIOMealy.t) =
    let rec _check_consistency (queue : (int*int) Fqueue.t) =
      (match Fqueue.dequeue queue with
      | None -> `Consistent
      | Some ((q, r), queue') ->
          if IIOObservationTree.apart ot q r then `NotConsistent (IIOObservationTree.access ot q)
          else
          (let queue'' = (Set.fold
            (IIOObservationTree.input_alphabet ot)
            ~init:queue'
            ~f:(fun qacc i ->
              match IIOObservationTree.step ot q i with
              | None -> qacc
              | Some p -> Fqueue.enqueue qacc (p, Option.value_exn (IIOMealy.step hyp r i))))
          in _check_consistency queue'')
      )
    in
    _check_consistency (Fqueue.enqueue Fqueue.empty (ot.s0, hyp.s0))

  let lsharp_run (oracle : IOSOracle.t) (sul : S.t) (input_alphabet : I.t list) (* (output_alphabet : O.t list) *) =
    (* This is for ADS and computes the expected reward
    let rec expected_reward ot u : int =
      let inp = IIOObservationTree.ISet.to_list (List.fold input_alphabet ~init:IIOObservationTree.ISet.empty ~f:(fun acc_inp i ->
          if IIOObservationTree.SSet.exists u ~f:(fun q -> Option.is_some (IIOObservationTree.transition ot (q, i))) then IIOObservationTree.ISet.add acc_inp i
          else acc_inp
        )) in
      let ui_card i = IIOObservationTree.SSet.count u ~f:(fun q -> Option.is_some (IIOObservationTree.transition ot (q, i))) in
      let uio i o = IIOObservationTree.SSet.fold ~init:IIOObservationTree.SSet.empty u ~f:(fun acc_q' q -> match IIOObservationTree.transition ot (q, i) with Some (o', q') when O.equal o o' -> IIOObservationTree.SSet.add acc_q' q' | _ -> acc_q') in
      let card s = IIOObservationTree.SSet.length s in
      let sum_over_o i = List.fold output_alphabet ~init:0 ~f:(fun acc_sum o ->
        let uio_set = uio i o in
        let uio_sz = card (uio i o) in
        let ui_sz = ui_card i in
          acc_sum + ((uio_sz * (ui_sz - uio_sz + (expected_reward ot uio_set)))/ui_sz)) in
          Option.value (List.max_elt ~compare:Int.compare (List.map inp ~f:sum_over_o)) ~default:0 in
    let rec ads *)
    (* Returns true if a basis is complete, i.e., the transition function is defined on S for any possible input *)
    let basis_complete (ot : IIOObservationTree.t) (basis : Int.Set.t) (input_alphabet : I.t list) : bool =
      let si_pairs = List.cartesian_product (Set.to_list basis) input_alphabet in
        List.for_all si_pairs ~f:(fun si -> Option.is_some (IIOObservationTree.transition ot si))
    in
    (* Recompute the frontier given the basis *)
    let gen_frontier (ot : IIOObservationTree.t) (basis : Int.Set.t) : Int.Set.t  =
      List.fold
        (List.filter_map
          (List.cartesian_product (Set.to_list basis) input_alphabet)
          ~f:(IIOObservationTree.transition ot))
      ~init:Int.Set.empty
      ~f:(fun prev_frontier (_, s') ->
            if not (Set.mem basis s') then Set.add prev_frontier s'
            else prev_frontier)
    in
    (* Computes the frontier to basis map *)
    let gen_f2b
      (ot : IIOObservationTree.t)
      ~(basis : Int.Set.t)
      ~(frontier : Int.Set.t) : f2b_map_t =
      Set.fold
        frontier
        ~init:F2BMap.empty
        ~f:(fun prev_f2b fs ->
          let fs_cand = Set.filter basis ~f:(fun b -> not (IIOObservationTree.apart ot fs b)) in
            Map.add_exn prev_f2b ~key:fs ~data:(Set.to_list fs_cand)
        ) in
    let shortest_cex (ot : IIOObservationTree.t) (hyp : IIOMealy.t) (rho : I.t list) : I.t list =
      (* Logs.debug (fun m -> m "shortest_cex: ot is %s" (Sexp.to_string (IIOObservationTree.sexp_of_t ot))); *)
      (* Logs.debug (fun m -> m "shortest_cex: hyp is %s" (Sexp.to_string (IIOMealy.sexp_of_t hyp))); *)
      let rec _shortest_cex rho pref =
        (match rho with
        | [] -> pref
        | i::rho_rest ->
            if List.is_empty pref then _shortest_cex rho_rest (pref @ [i])
            else
              (
                (* Logs.debug (fun m -> m "shortest_cex: pref is %s" (Sexp.to_string (List.sexp_of_t (I.sexp_of_t) pref))); *)
                (* Logs.debug (fun m -> m "shortest_cex: transition_all on ot"); *)
                let res_ot = IIOObservationTree.transition_all ot ot.s0 pref in
                (* Logs.debug (fun m -> m "shortest_cex: transition_all on hyp"); *)
                let res_hyp = IIOMealy.transition_all hyp hyp.s0 pref in
                match res_ot, res_hyp  with
                | Some (_, s_ot), Some (_, s_hyp) when IIOObservationTree.apart ot s_hyp s_ot -> pref
                | Some _, Some _ -> _shortest_cex rho_rest (pref @ [i])
                | _ -> failwith "shortest_cex: this may be a bug")
              )
      in
      _shortest_cex rho []
    in
    let rec proc_cex
      ~(ot : IIOObservationTree.t)
      ~(hyp : IIOMealy.t)
      ~(basis : Int.Set.t)
      ~(frontier : Int.Set.t)
      ~(sigma : I.t list) : IIOObservationTree.t * Int.Set.t =
        (* Logs.debug (fun m -> m "proc_cex: invoking transition_all for sigma on hyp"); *)
        let (_, q) = Option.value_exn (IIOMealy.transition_all hyp hyp.s0 sigma) in
        (* Logs.debug (fun m -> m "proc_cex: invoking transition_all for sigma on ot"); *)
        let (_, r) = Option.value_exn (IIOObservationTree.transition_all ot ot.s0 sigma) in
        (* Logs.debug (fun m -> m "proc_cex: r: %d; q: %d" r q); *)
        if Set.mem basis r || Set.mem frontier r then (ot, frontier)
        else
        (
          let sigma_prefixes = List.mapi sigma ~f:(fun idx _ -> List.take sigma (idx+1)) in
          let rho = Option.value_exn (List.find sigma_prefixes ~f:(fun pref ->
              let (_, s_cand) = Option.value_exn (IIOObservationTree.transition_all ot ot.s0 pref) in
              Set.mem frontier s_cand
              )) in
          (* Logs.debug (fun m -> m "proc_cex: rho: %s" (List.to_string ~f:I.show rho)); *)
          let h = (List.length rho + List.length sigma)/2 in
          let sigma_1 = List.slice sigma 0 h in
          let sigma_2 = List.slice sigma h 0 in
          (* Logs.debug (fun m -> m "proc_cex: h: %d; sigma: %s; sigma_1: %s, sigma_2: %s" h (List.to_string ~f:I.show sigma) (List.to_string ~f:I.show sigma_1) (List.to_string ~f:I.show sigma_2)); *)
          (* Logs.debug (fun m -> m "proc_cex: invoking transition_all for sigma_1 on hyp"); *)
          let _, q' = Option.value_exn (IIOMealy.transition_all hyp hyp.s0 sigma_1) in
          (* Logs.debug (fun m -> m "proc_cex: invoking transition_all for sigma_1 on ot"); *)
          let _, r' = Option.value_exn (IIOObservationTree.transition_all ot ot.s0 sigma_1) in
          (* Logs.debug (fun m -> m "proc_cex: r': %d; q': %d" r' q'); *)
          let witness = IIOObservationTree.apart_with_witness ot q r in
          match witness with
          | `NotApart -> failwith "proc_cex - could not find eta: this is a bug!"
          | `Apart eta -> (
                          let q'_access = (IIOObservationTree.access ot q') in
                          (* Logs.debug (fun m -> m "\x1B[33mproc_cex - invoking output_query\x1B[0m"); *)
                          (* Logs.debug (fun m -> m "proc_cex: q'_access: %s; eta: %s" (List.to_string ~f:I.show q'_access) (List.to_string ~f:I.show eta)); *)
                          let ot', _ = IOSOracle.output_query oracle ot sul (q'_access @ sigma_2 @ eta) in
                          let frontier' = gen_frontier ot' basis in
                          if IIOObservationTree.apart ot' q' r' then
                            proc_cex ~ot:ot' ~hyp:hyp ~basis:basis ~frontier:frontier' ~sigma:sigma_1
                          else
                            proc_cex ~ot:ot' ~hyp:hyp ~basis:basis ~frontier:frontier' ~sigma:(q'_access @ sigma_2))
        )
    in
    (*
      Here we specify the rules.
      The first bool value tells the caller if the rule has updated the parameters.
      The second one, tells if the algorithm should stop (actually, may be true just for rule 4)
    *)
    (*
      Rule 1: if we find an isolated state in frontier, update basis!
      We cannot (easily) batch updates to basis as we do for other rules, since changes to the basis change the frontier.
      FIXME: We could do that, but maybe it's not worthy
    *)
    let isolated_to_basis
      (ot : IIOObservationTree.t)
      (basis : Int.Set.t) =
      (* Logs.debug (fun m -> m "R1 check"); *)
      let frontier = gen_frontier ot basis in
      match Set.find frontier ~f:(fun q -> Set.for_all basis ~f:(IIOObservationTree.apart ot q)) with
      | None ->
          (* show_rule "\x1B[1;31m①\x1B[0m"; *)
          `ContinueNotApplied (ot, basis)
      | Some q ->
          (* show_rule "\x1B[1;32m①\x1B[0m"; *)
          `RestartApplied (ot, Set.add basis q)
    in
    (*
      Rule 2: If exists (s in basis) (i in input), ot.step s i = bot, then ask the teacher.
      Updates to rule 2 can be batched since we do not update basis/frontier/f2b but just the observation tree, but we avoid batching for performance reasons (i.e., too many output queries)
    *)
    let explore_frontier
      (ot : IIOObservationTree.t)
      (basis : Int.Set.t) =
      (* Logs.debug (fun m -> m "R2 check"); *)
      let undef_list = List.filter_map
        (List.cartesian_product (Set.to_list basis) input_alphabet)
        ~f:(fun (s, i) -> (match IIOObservationTree.step ot s i with Some _ -> None | _ -> Some (s, i))) in
      if List.is_empty undef_list then
        (* (show_rule "\x1B[1;31m②\x1B[0m"; *)
        (* Logs.debug (fun m -> m "R2 not applied"); *)
        `ContinueNotApplied (ot, basis)
        (* ) *)
      else
        (
        (* show_rule (sprintf "\x1B[1;32m②x%d\x1B[0m" (List.length undef_list)); *)
        (* `ContinueApplied (List.fold undef_list ~init:ot ~f:(fun acc_ot (s, i) ->
        let ot', _ (* iol *) = IOSOracle.output_query oracle acc_ot sul ((IIOObservationTree.access ot s) @ [i]) in
          (* (Logs.debug (fun m -> m "R2 applied: ot updated with %d -- %s/%s --> _"
            s
            (Sexp.to_string (I.sexp_of_t (fst (List.last_exn iol))))
            (Sexp.to_string (O.sexp_of_t (snd (List.last_exn iol))))
          )); *)
          ot'), basis) *)
        let (s, i) = List.random_element_exn undef_list in
        let ot', _ = IOSOracle.output_query oracle ot sul ((IIOObservationTree.access ot s) @ [i]) in
          `RestartApplied (ot', basis)
        )
    in
    (*
      Rule 3: applies if for some q in frontier there exist r, r' in basis with r <> r' s.t. not (q # r) and not (q # r'). Note that since r, r' in basis, we know r # r'

      This could be batched since the basis never changes and the only changes to the frontier happen due to changes to ot (i.e., frontier just grows, and our in-memory representation is always a subset of the actual one).
      Since we compute the list of candidate (q, r, r') s.t. not(q#r) and not(q#r') beforehand, it may happen that updates to ot make q#r or q#r'; In this case the triple is just skipped (the rule tries *exactly* to do that!).

      Again, we avoid batching for performance reasons (i.e., too many output queries)
    *)
    let explore_from_frontier
      (ot : IIOObservationTree.t)
      (basis : Int.Set.t) =
      (* This finds a state q in frontier s.t. exists r, r'. r <> r' /\ not (q # r) /\ not (q # r'), if any *)
      let frontier = gen_frontier ot basis in
      let f2b = gen_f2b ot ~basis ~frontier in
      let qrr'_list = List.filter_map (Map.to_alist f2b) ~f:(fun (q, r_list) -> match r_list with |
      r::r'::_ -> Some (q, r, r') | _ -> None) in
      if List.is_empty qrr'_list then
        (
          (* show_rule "\x1B[1;31m③\x1B[0m"; *)
          (* Logs.debug (fun m -> m "R3 not applied: no non-identified state q in frontier"); *)
          `ContinueNotApplied (ot, basis)
        )
      else
        (
          (* show_rule (sprintf "\x1B[1;32m③x%d\x1B[0m" (List.length qrr'_list)); *)
          (* Since we do not batch, we just select one from qrr'_list that satisfied the apartness conditions and use it. The fold_until stops after finding the first valid triple *)
          let ot' = List.fold_until qrr'_list ~init:ot ~finish:(fun ot -> ot) ~f:(
            fun acc_ot (q, r, r') ->
              if IIOObservationTree.apart acc_ot q r || IIOObservationTree.apart acc_ot q r' then
                Continue ot (* i.e., Skip the triple *)
              else
              (match IIOObservationTree.apart_with_witness ot r r' with
              | `Apart witness ->
                  let access_path = IIOObservationTree.access acc_ot q in
                  let ot', _ = IOSOracle.output_query oracle acc_ot sul (access_path @ witness) in
                  Stop ot'
                  (* let frontier' = gen_frontier ot' basis in
                  let f2b' = gen_f2b ot' ~basis:basis ~frontier:frontier' in *)
                    (* Logs.debug (fun m -> m "R3 applied"); *)
                    (* Logs.debug (fun p ->
                      let qr, qr' = IIOObservationTree.apart ot' q r, IIOObservationTree.apart ot' q r' in
                      assert (qr || qr');
                      p "After: ot' |- q # r? %b; ot' |- q # r'? %b" qr qr');
                    ot' *)
              | `NotApart ->
                  failwith (sprintf "[No witness of ot |- r # r' in R3]:
                    (ot |- q:%d # r:%d? %b),
                    (ot |- q:%d # r':%d? %b),
                    (acc_ot |- q:%d # r:%d? %b),
                    (acc_ot |- q:%d # r':%d? %b)"
                    q r (IIOObservationTree.apart ot q r)
                    q r' (IIOObservationTree.apart ot q r)
                    q r (IIOObservationTree.apart acc_ot q r)
                    q r' (IIOObservationTree.apart acc_ot q r))
              )
          ) in
            `RestartApplied (ot', basis)
        )
    in
    (* Rule 4: the only rule that can return true on the second component *)
    let check_hypothesis
      (ot : IIOObservationTree.t)
      (basis : Int.Set.t) =
      (* Logs.debug (fun m -> m "R4 check"); *)
      let frontier = gen_frontier ot basis in
      match (Set.find frontier ~f:(fun q -> Set.for_all basis ~f:(IIOObservationTree.apart ot q)), basis_complete ot basis input_alphabet) with
      | Some _, _ | None, false ->
        (* show_rule "\x1B[1;31m④\x1B[0m"; *)
        (* Logs.debug (fun m -> m "R4 not applied"); *)
        `RestartNotApplied (ot, basis)
      | None, true ->
        (* The conditions are OK for rule 4. *)
        let f2b = gen_f2b ot ~basis ~frontier in
        (* show_rule "\x1B[1;32m④\x1B[0m"; *)
        let h = build_hypothesis ot basis input_alphabet f2b in
        (* Logs.debug (fun m -> m "R4: ot is %s" (Sexp.to_string (IIOObservationTree.sexp_of_t ot))); *)
        (* Logs.debug (fun m -> m "R4: hypothesis is %s" (Sexp.to_string (IIOMealy.sexp_of_t h))); *)
        match check_consistency ot h with
        | `NotConsistent nc_witness ->
          (* Logs.debug (fun m -> m "R4: hypothesis not consistent"); *)
            let ot', _  = proc_cex ~ot:ot ~hyp:h ~basis:basis ~frontier:frontier ~sigma:nc_witness in
            (* let f2b' = gen_f2b ot' ~basis:basis ~frontier:frontier' in *)
              (* Logs.debug (fun m -> m "R4: applied"); *)
              `RestartApplied (ot', basis)
        | `Consistent -> (
          (match Logs.level () with
          | Some Logs.App -> Format.print_newline (); Out_channel.flush stdout
          | _ -> ());
            match IOSOracle.equiv_query oracle ot sul h with
            | `Cex (ot', icex) ->
                (* Logs.debug
                  (fun m -> m "R4: hyp consistent, cex found by equiv_query: %s"
                    (List.to_string ~f:I.show icex)); *)
                let short_cex = shortest_cex ot' h icex in
                  (* Logs.debug
                    (fun m -> m "R4: shortest_cex: %s"
                      (Sexp.to_string (List.sexp_of_t (I.sexp_of_t) short_cex))); *)
                let ot'', _ = proc_cex ~ot:ot' ~hyp:h ~basis:basis ~frontier:frontier ~sigma:short_cex in
                  (* Logs.debug (fun m -> m "R4 applied"); *)
                  (match Logs.level () with
                  | Some Logs.App -> Format.print_newline (); Out_channel.flush stdout
                  | _ -> ());
                  (* let f2b'' = gen_f2b ot'' ~basis:basis ~frontier:frontier' in *)
                  `RestartApplied (ot'', basis)
            | `Equivalent ->
              (* Logs.debug (fun m -> m "R4: done -- hyp and sul are equivalent!"); *)
              `Finished h
          )
    in
    (* Initialize basis, frontier and observation tree *)
    let basis = Int.Set.singleton 0 in
    let ot =
      IIOObservationTree.make
        ~states:(IIOObservationTree.SSet.singleton 0)
        ~s0:0
        ~input_alphabet: (Set.Using_comparator.of_list ~comparator:I.comparator input_alphabet)
        ~transition:(IIOObservationTree.TransitionMap.empty) in
    (* let frontier = gen_frontier ot basis in
    let f2b = gen_f2b ot ~basis:basis ~frontier:frontier in *)
    let rule_sched = [ isolated_to_basis; explore_frontier; explore_from_frontier; check_hypothesis ] in
    (* Execute the above rules, using Rule 4 only if nothing else applies (it's the last in the list!) *)
    let rec _rule_apply rl c_ot c_basis =
      (match rl with
      | [] -> failwith "No rule is applicable and R4 did not find a suitable automatons: this is a bug."
      | rule::rs ->
        match rule c_ot c_basis with
        | `RestartApplied (p_ot, p_basis)
        | `RestartNotApplied (p_ot, p_basis) ->
            (* The rule requested to start over *)
            (* show_rule " "; *)
            _rule_apply rule_sched p_ot p_basis
        | `ContinueNotApplied (p_ot, p_basis) ->
        (* | `ContinueApplied (p_ot, p_basis) -> *)
            (* Last rule not applied, proceed with current schedule *)
            _rule_apply rs p_ot p_basis
        | `Finished h ->
            (* Rule 4 completed the learning process *)
            h
      ) in
    _rule_apply rule_sched ot basis
end
