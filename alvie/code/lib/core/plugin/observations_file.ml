(*
  observations.yaml: the schema of what the backend observes. Each step of the system returns observations; an
  observation has a kind (its tag) and typed fields.

    format: 1
    types:
      mode: { enum: [UM, PM] }
      payload: { fields: { k: int, gie: bool, reg_val: word, mode: mode } }
    kinds:
      Reset: {}
      JmpIn: payload                                 # the fields of the record type payload
      Time_Handle: { fields: { time: payload, handle: payload } }

  Field types: int, bool, word (an integer from 0 to 65535), { int: [lowest, highest] }, or a declared type (an
  enumeration or a record). An observation is the value Node (kind, fields); a field of an enumeration is a Sym, a
  field of a record type a Node (type, fields).
*)

open Core
open Shape

type ftype = F_int of int * int | F_bool | F_enum of string | F_record of string [@@deriving sexp, equal]

type tydecl = Enum of string list | Record of (string * ftype) list [@@deriving sexp, equal]

type kind = { name : string; fields : (string * ftype) list; doc : string option; pos : Diag.pos }

type t = { types : (string * tydecl) list; kinds : kind list }

type fdecl = Builtin of ftype | Named of string

let ftype : fdecl Shape.t =
  let named = Shape.map_value (Shape.string ()) ~f:(function
      | "int" -> Builtin (F_int (Int.min_value, Int.max_value))
      | "bool" -> Builtin F_bool
      | "word" -> Builtin (F_int (0, 0xFFFF))
      | n -> Named n) in
  let range =
    let open Obj in
    Shape.map_result (obj (let+ r = req "int" (Shape.list (Shape.int ())) in r)) ~f:(fun n -> function
        | [ lo; hi ] when lo <= hi -> Ok (Builtin (F_int (lo, hi)))
        | _ -> fail n "expected { int: [lowest, highest] }") in
  by_kind ~what:"a field type" ~scalar:named ~map:range () ~doc:"int, bool, word, { int: [lowest, highest] }, or a declared type"

let fields_shape = Shape.map ftype

type tydecl_raw = R_enum of string list | R_record of (string * Diag.pos * fdecl) list

let tydecl : tydecl_raw Shape.t =
  let open Obj in
  let fields =
    let+ e = opt "enum" (Shape.list (Shape.string ())) ~doc:"The constants of an enumeration"
    and+ r = opt "fields" fields_shape ~doc:"The fields of a record type" in
    (e, r) in
  Shape.map_result (obj ~what:"a type declaration" fields) ~f:(fun n -> function
      | Some e, None -> Ok (R_enum e)
      | None, Some r -> Ok (R_record r)
      | _ -> fail n "a type is either { enum: [...] } or { fields: {...} }")

type kind_raw = K_like of string | K_fields of (string * Diag.pos * fdecl) list * string option

let kind_decl : kind_raw Shape.t =
  let like = Shape.map_value (Shape.string ()) ~f:(fun n -> K_like n) in
  let explicit =
    let open Obj in
    obj ~what:"a kind declaration"
      (let+ fields = dflt "fields" [] fields_shape ~doc:"The fields of observations of this kind"
       and+ doc = opt "doc" (Shape.string ()) in
       K_fields (fields, doc)) in
  by_kind ~what:"a kind declaration ({}, { fields: {...} } or the name of a record type)" ~scalar:like ~map:explicit ()

let shape =
  let open Obj in
  obj ~what:"an observations file"
    (let+ _ = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
     and+ types = dflt "types" [] (Shape.map tydecl) ~doc:"Enumerations and record types used by the fields"
     and+ kinds = req "kinds" (Shape.map kind_decl) ~doc:"The kinds of observations, by name" in
     (types, kinds))

