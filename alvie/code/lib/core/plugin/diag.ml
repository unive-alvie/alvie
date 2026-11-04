(*
  Diagnostics: the errors that Core reports about a plugin's files and about specs, with the place they refer to.
  They print as file:line:column: message, the form editors and compilers use, with an optional hint on how to fix
  the problem.
*)

open Core

type pos = { file : string; line : int; col : int } [@@deriving sexp, equal, compare]

type t = { pos : pos option; message : string; hint : string option } [@@deriving sexp, equal]

let error ?pos ?hint message = { pos; message; hint }
let errorf ?pos ?hint fmt = Printf.ksprintf (fun message -> error ?pos ?hint message) fmt

let pos_to_string p = sprintf "%s:%d:%d" p.file p.line p.col

let to_string d =
  let where = match d.pos with Some p -> pos_to_string p ^ ": " | None -> "" in
  let hint = match d.hint with Some h -> "\n  hint: " ^ h | None -> "" in
  where ^ d.message ^ hint

let list_to_string ds = String.concat ~sep:"\n" (List.map ds ~f:to_string)

(* The closest of candidates to s, to suggest it after a typo (edit distance at most 2, or a third of the length) *)
let did_you_mean s candidates =
  let distance a b =
    let la, lb = String.length a, String.length b in
    let d = Array.make_matrix ~dimx:(la + 1) ~dimy:(lb + 1) 0 in
    for i = 0 to la do d.(i).(0) <- i done;
    for j = 0 to lb do d.(0).(j) <- j done;
    for i = 1 to la do
      for j = 1 to lb do
        let cost = if Char.equal a.[i - 1] b.[j - 1] then 0 else 1 in
        d.(i).(j) <- Int.min (Int.min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + cost)
      done
    done;
    d.(la).(lb) in
  let scored = List.map candidates ~f:(fun c -> (distance (String.lowercase s) (String.lowercase c), c)) in
  match List.min_elt scored ~compare:(fun (a, _) (b, _) -> Int.compare a b) with
  | Some (d, c) when d <= Int.max 2 (String.length s / 3) && d < String.length s -> Some c
  | _ -> None

let hint_did_you_mean s candidates = Option.map (did_you_mean s candidates) ~f:(fun c -> sprintf "did you mean %S?" c)

(* "a, b or c" *)
let enumerate ?(conj = "or") items =
  match List.rev items with
  | [] -> ""
  | [ x ] -> x
  | last :: rest -> String.concat ~sep:", " (List.rev rest) ^ " " ^ conj ^ " " ^ last
