(*
  Brzozowski derivatives of spec bodies (Alvie_plugin.Spec.body) by atoms: the language of derive b a is the set of
  w such that a w is in the language of b. A section accepts atom a next iff derive b a is not empty.

  This is the construction of lib/sancus/attacker.ml and enclave.ml, on values: derivatives are not simplified, and
  are memoised, as there.
*)

open Core
open Alvie_plugin
module S = Spec

let rec nu (b : S.body) =
  match b with
  | Epsilon | Star _ -> true
  | Empty | Atom _ -> false
  | Seq (r, s) -> nu r && nu s
  | Choice (r, s) -> nu r || nu s

let memo : (S.body * Value.t, S.body) Hashtbl.t = Hashtbl.Poly.create ()

let rec derive (b : S.body) (a : Value.t) : S.body =
  match Hashtbl.find memo (b, a) with
  | Some d -> d
  | None ->
    let d : S.body = match b with
      | Empty | Epsilon -> Empty
      | Atom a' -> if Value.equal a a' then Epsilon else Empty
      | Seq (r, s) -> Choice (Seq (derive r a, s), Seq ((if nu r then Epsilon else Empty), derive s a))
      | Star r -> Seq (derive r a, Star r)
      | Choice (r, s) -> Choice (derive r a, derive s a) in
    Hashtbl.set memo ~key:(b, a) ~data:d;
    d

(* Whether the language of b is empty *)
let rec is_empty (b : S.body) =
  match b with
  | Empty -> true
  | Epsilon | Atom _ | Star _ -> false
  | Seq (r, s) -> is_empty r || is_empty s
  | Choice (r, s) -> is_empty r && is_empty s

let atoms_memo : (S.body, Value.t list) Hashtbl.t = Hashtbl.Poly.create ()

(* The atoms that occur in b, without repetitions *)
let atoms (b : S.body) =
  match Hashtbl.find atoms_memo b with
  | Some l -> l
  | None ->
    let l = List.dedup_and_sort (S.atoms b) ~compare:Value.compare in
    Hashtbl.set atoms_memo ~key:b ~data:l;
    l

(* The atoms that b accepts next, in the declaration order of the class cls *)
let next (g : Grammar.t) ~cls (b : S.body) : Value.t list =
  List.filter (atoms b) ~f:(fun a -> not (is_empty (derive b a)))
  |> List.sort ~compare:(Grammar.compare_atom g ~cls)
