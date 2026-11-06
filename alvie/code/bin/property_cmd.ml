(*
  alvie property for ALVIE/Sancus: the command of ALVIE/Core (Alvie_cli.Property_cmd) on Sancus models, as fa.exe
  reads them (Fa_cmd.Models), with the view of plugins/sancus.
*)
open Core

module Params () = struct
  let plugin = Lazy.force Sancus.Generic_inputgen.plugin
  let secret_values = [] (* no property here relates two secrets *)
end

let command =
  Alvie_cli.Property_cmd.command ~classify:Cli_diagnostics.classify_failure ~models:(fun () ->
      let module M = Fa_cmd.Models (Params ()) in
      Models {
        load = (fun ~what file -> ignore (Cli_diagnostics.require_file ~option:what file); M.load file);
        inclusion = M.Properties.inclusion;
        equivalence = M.Properties.equivalence;
        formula = M.Properties.formula;
      }) ()
