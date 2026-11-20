(* alvie-web: the commands of Core for the plugins of ALVIE that run in a browser, with the argv and the simulators
   that the host gives (Host: host.jsoo.ml) *)
module Sancus_web = Alvie_cli.Runner.Make_codec (Sancus_core.Wasm_target.Native) (Sancus_core.Wasm_target.Native.Codec)

(* alvie-web check FILE...: the problems of spec files, for the editor of the IDE, one JSON object per line:
   {"file", "line", "col", "severity", "message"}. A .vtdl file is checked as VTDL; .atdl, .etdl and .spec files as
   specs of ALVIE/Sancus, alone: only the problems in the file are given (a file may hold some of the sections). *)
let check =
  let open Core in
  Command.basic ~summary:"Print the problems of spec files as JSON lines (for the editor of the IDE)"
    (let%map_open.Command files = anon (sequence ("FILE" %: string)) in
     fun () ->
       let json file line col severity message =
         print_endline (Yojson.Safe.to_string (`Assoc [ ("file", `String file); ("line", `Int line); ("col", `Int col);
                                                        ("severity", `String severity); ("message", `String message) ])) in
       List.iter files ~f:(fun file ->
           match In_channel.read_all file with
           | exception Sys_error m -> json file 1 1 "error" m
           | text when String.is_suffix file ~suffix:".vtdl" ->
             (match Vaultlink.Vtdl.parse_result text with
              | Error ({ line; column }, msg) -> json file line column "error" msg
              | Ok spec -> List.iter (Vaultlink.Vtdl.warnings spec) ~f:(fun w -> json file 1 1 "warning" w))
           | text ->
             (match Alvie_plugin.Spec.parse (Lazy.force Sancus_core.Generic_inputgen.plugin) [ (file, text) ] with
              | Ok _ -> ()
              | Error ds ->
                List.iter ds ~f:(fun (d : Alvie_plugin.Diag.t) ->
                    Option.iter d.pos ~f:(fun p ->
                        if String.equal p.file file then
                          json file p.line p.col "error" (d.message ^ Option.value_map d.hint ~default:"" ~f:(fun h -> " (" ^ h ^ ")")))))))

let () =
  at_exit Host.on_exit;
  Host.install_sancus ();
  Host.write_files ();
  let commands =
    Core.Command.group ~summary:"ALVIE in the browser"
      [ ("tiny", Alvie_cli.Runner.commands (module Alvie_tiny.Tiny.Native));
        (* with the codec of ALVIE/Sancus, as learn.exe and alvie sancus-fpga: the models of Sancus, in their format *)
        ("sancus", Alvie_cli.Runner.group (module Sancus_web));
        (* the services in memory only: a browser opens no connection *)
        ("vaultlink", Vaultlink.Commands.group ());
        ("check", check) ] in
  try Command_web.run ~argv:(Host.argv ()) commands with Stdlib.Exit -> ()
