(*
  alvie-plugin.yaml: the manifest of a plugin.

    format: 1
    name: sancus
    version: "2026.10"
    core: "1"                  # the version of the plugin interface of Core that the plugin targets
    kind: native               # native (OCaml, linked with Core) or external (a program that speaks the protocol)
    command: [python3, backend.py]   # external plugins only
    config:                    # the parameters of the backend
      commit: { type: string, required: true, doc: "..." }
    variants:                  # the variants of the system to compare against (e.g. a baseline)
      no-interrupts: { doc: "..." }
    capabilities: [restore, clone]
    files: { sections: sections.yaml, ... }   # optional: these are the defaults
*)

open Core
open Shape

(* The versions of the plugin interface that this Core supports *)
let supported_core = [ "1" ]

type kind = Native | External of string list [@@deriving sexp, equal]

type ptype = P_string | P_path | P_int of int * int | P_bool | P_enum of string list [@@deriving sexp, equal]

type param = { pname : string; ptype : ptype; required : bool; default : string option; pdoc : string option; ppos : Diag.pos }

type capability = Restore | Clone | Parallel [@@deriving sexp, equal]

type files = { sections : string; atoms : string; observations : string; phases : string; view : string }

let default_files = { sections = "sections.yaml"; atoms = "atoms.yaml"; observations = "observations.yaml"; phases = "phases.yaml"; view = "view.yaml" }

type t = {
  name : string;
  version : string;
  core : string;
  kind : kind;
  description : string option;
  config : param list;
  variants : (string * string option) list;
  capabilities : capability list;
  files : files;
  fixtures : string option;
}

let param_shape =
  let open Obj in
  Shape.map_result
    (obj ~what:"a configuration parameter"
       (let+ ty = req "type" (enum [ ("string", `String); ("path", `Path); ("int", `Int); ("bool", `Bool); ("enum", `Enum) ]) ~doc:"string, path, int, bool or enum"
        and+ range = opt "range" (Shape.list (Shape.int ())) ~doc:"For int: [lowest, highest]"
        and+ values = opt "values" (Shape.list (Shape.string ())) ~doc:"For enum: the values"
        and+ required = dflt "required" false (Shape.bool ())
        and+ default = opt "default" (Shape.string ()) ~doc:"The default value, as it would be written on the command line"
        and+ doc = opt "doc" (Shape.string ()) in
        (ty, range, values, required, default, doc)))
    ~f:(fun n (ty, range, values, required, default, doc) ->
        let ptype = match ty, range, values with
          | `String, None, None -> Ok P_string
          | `Path, None, None -> Ok P_path
          | `Bool, None, None -> Ok P_bool
          | `Int, None, None -> Ok (P_int (Int.min_value, Int.max_value))
          | `Int, Some [ lo; hi ], None when lo <= hi -> Ok (P_int (lo, hi))
          | `Enum, None, Some (_ :: _ as vs) -> Ok (P_enum vs)
          | `Enum, _, _ -> fail n "an enum parameter needs its values (values: [...])"
          | _ -> fail n "range is for int parameters and values for enum parameters" in
        Result.bind ptype ~f:(fun ptype ->
            if required && Option.is_some default then fail n "a required parameter has no default"
            else Ok (ptype, required, default, doc)))

let files_shape =
  let open Obj in
  obj (let+ sections = dflt "sections" default_files.sections (Shape.string ())
       and+ atoms = dflt "atoms" default_files.atoms (Shape.string ())
       and+ observations = dflt "observations" default_files.observations (Shape.string ())
       and+ phases = dflt "phases" default_files.phases (Shape.string ())
       and+ view = dflt "view" default_files.view (Shape.string ()) in
       { sections; atoms; observations; phases; view })

let shape =
  let open Obj in
  Shape.with_pos
    (Shape.map_result
       (obj ~what:"a plugin manifest"
          (let+ _ = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
           and+ name = req "name" (Shape.string ()) ~doc:"The name of the plugin"
           and+ version = req "version" (Shape.string ()) ~doc:"The version of the plugin"
           and+ core = req "core" (Shape.string ()) ~doc:"The version of the plugin interface of ALVIE/Core: \"1\""
           and+ kind = req "kind" (enum [ ("native", `Native); ("external", `External) ]) ~doc:"native or external"
           and+ command = opt "command" (Shape.list (Shape.string ())) ~doc:"External plugins: the command that starts the backend"
           and+ description = opt "description" (Shape.string ())
           and+ config = dflt "config" [] (Shape.map param_shape) ~doc:"The configuration parameters of the backend"
           and+ variants = dflt "variants" [] (Shape.map (obj (let+ doc = opt "doc" (Shape.string ()) in doc))) ~doc:"The variants of the system (e.g. a baseline)"
           and+ capabilities = dflt "capabilities" [] (Shape.list (enum [ ("restore", Restore); ("clone", Clone); ("parallel", Parallel) ])) ~doc:"restore, clone, parallel"
           and+ files = dflt "files" default_files files_shape ~doc:"The plugin files, relative to the manifest"
           and+ fixtures = opt "fixtures" (Shape.string ()) ~doc:"The directory of the fixtures" in
           (name, version, core, kind, command, description, config, variants, capabilities, files, fixtures)))
       ~f:(fun n (name, version, core, kind, command, description, config, variants, capabilities, files, fixtures) ->
           let kind = match kind, command with
             | `Native, None -> Ok Native
             | `External, Some (_ :: _ as c) -> Ok (External c)
             | `Native, Some _ -> fail n "a native plugin has no command: it is linked with Core"
             | `External, _ -> fail n "an external plugin needs the command that starts it (command: [program, args...])" in
           let core_ok =
             if List.mem supported_core core ~equal:String.equal then Ok ()
             else fail n "this plugin targets version %S of the plugin interface, but this ALVIE supports %s" core (Diag.enumerate supported_core)
                 ~hint:"use a version of ALVIE that supports it, or update the plugin" in
           Result.bind (Shape.both kind core_ok) ~f:(fun (kind, ()) ->
               Ok {
                 name; version; core; kind; description;
                 config = List.map config ~f:(fun (pname, ppos, (ptype, required, default, pdoc)) -> { pname; ptype; required; default; pdoc; ppos });
                 variants = List.map variants ~f:(fun (v, _, doc) -> (v, doc));
                 capabilities; files; fixtures })))

let load ~file = Result.map (Shape.parse_file shape file) ~f:fst
let load_string ~file text = Result.map (Shape.parse_string shape ~file text) ~f:fst
