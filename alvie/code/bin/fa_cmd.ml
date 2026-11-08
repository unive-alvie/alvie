(*
  fa.exe: compares the four models of an experiment (secret 0 and 1, with and without interrupts): noninterference
  of the models with interrupts, with those without interrupts as the baseline. It is the compare command of
  ALVIE/Core (Alvie_cli.Runner) on Sancus, whose models it reads with the codec of Sancus; this module keeps the
  options and the output of fa.exe.
*)
open Core

(* The model name used in the logs: the file name without the directory and the .dot extension *)
let filename s = String.chop_suffix_if_exists (Filename.basename s) ~suffix:".dot"

(* The secret of a model, from its name: <commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-int|-nint].dot *)
let secret_of_name file =
  let parts = String.split (filename file) ~on:'-' in
  let parts = match List.rev parts with ("int" | "nint") :: rest -> List.rev rest | _ -> parts in
  match List.rev parts with
  | _delta :: _eps :: secret :: _ -> Some secret
  | _ -> None

let compare ~secret_values ~tmpdir ~cex_file ~limit ~m1_int_file ~m2_int_file ~m1_nint_file ~m2_nint_file =
  let baseline = match m1_nint_file, m2_nint_file with Some a, Some b -> Some (a, b) | _ -> None in
  let count, write =
    Sancus_runner.R.noninterference ~what:("--m1-int", "--m2-int", "--m1-nint", "--m2-nint") ~secrets:secret_values ~tmpdir ~limit
      ~m1:m1_int_file ~m2:m2_int_file ~baseline () in
  write (sprintf "%s_int.dot" cex_file);
  Logs.info (fun m -> m "\n\n=== Results: found %d FA violations. See %s_int.dot for details." count cex_file)

let command =
  Command.basic
    ~summary:"Given two Sancus models compares them using mCRL2 and shows witnesses of non-equivalence."
    (let%map_open.Command
      cex_file = flag "--witness-file-basename" (required string) ~doc:"file The file the counterexamples will be written to (in LTS form, dot file)"
      and dbg = flag "--debug" no_arg ~doc:"Enables debug-level logging"
      and m1_int_file = flag "--m1-int" (required string) ~doc:"filename Uses the specified dot file as the first model with interrupts in the comparison"
      and m2_int_file = flag "--m2-int" (required string) ~doc:"filename Uses the specified dot file as the second model with interrupts in the comparison"
      and m1_nint_file = flag "--m1-nint" (optional string) ~doc:"filename Uses the specified dot file as the first model w/o interrupts in the comparison"
      and m2_nint_file = flag "--m2-nint" (optional string) ~doc:"filename Uses the specified dot file as the second model w/o interrupts in the comparison"
      and tmpdir = flag "--tmpdir" (required string) ~doc:"directory Temporary directory where intermediate results will be stored"
      and limit = flag "--cex-limit" (optional int) ~doc:"limit Maximum number of counterexamples to extract before giving up (default: no limit)"
      and secrets = flag "--secrets" (optional string)
          ~doc:"s1,s2 The values of the secret in the first and the second model (default: from the model names, <commit>-<attacker>-<enclave>-<secret>-...)"
      in
      fun () ->
        Cli_diagnostics.protect ~debug:dbg (fun () ->
        (if dbg then Logs.set_level (Some Logs.Debug) else Logs.set_level (Some Logs.App));
        Logs.set_reporter (Logs_fmt.reporter ());
        let tmpdir = Cli_diagnostics.prepare_directory ~option:"--tmpdir" tmpdir in
        let cex_dir = Filename.dirname cex_file in
        Logs.info (fun m -> m "Result directory: %s" cex_dir);
        ignore (Cli_diagnostics.prepare_directory ~option:"parent directory of --witness-file-basename" cex_dir);
        ignore (Cli_diagnostics.require_file ~option:"--m1-int" m1_int_file);
        ignore (Cli_diagnostics.require_file ~option:"--m2-int" m2_int_file);
        Cli_diagnostics.require_optional_pair ~first_option:"--m1-nint" m1_nint_file ~second_option:"--m2-nint" m2_nint_file;
        Option.iter m1_nint_file ~f:(fun path -> ignore (Cli_diagnostics.require_file ~option:"--m1-nint" path));
        Option.iter m2_nint_file ~f:(fun path -> ignore (Cli_diagnostics.require_file ~option:"--m2-nint" path));
        Option.iter limit ~f:(fun value -> Cli_diagnostics.validate_positive ~option:"--cex-limit" value);
        let secret_values = match secrets with
          | Some s -> String.split s ~on:','
          | None ->
            (match secret_of_name m1_int_file, secret_of_name m2_int_file with
             | Some a, Some b -> [ a; b ]
             | _ -> Cli_diagnostics.fail "Cannot tell the secrets of the models from their names: give them with --secrets s1,s2.") in
        compare ~secret_values ~tmpdir ~cex_file ~limit ~m1_int_file ~m2_int_file ~m1_nint_file ~m2_nint_file))
