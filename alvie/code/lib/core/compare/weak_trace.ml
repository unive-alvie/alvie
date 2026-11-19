(*
  Weak trace inclusion between two labelled transition systems, with a shortest counterexample: what ALVIE asked
  mCRL2 for (ltscompare --preorder=weak-trace-ac --strategy=b, then tracepp -fplain).

  The labels in [silent] are tau. m1 ⊆ m2 holds when every trace of m1, without its silent labels, is a trace of m2
  without its silent labels. The search is breadth-first on pairs (state of m1, set of states of m2): the set holds
  the states that m2 can be in after the visible labels so far, closed under silent steps. A step of m1 with a silent
  label keeps the set; a step with a visible label moves every state of the set by that label and closes the result
  again. A visible step after which the set is empty is a counterexample. A pair (p, Q) is not explored when a pair
  (p, Q') with Q' ⊆ Q was: every counterexample from (p, Q) is one from (p, Q') too (the antichain of mCRL2).

  The counterexample is the path of m1 that the search found, silent labels included, as tracepp prints it: its last
  label is visible, and m2 cannot do the visible labels of the path. Breadth-first search finds a shortest one (in
  steps of m1, silent ones counted). Among paths of the same length, it takes the transitions of m1 in the order of
  [edges1].
*)

open Core

type edge = int * string * int

let successors (edges : edge list) =
  let tbl = Hashtbl.create (module Int) in
  (* Keep the order of the edges *)
  List.iter (List.rev edges) ~f:(fun (s, l, t) -> Hashtbl.add_multi tbl ~key:s ~data:(l, t));
  fun s -> Option.value (Hashtbl.find tbl s) ~default:[]

let counterexample ~(silent : string -> bool) ~initial1 ~(edges1 : edge list) ~initial2 ~(edges2 : edge list)
  : string list option =
  let succ1 = successors edges1 and succ2 = successors edges2 in
  let closure set =
    let rec go seen = function
      | [] -> seen
      | s :: rest ->
        let next = List.filter_map (succ2 s) ~f:(fun (l, t) -> if silent l && not (Set.mem seen t) then Some t else None) in
        go (List.fold next ~init:seen ~f:Set.add) (next @ rest) in
    go set (Set.to_list set) in
  let after set l =
    closure (Set.fold set ~init:Int.Set.empty ~f:(fun acc s ->
        List.fold (succ2 s) ~init:acc ~f:(fun acc (l', t) -> if String.equal l l' then Set.add acc t else acc))) in
  (* The antichain: for each state of m1, the minimal sets of m2 explored with it *)
  let explored = Hashtbl.create (module Int) in
  let subsumed p q = List.exists (Option.value (Hashtbl.find explored p) ~default:[]) ~f:(fun q' -> Set.is_subset q' ~of_:q) in
  let add p q =
    let kept = List.filter (Option.value (Hashtbl.find explored p) ~default:[]) ~f:(fun q' -> not (Set.is_subset q ~of_:q')) in
    Hashtbl.set explored ~key:p ~data:(q :: kept) in
  let queue = Queue.create () in
  let start = closure (Int.Set.singleton initial2) in
  add initial1 start;
  Queue.enqueue queue (initial1, start, []);
  let rec search () =
    match Queue.dequeue queue with
    | None -> None
    | Some (p, q, rev_path) ->
      let rec steps = function
        | [] -> search ()
        | (l, p') :: rest ->
          if silent l then (
            if not (subsumed p' q) then (add p' q; Queue.enqueue queue (p', q, l :: rev_path));
            steps rest)
          else
            let q' = after q l in
            if Set.is_empty q' then Some (List.rev (l :: rev_path))
            else (
              if not (subsumed p' q') then (add p' q'; Queue.enqueue queue (p', q', l :: rev_path));
              steps rest) in
      steps (succ1 p) in
  search ()
