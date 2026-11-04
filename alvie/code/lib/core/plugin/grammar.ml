(*
  The atom grammar of a plugin (atoms.yaml): typed atoms with syntax templates, the parser and printer that Core
  derives from them, and the checks of values against their types.

  A type is either a single form (syntax + args, its values are Node (type name, args)) or a set of variants (each
  with its own syntax and args, values Node (variant name, args)). Atom classes (the "atoms:" of atoms.yaml, e.g.
  attacker and enclave) are variant types whose variants are the atoms; sections name the class of their atoms.

  Argument types: int (non-negative), { int: [lo, hi] }, symbol (a name made of letters, digits, _ and -), the name
  of a declared type, or { list: <type>, exclude: [<variants>], sep: <separator> } (at least one element).

  Syntax templates are format strings: "mov {src}, {dst}". Each {arg} appears once. Spaces in a template are printed
  as one space; when parsing, whitespace is optional between any two parts of a template. A type may give several
  templates; the first is the one used to print. A variant marked secret is a hole for the secret: it parses to
  Hole "secret" and expands to its "expand" template with {value} replaced by the value of the secret.

  Parsing finds every way a type can match at a position, and when two alternatives match the same text the first
  declared one wins (e.g. &r5 is a register before it is a symbol if the register variant comes first). Parsing is
  memoised on (type, position), so it takes polynomial time even with ambiguous templates.
*)

open Core

type arg_type =
  | Int of int * int
  | Symbol
  | Ref of string
  | List of { elem : string; exclude : string list; sep : string }
[@@deriving sexp, equal]

type token = Lit of string | Space | Arg of string [@@deriving sexp, equal]

type template = token list [@@deriving sexp, equal]

type alt = {
  tag : string;
  syntax : template list; (* at least one; the first is canonical *)
  args : (string * arg_type) list;
  secret : template option; (* the expansion of a secret hole, with the argument "value" *)
  doc : string option;
  pos : Diag.pos;
}

type ty = { name : string; alts : alt list; single : bool; is_class : bool; tpos : Diag.pos }

type t = { types : ty list }

let find_type g name = List.find g.types ~f:(fun t -> String.equal t.name name)
let classes g = List.filter g.types ~f:(fun t -> t.is_class)

(* Template strings *)

let is_word c = Char.is_alphanum c || Char.equal c '_' || Char.equal c '-'

let parse_template (s : string) : (template, string) result =
  let n = String.length s in
  let buf = Buffer.create 8 in
  let flush acc = if Buffer.length buf = 0 then acc else (let l = Buffer.contents buf in Buffer.clear buf; Lit l :: acc) in
  let rec go i acc =
    if i >= n then Ok (List.rev (flush acc))
    else match s.[i] with
      | ' ' | '\t' ->
        let acc = flush acc in
        let acc = match acc with Space :: _ | [] -> acc | _ -> Space :: acc in
        go (i + 1) acc
      | '{' ->
        (match String.index_from s i '}' with
         | None -> Error (sprintf "unclosed { in %S" s)
         | Some j ->
           let name = String.sub s ~pos:(i + 1) ~len:(j - i - 1) in
           if String.is_empty name || not (String.for_all name ~f:is_word) then Error (sprintf "{%s} in %S is not an argument name" name s)
           else go (j + 1) (Arg name :: flush acc))
      | '}' -> Error (sprintf "unmatched } in %S" s)
      | c -> Buffer.add_char buf c; go (i + 1) acc in
  match go 0 [] with
  | Ok [] -> Error "an empty syntax template"
  | Ok t -> Ok (List.rev (match List.rev t with Space :: rest -> rest | t' -> t'))
  | Error e -> Error e

let template_to_string (t : template) =
  String.concat (List.map t ~f:(function Lit l -> l | Space -> " " | Arg a -> "{" ^ a ^ "}"))

let template_args t = List.filter_map t ~f:(function Arg a -> Some a | _ -> None)

(* Values and types *)

let secret_name = "secret"

let rec check g (ty : arg_type) (v : Value.t) : (unit, string) result =
  match ty, v with
  | Int (lo, hi), Int i -> if i >= lo && i <= hi then Ok () else Error (sprintf "%d is out of range %d..%d" i lo hi)
  | Symbol, Sym s -> if (not (String.is_empty s)) && String.for_all s ~f:is_word then Ok () else Error (sprintf "%S is not a symbol" s)
  | List { elem; exclude; _ }, List vs ->
    if List.is_empty vs then Error "an empty list"
    else Result.all_unit (List.map vs ~f:(fun v ->
        match Value.tag v with
        | Some t when List.mem exclude t ~equal:String.equal -> Error (sprintf "%s is not allowed in this list" t)
        | _ -> check g (Ref elem) v))
  | Ref name, v ->
    (match find_type g name with
     | None -> Error (sprintf "unknown type %s" name)
     | Some t -> check_ty g t v)
  | _, v -> Error (sprintf "%s does not have type %s" (Value.to_string v) (Sexp.to_string (sexp_of_arg_type ty)))

