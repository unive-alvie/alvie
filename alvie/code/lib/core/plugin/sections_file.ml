(*
  sections.yaml: the sections of a spec, their roles and their kinds, and where the secret comes from.

    format: 1
    sections:
      prepare: { role: attacker, atoms: attacker, initial: true }
      enclave: { role: victim, atoms: enclave }
    secret: { hole: true }

  Roles: attacker (its inputs are the low inputs of the comparison) or victim. Kinds:
  - code (the default): the section is code; all its runs in a test are prefixes of the longest one (Core replays
    the code that already ran, and chooses new atoms only beyond it);
  - stimulus: each input is a fresh choice (e.g. bus transactions), not replayed;
  - opaque: the backend supplies the program (e.g. an existing binary); its only input is Core's built-in run.
  Exactly one section is initial: the system starts in it.

  The secret is either a hole in the atoms ({ hole: true }, the variant marked secret in atoms.yaml) or a
  configuration parameter of the backend ({ config: <parameter> }), with the values to compare (values, optional).
*)

open Core
open Shape

type role = Attacker | Victim [@@deriving sexp, equal]
type kind = Code | Stimulus | Opaque [@@deriving sexp, equal]

type section = {
  name : string;
  role : role;
  kind : kind;
  atoms : string option;
  initial : bool;
  doc : string option;
  pos : Diag.pos;
}

type secret_source = Hole | Config of string [@@deriving sexp, equal]

type secret = { source : secret_source; values : string list option; spos : Diag.pos }

type t = { sections : section list; secret : secret option }

let section_shape =
  let open Obj in
  obj ~what:"a section"
    (let+ role = req "role" (enum [ ("attacker", Attacker); ("victim", Victim) ]) ~doc:"attacker or victim"
     and+ kind = dflt "kind" Code (enum [ ("code", Code); ("stimulus", Stimulus); ("opaque", Opaque) ]) ~doc:"code (default), stimulus or opaque"
     and+ atoms = opt "atoms" (Shape.string ()) ~doc:"The atom class of the section (an entry of atoms: in atoms.yaml)"
     and+ initial = dflt "initial" false (Shape.bool ()) ~doc:"The system starts in this section"
     and+ doc = opt "doc" (Shape.string ()) in
     (role, kind, atoms, initial, doc))

let secret_shape =
  let open Obj in
  Shape.with_pos
    (Shape.map_result
       (obj ~what:"a secret declaration"
          (let+ hole = dflt "hole" false (Shape.bool ()) ~doc:"The secret is the hole of the atoms (the variant marked secret)"
           and+ config = opt "config" (Shape.string ()) ~doc:"The secret is this configuration parameter of the backend"
           and+ values = opt "values" (Shape.list (Shape.string ())) ~doc:"The values of the secret to compare" in
           (hole, config, values)))
       ~f:(fun n -> function
           | true, None, values -> Ok (Hole, values)
           | false, Some c, values -> Ok (Config c, values)
           | _ -> fail n "the secret is either { hole: true } or { config: <parameter> }"))

let shape =
  let open Obj in
  obj ~what:"a sections file"
    (let+ _ = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
     and+ sections = req "sections" (Shape.map section_shape) ~doc:"The sections of a spec, by name, in the order specs list them"
     and+ secret = opt "secret" secret_shape ~doc:"Where the secret is" in
     (sections, secret))

let build (sections, secret) : (t, Diag.t list) Result.t =
  let errors = ref [] in
  let err ?hint pos fmt = Printf.ksprintf (fun m -> errors := Diag.error ~pos ?hint m :: !errors) fmt in
  let sections = List.map sections ~f:(fun (name, pos, (role, kind, atoms, initial, doc)) ->
      (match kind, atoms with
       | (Code | Stimulus), None -> err pos "the section %s needs the atom class of its inputs (atoms: ...)" name
       | Opaque, Some _ -> err pos "the opaque section %s has no atoms: the backend supplies its program" name
       | _ -> ());
      if String.equal name "eps" then err pos "eps is a keyword of specs and cannot name a section";
      { name; role; kind; atoms; initial; doc; pos }) in
  (match List.filter sections ~f:(fun s -> s.initial) with
   | [ _ ] -> ()
   | [] -> (match sections with s :: _ -> err s.pos "no section is initial: mark the one the system starts in with initial: true" | [] -> ())
   | _ :: s :: _ -> err s.pos "only one section can be initial");
  if List.is_empty sections then errors := Diag.error "there are no sections" :: !errors;
  let secret = Option.map secret ~f:(fun ((source, values), spos) -> { source; values; spos }) in
  match List.rev !errors with [] -> Ok { sections; secret } | es -> Error es

let load ~file = Result.bind (Shape.parse_file shape file) ~f:build
let load_string ~file text = Result.bind (Shape.parse_string shape ~file text) ~f:build

let find t name = List.find t.sections ~f:(fun s -> String.equal s.name name)
let names t = List.map t.sections ~f:(fun s -> s.name)
let initial t = List.find_exn t.sections ~f:(fun s -> s.initial)
