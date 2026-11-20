(* alvie-web: the commands of Core for the plugins of ALVIE that run in a browser, with the argv of the host *)
module Sancus_web = Alvie_cli.Runner.Make_codec (Sancus_core.Wasm_target.Native) (Sancus_core.Wasm_target.Native.Codec)

let () =
  Sancus_host.install ();
  let argv = "alvie" :: List.tl (Array.to_list Sys.argv) in
  Command_web.run ~argv
    (Core.Command.group ~summary:"ALVIE in the browser"
       [ ("tiny", Alvie_cli.Runner.commands (module Alvie_tiny.Tiny.Native));
         (* with the codec of ALVIE/Sancus, as learn.exe and alvie sancus-fpga: the models of Sancus, in their format *)
         ("sancus", Alvie_cli.Runner.group (module Sancus_web)) ])
