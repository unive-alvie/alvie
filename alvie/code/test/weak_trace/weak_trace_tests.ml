(* Tests of Weak_trace: cases with the counterexamples of mCRL2 (ltscompare --preorder=weak-trace-ac --strategy=b,
   tracepp -fplain), and random systems checked against a search of every path. *)
open Core

let silent l = String.equal l "t"
let cex ?(i1 = 0) ?(i2 = 0) e1 e2 = Ltscompare.Weak_trace.counterexample ~silent ~initial1:i1 ~edges1:e1 ~initial2:i2 ~edges2:e2
let check name expected actual = Alcotest.(check (option (list string))) name expected actual

(* Counterexamples that mCRL2 202607.0 gives *)
let fixed () =
  let m1 = [ (0, "a", 1); (1, "t", 2); (2, "b", 3); (1, "c", 3) ] and m2 = [ (0, "a", 1); (1, "t", 2); (2, "c", 1) ] in
  check "silent step on the path" (Some [ "a"; "t"; "b" ]) (cex m1 m2);
  check "silent steps of m2 are free" None (cex [ (0, "a", 1); (1, "c", 2) ] m2);
  check "first label" (Some [ "b" ]) (cex [ (0, "b", 1) ] m2);
  check "empty system" None (cex [] m2);
  check "itself" None (cex m1 m1);
  check "silent loop" None (cex [ (0, "t", 0); (0, "a", 1) ] [ (0, "a", 0) ])

(* Every path of m from its initial state with at most [depth] steps, as label lists *)
let paths ~depth edges initial =
  let rec go s d = if d = 0 then [ [] ] else
      [] :: List.concat_map edges ~f:(fun (s', l, t) -> if s = s' then List.map (go t (d - 1)) ~f:(fun p -> l :: p) else []) in
  List.dedup_and_sort (go initial depth) ~compare:[%compare: string list]

(* Whether m has the visible labels of [labels] as a weak trace *)
let accepts edges initial labels =
  let close set =
    let rec fix set = let set' = List.fold edges ~init:set ~f:(fun acc (s, l, t) -> if silent l && Set.mem set s then Set.add acc t else acc) in
      if Set.equal set set' then set else fix set' in fix set in
  let visible = List.filter labels ~f:(Fn.non silent) in
  not (Set.is_empty (List.fold visible ~init:(close (Int.Set.singleton initial)) ~f:(fun set l ->
      close (List.fold edges ~init:Int.Set.empty ~f:(fun acc (s, l', t) -> if Set.mem set s && String.equal l l' then Set.add acc t else acc)))))

let is_cex e1 e2 p = (match List.last p with Some l -> not (silent l) | None -> false) && not (accepts e2 0 p)

let random () =
  let rng = Random.State.make [| 7 |] in
  let system () =
    let n = 1 + Random.State.int rng 4 and m = Random.State.int rng 7 in
    List.init m ~f:(fun _ -> (Random.State.int rng n, List.random_element_exn ~random_state:rng [ "a"; "b"; "t" ], Random.State.int rng n)) in
  for case = 1 to 3000 do
    let e1 = system () and e2 = system () in
    let all = paths ~depth:5 e1 0 in
    let shortest = List.filter all ~f:(is_cex e1 e2) |> List.map ~f:List.length |> List.min_elt ~compare:Int.compare in
    match cex e1 e2, shortest with
    | None, None -> ()
    | None, Some k -> Alcotest.failf "case %d: no counterexample, but there is one of %d steps" case k
    | Some p, _ ->
      if not (List.mem all p ~equal:[%equal: string list]) && List.length p <= 5 then Alcotest.failf "case %d: %s is not a path of m1" case (String.concat ~sep:" " p);
      if not (is_cex e1 e2 p) then Alcotest.failf "case %d: %s is not a counterexample" case (String.concat ~sep:" " p);
      Option.iter shortest ~f:(fun k -> if List.length p <> k then Alcotest.failf "case %d: %d steps, the shortest has %d" case (List.length p) k)
  done

let () =
  Alcotest.run "weak_trace"
    [ ("weak trace inclusion", [ Alcotest.test_case "cases of mCRL2" `Quick fixed; Alcotest.test_case "random systems" `Quick random ]) ]
