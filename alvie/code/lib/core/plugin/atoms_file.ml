(*
  atoms.yaml: the types of a plugin's atoms and their syntax (see Grammar for the meaning).

    format: 1
    types:
      reg: { syntax: ["r{i}", "R{i}"], args: { i: { int: [0, 14] } } }
      src:
        variants:
          reg: { syntax: "{r}", args: { r: reg } }
          imm: { syntax: "#{v}", args: { v: symbol } }
          secret: { syntax: "?", secret: { expand: "#{value}" } }
    atoms:
      attacker:
        rst: { syntax: rst }
        timer_enable: { syntax: "timer_enable {t}", args: { t: { int: [0, 65535] } } }
*)

open Core
open Shape

let builtin = [ "int"; "symbol" ]

let arg_type : Grammar.arg_type Shape.t =
  let named = Shape.map_value (Shape.string ()) ~f:(function
      | "int" -> Grammar.Int (0, Int.max_value)
      | "symbol" -> Grammar.Symbol
      | name -> Grammar.Ref name) in
  let int_range = Shape.map_result (Shape.list (Shape.int ())) ~f:(fun n -> function
      | [ lo; hi ] when lo <= hi -> Ok (lo, hi)
      | _ -> fail n "expected [lowest, highest]") in
  let structured =
    let open Obj in
    let fields =
      let+ range = opt "int" int_range ~doc:"An integer from lowest to highest: [lowest, highest]"
      and+ elem = opt "list" (Shape.string ()) ~doc:"A list of values of this type (at least one)"
      and+ exclude = dflt "exclude" [] (Shape.list (Shape.string ())) ~doc:"Variants of the element type not allowed in the list"
      and+ sep = dflt "sep" ";" (Shape.string ()) ~doc:"The separator of the elements (default ;)" in
      (range, elem, exclude, sep) in
    Shape.map_result (obj ~what:"an argument type" fields) ~f:(fun n -> function
        | Some (lo, hi), None, [], _ -> Ok (Grammar.Int (lo, hi))
        | None, Some elem, exclude, sep -> Ok (Grammar.List { elem; exclude; sep })
        | _ -> fail n "an argument type is either { int: [lowest, highest] } or { list: <type>, exclude: [...], sep: ... }") in
  by_kind ~what:"an argument type" ~scalar:named ~map:structured ()
    ~doc:"int, symbol, a declared type, { int: [lowest, highest] } or { list: <type>, exclude: [...], sep: ... }"

let template : (string * Grammar.template) Shape.t =
  Shape.map_result (Shape.string ()) ~f:(fun n s ->
      match Grammar.parse_template s with Ok t -> Ok (s, t) | Error e -> fail n "%s" e)

type alt_decl = {
  syntax : (string * Grammar.template) list;
  args : (string * Diag.pos * Grammar.arg_type) list;
  secret : (string * Grammar.template) option;
  doc : string option;
}

let secret_decl =
  let open Obj in
  obj (let+ expand = req "expand" template ~doc:"The text the secret becomes, with {value} for the value of the secret: e.g. #{value}" in expand)

let alt_decl : alt_decl Shape.t =
  let open Obj in
  obj ~what:"a syntax declaration"
    (let+ syntax = req "syntax" (one_or_list template) ~doc:"The syntax template, or a list of them (the first is used to print)"
     and+ args = dflt "args" [] (Shape.map arg_type) ~doc:"The arguments, by name, with their types"
     and+ secret = opt "secret" secret_decl ~doc:"Makes this variant the hole of the secret"
     and+ doc = opt "doc" (Shape.string ()) in
     { syntax; args; secret; doc })

type type_decl = Single of alt_decl | Variants of (string * Diag.pos * alt_decl) list

let type_decl : (type_decl * string option) Shape.t =
  let open Obj in
  let fields =
    let+ syntax = opt "syntax" (one_or_list template) ~doc:"The syntax of a type with a single form"
    and+ args = dflt "args" [] (Shape.map arg_type)
    and+ variants = opt "variants" (Shape.map alt_decl) ~doc:"The variants of the type, by name"
    and+ doc = opt "doc" (Shape.string ()) in
    (syntax, args, variants, doc) in
  Shape.map_result (obj ~what:"a type declaration" fields) ~f:(fun n -> function
      | Some syntax, args, None, doc -> Ok (Single { syntax; args; secret = None; doc }, doc)
      | None, [], Some variants, doc -> Ok (Variants variants, doc)
      | _ -> fail n "a type has either a syntax (and args) or variants")

let shape =
  let open Obj in
  obj ~what:"an atoms file"
    (let+ format = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
     and+ types = dflt "types" [] (Shape.map type_decl) ~doc:"The types of the arguments of atoms"
     and+ atoms = req "atoms" (Shape.map (Shape.map alt_decl)) ~doc:"The atom classes (e.g. attacker, victim), each with its atoms" in
     ignore format;
     (types, atoms))

