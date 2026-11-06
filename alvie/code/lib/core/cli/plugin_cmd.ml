(*
  alvie plugin: commands for plugin authors.

  - alvie plugin check [DIR]: reads the plugin files of DIR (by default the plugin the program was built with) and
    their checks across files, and reports every problem with its place, or a summary of the plugin.
  - alvie plugin new NAME: makes a native plugin from the template (Plugin_template), which works from the start.
  - alvie plugin types DIR OUT: writes the Python constructors of the plugin's observations (Python_types).
  - alvie plugin schemas [DIR] OUT: writes the JSON Schemas of the plugin files (for editors) and of the values of
    the plugin's atoms and observations (for the external protocol) to OUT.
*)

open Core
open Alvie_plugin

let load ~default dir : Plugin.t =
  match (match dir with Some d -> Plugin.load d | None -> Lazy.force default) with
  | Ok p -> p
  | Error ds ->
    eprintf "%s\n" (Diag.list_to_string ds);
    eprintf "ALVIE error: the plugin has %d problem%s (see above).\n" (List.length ds) (if List.length ds = 1 then "" else "s");
    exit 2

let summary (p : Plugin.t) =
  let classes = Grammar.classes p.grammar in
  sprintf "plugin %s %s (%s, plugin interface %s)\n  sections: %s\n  atom classes: %s\n  kinds of observations: %d\n  phase rules: %d, view rules: %d\n  configuration: %s"
    p.manifest.name p.manifest.version (match p.manifest.kind with Native -> "native" | External _ -> "external") p.manifest.core
    (String.concat ~sep:", " (List.map p.sections.sections ~f:(fun s ->
         sprintf "%s (%s%s)" s.name (match s.role with Attacker -> "attacker" | Victim -> "victim")
           (match s.kind with Code -> "" | Stimulus -> ", stimulus" | Opaque -> ", opaque"))))
    (String.concat ~sep:", " (List.map classes ~f:(fun c -> sprintf "%s (%d atoms)" c.name (List.length c.alts))))
    (List.length p.observations.kinds) (List.length p.phases) (List.length p.view)
    (match p.manifest.config with [] -> "none" | ps -> String.concat ~sep:" " (List.map ps ~f:(fun q -> "--" ^ q.pname)))

let command ~(default : (Plugin.t, Diag.t list) Result.t Lazy.t) =
  let dir_arg = Command.Param.(anon (maybe ("DIR" %: string))) in
  Command.group ~summary:"Commands for plugin authors"
    [ ("check", Command.basic ~summary:"Check the files of a plugin (DIR, or the plugin this program was built with)"
         (let%map_open.Command dir = dir_arg in
          fun () ->
            let p = load ~default dir in
            printf "OK: %s\n" (summary p)));
      ("new", Command.basic ~summary:"Make a native plugin from the template: plugins/NAME and lib/plugins/NAME, from the directory alvie/code"
         ~readme:(fun () -> "The template is a small platform that works: its fixtures and the conformance checks pass. Change it into yours: the plugin files in plugins/NAME, the backend in lib/plugins/NAME. With --external, the backend is a Python program (backend.py) that speaks the protocol of ALVIE/Core through the Python SDK, which the plugin gets a copy of; nothing is built.")
         (let%map_open.Command name = anon ("NAME" %: string)
          and external_ = flag "--external" no_arg ~doc:" an external plugin in Python (with the SDK), instead of a native one in OCaml"
          and root = flag "--root" (optional_with_default "." string) ~doc:"dir the directory alvie/code of ALVIE (default: the current one)" in
          fun () ->
            Errors.protect ~debug:false (fun () ->
                let valid = String.length name >= 2 && Char.is_lowercase name.[0]
                            && String.for_all name ~f:(fun c -> Char.is_lowercase c || Char.is_digit c || Char.equal c '-')
                            && not (String.is_suffix name ~suffix:"-") in
                if not valid then Errors.fail "%S is not a name for a plugin: use lowercase letters, digits and -, starting with a letter (e.g. my-chip)." name;
                if List.mem [ "sancus"; "tiny"; "core"; "plugin" ] name ~equal:String.equal then Errors.fail "%s is taken: choose another name." name;
                let root = Errors.require_directory ~option:"--root" root in
                if not (Sys_unix.file_exists_exn (Filename.concat root "dune-project")) then
                  Errors.fail "%s is not the directory alvie/code of ALVIE (it has no dune-project): run from there, or give it with --root." root;
                let types yaml_files =
                  let dir = Filename.concat "plugins" name in
                  match Plugin.load_with ~dir ~read:(fun f -> match List.Assoc.find yaml_files ~equal:String.equal (Filename.concat dir f) with
                      | Some t -> Ok t | None -> Error (sprintf "no file %s in the template" f)) with
                  | Ok p -> Python_types.generate p
                  | Error ds -> failwithf "the template does not load (a bug):\n%s" (Diag.list_to_string ds) () in
                let files = Plugin_template.files ~external_ ~name ~types () in
                List.iter [ Filename.concat "plugins" name; Filename.concat "lib/plugins" name ] ~f:(fun d ->
                    if Sys_unix.file_exists_exn (Filename.concat root d) then Errors.fail "%s exists already: choose another name, or remove it." (Filename.concat root d));
                List.iter files ~f:(fun (path, text) ->
                    let path = Filename.concat root path in
                    Core_unix.mkdir_p (Filename.dirname path);
                    Out_channel.write_all path ~data:text;
                    printf "wrote %s\n" path);
                if external_ then
                  printf "\nNext:\n  alvie plugin check plugins/%s\n  alvie external plugins/%s conformance --spec plugins/%s/fixtures/leak.spec --secret 0\n  alvie external plugins/%s fixtures\nthen change the files and backend.py into your platform (see the Plugin Author Guide).\n" name name name name
                else
                  printf "\nNext:\n  dune build\n  dune exec alvie -- plugin check plugins/%s\n  dune exec alvie-%s -- conformance --spec plugins/%s/fixtures/leak.spec --secret 0\n  dune exec alvie-%s -- fixtures\nthen change the files into your platform (see the Plugin Author Guide).\n" name name name name)));
      ("types", Command.basic ~summary:"Write the Python constructors of the observations of the plugin in DIR to OUT (for the Python SDK)"
         (let%map_open.Command dir = anon ("DIR" %: string) and out = anon ("OUT" %: string) in
          fun () ->
            let p = load ~default (Some dir) in
            Out_channel.write_all out ~data:(Python_types.generate p);
            printf "wrote %s\n" out));
      ("schemas", Command.basic ~summary:"Write the JSON Schemas of the plugin files and of the plugin's values to OUT"
         (let%map_open.Command out = anon ("OUT" %: string) and dir = flag "--plugin" (optional string) ~doc:"dir the plugin (default: the one this program was built with)" in
          fun () ->
            let p = load ~default dir in
            Core_unix.mkdir_p out;
            let write name json =
              let path = Filename.concat out name in
              Out_channel.write_all path ~data:(Yojson.Safe.pretty_to_string json ^ "\n");
              printf "wrote %s\n" path in
            List.iter (Plugin.file_schemas ()) ~f:(fun (name, schema) -> write name schema);
            write "protocol.schema.json" (Alvie_backend.Protocol.json_schema ());
            write (p.manifest.name ^ "-atoms.values.schema.json") (Grammar.json_schema p.grammar);
            write (p.manifest.name ^ "-observations.values.schema.json") (Observations_file.json_schema p.observations))) ]
