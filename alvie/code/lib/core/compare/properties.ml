(*
  The properties that ALVIE/Core checks on learned models: a fixed catalogue, version 1. A plugin chooses among
  them; it does not add its own (new properties are extensions of Core).

  All of them see the models as the attacker does: through the hooks (Plugin_hooks derives them from the attacker
  view), with hidden outputs silent.

  - Noninterference between two models that differ only in the secret (e.g. secret 0 and 1): the pairs of runs
    with the same low inputs and the same victim code (up to the secret) that the attacker tells apart, minus
    those of a baseline (e.g. the same models without interrupts). Checked in both directions.
  - Inclusion of the traces of a model in those of another, and equivalence (inclusion both ways): e.g. two
    versions of a design with the same secret, to find a regression or check a patch.
  - A modal mu-calculus formula of mCRL2 on one model, whose actions are the comparison labels of its transitions.
*)

open Core

let version = 1

module Make (H : Hooks.S) = struct
  module C = Cexfinder.Make (H)

  type witness = C.Obs.t list * C.Obs.t list

  (* Noninterference: (number of witnesses, witness graph, witnesses) *)
  let noninterference ?limit ?(baseline : (C.i_lts_t * C.i_lts_t) option) ~tmpdir ~names:(n1, n2) (m1 : C.i_lts_t) (m2 : C.i_lts_t) =
    let to_remove = match baseline with
      | None -> []
      | Some (b1, b2) -> trd3 (C.find_all_cex_sym ?limit ~to_remove:[] ~tmpdir ~m1_name:(n1 ^ " (baseline)") ~m2_name:(n2 ^ " (baseline)") ~m1:b1 ~m2:b2 ()) in
    C.find_all_cex_sym ?limit ~to_remove ~tmpdir ~m1_name:n1 ~m2_name:n2 ~m1 ~m2 ()

  (* A trace (comparison labels) of m1 that m2 does not have, if any *)
  let inclusion ~tmpdir (m1 : C.i_lts_t) (m2 : C.i_lts_t) : string list option = C.find_cex_aut ~tmpdir m1 m2

  let equivalence ~tmpdir m1 m2 =
    match inclusion ~tmpdir m1 m2 with
    | Some trace -> `Only_in_first trace
    | None -> (match inclusion ~tmpdir m2 m1 with Some trace -> `Only_in_second trace | None -> `Equivalent)

  (*
    Whether the model satisfies the formula (an .mcf file of mCRL2), with lts2pbes and pbes2bool. Hidden transitions
    are tau. mCRL2 actions are identifiers: each visible label becomes one, made of its letters and digits (with a
    number when two would be the same), and actions.txt, next to the model, lists them. With --debug the directory
    is kept.
  *)
  let formula ~tmpdir (m : C.i_lts_t) ~formula_file : (bool, string) Result.t =
    let names = Hashtbl.create (module String) and used = Hash_set.create (module String) in
    let name_of label =
      match Hashtbl.find names label with
      | Some n -> n
      | None ->
        let base = String.map label ~f:(fun c -> if Char.is_alphanum c then c else '_') in
        let base = if String.is_empty base || not (Char.is_alpha base.[0]) then "a_" ^ base else base in
        let rec fresh k = let n = if k = 0 then base else sprintf "%s_%d" base k in if Hash_set.mem used n then fresh (k + 1) else n in
        let n = fresh 0 in
        Hash_set.add used n; Hashtbl.set names ~key:label ~data:n; n in
    let states = m.initial :: Set.to_list (Set.remove m.states m.initial) in
    let index = Int.Map.of_alist_exn (List.mapi states ~f:(fun i s -> (s, i))) in
    let edges = Map.fold m.transition ~init:[] ~f:(fun ~key:(s, o) ~data:targets acc ->
        let action = if C.Obs.is_silent o then "tau" else name_of (C.label o) in
        Set.fold targets ~init:acc ~f:(fun acc t -> sprintf "(%d, \"%s\", %d)" (Map.find_exn index s) action (Map.find_exn index t) :: acc)) in
    let lines l = String.concat (List.map l ~f:(fun x -> x ^ "\n")) in
    let aut = lines (sprintf "des (0, %d, %d)" (List.length edges) (List.length states) :: List.rev edges) in
    let actions = Hashtbl.to_alist names in
    let spec = sprintf "act %s;\ninit delta;\n" (match actions with [] -> "none" | _ -> String.concat ~sep:", " (List.map actions ~f:snd)) in
    Alvie_mcrl2.Mcrl2_engine.formula ~tmpdir ~aut ~spec ~actions:(lines (List.map actions ~f:(fun (label, n) -> n ^ "\t" ^ label))) ~formula_file
end
