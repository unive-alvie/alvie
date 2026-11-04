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
  A spec may be split across files (e.g. the victim and the attacker); every section that is not opaque must have
  exactly one body. constraint { ... };, threads { ... }; and step <unit>; are reserved for later versions: they
  are recognised, and rejected with an explanation.
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

type t = section list

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

let body_of t name = List.find_map t ~f:(fun s -> if String.equal s.name name then Some s.body else None)

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

let print (p : Plugin.t) (t : t) =
  String.concat ~sep:"\n" (List.map t ~f:(fun s ->
      let cls = Option.value (Plugin.atoms_of p s.name) ~default:"" in
      sprintf "%s { %s };" s.name (print_body p.grammar ~cls s.body)))

(* Parsing *)

exception Parse_error of Diag.t

let reserved = [ ("constraint", "constraints between sections"); ("threads", "several threads of control"); ("step", "the granularity of a step") ]

let parse_text (p : Plugin.t) ~file text : (section list, Diag.t list) Result.t =
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
  let rec blocks pos acc =
    let pos = ws pos in
    if pos >= len then List.rev acc
    else
      let start, stop, name = word_at pos in
      let here = Grammar.Input.pos_of inp start in
      if String.is_empty name then (Grammar.Input.note inp start "the name of a section"; fail_here ())
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
    if List.is_empty reserved then Ok sections else Error reserved
  | exception Parse_error d -> Error [ d ]

(* Parses the spec made of these files, (file name, text), in order; every section that is not opaque must have
   exactly one body among them *)
let parse (p : Plugin.t) (files : (string * string) list) : (t, Diag.t list) Result.t =
  let parsed = List.map files ~f:(fun (file, text) -> parse_text p ~file text) in
  match List.concat_map parsed ~f:(function Error es -> es | Ok _ -> []) with
  | _ :: _ as es -> Error es
  | [] ->
    let found = List.concat_map parsed ~f:(function Ok ss -> ss | Error _ -> []) in
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
       Ok (List.filter_map p.sections.sections ~f:(fun s -> List.find found ~f:(fun f -> String.equal f.name s.name)))
     | es -> Error es)

let parse_files p paths =
  match List.map paths ~f:(fun path -> (path, In_channel.read_all path)) with
  | files -> parse p files
  | exception Sys_error m -> Error [ Diag.errorf "cannot read the spec: %s" m ]

(* Replaces the secret holes of every section by the expansion of value *)
let expand_secret (p : Plugin.t) (t : t) ~value : (t, Diag.t) Result.t =
  let open Result.Let_syntax in
  let%map sections = Result.all (List.map t ~f:(fun s ->
      let cls = Option.value_exn (Plugin.atoms_of p s.name) in
      let rec go b = match b with
        | Empty | Epsilon -> Ok b
        | Atom a -> Result.map (Grammar.expand_secret p.grammar ~ty:(Grammar.Ref cls) ~value a) ~f:(fun a -> Atom a)
        | Choice (l, r) -> let%bind l = go l in let%map r = go r in Choice (l, r)
        | Seq (l, r) -> let%bind l = go l in let%map r = go r in Seq (l, r)
        | Star b -> let%map b = go b in Star b in
      Result.map_error (Result.map (go s.body) ~f:(fun body -> { s with body })) ~f:(fun m -> Diag.error ~pos:s.pos m))) in
  sections
