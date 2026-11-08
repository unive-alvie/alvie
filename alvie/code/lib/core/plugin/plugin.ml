(*
  A plugin: its manifest and its declaration files, loaded from its directory and checked against each other.

  Each file is checked on its own when it is read (Shape); then the files are checked together: the sections name
  atom classes of atoms.yaml, the rules name kinds of observations.yaml and sections of sections.yaml, the fields
  in when: and show: exist in the kinds the rules match, with values of their types, and the secret is a hole of
  the atoms or a parameter of the manifest. All the errors of all the files are reported at once.
*)

open Core

type t = {
  dir : string;
  manifest : Manifest_file.t;
  sections : Sections_file.t;
  grammar : Grammar.t;
  observations : Observations_file.t;
  phases : Rules_file.phases;
  view : Rules_file.view;
}

let manifest_name = "alvie-plugin.yaml"

let check_cross ~(manifest : Manifest_file.t) ~(sections : Sections_file.t) ~(grammar : Grammar.t) ~(observations : Observations_file.t) ~phases ~view =
  let errors = ref [] in
  let err ?hint pos fmt = Printf.ksprintf (fun m -> errors := Diag.error ~pos ?hint m :: !errors) fmt in
  let class_names = List.map (Grammar.classes grammar) ~f:(fun t -> t.name) in
  let section_names = Sections_file.names sections in
  let kind_names = Observations_file.kind_names observations in
  (* Sections and atom classes *)
  List.iter sections.sections ~f:(fun s ->
      Option.iter s.atoms ~f:(fun a ->
          if not (List.mem class_names a ~equal:String.equal) then
            err s.pos "the section %s uses the atom class %s, which atoms.yaml does not declare" s.name a
              ?hint:(match Diag.hint_did_you_mean a class_names with Some h -> Some h | None -> Some ("the atom classes are " ^ Diag.enumerate ~conj:"and" class_names))));
  (* The secret *)
  (match sections.secret with
   | Some { source = Hole; spos; _ } ->
     if not (List.exists grammar.types ~f:(fun t -> List.exists t.alts ~f:(fun a -> Option.is_some a.secret))) then
       err spos "the secret is a hole, but no variant in atoms.yaml is marked secret"
   | Some { source = Config c; spos; _ } ->
     if not (List.exists manifest.config ~f:(fun p -> String.equal p.pname c)) then
       err spos "the secret is the configuration parameter %s, which the manifest does not declare" c
         ?hint:(Diag.hint_did_you_mean c (List.map manifest.config ~f:(fun p -> p.pname)))
   | None -> ());
  (* Rules *)
  let check_section pos s =
    if not (List.mem section_names s ~equal:String.equal) then
      err pos "unknown section %s" s ?hint:(match Diag.hint_did_you_mean s section_names with Some h -> Some h | None -> Some ("the sections are " ^ Diag.enumerate ~conj:"and" section_names)) in
  let check_rule (r : _ Rules_file.rule) =
    let kinds = match r.kinds with
      | None -> observations.kinds
      | Some ks ->
        List.filter_map ks ~f:(fun k ->
            match Observations_file.find_kind observations k with
            | Some kd -> Some kd
            | None ->
              err r.pos "unknown kind of observation %s" k ?hint:(match Diag.hint_did_you_mean k kind_names with Some h -> Some h | None -> Some ("the kinds are " ^ Diag.enumerate ~conj:"and" kind_names));
              None) in
    Option.iter r.sections ~f:(List.iter ~f:(check_section r.pos));
    (* The fields of when: must exist in every kind the rule names; a rule without match: applies to the kinds
       that have them, so at least one must *)
    List.iter r.when_ ~f:(fun c ->
        let shown = String.concat ~sep:"." c.path in
        let typed = List.filter_map kinds ~f:(fun k -> Option.map (Observations_file.path_type observations k.fields c.path) ~f:(fun t -> (k, t))) in
        (match r.kinds with
         | Some _ ->
           List.iter kinds ~f:(fun k ->
               if Option.is_none (Observations_file.path_type observations k.fields c.path) then
                 err c.kpos "the kind %s has no field %s" k.name shown ?hint:(Diag.hint_did_you_mean shown (List.map k.fields ~f:fst)))
         | None -> if List.is_empty typed then err c.kpos "no kind of observation has a field %s" shown);
        List.iter typed ~f:(fun (k, t) ->
            match Observations_file.scalar_value observations t c.value with
            | Ok _ -> ()
            | Error e -> err c.cpos "%s is not a value of the field %s of %s: %s" c.value shown k.name e)) in
  List.iter phases ~f:(fun (r : Rules_file.action list Rules_file.rule) ->
      check_rule r;
      List.iter r.effect ~f:(function
          | Rules_file.Enter s | Switch s | Interrupt s -> check_section r.pos s
          | Restart | Reset | Resume | Stop _ -> ()));
  List.iter view ~f:(fun (r : Rules_file.effect Rules_file.rule) ->
      check_rule r;
      match r.effect with
      | Rules_file.Parts ps ->
        let kinds = match r.kinds with None -> observations.kinds | Some ks -> List.filter_map ks ~f:(Observations_file.find_kind observations) in
        List.iter ps ~f:(fun (p : Rules_file.part) ->
            match Observations_file.find_kind observations p.as_kind with
            | None -> err r.pos "unknown kind of observation %s" p.as_kind ?hint:(Diag.hint_did_you_mean p.as_kind kind_names)
            | Some target ->
              Option.iter p.field ~f:(fun f ->
                  List.iter kinds ~f:(fun k ->
                      if String.equal f "self" then (
                        if not (List.equal [%equal: string * Observations_file.ftype] k.fields target.fields) then
                          err r.pos "the kind %s does not have the fields of %s (field: self)" k.name p.as_kind)
                      else
                      match List.Assoc.find k.fields ~equal:String.equal f with
                      | Some (Observations_file.F_record rt) ->
                        (match List.Assoc.find observations.types ~equal:String.equal rt with
                         | Some (Observations_file.Record fs) when List.equal [%equal: string * Observations_file.ftype] fs target.fields -> ()
                         | _ -> err r.pos "the field %s of %s does not have the fields of %s" f k.name p.as_kind)
                      | _ -> err r.pos "the kind %s has no record field %s" k.name f)))
      | Rules_file.Show (Rules_file.Fields fs) ->
        let kinds = match r.kinds with None -> observations.kinds | Some ks -> List.filter_map ks ~f:(Observations_file.find_kind observations) in
        List.iter fs ~f:(fun p ->
            List.iter kinds ~f:(fun k ->
                if Option.is_none (Observations_file.path_type observations k.fields p) then
                  err r.pos "the kind %s has no field %s to show" k.name (String.concat ~sep:"." p)))
      | Show (Hidden | Tag | Distinct | All) -> ());
  List.rev !errors

