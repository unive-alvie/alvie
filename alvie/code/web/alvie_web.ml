(* alvie-web: the commands of Core for the plugins of ALVIE that run in a browser, with the argv and the simulators
   that the host gives (Host: host.jsoo.ml) *)
module Sancus_web = Alvie_cli.Runner.Make_codec (Sancus_core.Wasm_target.Native) (Sancus_core.Wasm_target.Native.Codec)

let () =
  at_exit Host.on_exit;
  Host.install_sancus ();
  Host.write_files ();
  let commands =
    Core.Command.group ~summary:"ALVIE in the browser"
      [ ("tiny", Alvie_cli.Runner.commands (module Alvie_tiny.Tiny.Native));
        (* with the codec of ALVIE/Sancus, as learn.exe and alvie sancus-fpga: the models of Sancus, in their format *)
        ("sancus", Alvie_cli.Runner.group (module Sancus_web)) ] in
  try Command_web.run ~argv:(Host.argv ()) commands with Stdlib.Exit -> ()
