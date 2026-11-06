(*
  alvie property: checks a property of the catalogue of ALVIE/Core (Ltscompare.Properties, version 1) on learned
  models, as the attacker sees them (the view of plugins/sancus).

    alvie property inclusion M1 M2      every trace of M1 is one of M2 (else: a trace of M1 that M2 does not have)
    alvie property equivalence M1 M2    inclusion both ways (else: a trace of one model only, and which)
    alvie property formula M -f F.mcf   M satisfies the mCRL2 modal mu-calculus formula of F.mcf

  Noninterference, the fourth property of the catalogue, is alvie compare. The exit status is 0 when the property
  holds, 4 when it does not, and that of the other commands on errors (2 for a mistake in the command or the files).
*)
open Core

let does_not_hold = 4

module Params () = struct
  let plugin = Lazy.force Sancus.Generic_inputgen.plugin
  let secret_values = [] (* no property here relates two secrets *)
end

let run ~debug ~tmpdir f =
  Cli_diagnostics.protect ~debug (fun () ->
      Logs.set_level (Some (if debug then Logs.Debug else Logs.Warning));
      Logs.set_reporter (Logs_fmt.reporter ());
      f ~tmpdir:(Cli_diagnostics.prepare_directory ~option:"--tmpdir" tmpdir))
  |> fun holds -> if not holds then Stdlib.exit does_not_hold

let print_trace trace =
  List.iter trace ~f:(fun l -> printf "  %s\n" l)

let common =
  let open Command.Param in
  map2 (flag "--tmpdir" (optional_with_default "/tmp/alvie" string) ~doc:"dir directory for the files of mCRL2 (default: /tmp/alvie)")
    (flag "--debug" no_arg ~doc:" debug-level logging; keep the files of mCRL2")
    ~f:(fun tmpdir debug -> (tmpdir, debug))

let two_models = Command.Param.(both (anon ("M1" %: string)) (anon ("M2" %: string)))

let inclusion =
  Command.basic ~summary:"Check that every trace of model M1 is a trace of model M2"
    (let%map_open.Command (m1, m2) = two_models and tmpdir, debug = common in
     fun () ->
       run ~debug ~tmpdir (fun ~tmpdir ->
           let module M = Fa_cmd.Models (Params ()) in
           let load ~what file = ignore (Cli_diagnostics.require_file ~option:what file); M.load file in
           let a = load ~what:"M1" m1 and b = load ~what:"M2" m2 in
           match M.Properties.inclusion ~tmpdir a b with
           | None -> printf "holds: every trace of %s is one of %s\n" m1 m2; true
           | Some trace -> printf "does not hold: a trace of %s that %s does not have:\n" m1 m2; print_trace trace; false))

let equivalence =
  Command.basic ~summary:"Check that models M1 and M2 have the same traces"
    (let%map_open.Command (m1, m2) = two_models and tmpdir, debug = common in
     fun () ->
       run ~debug ~tmpdir (fun ~tmpdir ->
           let module M = Fa_cmd.Models (Params ()) in
           let load ~what file = ignore (Cli_diagnostics.require_file ~option:what file); M.load file in
           let a = load ~what:"M1" m1 and b = load ~what:"M2" m2 in
           match M.Properties.equivalence ~tmpdir a b with
           | `Equivalent -> printf "holds: %s and %s have the same traces\n" m1 m2; true
           | `Only_in_first trace -> printf "does not hold: a trace of %s only:\n" m1; print_trace trace; false
           | `Only_in_second trace -> printf "does not hold: a trace of %s only:\n" m2; print_trace trace; false))

let formula =
  Command.basic ~summary:"Check that model M satisfies an mCRL2 modal mu-calculus formula"
    (let%map_open.Command m = anon ("M" %: string)
     and formula_file = flag "--formula" ~aliases:[ "-f" ] (required string) ~doc:"file the formula (.mcf); its actions are the labels of the model, see actions.txt with --debug"
     and tmpdir, debug = common in
     fun () ->
       run ~debug ~tmpdir (fun ~tmpdir ->
           let module M = Fa_cmd.Models (Params ()) in
           let load ~what file = ignore (Cli_diagnostics.require_file ~option:what file); M.load file in
           let model = load ~what:"M" m in
           let formula_file = Cli_diagnostics.require_file ~option:"--formula" formula_file in
           match M.Properties.formula ~tmpdir model ~formula_file with
           | Ok true -> printf "holds: %s satisfies %s\n" m formula_file; true
           | Ok false -> printf "does not hold: %s does not satisfy %s\n" m formula_file; false
           | Error message -> Cli_diagnostics.fail "%s" message))

let command =
  Command.group ~summary:"Check a property of the catalogue (inclusion, equivalence, a formula) on learned models"
    ~readme:(fun () -> "Exit status: 0 when the property holds, 4 when it does not, 2 for a mistake in the command or the files.\nNoninterference is alvie compare.")
    [ ("inclusion", inclusion); ("equivalence", equivalence); ("formula", formula) ]
