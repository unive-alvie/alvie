(*
  alvie plugin: commands for plugin authors.

  - alvie plugin check [DIR]: reads the plugin files of DIR (by default the plugin the program was built with) and
    their checks across files, and reports every problem with its place, or a summary of the plugin.
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
            write (p.manifest.name ^ "-atoms.values.schema.json") (Grammar.json_schema p.grammar);
            write (p.manifest.name ^ "-observations.values.schema.json") (Observations_file.json_schema p.observations))) ]
