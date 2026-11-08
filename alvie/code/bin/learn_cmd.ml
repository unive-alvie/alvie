(*
  alvie learn (learn.exe): learns a model of Sancus under an attacker and an enclave spec, with the commands of
  ALVIE/Core (Alvie_cli.Runner) and the codec of Sancus (Sancus.Native.Codec), so that the models and their files
  are those learn.exe always gave. This module keeps the options of learn.exe, their checks and --report.
*)
open Core
open Sancus

module R = Sancus_runner.R

let command =
  Command.basic
    ~summary:"Learns Sancus Mealy machine using the L# algorithm and the specified attacker and enclave spec"
    (let%map_open.Command
    report =
      flag "--report" no_arg ~doc:"Prints a report table with statistics about the learning"
    and dry =
      flag
        "--dry"
        no_arg
        ~doc:"Does everything except learning and substitutes the learned automata with a trivial one"
    and dbg =
      flag
        "--debug"
        no_arg
        ~doc:"Enables debug-level logging"
    and info =
      flag
        "--info"
        no_arg
        ~doc:"Enables info-level logging"
    and enclave_spec_fn =
      flag
        "--encl-spec"
        (required string)
        ~doc:"filename Enclave specification file, using the TestDL language"
    and attacker_spec_fn =
      flag
        "--att-spec"
        (required string)
        ~doc:"filename Attacker specification file, using the TestDL language"
    and resfile =
      flag
        "--res"
        (required string)
        ~doc:"filename File where the final learned model will be stored"
    (* The options of the backend: the configuration parameters of plugins/sancus/alvie-plugin.yaml *)
    and config = Alvie_cli.Config.param (Lazy.force Generic_inputgen.plugin).manifest
    and oracle_name =
    flag
      "--oracle"
      (required string)
      ~doc:"oracle Equivalence oracle: randomwalk, pac, or exhaustive"
    and epsilon =
      flag
        "--epsilon"
        (optional_with_default 0.001 float)
        ~doc:"probability PAC error bound used by the pac oracle (default: 0.001)"
    and pac_bound =
      flag
        "--pac-bound"
        (optional_with_default 1 int)
        ~doc:"count Included in --report output only; does not limit the current PAC oracle (default: 1)"
    and delta =
      flag
        "--delta"
        (optional_with_default 0.001 float)
        ~doc:"probability PAC confidence parameter used by the pac oracle (default: 0.001)"
    and step_limit =
      flag
        "--step-limit"
        (optional_with_default 500 int)
        ~doc:"limit (Only for randomwalk oracle) Maximum number of steps for the equivalence oracle before giving up looking for a counterexample (default: 500)"
    and round_limit =
      flag
        "--round-limit"
        (optional int)
        ~doc:"limit (Only for pac oracle) Maximum number of rounds for the equivalence oracle before giving up looking for a counterexample (default: no limit)"
    and reset_prob =
      flag
        "--reset-probability"
        (optional_with_default 0.05 float)
        ~doc:"probability (Only for randomwalk oracle) Probability for the equivalence oracle to give up the current exploration path and start with a new one. Step count *will not* be reset! (default: 0.05)"
    and bad_prob =
      flag
        "--bad-probability"
        (optional_with_default 0.20 float)
        ~doc:"probability Probability of generating bad observables (i.e. not driven by the specification) during the equivalence check (default: 0.20)"
    and secret =
      flag
        "--secret"
        (optional string)
        ~doc:"value This is the value of the secret. It will be substituted inside the enclave."
    and ignore_interrupts =
      flag
        "--ignore-interrupts"
        no_arg
        ~doc:"Ignores *any* interrupt-scheduling actions from the attacker (i.e., timer_enable)."
(* and precompute =
      flag
      "--precompute"
      no_arg
      ~doc:"Tries to compute all the spec strings beforehand, so filling the observation tree and speeding up the learning (WARNING: may take a long time or fail to terminate!)" *)
    in
    fun () ->
      let tmpdir = Alvie_cli.Config.get_exn config "tmpdir"
      and sancus_core_gap_dir = Alvie_cli.Config.get_exn config "sancus" in
      Cli_diagnostics.protect ~debug:dbg (fun () ->
        (* Learning keeps a large heap alive while allocating many short-lived values: a larger minor
           heap and a less eager major GC make runs ~13% faster (same results). OCAMLRUNPARAM wins. *)
        if Option.is_none (Sys.getenv "OCAMLRUNPARAM") then
          Gc.set { (Gc.get ()) with minor_heap_size = 8 * 1024 * 1024; space_overhead = 200 };
        Logs.set_reporter (Logs_fmt.reporter ());
        if dbg then Logs.set_level (Some Logs.Debug)
        else if info then Logs.set_level (Some Logs.Info)
        else Logs.set_level (Some Logs.App);
        (* The simulator does not want a trailing / in the temporary directory *)
        let tmpdir = Cli_diagnostics.prepare_directory ~option:"--tmpdir" tmpdir in
        let config = List.Assoc.add config ~equal:String.equal "tmpdir" tmpdir in
        ignore (Cli_diagnostics.prepare_directory ~option:"parent directory of --res" (Filename.dirname resfile));
        Cli_diagnostics.validate_learning_options ~oracle:oracle_name ~epsilon ~delta ~step_limit
          ~reset_probability:reset_prob ~bad_probability:bad_prob ~round_limit;
        ignore (Cli_diagnostics.require_directory ~option:"--sancus" sancus_core_gap_dir);
        (* The spec, with the grammar of plugins/sancus; its secret expanded *)
        ignore (Cli_diagnostics.read_file ~option:"--encl-spec" enclave_spec_fn);
        ignore (Cli_diagnostics.read_file ~option:"--att-spec" attacker_spec_fn);
        let core_spec, (Enclave enclave, _, _, _) = Cli_diagnostics.parse_spec_files ~enclave_spec_file:enclave_spec_fn ~attacker_spec_file:attacker_spec_fn in
        Cli_diagnostics.require_secret_if_needed enclave secret;
        let spec = match secret with
          | None -> core_spec
          | Some value ->
            (match Alvie_plugin.Spec.expand_secret (Lazy.force Generic_inputgen.plugin) core_spec ~value with
             | Ok s -> s
             | Error d -> Cli_diagnostics.fail "Could not expand the secret %S: %s." value (Alvie_plugin.Diag.to_string d)) in
        let oracle : R.oracle = match oracle_name with
          | "randomwalk" -> Random_walk { test_count = step_limit; reset_probability = reset_prob }
          | "pac" -> Pac { epsilon; delta; round_limit }
          | _ -> Exhaustive (* validate_learning_options accepts no other *) in
        (* The random walk and the PAC oracle offer an input outside the spec with probability --bad-probability *)
        let bad_probability = match oracle with Exhaustive -> None | Pac _ | Random_walk _ -> Some bad_prob in
        let variant = if ignore_interrupts then Some "no-interrupts" else None in
        let l = R.learn ?bad_probability ~dry ~config ~variant ~spec ~oracle ~seed:0 () in
        if report then
          eprintf "%s, %d, %f, %f, %d, %f, %d, %d, %d, %d, %d, %f, %f, %Ld\n"
            oracle_name pac_bound epsilon delta step_limit reset_prob
            l.stats.resets l.stats.steps l.stats.dry_steps l.stats.queries l.stats.equivalence_queries
            l.stats.avg_length l.stats.var_length
            (Int63.to_int64 (Int63.(/) l.nanoseconds (Int63.of_int 1000000)));
        R.write_model resfile l.model;
        Logs.debug (fun m -> m "\n=== Graph written to %s\n" resfile))
    )
