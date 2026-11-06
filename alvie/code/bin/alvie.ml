(*
  alvie: the command line of ALVIE, built with the Sancus plugin.

    alvie learn ...     learns a model (the options of learn.exe; the backend's come from plugins/sancus)
    alvie compare ...   compares the four models of an experiment (fa.exe)
    alvie exec ...      runs a sequence of inputs on the backend (exec.exe)
    alvie pbt ...       property-based testing of two attacker specs (pbt.exe)
    alvie property ...  checks inclusion, equivalence or an mCRL2 formula on learned models
    alvie sancus ...    conformance, fixtures and exec of ALVIE/Core on Sancus
    alvie sancus-fpga ...  the commands of ALVIE/Core on Sancus-FPGA, Sancus on a board (plugins/sancus-fpga)
    alvie tiny ...      the commands of ALVIE/Core on Tiny, the reference platform (plugins/tiny)
    alvie external DIR ...  the same commands on the external plugin in DIR (a program that speaks the protocol)
    alvie plugin check  checks the plugin files; alvie plugin schemas writes their JSON Schemas

  learn.exe, fa.exe, exec.exe and pbt.exe remain, as the same commands, for one release.
*)
open Core

(* alvie external DIR COMMAND ...: the commands of the plugin in DIR, whose options come from its manifest, so they
   are made once DIR is known *)
let external_command () =
  Core.Command.basic ~summary:"The commands of ALVIE/Core on the external plugin in DIR: alvie external DIR learn|compare|property|exec|conformance|fixtures ..."
    ~readme:(fun () -> "An external plugin is a program, in any language, that speaks the protocol of ALVIE/Core (see the Plugin Author Guide). Its manifest (DIR/alvie-plugin.yaml) gives the command that starts it, and its configuration parameters are options of these commands.")
    (Core.Command.Param.return (fun () ->
         eprintf "Usage: alvie external DIR COMMAND [OPTIONS]  (alvie external DIR -help lists the commands)\n";
         Stdlib.exit 2))

let run_external dir rest =
  Alvie_cli.Errors.protect ~debug:false (fun () ->
      let dir = Alvie_cli.Errors.require_directory ~option:"alvie external DIR" dir in
      match Alvie_plugin.Plugin.load dir with
      | Error ds ->
        Alvie_cli.Errors.fail "the plugin in %s has %d problem%s:\n%s" dir (List.length ds) (if List.length ds = 1 then "" else "s") (Alvie_plugin.Diag.list_to_string ds)
      | Ok p when Poly.equal p.manifest.kind Alvie_plugin.Manifest_file.Native ->
        Alvie_cli.Errors.fail "the plugin in %s is native: it is built into a program of its own (alvie-%s), not run with alvie external." dir p.manifest.name
      | Ok _ -> ());
  Command_unix.run ~version:Alvie_cli.Version.version ~argv:(("alvie external " ^ dir) :: rest)
    (Alvie_cli.Runner.commands (Alvie_rpc.Rpc_backend.native ~dir))

let () =
  match Array.to_list (Sys.get_argv ()) with
  | _ :: "external" :: dir :: rest when not (String.is_prefix dir ~prefix:"-") -> run_external dir rest
  | _ ->
  Command_unix.run ~version:Alvie_cli.Version.version
    (Core.Command.group ~summary:"ALVIE: learn models of a system and compare them to find information leaks"
       [ ("learn", Learn_cmd.command);
         ("compare", Fa_cmd.command);
         ("exec", Exec_cmd.command);
         ("pbt", Pbt_cmd.command);
         ("property", Property_cmd.command);
         ("sancus", Alvie_cli.Runner.group ~only:[ "conformance"; "fixtures"; "exec" ]
                      ~summary:"The commands of ALVIE/Core on Sancus: conformance of the simulator, and the fixtures (learn and compare are the commands above)"
                      (module Sancus_runner.R));
         ("sancus-fpga", Alvie_cli.Runner.group
                           ~summary:"The commands of ALVIE/Core on Sancus-FPGA: Sancus on an openMSP430/Sancus board, with the specs of ALVIE/Sancus (see docs/sancus/fpga.md)"
                           (module Sancus_runner.Fpga_r));
         ("tiny", Alvie_cli.Runner.commands (module Alvie_tiny.Tiny.Native));
         ("external", external_command ());
         ("plugin", Alvie_cli.Plugin_cmd.command ~default:(lazy (Ok (Lazy.force Sancus.Generic_inputgen.plugin)))) ])
