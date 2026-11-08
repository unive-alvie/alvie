(*
  Values: the one representation of atoms, observations and configuration that Core and every plugin share.

  A plugin declares its types in YAML (atoms.yaml, observations.yaml); every value of those types is a Value.t:

  - Int: a bounded integer (the bounds are in the type, not in the value);
  - Bool;
  - Sym: a name (an identifier such as a label, or a constant of an enumeration);
  - List: a list of values of one type;
  - Node (tag, fields): a variant or a record, with its fields in the order of the declaration;
  - Hole name: a typed hole for a secret, before the secret is expanded.

  Values compare, hash and serialize structurally. Their JSON form (see to_json) is the one of the external plugin
  protocol and of the JSON Schemas that Core generates.
*)

open Core

type t =
  | Int of int
  | Bool of bool
  | Sym of string
  | List of t list
  | Node of string * (string * t) list
  | Hole of string
[@@deriving equal, compare, sexp, hash]

let node ?(fields = []) tag = Node (tag, fields)

let tag = function Node (tag, _) -> Some tag | _ -> None

let field v name =
  match v with
  | Node (_, fields) -> List.Assoc.find fields ~equal:String.equal name
  | _ -> None

(* The value at a dotted path of fields (e.g. "time.mode"), if there is one *)
let rec path v = function
  | [] -> Some v
  | name :: rest -> Option.bind (field v name) ~f:(fun v -> path v rest)

let rec has_hole = function
  | Hole _ -> true
  | Int _ | Bool _ | Sym _ -> false
  | List vs -> List.exists vs ~f:has_hole
  | Node (_, fields) -> List.exists fields ~f:(fun (_, v) -> has_hole v)

(* Replaces every hole by the value that f gives for it *)
let rec fill_holes v ~f =
  match v with
  | Hole name -> f name
  | Int _ | Bool _ | Sym _ -> v
  | List vs -> List (List.map vs ~f:(fill_holes ~f))
  | Node (tag, fields) -> Node (tag, List.map fields ~f:(fun (name, v) -> (name, fill_holes v ~f)))

(*
  A readable form for messages and logs, e.g. mov(src = reg(i = 5), dst = reg(i = 6)). Specs and witness graphs use
  the plugin's syntax instead (Grammar.print).
*)
let rec to_string = function
  | Int i -> Int.to_string i
  | Bool b -> Bool.to_string b
  | Sym s -> s
  | List vs -> "[" ^ String.concat ~sep:"; " (List.map vs ~f:to_string) ^ "]"
  | Node (tag, []) -> tag
  | Node (tag, fields) ->
    tag ^ "(" ^ String.concat ~sep:", " (List.map fields ~f:(fun (name, v) -> name ^ " = " ^ to_string v)) ^ ")"
  | Hole name -> "?" ^ name

let pp fmt v = Format.pp_print_string fmt (to_string v)

(*
  The JSON form:
  - Int, Bool: JSON numbers and booleans; Sym: a JSON string; List: a JSON array;
  - Node (tag, fields): an object with a single member, the tag, whose value is the object of the fields
    ({"mov": {"src": ..., "dst": ...}}); a node without fields is {"nop": {}};
  - Hole name: {"?": name}. "?" is never a tag, so the two cannot be confused.
*)
let rec to_json : t -> Yojson.Safe.t = function
  | Int i -> `Int i
  | Bool b -> `Bool b
  | Sym s -> `String s
  | List vs -> `List (List.map vs ~f:to_json)
  | Node (tag, fields) -> `Assoc [ (tag, `Assoc (List.map fields ~f:(fun (name, v) -> (name, to_json v)))) ]
  | Hole name -> `Assoc [ ("?", `String name) ]

let rec of_json (j : Yojson.Safe.t) : (t, string) result =
  let open Result.Let_syntax in
  match j with
  | `Int i -> Ok (Int i)
  | `Bool b -> Ok (Bool b)
  | `String s -> Ok (Sym s)
  | `List js ->
    let%map vs = Result.all (List.map js ~f:of_json) in
    List vs
  | `Assoc [ ("?", `String name) ] -> Ok (Hole name)
  | `Assoc [ (tag, `Assoc fields) ] ->
    let%map fields =
      Result.all (List.map fields ~f:(fun (name, j) -> let%map v = of_json j in (name, v)))
    in
    Node (tag, fields)
  | j -> Error (sprintf "not a value: %s" (Yojson.Safe.to_string j))

include Comparator.Make (struct
  type nonrec t = t
  let compare = compare
  let sexp_of_t = sexp_of_t
end)

(*
  Interning (hash-consing): structurally equal values share one representative, numbered by a unique id, so that
  equality and hashing of interned values are integer operations. The learner compares inputs and outputs in its
  hot paths (the observation tree, the oracles' caches), where this matters; see test/value_bench.ml.

  Interned values are ordered as the values they stand for, so that sets and maps of interned values iterate exactly
  as those of plain values (learning depends on that order). Comparing two values preloaded together (preload, with
  e.g. the atoms of a spec before learning starts) is an integer comparison: their ids are given in sorted order.
  Other comparisons fall back to comparing the values.

  The table keeps the values it has seen for the lifetime of the program, which is fine for the alphabets of a
  learning run (thousands of distinct values at most).
*)
type value = t

module Interned : sig
  type t [@@deriving sexp]

  val intern : value -> t
  val preload : value list -> unit
  val value : t -> value
  val id : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val hash : t -> int
  val hash_fold_t : Hash.state -> t -> Hash.state
  val count : unit -> int
end = struct
  type t = { id : int; value : value }

  let table : (value, t) Hashtbl.t = Hashtbl.create (module struct
    type nonrec t = value
    let compare = compare
    let sexp_of_t = sexp_of_t
    let hash = hash
  end)

  (* The ids below ordered_upto are in the order of their values *)
  let ordered_upto = ref 0

  let add v =
    let i = { id = Hashtbl.length table; value = v } in
    Hashtbl.set table ~key:v ~data:i;
    i

  let intern v = match Hashtbl.find table v with Some i -> i | None -> add v

  let preload vs =
    let fresh = List.dedup_and_sort (List.filter vs ~f:(fun v -> not (Hashtbl.mem table v))) ~compare in
    let all_fresh_and_first = Hashtbl.length table = !ordered_upto in
    List.iter fresh ~f:(fun v -> ignore (add v));
    (* The new ids extend the ordered ones only if nothing else was interned since, and if each new value comes
       after all the ordered ones *)
    let after_ordered = match fresh with
      | [] -> true
      | first :: _ ->
        Hashtbl.for_all table ~f:(fun i -> i.id >= !ordered_upto || compare i.value first < 0) in
    if all_fresh_and_first && after_ordered then ordered_upto := Hashtbl.length table

  let value i = i.value
  let id i = i.id
  let equal a b = Int.equal a.id b.id

  let compare a b =
    if Int.equal a.id b.id then 0
    else if a.id < !ordered_upto && b.id < !ordered_upto then Int.compare a.id b.id
    else compare a.value b.value

  let hash i = Int.hash i.id
  let hash_fold_t st i = Int.hash_fold_t st i.id
  let sexp_of_t i = sexp_of_t i.value
  let t_of_sexp s = intern (t_of_sexp s)
  let count () = Hashtbl.length table
end