let build ~types ~kinds : (t, Diag.t list) Result.t =
  let errors = ref [] in
  let err ?hint pos fmt = Printf.ksprintf (fun m -> errors := Diag.error ~pos ?hint m :: !errors) fmt in
  let type_names = List.map types ~f:(fun (n, _, _) -> n) in
  let resolve pos = function
    | Builtin f -> f
    | Named n ->
      (match List.find types ~f:(fun (m, _, _) -> String.equal m n) with
       | Some (_, _, R_enum _) -> F_enum n
       | Some (_, _, R_record _) -> F_record n
       | None ->
         err pos "unknown field type %s" n ?hint:(Diag.hint_did_you_mean n (type_names @ [ "int"; "bool"; "word" ]));
         F_bool) in
  let resolve_fields fs = List.map fs ~f:(fun (name, pos, f) -> (name, resolve pos f)) in
  let types' = List.map types ~f:(fun (name, pos, d) ->
      if List.count type_names ~f:(String.equal name) > 1 then err pos "the type %s is declared twice" name;
      match d with
      | R_enum cs ->
        if List.is_empty cs then err pos "the enumeration %s has no constants" name;
        (name, Enum cs)
      | R_record fs -> (name, Record (resolve_fields fs))) in
  (* Record types cannot contain themselves *)
  List.iter types' ~f:(fun (name, _) ->
      let rec contains visited n =
        match List.Assoc.find types' ~equal:String.equal n with
        | Some (Record fs) ->
          List.exists fs ~f:(fun (_, f) -> match f with
              | F_record m -> String.equal m name || (not (List.mem visited m ~equal:String.equal) && contains (m :: visited) m)
              | _ -> false)
        | _ -> false in
      if contains [] name then
        err (List.find_map_exn types ~f:(fun (n, p, _) -> if String.equal n name then Some p else None)) "the record type %s contains itself" name);
  let kinds' = List.map kinds ~f:(fun (name, pos, k) ->
      match k with
      | K_fields (fs, doc) -> { name; fields = resolve_fields fs; doc; pos }
      | K_like n ->
        (match List.Assoc.find types' ~equal:String.equal n with
         | Some (Record fs) -> { name; fields = fs; doc = None; pos }
         | Some (Enum _) -> err pos "%s is an enumeration: a kind takes the fields of a record type" n; { name; fields = []; doc = None; pos }
         | None -> err pos "unknown record type %s" n ?hint:(Diag.hint_did_you_mean n type_names); { name; fields = []; doc = None; pos })) in
  match List.rev !errors with
  | [] -> Ok { types = types'; kinds = kinds' }
  | es -> Error es

let load ~file = Result.bind (Shape.parse_file shape file) ~f:(fun (types, kinds) -> build ~types ~kinds)
let load_string ~file text = Result.bind (Shape.parse_string shape ~file text) ~f:(fun (types, kinds) -> build ~types ~kinds)

let find_kind t name = List.find t.kinds ~f:(fun k -> String.equal k.name name)
let kind_names t = List.map t.kinds ~f:(fun k -> k.name)

(* The type of a dotted path of fields in a kind (e.g. ["time"; "mode"]) *)
let rec path_type t (fields : (string * ftype) list) (path : string list) : ftype option =
  match path with
  | [] -> None
  | [ f ] -> List.Assoc.find fields ~equal:String.equal f
  | f :: rest ->
    (match List.Assoc.find fields ~equal:String.equal f with
     | Some (F_record r) ->
       (match List.Assoc.find t.types ~equal:String.equal r with Some (Record fs) -> path_type t fs rest | _ -> None)
     | _ -> None)

