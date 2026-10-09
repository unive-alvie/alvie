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
  let check_consistency ?(apart = IIOObservationTree.apart) (ot : IIOObservationTree.t) (hyp : IIOMealy.t) =
    let rec _check_consistency (queue : (int*int) Fqueue.t) =
      (match Fqueue.dequeue queue with
      | None -> `Consistent
      | Some ((q, r), queue') ->
          if apart ot q r then `NotConsistent (IIOObservationTree.access ot q)
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
    (*
      All the observation trees handled during a run are extensions of one another, and apartness is
      monotone wrt extension: once q # r holds, it holds forever. Hence we remember positive answers
      (only booleans: witnesses may change when the tree grows) and recompute just the negative ones.
    *)
    let known_apart = Hash_set.Poly.create () in
    (*
      Negative answers can be reused too, as long as the tree did not change below q or r: q # r only
      depends on the subtrees rooted in q and r. We keep, for each node, the last epoch in which a node
      was added to its subtree, and for each non-apart pair the epoch in which this was checked.
      New nodes are found relying on the fact that the oracles number them increasingly.
    *)
    let epoch = ref 0 in
    let max_seen = ref (-1) in
    let modified_at = Int.Table.create () in
    (* Outgoing edges of each node, kept in sync with the tree (transitions are only ever added) *)
    let children : (I.t * O.t * int) list Int.Table.t = Int.Table.create () in
    (* Nodes that got new children since the frontier was last computed (see gen_frontier) *)
    let new_parents = Int.Hash_set.create () in
    (* Same as new_parents, for explore_frontier *)
    let new_parents_r2 = Int.Hash_set.create () in
    let known_not_apart = Hashtbl.Poly.create () in
    let sync (ot : IIOObservationTree.t) =
      match Set.max_elt ot.states with
      | Some m when m > !max_seen ->
        incr epoch;
        Sequence.iter (Set.to_sequence ot.states ~greater_or_equal_to:(!max_seen + 1)) ~f:(fun n ->
          Option.iter (Map.find ot.pred_map n) ~f:(fun (p, i) ->
            let o = Option.value_exn (IIOMealy.output ot p i) in
            Hashtbl.add_multi children ~key:p ~data:(i, o, n);
            Hash_set.add new_parents p;
            Hash_set.add new_parents_r2 p);
          (* Mark n and its ancestors, stopping at the first one already marked in this epoch *)
          let rec mark n =
            match Hashtbl.find modified_at n with
            | Some e when e = !epoch -> ()
            | _ ->
              Hashtbl.set modified_at ~key:n ~data:!epoch;
              Option.iter (Map.find ot.pred_map n) ~f:(fun (p, _) -> mark p) in
          mark n);
        max_seen := m
      | _ -> () in
    (* Same answer as IIOObservationTree.apart on the latest tree, using the index above *)
    let apart_indexed q r =
      let edges n = Option.value (Hashtbl.find children n) ~default:[] in
      let rec explore = function
        | [] -> false
        | (a, b) :: rest ->
          let eb = edges b in
          let rec scan todo = function
            | [] -> explore todo
            | (i, o, a') :: ea ->
              match List.find eb ~f:(fun (i', _, _) -> I.equal i i') with
              | None -> scan todo ea
              | Some (_, o', b') -> if O.equal o o' then scan ((a', b') :: todo) ea else true in
          scan rest (edges a) in
      explore [ (q, r) ] in
    let unchanged_since e n = Option.value (Hashtbl.find modified_at n) ~default:0 <= e in
    let apart_fast (ot : IIOObservationTree.t) q r =
      Hash_set.mem known_apart (q, r) ||
      (sync ot;
       match Hashtbl.find known_not_apart (q, r) with
       | Some e when unchanged_since e q && unchanged_since e r -> false
       | _ ->
         let res = Prof.time "lsharp.apart(miss)" (fun () -> apart_indexed q r) in
         if res then (Hash_set.add known_apart (q, r); Hash_set.add known_apart (r, q))
         else Hashtbl.set known_not_apart ~key:(q, r) ~data:!epoch;
         res) in
    let check_apart = Option.is_some (Sys.getenv "ALVIE_CHECK_APART") in
    let apart (ot : IIOObservationTree.t) q r =
      let res = apart_fast ot q r in
      if check_apart && not (Bool.equal res (IIOObservationTree.apart ot q r)) then
        failwithf "apartness cache disagrees on (%d, %d)" q r ();
      res in
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
    (*
      Basis states that are not apart from q. Since apartness is monotone and the basis only grows,
      we only need to re-check the previous candidates of q and the basis states added since then.
    *)
    let cand_memo : (Int.Set.t * Int.Set.t * int) Int.Table.t = Int.Table.create () in
    let rec candidates (ot : IIOObservationTree.t) (basis : Int.Set.t) (q : int) : Int.Set.t =
      let res = candidates_fast ot basis q in
      if check_apart && not (Set.equal res (Set.filter basis ~f:(fun b -> not (IIOObservationTree.apart ot q b)))) then
        failwithf "candidate cache disagrees on %d" q ();
      res
    and candidates_fast (ot : IIOObservationTree.t) (basis : Int.Set.t) (q : int) : Int.Set.t =
      sync ot;
      match Hashtbl.find cand_memo q with
      (* Nothing changed below q or its candidates since we computed them: they are still the same *)
      | Some (old_basis, old_cands, e) when phys_equal old_basis basis && unchanged_since e q && Set.for_all old_cands ~f:(unchanged_since e) ->
        old_cands
      | memo ->
        let to_check = match memo with
          | Some (old_basis, old_cands, _) when phys_equal old_basis basis -> old_cands
          | Some (old_basis, old_cands, _) when Set.is_subset old_basis ~of_:basis -> Set.union old_cands (Set.diff basis old_basis)
          | _ -> basis in
        let cands = Set.filter to_check ~f:(fun b -> not (apart ot q b)) in
        Hashtbl.set cand_memo ~key:q ~data:(basis, cands, !epoch);
        cands in
    (* Recompute the frontier given the basis *)
    let frontier_memo : (Int.Set.t * Int.Set.t) option ref = ref None in
    let rec gen_frontier (ot : IIOObservationTree.t) (basis : Int.Set.t) : Int.Set.t  =
      Prof.time "lsharp.gen_frontier" @@ fun () ->
      (* Same as gen_frontier_orig, using the index of the children of each node *)
      sync ot;
      let add_children_of acc b =
        List.fold (Option.value (Hashtbl.find children b) ~default:[]) ~init:acc ~f:(fun acc (_, _, s') ->
          if Set.mem basis s' then acc else Set.add acc s') in
      let res = match !frontier_memo with
        (* Same basis as last time: only the nodes that got new children can extend the frontier *)
        | Some (old_basis, old_frontier) when phys_equal old_basis basis ->
          Hash_set.fold new_parents ~init:old_frontier ~f:(fun acc p -> if Set.mem basis p then add_children_of acc p else acc)
        | _ -> Set.fold basis ~init:Int.Set.empty ~f:add_children_of in
      Hash_set.clear new_parents;
      frontier_memo := Some (basis, res);
      if check_apart && not (Set.equal res (gen_frontier_orig ot basis)) then failwith "frontier index disagrees";
      res
    and gen_frontier_orig (ot : IIOObservationTree.t) (basis : Int.Set.t) : Int.Set.t  =
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
      Prof.time "lsharp.gen_f2b" @@ fun () ->
      Set.fold
        frontier
        ~init:F2BMap.empty
        ~f:(fun prev_f2b fs ->
          let fs_cand = candidates ot basis fs in
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
                | Some (_, s_ot), Some (_, s_hyp) when apart ot s_hyp s_ot -> pref
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
                          if apart ot' q' r' then
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
      match Set.find frontier ~f:(fun q -> Set.is_empty (candidates ot basis q)) with
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
    let undef_memo : (Int.Set.t * (int * I.t) list) option ref = ref None in
    let explore_frontier
      (ot : IIOObservationTree.t)
      (basis : Int.Set.t) =
      (* Logs.debug (fun m -> m "R2 check"); *)
      (* The undefined transitions from basis states, in the same order as
           List.cartesian_product (Set.to_list basis) input_alphabet (a random one is picked below).
           They can only change when the basis changes or a basis state gets a new transition. *)
      sync ot;
      let undef_list = match !undef_memo with
        | Some (old_basis, l) when phys_equal old_basis basis && not (Hash_set.exists new_parents_r2 ~f:(Set.mem basis)) -> l
        | _ ->
          List.concat_map (Set.to_list basis) ~f:(fun s ->
            let defined = Option.value (Hashtbl.find children s) ~default:[] in
            List.filter_map input_alphabet ~f:(fun i ->
              if List.exists defined ~f:(fun (i', _, _) -> I.equal i i') then None else Some (s, i))) in
      Hash_set.clear new_parents_r2;
      undef_memo := Some (basis, undef_list);
      if check_apart then assert (List.equal (fun (s, i) (s', i') -> s = s' && I.equal i i') undef_list
        (List.filter_map (List.cartesian_product (Set.to_list basis) input_alphabet)
          ~f:(fun (s, i) -> (match IIOObservationTree.step ot s i with Some _ -> None | _ -> Some (s, i)))));
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
      (* Only the first triple (in increasing order of q) can be used below, since candidates are never
         apart from q in ot: look for it lazily instead of building the whole frontier-to-basis map *)
      let qrr'_list =
        Set.to_sequence frontier
        |> Sequence.find_map ~f:(fun q ->
          match Set.to_list (candidates ot basis q) with r :: r' :: _ -> Some (q, r, r') | _ -> None)
        |> Option.to_list in
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
              if apart acc_ot q r || apart acc_ot q r' then
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
      match (Set.find frontier ~f:(fun q -> Set.is_empty (candidates ot basis q)), basis_complete ot basis input_alphabet) with
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
        match Prof.time "lsharp.check_consistency" (fun () -> check_consistency ~apart ot h) with
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
            match Prof.time "oracle.equiv_query" (fun () -> IOSOracle.equiv_query oracle ot sul h) with
            | `Cex (ot', icex) ->
                (* Logs.debug
                  (fun m -> m "R4: hyp consistent, cex found by equiv_query: %s"
                    (List.to_string ~f:I.show icex)); *)
                let short_cex = shortest_cex ot' h icex in
                  (* Logs.debug
                    (fun m -> m "R4: shortest_cex: %s"
                      (Sexp.to_string (List.sexp_of_t (I.sexp_of_t) short_cex))); *)
                let ot'', _ = Prof.time "lsharp.proc_cex" @@ fun () -> proc_cex ~ot:ot' ~hyp:h ~basis:basis ~frontier:frontier ~sigma:short_cex in
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
    let rule_sched = [
      (fun ot b -> Prof.time "lsharp.R1 isolated_to_basis" (fun () -> isolated_to_basis ot b));
      (fun ot b -> Prof.time "lsharp.R2 explore_frontier" (fun () -> explore_frontier ot b));
      (fun ot b -> Prof.time "lsharp.R3 explore_from_frontier" (fun () -> explore_from_frontier ot b));
      (fun ot b -> Prof.time "lsharp.R4 check_hypothesis" (fun () -> check_hypothesis ot b)) ] in
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