and check_ty g (t : ty) (v : Value.t) =
  match v with
  | Hole _ when List.exists t.alts ~f:(fun a -> Option.is_some a.secret) -> Ok ()
  | Node (tag, fields) ->
    (match List.find t.alts ~f:(fun a -> String.equal a.tag tag) with
     | None -> Error (sprintf "%s is not a variant of %s" tag t.name)
     | Some a ->
       if not (List.equal String.equal (List.map fields ~f:fst) (List.map a.args ~f:fst)) then
         Error (sprintf "%s has the fields %s, not %s" tag (String.concat ~sep:", " (List.map a.args ~f:fst)) (String.concat ~sep:", " (List.map fields ~f:fst)))
       else Result.all_unit (List.map2_exn fields a.args ~f:(fun (_, v) (_, ty) -> check g ty v)))
  | v -> Error (sprintf "%s is not a value of %s" (Value.to_string v) t.name)

(* Printing, with the first template of each alternative *)

let rec print g (ty : arg_type) (v : Value.t) : string =
  match ty, v with
  | Int _, Int i -> Int.to_string i
  | Symbol, Sym s -> s
  | List { elem; sep; _ }, List vs -> String.concat ~sep:(sep ^ " ") (List.map vs ~f:(print g (Ref elem)))
  | Ref name, v ->
    (match find_type g name with
     | Some t -> print_ty g t v
     | None -> Value.to_string v)
  | _, v -> Value.to_string v

and print_ty g t v =
  let alt = match v with
    | Hole _ -> List.find t.alts ~f:(fun a -> Option.is_some a.secret)
    | Node (tag, _) -> List.find t.alts ~f:(fun a -> String.equal a.tag tag)
    | _ -> None in
  match alt with
  | None -> Value.to_string v
  | Some a ->
    let fields = match v with Node (_, fields) -> fields | _ -> [] in
    String.concat (List.map (List.hd_exn a.syntax) ~f:(function
        | Lit l -> l
        | Space -> " "
        | Arg name ->
          (match List.Assoc.find fields ~equal:String.equal name, List.Assoc.find a.args ~equal:String.equal name with
           | Some v, Some ty -> print g ty v
           | _ -> "{" ^ name ^ "}")))

let print_atom g ~cls v = match find_type g cls with Some t -> print_ty g t v | None -> Value.to_string v

(* Parsing *)

module Input = struct
  type t = {
    text : string;
    file : string;
    (* the position of the furthest failure, and what was expected there *)
    mutable furthest : int;
    mutable expected : string list;
    mutable problems : string list; (* e.g. an integer out of range, at furthest *)
  }

  let make ~file text = { text; file; furthest = -1; expected = []; problems = [] }

  let length i = String.length i.text

  let note i pos what =
    if pos > i.furthest then (i.furthest <- pos; i.expected <- [ what ]; i.problems <- [])
    else if pos = i.furthest && not (List.mem i.expected what ~equal:String.equal) then i.expected <- what :: i.expected

  let problem i pos what =
    if pos > i.furthest then (i.furthest <- pos; i.expected <- []; i.problems <- [ what ])
    else if pos = i.furthest && not (List.mem i.problems what ~equal:String.equal) then i.problems <- what :: i.problems

  let rec skip_ws i pos = if pos < length i && Char.is_whitespace i.text.[pos] then skip_ws i (pos + 1) else pos

  let pos_of i (offset : int) : Diag.pos =
    let line = ref 1 and col = ref 1 in
    for k = 0 to Int.min offset (length i) - 1 do
      if Char.equal i.text.[k] '\n' then (incr line; col := 1) else incr col
    done;
    { Diag.file = i.file; line = !line; col = !col }

  let found i pos =
    let pos = skip_ws i pos in
    if pos >= length i then "the end of the text"
    else
      let stop = ref pos in
      while !stop < length i && !stop - pos < 20 && not (Char.is_whitespace i.text.[!stop]) do incr stop done;
      sprintf "%S" (String.sub i.text ~pos ~len:(!stop - pos))

  (* The error at the furthest position any alternative reached *)
  let error i =
    let pos = Int.max 0 i.furthest in
    let message = match i.problems, List.rev i.expected with
      | p :: _, _ -> p
      | [], [] -> "cannot parse this"
      | [], expected -> sprintf "expected %s, found %s" (Diag.enumerate (List.dedup_and_sort expected ~compare:String.compare)) (found i pos) in
    Diag.error ~pos:(pos_of i (skip_ws i pos)) message