(* Builds the grammar and checks it *)
let build ~(types : (string * Diag.pos * (type_decl * string option)) list) ~(atoms : (string * Diag.pos * (string * Diag.pos * alt_decl) list) list) : (Grammar.t, Diag.t list) Result.t =
  let errors = ref [] in
  let err ?hint pos fmt = Printf.ksprintf (fun m -> errors := Diag.error ~pos ?hint m :: !errors) fmt in
  let make_alt tag pos (d : alt_decl) : Grammar.alt =
    { tag; syntax = List.map d.syntax ~f:snd; args = List.map d.args ~f:(fun (n, _, t) -> (n, t)); secret = Option.map d.secret ~f:snd; doc = d.doc; pos } in
  let tys =
    List.map types ~f:(fun (name, pos, (decl, _)) ->
        match decl with
        | Single d -> { Grammar.name; alts = [ make_alt name pos d ]; single = true; is_class = false; tpos = pos }
        | Variants vs -> { Grammar.name; alts = List.map vs ~f:(fun (tag, p, d) -> make_alt tag p d); single = false; is_class = false; tpos = pos })
    @ List.map atoms ~f:(fun (name, pos, vs) ->
        { Grammar.name; alts = List.map vs ~f:(fun (tag, p, d) -> make_alt tag p d); single = false; is_class = true; tpos = pos }) in
  let g = { Grammar.types = tys } in
  let names = List.map tys ~f:(fun t -> t.name) in
  (* Names *)
  List.iter tys ~f:(fun t ->
      if List.mem builtin t.name ~equal:String.equal then err t.tpos "%s is a built-in type and cannot be declared" t.name;
      if List.count names ~f:(String.equal t.name) > 1 then err t.tpos "the type %s is declared twice (types and atoms share one set of names)" t.name;
      if List.is_empty t.alts then err t.tpos "%s has no variants" t.name);
  let check_ref pos name =
    if not (List.mem names name ~equal:String.equal) then
      err pos "unknown type %s" name ?hint:(Diag.hint_did_you_mean name (names @ builtin)) in
  List.iter tys ~f:(fun t ->
      List.iter t.alts ~f:(fun (a : Grammar.alt) ->
          let declared = List.map a.args ~f:fst in
          List.iter a.args ~f:(fun (_, ty) ->
              match ty with
              | Grammar.Ref r -> check_ref a.pos r
              | List { elem; exclude; _ } ->
                check_ref a.pos elem;
                (match Grammar.find_type g elem with
                 | Some et ->
                   List.iter exclude ~f:(fun x ->
                       if not (List.exists et.alts ~f:(fun ea -> String.equal ea.tag x)) then
                         err a.pos "%s, excluded from the list, is not a variant of %s" x elem)
                 | None -> ())
              | Int _ | Symbol -> ());
          (match a.secret with
           | Some expansion ->
             if not (List.is_empty a.args) then err a.pos "the secret variant %s cannot have arguments" a.tag;
             if not (List.equal String.equal (Grammar.template_args expansion) [ "value" ]) then
               err a.pos "the expansion of the secret must use {value} exactly once, as in #{value}"
           | None -> ());
          List.iter a.syntax ~f:(fun tpl ->
              let used = Grammar.template_args tpl in
              let shown = Grammar.template_to_string tpl in
              if Option.is_none a.secret then (
                List.iter used ~f:(fun u ->
                    if not (List.mem declared u ~equal:String.equal) then
                      err a.pos "the syntax %S of %s uses {%s}, which is not one of its arguments" shown a.tag u ?hint:(Diag.hint_did_you_mean u declared));
                List.iter declared ~f:(fun d ->
                    match List.count used ~f:(String.equal d) with
                    | 0 -> err a.pos "the syntax %S of %s does not show the argument {%s}" shown a.tag d
                    | 1 -> ()
                    | _ -> err a.pos "the syntax %S of %s shows {%s} more than once" shown a.tag d))
              else if not (List.is_empty used) then err a.pos "the syntax of the secret variant %s cannot have arguments" a.tag)));
  (* Left recursion: a template that starts with an argument whose type can start, without consuming text, with
     the same type again would make the parser find nothing *)
  let first_types (t : Grammar.ty) =
    List.concat_map t.alts ~f:(fun a ->
        List.filter_map a.syntax ~f:(fun tpl ->
            match List.find tpl ~f:(function Grammar.Space -> false | _ -> true) with
            | Some (Grammar.Arg n) ->
              (match List.Assoc.find a.args ~equal:String.equal n with
               | Some (Grammar.Ref r) -> Some r
               | Some (Grammar.List { elem; _ }) -> Some elem
               | _ -> None)
            | _ -> None)) in
  List.iter tys ~f:(fun t ->
      let rec reaches visited name =
        if List.mem visited name ~equal:String.equal then false
        else match Grammar.find_type g name with
          | None -> false
          | Some u -> List.exists (first_types u) ~f:(fun n -> String.equal n t.name || reaches (name :: visited) n) in
      if reaches [] t.name then err t.tpos "%s is left-recursive: one of its syntaxes starts with an argument that can start with %s again" t.name t.name);
  match List.rev !errors with [] -> Ok g | es -> Error es

let load ~file : (Grammar.t, Diag.t list) Result.t =
  Result.bind (Shape.parse_file shape file) ~f:(fun (types, atoms) -> build ~types ~atoms)

let load_string ~file text = Result.bind (Shape.parse_string shape ~file text) ~f:(fun (types, atoms) -> build ~types ~atoms)
