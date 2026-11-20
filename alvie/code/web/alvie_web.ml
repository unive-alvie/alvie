(*
  alvie-web: the commands of Core for the plugins of ALVIE that run in a browser.

  The host may give, as JavaScript globals, before the program starts:
  - alvieArgv: the arguments of the command (an array of strings; default: the argv of the program, as in Node);
  - alvieFiles: files to write before the command runs, an object from path to text (e.g. the specs that the command
    reads, in a page where there is no other file system);
  - alvieCollect: paths of files to read when the command ends (e.g. the model it learned);
  - alvieDone(files): called when the command ends (its output says how), with the files of alvieCollect that exist,
    as an object from path to text.
  The host of the simulators of ALVIE/Sancus is globalThis.alvieSancus (Sancus_host).
*)
open Js_of_ocaml

module Sancus_web = Alvie_cli.Runner.Make_codec (Sancus_core.Wasm_target.Native) (Sancus_core.Wasm_target.Native.Codec)

let global name : Js.Unsafe.any Js.Optdef.t = Js.Unsafe.get Js.Unsafe.global (Js.string name)

let argv () =
  match Js.Optdef.to_option (global "alvieArgv") with
  | Some a -> "alvie" :: List.map Js.to_string (Array.to_list (Js.to_array (Js.Unsafe.coerce a)))
  | None -> "alvie" :: List.tl (Array.to_list Sys.argv)

let write_files () =
  Js.Optdef.iter (global "alvieFiles") (fun files ->
      let keys : Js.js_string Js.t Js.js_array Js.t = Js.object_keys (Js.Unsafe.coerce files) in
      Array.iter (fun key ->
          let path = Js.to_string key and text : Js.js_string Js.t = Js.Unsafe.get files key in
          Sancus_core.Step.mkdir_p (Filename.dirname path);
          Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc (Js.to_string text)))
        (Js.to_array keys))

let () =
  at_exit (fun () ->
      Js.Optdef.iter (global "alvieDone") (fun f ->
          let collected = Js.Unsafe.obj [||] in
          Js.Optdef.iter (global "alvieCollect") (fun paths ->
              Array.iter (fun p ->
                  let path = Js.to_string p in
                  if Sys.file_exists path then
                    Js.Unsafe.set collected p (Js.string (In_channel.with_open_bin path In_channel.input_all)))
                (Js.to_array (Js.Unsafe.coerce paths)));
          ignore (Js.Unsafe.fun_call f [| Js.Unsafe.inject collected |])));
  Sancus_host.install ();
  write_files ();
  let commands =
    Core.Command.group ~summary:"ALVIE in the browser"
      [ ("tiny", Alvie_cli.Runner.commands (module Alvie_tiny.Tiny.Native));
        (* with the codec of ALVIE/Sancus, as learn.exe and alvie sancus-fpga: the models of Sancus, in their format *)
        ("sancus", Alvie_cli.Runner.group (module Sancus_web)) ] in
  try Command_web.run ~argv:(argv ()) commands with Stdlib.Exit -> ()