(* The value that a scalar of a rule (when: { mode: PM }) stands for, in a field of type f *)
let scalar_value t (f : ftype) (s : string) : (Value.t, string) Result.t =
  match f with
  | F_bool -> (match s with "true" -> Ok (Value.Bool true) | "false" -> Ok (Value.Bool false) | _ -> Error "expected true or false")
  | F_int (lo, hi) ->
    (match Option.try_with (fun () -> Int.of_string s) with
     | Some i when i >= lo && i <= hi -> Ok (Value.Int i)
     | _ -> Error (sprintf "expected an integer from %d to %d" lo hi))
  | F_enum e ->
    (match List.Assoc.find t.types ~equal:String.equal e with
     | Some (Enum cs) when List.mem cs s ~equal:String.equal -> Ok (Value.Sym s)
     | Some (Enum cs) -> Error (sprintf "expected one of %s" (Diag.enumerate cs))
     | _ -> Error "unknown enumeration")
  | F_record r -> Error (sprintf "%s is a record: compare one of its fields" r)

let rec check_field t (f : ftype) (v : Value.t) : (unit, string) Result.t =
  match f, v with
  | F_bool, Bool _ -> Ok ()
  | F_int (lo, hi), Int i -> if i >= lo && i <= hi then Ok () else Error (sprintf "%d is out of range" i)
  | F_enum e, Sym s ->
    (match List.Assoc.find t.types ~equal:String.equal e with
     | Some (Enum cs) when List.mem cs s ~equal:String.equal -> Ok ()
     | _ -> Error (sprintf "%s is not a constant of %s" s e))
  | F_record r, Node (tag, fs) when String.equal tag r ->
    (match List.Assoc.find t.types ~equal:String.equal r with
     | Some (Record decl) -> check_fields t decl fs
     | _ -> Error "unknown record")
  | _ -> Error (sprintf "%s does not have the declared type" (Value.to_string v))

and check_fields t decl fs =
  if not (List.equal String.equal (List.map decl ~f:fst) (List.map fs ~f:fst)) then Error "the fields differ from the declaration"
  else Result.all_unit (List.map2_exn decl fs ~f:(fun (_, f) (_, v) -> check_field t f v))

(* Checks that v is an observation of this schema *)
let check t (v : Value.t) : (unit, string) Result.t =
  match v with
  | Node (kind, fs) ->
    (match find_kind t kind with
     | None -> Error (sprintf "%s is not a kind of observation" kind)
     | Some k -> check_fields t k.fields fs)
  | _ -> Error "an observation is a node"

let json_schema t : Yojson.Safe.t =
  let rec field : ftype -> Yojson.Safe.t = function
    | F_bool -> `Assoc [ ("type", `String "boolean") ]
    | F_int (lo, hi) ->
      `Assoc ([ ("type", `String "integer") ]
              @ (if lo = Int.min_value then [] else [ ("minimum", `Int lo) ])
              @ (if hi = Int.max_value then [] else [ ("maximum", `Int hi) ]))
    | F_enum e -> `Assoc [ ("$ref", `String ("#/$defs/" ^ e)) ]
    | F_record r -> `Assoc [ ("$ref", `String ("#/$defs/" ^ r)) ]
  and node tag fs : Yojson.Safe.t =
    let inner = `Assoc [
        ("type", `String "object");
        ("properties", `Assoc (List.map fs ~f:(fun (n, f) -> (n, field f))));
        ("required", `List (List.map fs ~f:(fun (n, _) -> `String n)));
        ("additionalProperties", `Bool false) ] in
    `Assoc [ ("type", `String "object"); ("properties", `Assoc [ (tag, inner) ]); ("required", `List [ `String tag ]); ("additionalProperties", `Bool false) ] in
  let defs = List.map t.types ~f:(fun (n, d) ->
      match d with
      | Enum cs -> (n, `Assoc [ ("enum", `List (List.map cs ~f:(fun c -> `String c))) ])
      | Record fs -> (n, node n fs)) in
  `Assoc [
    ("$schema", `String "https://json-schema.org/draft/2020-12/schema");
    ("title", `String "Observations");
    ("oneOf", `List (List.map t.kinds ~f:(fun k -> node k.name k.fields)));
    ("$defs", `Assoc defs) ]
