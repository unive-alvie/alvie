(*
  alvie property: checks a property of the catalogue of ALVIE/Core (Ltscompare.Properties, version 1) on learned
  models, as the attacker sees them (the plugin's view).

    property inclusion M1 M2      every trace of M1 is one of M2 (else: a trace of M1 that M2 does not have)
    property equivalence M1 M2    inclusion both ways (else: a trace of one model only, and which)
    property formula M -f F.mcf   M satisfies the mCRL2 modal mu-calculus formula of F.mcf

  Noninterference, the fourth property of the catalogue, is the compare command. The exit status is 0 when the
  property holds, 4 when it does not, and 2 for a mistake in the command or the files.

  The command is the same for every plugin: a plugin gives how to read its models and the properties on them
  (models), made when the command runs, so that nothing is loaded before.
*)
open Core

type models =
  | Models : {
      load : what:string -> string -> 'm; (* checks the file *)
      inclusion : tmpdir:string -> 'm -> 'm -> string list option;
      equivalence : tmpdir:string -> 'm -> 'm -> [ `Equivalent | `Only_in_first of string list | `Only_in_second of string list ];
      formula : tmpdir:string -> 'm -> formula_file:string -> (bool, string) Result.t;
    } -> models

(* classify: the plugin's failures (Errors.protect) *)
let run ?classify ~debug ~tmpdir f =
  let holds = Errors.protect ?classify ~debug (fun () ->
      Errors.setup_logs ~debug;
      f ~tmpdir:(Errors.prepare_directory ~option:"--tmpdir" tmpdir)) in
  if not holds then Stdlib.exit Errors.does_not_hold

let print_trace trace = List.iter trace ~f:(fun l -> printf "  %s\n" l)

let common =
  let open Command.Param in
  map2 (flag "--tmpdir" (optional_with_default "/tmp/alvie" string) ~doc:"dir directory for the files of mCRL2 (default: /tmp/alvie)")
    (flag "--debug" no_arg ~doc:" debug-level logging; keep the files of mCRL2")
    ~f:(fun tmpdir debug -> (tmpdir, debug))

let two_models = Command.Param.(both (anon ("M1" %: string)) (anon ("M2" %: string)))

let command ?classify ~(models : unit -> models) () =
  let inclusion =
    Command.basic ~summary:"Check that every trace of model M1 is a trace of model M2"
      (let%map_open.Command (m1, m2) = two_models and tmpdir, debug = common in
       fun () ->
         run ?classify ~debug ~tmpdir (fun ~tmpdir ->
             let (Models m) = models () in
             let a = m.load ~what:"M1" m1 and b = m.load ~what:"M2" m2 in
             match m.inclusion ~tmpdir a b with
             | None -> printf "holds: every trace of %s is one of %s\n" m1 m2; true
             | Some trace -> printf "does not hold: a trace of %s that %s does not have:\n" m1 m2; print_trace trace; false)) in
  let equivalence =
    Command.basic ~summary:"Check that models M1 and M2 have the same traces"
      (let%map_open.Command (m1, m2) = two_models and tmpdir, debug = common in
       fun () ->
         run ?classify ~debug ~tmpdir (fun ~tmpdir ->
             let (Models m) = models () in
             let a = m.load ~what:"M1" m1 and b = m.load ~what:"M2" m2 in
             match m.equivalence ~tmpdir a b with
             | `Equivalent -> printf "holds: %s and %s have the same traces\n" m1 m2; true
             | `Only_in_first trace -> printf "does not hold: a trace of %s only:\n" m1; print_trace trace; false
             | `Only_in_second trace -> printf "does not hold: a trace of %s only:\n" m2; print_trace trace; false)) in
  let formula =
    Command.basic ~summary:"Check that model M satisfies an mCRL2 modal mu-calculus formula"
      (let%map_open.Command m = anon ("M" %: string)
       and formula_file = flag "--formula" ~aliases:[ "-f" ] (required string) ~doc:"file the formula (.mcf); its actions are the labels of the model, see actions.txt with --debug"
       and tmpdir, debug = common in
       fun () ->
         run ?classify ~debug ~tmpdir (fun ~tmpdir ->
             let (Models ms) = models () in
             let model = ms.load ~what:"M" m in
             let formula_file = Errors.require_file ~option:"--formula" formula_file in
             match ms.formula ~tmpdir model ~formula_file with
             | Ok true -> printf "holds: %s satisfies %s\n" m formula_file; true
             | Ok false -> printf "does not hold: %s does not satisfy %s\n" m formula_file; false
             | Error message -> Errors.fail "%s" message)) in
  Command.group ~summary:"Check a property of the catalogue (inclusion, equivalence, a formula) on learned models"
    ~readme:(fun () -> "Exit status: 0 when the property holds, 4 when it does not, 2 for a mistake in the command or the files.\nNoninterference is the compare command.")
    [ ("inclusion", inclusion); ("equivalence", equivalence); ("formula", formula) ]
