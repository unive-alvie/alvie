(*
  alvie: the command line of ALVIE, built with the Sancus plugin.

    alvie learn ...     learns a model (the options of learn.exe; the backend's come from plugins/sancus)
    alvie compare ...   compares the four models of an experiment (fa.exe)
    alvie exec ...      runs a sequence of inputs on the backend (exec.exe)
    alvie pbt ...       property-based testing of two attacker specs (pbt.exe)
    alvie property ...  checks inclusion, equivalence or an mCRL2 formula on learned models
    alvie plugin check  checks the plugin files; alvie plugin schemas writes their JSON Schemas

  learn.exe, fa.exe, exec.exe and pbt.exe remain, as the same commands, for one release.
*)
let () =
  Command_unix.run ~version:"2026.10"
    (Core.Command.group ~summary:"ALVIE: learn models of a system and compare them to find information leaks"
       [ ("learn", Learn_cmd.command);
         ("compare", Fa_cmd.command);
         ("exec", Exec_cmd.command);
         ("pbt", Pbt_cmd.command);
         ("property", Property_cmd.command);
         ("plugin", Alvie_cli.Plugin_cmd.command ~default:(lazy (Ok (Lazy.force Sancus.Generic_inputgen.plugin)))) ])
