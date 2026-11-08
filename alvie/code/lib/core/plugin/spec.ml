(*
  Specs: the language in which users describe the tests to learn, one body per section of the plugin.

    enclave { cmp ?, r4; (ifz (nop) (dint) | eps); jmp #enc_e };
    prepare { (timer_enable 1 | timer_enable 2); create <enc_s, enc_e, data_s, data_e>; jin enc_s };

  A body is a regular expression over the atoms of the section's class:

    body   ::= action | action "|" body          (choice)
    action ::= "eps" | factor | factor ";" action (sequence; eps is the empty sequence)
    factor ::= primary | primary "*"            (any number of repetitions)
    primary ::= atom | "(" body ")"

  The atoms are parsed with the plugin's grammar (Grammar); whitespace separates nothing and is allowed anywhere.
  A comment runs from // to the end of the line.
  A spec may be split across files (e.g. the victim and the attacker); every section that is not opaque must have
  exactly one body.

  Constraints span sections; they hold over a whole test:

    constraint { disjoint(writes(isr), reads(enclave)); subset(writes(isr), {r12, r13}) };

  disjoint(A, B): no value is in both sets; subset(A, {...}): every value of A is listed. A set is attr(section),
  the values of an attribute (atoms.yaml) of the atoms that the section runs, or a list of values of the attribute's
  type. threads { ... }; and step <unit>; are reserved for later versions: they are recognised, and rejected with
  an explanation.
*)

open Core

type body =
  | Empty
  | Epsilon
  | Atom of Value.t
  | Choice of body * body
  | Seq of body * body
  | Star of body
[@@deriving sexp, equal, compare, hash]

type section = { name : string; body : body; pos : Diag.pos }

type set = Attr of { attr : string; section : string } | Values of Value.t list [@@deriving sexp, equal]

type relation = Disjoint | Subset [@@deriving sexp, equal]

type constraint_ = { relation : relation; left : set; right : set; cpos : Diag.pos }

type t = { sections : section list; constraints : constraint_ list }

let rec atoms = function
  | Empty | Epsilon -> []
  | Atom a -> [ a ]
  | Choice (l, r) | Seq (l, r) -> atoms l @ atoms r
  | Star b -> atoms b

let rec has_secret = function
  | Empty | Epsilon -> false
  | Atom a -> Value.has_hole a
  | Choice (l, r) | Seq (l, r) -> has_secret l || has_secret r
  | Star b -> has_secret b

let rec map_atoms b ~f =
  match b with
  | Empty | Epsilon -> b
  | Atom a -> Atom (f a)
  | Choice (l, r) -> Choice (map_atoms l ~f, map_atoms r ~f)
  | Seq (l, r) -> Seq (map_atoms l ~f, map_atoms r ~f)
  | Star b -> Star (map_atoms b ~f)

let body_of t name = List.find_map t.sections ~f:(fun s -> if String.equal s.name name then Some s.body else None)

(* Printing, in the concrete syntax: parsing the result gives the same body *)
let rec print_body (g : Grammar.t) ~cls b =
  match b with
  | Empty -> "<empty>" (* the empty language has no syntax: it comes from derivatives, never from a spec *)
  | Epsilon -> "eps"
  | Atom a -> Grammar.print_atom g ~cls a
  | Choice (l, r) -> print_action g ~cls l ^ " | " ^ print_body g ~cls r
  | Seq _ | Star _ -> print_action g ~cls b

and print_action g ~cls b =
  match b with
  | Seq (l, r) -> print_factor g ~cls l ^ "; " ^ print_action g ~cls r
  | Epsilon -> "eps"
  | _ -> print_factor g ~cls b

and print_factor g ~cls b =
  match b with
  | Star p -> print_primary g ~cls p ^ "*"
  | _ -> print_primary g ~cls b

and print_primary g ~cls b =
  match b with
  | Atom a -> Grammar.print_atom g ~cls a
  | _ -> "(" ^ print_body g ~cls b ^ ")"

let print_set (p : Plugin.t) = function
  | Attr { attr; section } -> sprintf "%s(%s)" attr section
  | Values vs ->
    "{" ^ String.concat ~sep:", " (List.map vs ~f:(fun v ->
        match List.find_map p.grammar.attributes ~f:(fun (_, ty) -> match Grammar.check p.grammar (Grammar.Ref ty) v with Ok () -> Some ty | Error _ -> None) with
        | Some ty -> Grammar.print p.grammar (Grammar.Ref ty) v
        | None -> Value.to_string v)) ^ "}"

let print (p : Plugin.t) (t : t) =
  let constraints = match t.constraints with
    | [] -> []
    | cs -> [ "constraint { " ^ String.concat ~sep:"; " (List.map cs ~f:(fun c ->
        sprintf "%s(%s, %s)" (match c.relation with Disjoint -> "disjoint" | Subset -> "subset") (print_set p c.left) (print_set p c.right))) ^ " };" ] in
  String.concat ~sep:"\n" (constraints @ List.map t.sections ~f:(fun s ->
      let cls = Option.value (Plugin.atoms_of p s.name) ~default:"" in
      sprintf "%s { %s };" s.name (print_body p.grammar ~cls s.body)))

(* Parsing *)

exception Parse_error of Diag.t

let reserved = [ ("threads", "several threads of control"); ("step", "the granularity of a step") ]

(* Comments run from // to the end of the line; they become spaces, so that positions do not change *)
let blank_comments text =
  let b = Bytes.of_string text in
  let n = Bytes.length b in
  let i = ref 0 in
  while !i < n - 1 do
    if Char.equal (Bytes.get b !i) '/' && Char.equal (Bytes.get b (!i + 1)) '/' then
      while !i < n && not (Char.equal (Bytes.get b !i) '\n') do Bytes.set b !i ' '; incr i done
    else incr i
  done;
  Bytes.to_string b

let parse_text (p : Plugin.t) ~file text : (section list * constraint_ list, Diag.t list) Result.t =
  let text = blank_comments text in
  let g = p.grammar in
  let inp = Grammar.Input.make ~file text in
  let memo = Grammar.make_memo () in
  let len = Grammar.Input.length inp in
  let ws pos = Grammar.Input.skip_ws inp pos in
  let peek pos = let pos = ws pos in if pos < len then Some inp.text.[pos] else None in
  let fail_here () = raise (Parse_error (Grammar.Input.error inp)) in
  let expect pos c =
    let pos = ws pos in
    if pos < len && Char.equal inp.text.[pos] c then pos + 1 else (Grammar.Input.note inp pos (sprintf "%S" (String.of_char c)); fail_here ()) in
  let word_at pos =
    let pos = ws pos in
    let stop = ref pos in
    while !stop < len && Grammar.is_word inp.text.[!stop] do incr stop done;
    (pos, !stop, String.sub inp.text ~pos ~len:(!stop - pos)) in
  (* What may follow an atom: an operator, or the end of the enclosing parenthesis or section *)
  let followers close = [ ';'; '|'; '*'; close ] in
  let rec body ~cls ~close pos : int * body =
    let pos, a = action ~cls ~close pos in
    match peek pos with
    | Some '|' -> let pos, b = body ~cls ~close (ws pos + 1) in (pos, Choice (a, b))
    | _ -> Grammar.Input.note inp (ws pos) "\"|\""; (pos, a)
  and action ~cls ~close pos =
    let _, stop, w = word_at pos in
    if String.equal w "eps" then (stop, Epsilon)
    else
      let pos, f = factor ~cls ~close pos in
      match peek pos with
      | Some ';' -> let pos, rest = action ~cls ~close (ws pos + 1) in (pos, Seq (f, rest))
      | _ -> Grammar.Input.note inp (ws pos) "\";\""; (pos, f)
  and factor ~cls ~close pos =
    let pos, prim = primary ~cls ~close pos in
    match peek pos with
    | Some '*' -> (ws pos + 1, Star prim)
    | _ -> Grammar.Input.note inp (ws pos) "\"*\""; (pos, prim)
  and primary ~cls ~close pos =
    match peek pos with
    | Some '(' ->
      let pos, b = body ~cls ~close:')' (ws pos + 1) in
      (expect pos ')', b)
    | _ ->
      Grammar.Input.note inp (ws pos) "\"(\"";
      Grammar.Input.note inp (ws pos) "\"eps\"";
      let candidates = Grammar.parse_type g memo inp ~exclude:[] cls pos in
      (* An atom is followed by one of the operators of the body: of the ways to read an atom here, take the
         longest one that is *)
      let ok = List.filter candidates ~f:(fun (e, _) ->
          match peek e with
          | Some c when List.mem (followers close) c ~equal:Char.equal -> true
          | _ -> List.iter (followers close) ~f:(fun c -> Grammar.Input.note inp (ws e) (sprintf "%S" (String.of_char c))); false) in
      (match List.max_elt ok ~compare:(fun (a, _) (b, _) -> Int.compare a b) with
       | Some (e, v) -> (e, Atom v)
       | None -> fail_here ()) in
  let section_names = Sections_file.names p.sections in
  let attribute_names = List.map g.attributes ~f:fst in
  let err_at offset fmt = Printf.ksprintf (fun m -> raise (Parse_error (Diag.error ~pos:(Grammar.Input.pos_of inp (ws offset)) m))) fmt in
  (* constraint { relation(set, set); ... }; *)
  let constraints pos : int * constraint_ list =
    let operand pos =
      match peek pos with
      | Some '{' ->
        let start = ws pos + 1 in
        (match String.index_from inp.text start '}' with
         | None -> err_at pos "this list of values has no closing }"
         | Some close -> (close + 1, `Values (start, close)))
      | _ ->
        let start, stop, attr = word_at pos in
        if String.is_empty attr then (Grammar.Input.note inp start "an attribute or a list of values {...}"; fail_here ());
        if not (List.mem attribute_names attr ~equal:String.equal) then
          err_at start "%s is not an attribute of the atoms of %s%s" attr p.manifest.name
            (match Diag.did_you_mean attr attribute_names with Some c -> sprintf " (did you mean %s?)" c | None -> if List.is_empty attribute_names then " (atoms.yaml declares none)" else "");
        let pos = expect stop '(' in
        let sstart, sstop, section = word_at pos in
        (match Sections_file.find p.sections section with
         | None -> err_at sstart "unknown section %s%s" section (match Diag.did_you_mean section section_names with Some c -> sprintf " (did you mean %s?)" c | None -> "")
         | Some { kind = Opaque; _ } -> err_at sstart "the section %s is opaque: Core does not know its atoms" section
         | Some _ -> ());
        (expect sstop ')', `Attr (attr, section, start)) in
    let values ~ty (start, close) =
      let items = String.split (String.sub inp.text ~pos:start ~len:(close - start)) ~on:',' in
      let offset = ref start in
      List.filter_map items ~f:(fun item ->
          let here = !offset in
          offset := !offset + String.length item + 1;
          if String.is_empty (String.strip item) then None
          else match Grammar.parse_value g ~file ~ty item with
            | Ok v -> Some v
            | Error d -> err_at here "%S is not a value of %s: %s" (String.strip item) ty d.message) in
    let rec items pos acc =
      let start, stop, rel = word_at pos in
      let relation = match rel with
        | "disjoint" -> Disjoint
        | "subset" -> Subset
        | "" -> Grammar.Input.note inp start "disjoint or subset"; fail_here ()
        | other -> err_at start "unknown constraint %s: the constraints are disjoint(A, B) and subset(A, {values})" other in
      let pos = expect stop '(' in
      let pos, l = operand pos in
      let pos = expect pos ',' in
      let pos, r = operand pos in
      let pos = expect pos ')' in
      let type_of = function `Attr (a, _, _) -> Some (List.Assoc.find_exn g.attributes ~equal:String.equal a) | `Values _ -> None in
      let ty = match type_of l, type_of r with
        | Some t, _ | None, Some t -> t
        | None, None -> err_at start "a constraint compares at least one attribute" in
      let set = function `Attr (attr, section, _) -> Attr { attr; section } | `Values range -> Values (values ~ty range) in
      (match relation, r with
       | Subset, `Attr _ -> err_at start "the second set of subset must be a list of values {...}: an attribute can still grow"
       | _ -> ());
      (match type_of l, type_of r with
       | Some a, Some b when not (String.equal a b) -> err_at start "the two attributes have different types (%s and %s)" a b
       | _ -> ());
      let c = { relation; left = set l; right = set r; cpos = Grammar.Input.pos_of inp start } in
      match peek pos with
      | Some ';' -> items (ws pos + 1) (c :: acc)
      | _ -> (pos, List.rev (c :: acc)) in
    items pos [] in
  let rec blocks pos acc =
    let pos = ws pos in
    if pos >= len then List.rev acc
    else
      let start, stop, name = word_at pos in
      let here = Grammar.Input.pos_of inp start in
      if String.is_empty name then (Grammar.Input.note inp start "the name of a section"; fail_here ())
      else if String.equal name "constraint" then
        let pos = expect stop '{' in
        let pos, cs = constraints pos in
        let pos = expect pos '}' in
        let pos = expect pos ';' in
        blocks pos (`Constraints cs :: acc)
      else match List.Assoc.find reserved ~equal:String.equal name with
        | Some what ->
          (* Skip the block, to report it (and any later error) properly *)
          let rec skip i depth =
            if i >= len then i
            else match inp.text.[i] with
              | '{' -> skip (i + 1) (depth + 1)
              | '}' -> skip (i + 1) (depth - 1)
              | ';' when depth = 0 -> i + 1
              | _ -> skip (i + 1) depth in
          let d = Diag.errorf ~pos:here "%s blocks (%s) are reserved for a later version of ALVIE and are not supported yet" name what
              ~hint:"remove the block" in
          blocks (skip stop 0) (`Reserved d :: acc)
        | None ->
          (match Sections_file.find p.sections name with
           | None ->
             let hint = match Diag.hint_did_you_mean name section_names with
               | Some h -> h
               | None -> "the sections of " ^ p.manifest.name ^ " are " ^ Diag.enumerate ~conj:"and" section_names in
             raise (Parse_error (Diag.errorf ~pos:here ~hint "unknown section %s" name))
           | Some { kind = Opaque; _ } ->
             raise (Parse_error (Diag.errorf ~pos:here "the section %s is opaque: its program comes from the backend, not from the spec" name))
           | Some s ->
             let cls = Option.value_exn s.atoms in
             let pos = expect stop '{' in
             let pos, b = body ~cls ~close:'}' pos in
             let pos = expect pos '}' in
             let pos = expect pos ';' in
             blocks pos (`Section { name; body = b; pos = here } :: acc)) in
  match blocks 0 [] with
  | items ->
    let reserved = List.filter_map items ~f:(function `Reserved d -> Some d | _ -> None) in
    let sections = List.filter_map items ~f:(function `Section s -> Some s | _ -> None) in
    let constraints = List.concat_map items ~f:(function `Constraints cs -> cs | _ -> []) in
    if List.is_empty reserved then Ok (sections, constraints) else Error reserved
  | exception Parse_error d -> Error [ d ]

(* Parses the spec made of these files, (file name, text), in order; every section that is not opaque must have
   exactly one body among them *)
let parse (p : Plugin.t) (files : (string * string) list) : (t, Diag.t list) Result.t =
  let parsed = List.map files ~f:(fun (file, text) -> parse_text p ~file text) in
  match List.concat_map parsed ~f:(function Error es -> es | Ok _ -> []) with
  | _ :: _ as es -> Error es
  | [] ->
    let found = List.concat_map parsed ~f:(function Ok (ss, _) -> ss | Error _ -> []) in
    let constraints = List.concat_map parsed ~f:(function Ok (_, cs) -> cs | Error _ -> []) in
    let errors = ref [] in
    List.iter p.sections.sections ~f:(fun s ->
        match List.filter found ~f:(fun f -> String.equal f.name s.name), s.kind with
        | [], Opaque | [ _ ], _ -> ()
        | [], _ ->
          errors := Diag.errorf "the spec has no %s section" s.name
              ~hint:(sprintf "add %s { ... }; (write %s { eps }; for an empty one)" s.name s.name) :: !errors
        | _ :: again :: _, _ -> errors := Diag.errorf ~pos:again.pos "the section %s appears twice" s.name :: !errors);
    (match List.rev !errors with
     | [] ->
       (* In the order of the plugin's sections *)
       Ok { sections = List.filter_map p.sections.sections ~f:(fun s -> List.find found ~f:(fun f -> String.equal f.name s.name)); constraints }
     | es -> Error es)

let parse_files p paths =
  match List.map paths ~f:(fun path -> (path, In_channel.read_all path)) with
  | files -> parse p files
  | exception Sys_error m -> Error [ Diag.errorf "cannot read the spec: %s" m ]

(* Replaces the secret holes of every section by the expansion of value *)
let expand_secret (p : Plugin.t) (t : t) ~value : (t, Diag.t) Result.t =
  let open Result.Let_syntax in
  let%map sections = Result.all (List.map t.sections ~f:(fun s ->
      let cls = Option.value_exn (Plugin.atoms_of p s.name) in
      let rec go b = match b with
        | Empty | Epsilon -> Ok b
        | Atom a -> Result.map (Grammar.expand_secret p.grammar ~ty:(Grammar.Ref cls) ~value a) ~f:(fun a -> Atom a)
        | Choice (l, r) -> let%bind l = go l in let%map r = go r in Choice (l, r)
        | Seq (l, r) -> let%bind l = go l in let%map r = go r in Seq (l, r)
        | Star b -> let%map b = go b in Star b in
      Result.map_error (Result.map (go s.body) ~f:(fun body -> { s with body })) ~f:(fun m -> Diag.error ~pos:s.pos m))) in
  { t with sections }
