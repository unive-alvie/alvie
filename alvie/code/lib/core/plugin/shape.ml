(*
  Shapes: the format of a plugin file, defined once, as a decoder from YAML trees with precise errors and as the
  JSON Schema that editors use to check the same file as it is typed. Generating the schemas from the decoders keeps
  the two from drifting apart.

  Decoding collects every error it can (e.g. all the unknown fields of a mapping) instead of stopping at the first.
*)

open Core

type 'a result = ('a, Diag.t list) Result.t

type 'a t = {
  decode : Yaml_tree.node -> 'a result;
  schema : Yojson.Safe.t;
}

let decode t n = t.decode n
let schema t = t.schema

let fail (n : Yaml_tree.node) ?hint fmt = Printf.ksprintf (fun m -> Error [ Diag.error ~pos:n.pos ?hint m ]) fmt

let with_doc doc (schema : Yojson.Safe.t) : Yojson.Safe.t =
  match doc, schema with
  | None, _ -> schema
  | Some d, `Assoc members -> `Assoc (members @ [ ("description", `String d) ])
  | Some d, s -> `Assoc [ ("allOf", `List [ s ]); ("description", `String d) ]

(* Collects the errors of all results, or returns all the values *)
let all (rs : 'a result list) : 'a list result =
  match List.concat_map rs ~f:(function Error es -> es | Ok _ -> []) with
  | [] -> Ok (List.map rs ~f:(function Ok v -> v | Error _ -> assert false))
  | es -> Error es

let both (a : 'a result) (b : 'b result) : ('a * 'b) result =
  match a, b with
  | Ok x, Ok y -> Ok (x, y)
  | Error e, Error e' -> Error (e @ e')
  | Error e, Ok _ | Ok _, Error e -> Error e

(* The words that YAML 1.1 reads as booleans and YAML 1.2 as strings *)
let yaml11_booleans = [ "y"; "yes"; "n"; "no"; "on"; "off" ]

let scalar (n : Yaml_tree.node) ~what : string result =
  match n.desc with
  | Scalar { value; quoted = false } when List.mem yaml11_booleans (String.lowercase value) ~equal:String.equal ->
    fail n "%S is ambiguous in YAML: YAML 1.1 reads it as a boolean, YAML 1.2 as a string" value
      ~hint:(sprintf "quote it (\"%s\") if you mean the word, or write true or false for a boolean" value)
  | Scalar { value; _ } -> Ok value
  | _ -> fail n "expected %s, found %s" what (Yaml_tree.describe n)

let string ?doc () =
  { decode = (fun n -> scalar n ~what:"a string"); schema = with_doc doc (`Assoc [ ("type", `String "string") ]) }

let int ?doc ?min ?max () =
  let range = List.filter_opt [ Option.map min ~f:(fun m -> ("minimum", `Int m)); Option.map max ~f:(fun m -> ("maximum", `Int m)) ] in
  { decode = (fun n ->
        match n.desc with
        | Scalar { value; quoted = false } ->
          (match Option.try_with (fun () -> Int.of_string value) with
           | None -> fail n "expected an integer, found %S" value
           | Some i ->
             (match min, max with
              | Some lo, _ when i < lo -> fail n "%d is too small: the minimum is %d" i lo
              | _, Some hi when i > hi -> fail n "%d is too large: the maximum is %d" i hi
              | _ -> Ok i))
        | _ -> fail n "expected an integer, found %s" (Yaml_tree.describe n));
    schema = with_doc doc (`Assoc ([ ("type", `String "integer") ] @ range)) }

let bool ?doc () =
  { decode = (fun n ->
        match n.desc with
        | Scalar { value = "true"; quoted = false } -> Ok true
        | Scalar { value = "false"; quoted = false } -> Ok false
        | _ -> fail n "expected true or false, found %s" (Yaml_tree.describe n));
    schema = with_doc doc (`Assoc [ ("type", `String "boolean") ]) }