end

(*
  Every way type ty matches at pos, as (end position, value): one value per end position, the one of the first
  alternative in the declaration order. Leading whitespace is skipped.
*)
type memo = (string * int, (int * Value.t) list) Hashtbl.t

let make_memo () : memo = Hashtbl.Poly.create ()

let dedup_ends results =
  let seen = Hash_set.create (module Int) in
  List.filter results ~f:(fun (e, _) -> if Hash_set.mem seen e then false else (Hash_set.add seen e; true))

let literal (inp : Input.t) pos l =
  let pos = Input.skip_ws inp pos in
  let n = String.length l in
  if pos + n <= Input.length inp && String.equal (String.sub inp.text ~pos ~len:n) l then Some (pos + n)
  else (Input.note inp pos (sprintf "%S" l); None)

let rec parse_arg g memo (inp : Input.t) (ty : arg_type) pos : (int * Value.t) list =
  match ty with
  | Int (lo, hi) ->
    let start = Input.skip_ws inp pos in
    let stop = ref start in
    while !stop < Input.length inp && Char.is_digit inp.text.[!stop] do incr stop done;
    if !stop = start then (Input.note inp start "an integer"; [])
    else
      (match Option.try_with (fun () -> Int.of_string (String.sub inp.text ~pos:start ~len:(!stop - start))) with
       | Some i when i >= lo && i <= hi -> [ (!stop, Value.Int i) ]
       | _ ->
         Input.problem inp start (sprintf "%s is out of range: expected an integer from %d to %d" (String.sub inp.text ~pos:start ~len:(!stop - start)) lo hi);
         [])
  | Symbol ->
    let start = Input.skip_ws inp pos in
    let stop = ref start in
    while !stop < Input.length inp && is_word inp.text.[!stop] do incr stop done;
    if !stop = start then (Input.note inp start "a name"; [])
    else [ (!stop, Value.Sym (String.sub inp.text ~pos:start ~len:(!stop - start))) ]
  | Ref name -> parse_type g memo inp ~exclude:[] name pos
  | List { elem; exclude; sep } ->
    (* elem (sep elem)*: all the end positions, the longest first *)
    let rec more pos acc_rev : (int * Value.t) list =
      let firsts = parse_type g memo inp ~exclude elem pos in
      List.concat_map firsts ~f:(fun (e, v) ->
          let acc_rev = v :: acc_rev in
          let here = (e, Value.List (List.rev acc_rev)) in
          let after = match literal inp e sep with Some e' -> more e' acc_rev | None -> [] in
          after @ [ here ]) in
    dedup_ends (more pos [])

and parse_type g memo (inp : Input.t) ~exclude name pos : (int * Value.t) list =
  let key = (name ^ "\000" ^ String.concat ~sep:"," exclude, pos) in
  match Hashtbl.find memo key with
  | Some r -> r
  | None ->
    Hashtbl.set memo ~key ~data:[]; (* a left-recursive template finds nothing instead of looping *)
    let results = match find_type g name with
      | None -> []
      | Some t ->
        List.concat_map t.alts ~f:(fun a ->
            if List.mem exclude a.tag ~equal:String.equal then []
            else List.concat_map a.syntax ~f:(fun template -> parse_alt g memo inp a template pos)) in
    let results = dedup_ends results in
    Hashtbl.set memo ~key ~data:results;
    results

and parse_alt g memo inp (a : alt) (template : template) pos : (int * Value.t) list =
  let rec go tokens pos (fields : (string * Value.t) list) : (int * (string * Value.t) list) list =
    match tokens with
    | [] -> [ (pos, fields) ]
    | Space :: rest -> go rest pos fields
    | Lit l :: rest -> (match literal inp pos l with Some e -> go rest e fields | None -> [])
    | Arg name :: rest ->
      (match List.Assoc.find a.args ~equal:String.equal name with
       | None -> []
       | Some ty -> List.concat_map (parse_arg g memo inp ty pos) ~f:(fun (e, v) -> go rest e ((name, v) :: fields))) in
  List.map (go template pos []) ~f:(fun (e, fields) ->
      if Option.is_some a.secret then (e, Value.Hole secret_name)
      else
        (* in the order of the declaration, not of the template *)
        let fields = List.map a.args ~f:(fun (name, _) -> (name, List.Assoc.find_exn fields ~equal:String.equal name)) in
        (e, Value.Node (a.tag, fields)))