(*
  Loads the plugin whose files read gives: read name is the text of the file name (relative to the plugin's
  directory), or an error. Diagnostics name the files dir/name.
*)
let load_with ~dir ~(read : string -> (string, string) Result.t) : (t, Diag.t list) Result.t =
  let path f = Filename.concat dir f in
  let text f = Result.map_error (read f) ~f:(fun m -> [ Diag.errorf "cannot read %s: %s" (path f) m ]) in
  let load f parse = Result.bind (text f) ~f:(fun t -> parse ~file:(path f) t) in
  match load manifest_name Manifest_file.load_string with
  | Error es -> Error es
  | Ok manifest ->
    let f = manifest.files in
    let sections = load f.sections Sections_file.load_string in
    let grammar = load f.atoms Atoms_file.load_string in
    let observations = load f.observations Observations_file.load_string in
    let phases = load f.phases Rules_file.load_phases_string in
    let view = load f.view Rules_file.load_view_string in
    let errors r = match r with Ok _ -> [] | Error es -> es in
    match sections, grammar, observations, phases, view with
    | Ok sections, Ok grammar, Ok observations, Ok phases, Ok view ->
      (match check_cross ~manifest ~sections ~grammar ~observations ~phases ~view with
       | [] -> Ok { dir; manifest; sections; grammar; observations; phases; view }
       | es -> Error es)
    | _ -> Error (errors sections @ errors grammar @ errors observations @ errors phases @ errors view)

(* Loads the plugin in directory dir *)
let load dir : (t, Diag.t list) Result.t =
  load_with ~dir ~read:(fun name ->
      match In_channel.read_all (Filename.concat dir name) with
      | text -> Ok text
      | exception Sys_error m -> Error m)

(* Loads a plugin from files embedded in a program: (name, text) *)
let load_embedded ~dir (files : (string * string) list) =
  load_with ~dir ~read:(fun name ->
      match List.Assoc.find files ~equal:String.equal name with Some t -> Ok t | None -> Error "not embedded")

(* The atom class of a section *)
let atoms_of t section = Option.bind (Sections_file.find t.sections section) ~f:(fun s -> s.atoms)

(* The JSON Schemas of the plugin files, for editors: (file name, schema) *)
let file_schemas () : (string * Yojson.Safe.t) list =
  let base = "https://unive-alvie.github.io/alvie/schemas/1/" in
  let s name title shape = (name ^ ".schema.json", Shape.json_schema ~title ~id:(base ^ name ^ ".schema.json") shape) in
  [ s "alvie-plugin" "ALVIE plugin manifest" (Shape.map_value Manifest_file.shape ~f:ignore);
    s "sections" "ALVIE plugin sections" (Shape.map_value Sections_file.shape ~f:ignore);
    s "atoms" "ALVIE plugin atoms" (Shape.map_value Atoms_file.shape ~f:ignore);
    s "observations" "ALVIE plugin observations" (Shape.map_value Observations_file.shape ~f:ignore);
    s "phases" "ALVIE plugin phase rules" (Shape.map_value Rules_file.phases_shape ~f:ignore);
    s "view" "ALVIE plugin attacker view" (Shape.map_value Rules_file.view_shape ~f:ignore);
    s "fixture" "ALVIE plugin fixture" (Shape.map_value Fixture_file.shape ~f:ignore) ]