let enum ?doc (cases : (string * 'a) list) =
  let names = List.map cases ~f:fst in
  { decode = (fun n ->
        Result.bind (scalar n ~what:(sprintf "one of %s" (Diag.enumerate names))) ~f:(fun s ->
            match List.Assoc.find cases ~equal:String.equal s with
            | Some v -> Ok v
            | None ->
              let hint = match Diag.hint_did_you_mean s names with Some h -> h | None -> "expected " ^ Diag.enumerate names in
              fail n ~hint "%S is not one of %s" s (Diag.enumerate names)));
    schema = with_doc doc (`Assoc [ ("enum", `List (List.map names ~f:(fun s -> `String s))) ]) }

let list ?doc (t : 'a t) =
  { decode = (fun n ->
        match n.desc with
        | Seq items -> all (List.map items ~f:t.decode)
        | _ -> fail n "expected a list, found %s" (Yaml_tree.describe n));
    schema = with_doc doc (`Assoc [ ("type", `String "array"); ("items", t.schema) ]) }

(* Either one item or a list of them: match: Reset, or match: [Illegal, Unsupported] *)
let one_or_list ?doc (t : 'a t) =
  { decode = (fun n -> match n.desc with Seq items -> all (List.map items ~f:t.decode) | _ -> Result.map (t.decode n) ~f:List.return);
    schema = with_doc doc (`Assoc [ ("anyOf", `List [ t.schema; `Assoc [ ("type", `String "array"); ("items", t.schema) ] ]) ]) }

(* A mapping from names to items, in the order of the file; each item comes with the position of its key *)
let map ?doc (t : 'a t) =
  { decode = (fun n ->
        match n.desc with
        | Map members ->
          all (List.map members ~f:(fun (k, v) ->
              match scalar k ~what:"a name" with
              | Error e -> Error e
              | Ok key -> Result.map (t.decode v) ~f:(fun x -> (key, k.pos, x))))
        | _ -> fail n "expected a mapping, found %s" (Yaml_tree.describe n));
    schema = with_doc doc (`Assoc [ ("type", `String "object"); ("additionalProperties", t.schema) ]) }

let map_result (t : 'a t) ~(f : Yaml_tree.node -> 'a -> 'b result) = { t with decode = (fun n -> Result.bind (t.decode n) ~f:(f n)) }
let map_value (t : 'a t) ~(f : 'a -> 'b) = { t with decode = (fun n -> Result.map (t.decode n) ~f) }

let with_pos (t : 'a t) = { t with decode = (fun n -> Result.map (t.decode n) ~f:(fun x -> (x, n.pos))) }

let custom ~schema decode = { decode; schema }

(* Tries the shapes in order on the kind of node they accept (a scalar, a list or a mapping) *)
let by_kind ?doc ?scalar ?seq ?map:m ~what () =
  let schemas = List.filter_opt [ Option.map scalar ~f:schema; Option.map seq ~f:schema; Option.map m ~f:schema ] in
  { decode = (fun (n : Yaml_tree.node) ->
        let try_ = function Some t -> t.decode n | None -> fail n "expected %s, found %s" what (Yaml_tree.describe n) in
        match n.desc with Scalar _ -> try_ scalar | Seq _ -> try_ seq | Map _ -> try_ m);
    schema = with_doc doc (match schemas with [ s ] -> s | ss -> `Assoc [ ("anyOf", `List ss) ]) }

(* Mappings with known fields, decoded applicatively: let+ a = req "a" ... and+ b = opt "b" ... in { a; b } *)
module Obj = struct
  type field_info = { name : string; required : bool; fschema : Yojson.Safe.t }

  type 'a fields = {
    infos : field_info list;
    get : Yaml_tree.node -> (Yaml_tree.node * Yaml_tree.node) list -> 'a result;
  }

  let find members name =
    List.find_map members ~f:(fun ((k : Yaml_tree.node), v) ->
        match k.desc with Scalar { value; _ } when String.equal value name -> Some v | _ -> None)

  let req ?doc name (t : 'a t) =
    { infos = [ { name; required = true; fschema = with_doc doc t.schema } ];
      get = (fun m members ->
          match find members name with
          | Some v -> t.decode v
          | None -> fail m "the field %S is missing" name) }

  let opt ?doc name (t : 'a t) =
    { infos = [ { name; required = false; fschema = with_doc doc t.schema } ];
      get = (fun _ members -> match find members name with Some v -> Result.map (t.decode v) ~f:Option.some | None -> Ok None) }

  let dflt ?doc name default (t : 'a t) =
    { infos = [ { name; required = false; fschema = with_doc doc t.schema } ];
      get = (fun _ members -> match find members name with Some v -> t.decode v | None -> Ok default) }

  (* No field at all: always x *)
  let pure x = { infos = []; get = (fun _ _ -> Ok x) }

  let map f a = { a with get = (fun m ms -> Result.map (a.get m ms) ~f) }
  let both a b = { infos = a.infos @ b.infos; get = (fun m ms -> both (a.get m ms) (b.get m ms)) }
  let ( let+ ) a f = map f a
  let ( and+ ) = both

  (*
    The mapping of these fields. Unknown fields are errors, with a suggestion when they look like a typo of a known
    one: a misspelt optional field would otherwise be silently ignored.
  *)
  let obj ?doc ?(what = "a mapping") (fields : 'a fields) =
    let names = List.map fields.infos ~f:(fun i -> i.name) in
    { decode = (fun n ->
          match n.desc with
          | Map members ->
            let unknown = List.filter_map members ~f:(fun ((k : Yaml_tree.node), _) ->
                match scalar k ~what:"a field name" with
                | Error e -> Some (Error e)
                | Ok key when List.mem names key ~equal:String.equal -> None
                | Ok key ->
                  let hint = match Diag.hint_did_you_mean key names with
                    | Some h -> h
                    | None -> "the fields are " ^ Diag.enumerate ~conj:"and" names in
                  Some (fail k ~hint "unknown field %S" key)) in
            let unknown = List.concat_map unknown ~f:(function Error e -> e | Ok () -> []) in
            (match unknown, fields.get n members with
             | [], r -> r
             | es, Ok _ -> Error es
             | es, Error es' -> Error (es @ es'))
          | Scalar { value = ""; quoted = false } when List.for_all fields.infos ~f:(fun i -> not i.required) ->
            (* "kind:" with nothing after it: an empty mapping *)
            fields.get n []
          | _ -> fail n "expected %s, found %s" what (Yaml_tree.describe n));
      schema = with_doc doc (`Assoc [
          ("type", `String "object");
          ("properties", `Assoc (List.map fields.infos ~f:(fun i -> (i.name, i.fschema))));
          ("required", `List (List.filter_map fields.infos ~f:(fun i -> if i.required then Some (`String i.name) else None)));
          ("additionalProperties", `Bool false) ]) }
end

let parse_file (t : 'a t) file : 'a result =
  match Yaml_tree.parse_file file with
  | Error d -> Error [ d ]
  | Ok n -> t.decode n

let parse_string (t : 'a t) ~file text : 'a result =
  match Yaml_tree.parse ~file text with
  | Error d -> Error [ d ]
  | Ok n -> t.decode n

(* The JSON Schema document of a file format *)
let json_schema ~title ~id (t : 'a t) : Yojson.Safe.t =
  match t.schema with
  | `Assoc members ->
    `Assoc ([ ("$schema", `String "https://json-schema.org/draft/2020-12/schema"); ("$id", `String id); ("title", `String title) ] @ members)
  | s -> `Assoc [ ("$schema", `String "https://json-schema.org/draft/2020-12/schema"); ("$id", `String id); ("title", `String title); ("allOf", `List [ s ]) ]