(* Parses the whole of text as a value of type name *)
let parse_value g ~file ~ty text : (Value.t, Diag.t) result =
  let inp = Input.make ~file text in
  let memo = make_memo () in
  let results = parse_type g memo inp ~exclude:[] ty 0 in
  let total = Input.length inp in
  match List.find results ~f:(fun (e, _) -> Input.skip_ws inp e = total) with
  | Some (_, v) -> Ok v
  | None ->
    (match results with
     | (e, _) :: _ -> Input.note inp (Input.skip_ws inp e) "the end of the text"
     | [] -> ());
    Error (Input.error inp)

(* Replaces the secret holes in v (of type ty) by the expansion of the secret's value *)
let rec expand_secret g ~(ty : arg_type) ~value (v : Value.t) : (Value.t, string) result =
  let open Result.Let_syntax in
  match ty, v with
  | Ref name, Hole _ ->
    (match find_type g name with
     | None -> Error (sprintf "unknown type %s" name)
     | Some t ->
       (match List.find_map t.alts ~f:(fun a -> a.secret) with
        | None -> Error (sprintf "%s has no secret variant" name)
        | Some expansion ->
          let text = String.concat (List.map expansion ~f:(function Lit l -> l | Space -> " " | Arg _ -> value)) in
          Result.map_error (parse_value g ~file:"<secret>" ~ty:name text) ~f:(fun d ->
              sprintf "the secret %S does not expand to a value of %s: %s" value name d.message)))
  | Ref name, Node (tag, fields) ->
    (match Option.bind (find_type g name) ~f:(fun t -> List.find t.alts ~f:(fun a -> String.equal a.tag tag)) with
     | None -> Ok v
     | Some a ->
       let%map fields = Result.all (List.map fields ~f:(fun (f, fv) ->
           match List.Assoc.find a.args ~equal:String.equal f with
           | Some fty -> let%map fv = expand_secret g ~ty:fty ~value fv in (f, fv)
           | None -> Ok (f, fv))) in
       Value.Node (tag, fields))
  | List { elem; _ }, List vs ->
    let%map vs = Result.all (List.map vs ~f:(expand_secret g ~ty:(Ref elem) ~value)) in
    Value.List vs
  | _ -> Ok v

(* JSON Schema of the values of each type, for the external plugin protocol *)
let json_schema g : Yojson.Safe.t =
  let rec arg : arg_type -> Yojson.Safe.t = function
    | Int (lo, hi) -> `Assoc [ ("type", `String "integer"); ("minimum", `Int lo); ("maximum", `Int hi) ]
    | Symbol -> `Assoc [ ("type", `String "string"); ("pattern", `String "^[A-Za-z0-9_-]+$") ]
    | Ref name -> `Assoc [ ("$ref", `String ("#/$defs/" ^ name)) ]
    | List { elem; exclude = _; sep = _ } -> `Assoc [ ("type", `String "array"); ("minItems", `Int 1); ("items", arg (Ref elem)) ] in
  let alt (a : alt) : Yojson.Safe.t =
    if Option.is_some a.secret then
      `Assoc [ ("type", `String "object"); ("properties", `Assoc [ ("?", `Assoc [ ("const", `String secret_name) ]) ]); ("required", `List [ `String "?" ]); ("additionalProperties", `Bool false) ]
    else
      let fields = `Assoc [
          ("type", `String "object");
          ("properties", `Assoc (List.map a.args ~f:(fun (n, ty) -> (n, arg ty))));
          ("required", `List (List.map a.args ~f:(fun (n, _) -> `String n)));
          ("additionalProperties", `Bool false) ] in
      `Assoc ([ ("type", `String "object"); ("properties", `Assoc [ (a.tag, fields) ]); ("required", `List [ `String a.tag ]); ("additionalProperties", `Bool false) ]
              @ (match a.doc with Some d -> [ ("description", `String d) ] | None -> [])) in
  `Assoc [
    ("$schema", `String "https://json-schema.org/draft/2020-12/schema");
    ("title", `String "Atom values");
    ("$defs", `Assoc (List.map g.types ~f:(fun t -> (t.name, `Assoc [ ("oneOf", `List (List.map t.alts ~f:alt)) ])))) ]
