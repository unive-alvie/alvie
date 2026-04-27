open Core
open Learninglib.Lsharp
open Sancus
open Interop

open Attacker
open Enclave

module IOInteropInternal = Interop (Sancus.Input) (Sancus.Output_internal)

module IIBLSharpRW = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Randomwalkoracle.RandomWalkOracle)
module IIBLSharpPAC = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Pacoracle.PACOracle)
module IIBLSharpExh = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Exhaustiveoracle.ExhaustiveOracle)
module IIBLSharpIncrExh = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Incrementalexhoracle.IncrementalExhOracle)
(* module IIBLSharpHybrid = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Hybridoracle.HybridOracle) *)

module RWOracle = Learninglib.Randomwalkoracle.RandomWalkOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog)
module PACOracle = Learninglib.Pacoracle.PACOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog)
module ExhaustiveOracle = Learninglib.Exhaustiveoracle.ExhaustiveOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog)
module IncrementalOracle = Learninglib.Incrementalexhoracle.IncrementalExhOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog)
(* module HybridOracle = Learninglib.Hybridoracle.HybridOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) *)

let spec_parse_or_fail spec =
  match Testdl.Parser.parse_spec spec with
  | Result.Ok r -> r
  | Result.Error e -> failwith e

let filter_model (m : IOInteropInternal.IIOMealy.t) =
  let _filtered_transition = Map.filteri
    m.transition
    ~f:(fun ~key ~data ->
          match key, data with
          | (_, Input.INoInput), _ | _, (([Output_internal.OIllegal], _, _), _) -> false
          | _ -> true
    ) in
  let _filtered_states = Set.filter
    m.states
    ~f:(fun s ->
      (* Returns true if the state appears in at least one transition *)
      Map.existsi
      _filtered_transition
      ~f:(fun ~key:(s', _) ~data:(_, s'') -> s' = s || s'' = s)
    ) in
  { m with transition = _filtered_transition; states = _filtered_states }

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
    and tmpdir =
      flag
        "--tmpdir"
        (required string)
        ~doc:"directory Temporary directory where intermediate results will be stored"
    and resfile =
      flag
        "--res"
        (required string)
        ~doc:"filename File where the final learned model will be stored"
    and sancus_core_gap_dir =
      flag
        "--sancus"
        (required string)
        ~doc:"directory Directory where the sancus-core-gap repository was cloned"
    and sancus_master_key =
      flag
        "--sancus-master-key"
        (optional_with_default "cafe" string)
        ~doc:"key A hex number to be used as the master key when building the processor (default: cafe)"
    and commit =
      flag
        "--commit"
        (optional_with_default "ef753b6" string)
        ~doc:"checksum/label Checksum/label of the commit for which we want to learn the Mealy model (default: ef753b6, i.e., the version w/o Mind the Gap mitigations)"
    and oracle_name =
    flag
      "--oracle"
      (required string)
      ~doc:"oracle Oracle that must be used for equivalence check, choose among: randomwalk, pac, pacprefix"
    and epsilon =
      flag
        "--epsilon"
        (optional_with_default 0.001 float)
        ~doc:"bound (Only for pac_bound and pac_unbound oracles) Upper bound on the probability we find a defect in the model (default: 0.001)"
    and pac_bound =
      flag
        "--pac-bound"
        (optional_with_default 1 int)
        ~doc:"bound (Only for pac_bound and pac_unbound oracles) Maximum number of resets before stopping (default: 1)"
    and delta =
      flag
        "--delta"
        (optional_with_default 0.001 float)
        ~doc:"bound (Only for pac_bound and pac_unbound oracles) 1-delta is the upper bound on the confidence we want on the fact we find a defect with probability epsilon (default: 0.001)"
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
        (* Random.self_init (); *)
        Random.init 0;
        Logs.set_reporter (Logs_fmt.reporter ());

        if dbg then Logs.set_level (Some Logs.Debug)
        else if info then Logs.set_level (Some Logs.Info)
        else Logs.set_level (Some Logs.App);

        let cwd = Sys_unix.getcwd () in
        (* Logs.debug (fun m -> m "Current directory: %s" cwd); *)
        (* Create tmpdir if not present *)
        (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
        let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
        (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
        (* Create resultdir if not present *)
        let resdir = String.drop_suffix resfile (String.length (List.last_exn (String.split resfile ~on:'/'))) in
        (* Logs.debug (fun m -> m "Result directory: %s" resdir); *)
        (match Sys_unix.file_exists resdir with | `No -> Core_unix.mkdir_p resdir | _ -> ());
        (* Basic sanity checks on the repo *)
        assert (Sys_unix.file_exists_exn sancus_core_gap_dir);
        assert (Sys_unix.is_directory_exn sancus_core_gap_dir);
        (* (1) load the spec *)
        let enclave_spec_str = In_channel.read_all enclave_spec_fn in
        let attacker_spec_str = In_channel.read_all attacker_spec_fn in
        Logs.debug (fun m -> m "Enclave spec: %s" enclave_spec_str);
        Logs.debug (fun m -> m "Attacker spec: %s" attacker_spec_str);
        let spec_w_secret = spec_parse_or_fail (enclave_spec_str ^ " " ^ attacker_spec_str) in
        let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = spec_w_secret in
        (* Secret must be expanded *)
        let enclave = match secret with | None -> assert (not (Enclave.has_secret enclave)); enclave | Some secret -> Enclave.expand_secret secret enclave in
        let complete_spec = let open Testdl in (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) in
        let spec_dfa = Inputgen.build_spec_dfa complete_spec in
        (* (2) initialize the interface with the processor's implementation *)
        let sul =
          Sancus.Verilog.make
            ~workingdir:cwd
            ~tmpdir:tmpdir
            ~basename:"generic"
            ~verilog_compile: (cwd ^ "/../scripts/verilog_compile")
            ~get_symbolpos: (cwd ^ "/../scripts/get_symbolpos.sh")
            ~pmem_elf:"pmem.elf"
            ~pmem_script:(cwd ^ "/../scripts/build_pmem")
            ~simulate_script:(cwd ^ "/../scripts/simulate")
            ~submitfile:(cwd ^ "/../src/submit.f")
            ~sancus_repo:sancus_core_gap_dir
            ~sancus_master_key:sancus_master_key
            ~commit:commit
            ~templatefile:(cwd ^ "/../src/generic_template.s43")
            ~filledfile:"generic.s43"
            ~dumpfile:"tb_openMSP430.vcd"
            ~initial_spec:spec_dfa
            ~ignore_interrupts:ignore_interrupts
            () in
        (* (3) prepare the oracle *)
        let attacker_atoms =
          List.fold [isr; prepare; cleanup] ~init:[] ~f:(fun acc b -> acc @ (Set.to_list (Attacker.get_atoms b))) in
        let enclave_atoms = Set.to_list (Enclave.get_atoms enclave) in
        let alphabet_attacker = List.map attacker_atoms ~f:(fun ca -> Input.IAttacker ca) in
        let alphabet_enclave = List.map enclave_atoms ~f:(fun i -> Input.IEnclave i) in
        let complete_input_alphabet = Input.INoInput :: alphabet_attacker @ alphabet_enclave in
        let
          (outputquery_cnt, equivquery_cnt, sul_reset_cnt, sul_step_cnt, sul_step_dry_cnt, avg_len, sigmasq_len), time, learned =
          if String.equal oracle_name "randomwalk" then
            let oracle = (RWOracle.make
                ~step_limit:step_limit
                ~reset_prob:reset_prob
                ~next_input:(fun _ il ol ->
                  (* Generates a good input with probablility 1 - bad_prob, a random one with probability bad_prob *)
                  if Float.(<=) (Random.float_range 0.0 1.0) bad_prob then
                    List.random_element_exn complete_input_alphabet
                  else
                    match Inputgen.generate_next spec_dfa il ol with
                    | `Stop -> Input.INoInput
                    | `Next i -> i
                  )
              (* ~next_input:(fun _ _ _ -> List.random_element_exn complete_input_alphabet) *)
              (* ~matchable:(fun i il ol -> snd (Inputgen.matchable spec_dfa i il ol))  *)
              ()) in
              (* (4) learn *)
              let start = Time_now.nanoseconds_since_unix_epoch () in
              let learned =
                if dry then
                  IOInteropInternal.IIOMealy.make
                    ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                    ~s0:0
                    ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                    ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
                else
                  IIBLSharpRW.lsharp_run oracle sul complete_input_alphabet in
              let open Int63 in
              RWOracle.get_stats oracle,
              Time_now.nanoseconds_since_unix_epoch () - start,
              learned
          (* else if String.equal oracle_name "pac_unbound" then
            let oracle = PACOracle.make
                ~epsilon:epsilon
                ~delta:delta
                ~next_input:(fun _ il ol ->
                  Inputgen.generate_next
                    ~choose:(fun il ol options ->
                        let ol_includes o = List.exists ol ~f:(fun oi -> List.mem (fst3 oi) ~equal:Poly.equal o) in
                        if (
                          ol_includes Output_internal.OIllegal ||
                          ol_includes Output_internal.OUnsupported) then
                            failwith (sprintf "Shouldn't happen:\n%s\n%s" (List.to_string ~f:Input.show il) (List.to_string ~f:Output_internal.show ol))
                        else
                          let options' = (match List.last ol with | Some o when List.mem ~equal:Output_internal.equal_element_t (fst3 o) Output_internal.OReset -> `Stop::options | _ -> options) in
                        (match List.random_element options' with
                        | None -> `Stop
                        | Some i -> i)
                    )
                    spec_dfa il ol)
                () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpPAC.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            PACOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned
          else if String.equal oracle_name "pac_invexp" then
            let oracle = PACOracle.make
                ~epsilon:epsilon
                ~delta:delta
                ~next_input:(fun _ il ol ->
                  Inputgen.generate_next
                    ~choose:(fun _ ol options ->
                      let ol_includes o = List.exists ol ~f:(fun oi -> List.mem (fst3 oi) ~equal:Poly.equal o) in
                      let ol_cnt o = Float.of_int (List.count ol ~f:(fun oi -> List.mem (fst3 oi) ~equal:Poly.equal o)) in
                      let is_last_reset ol = (match List.last ol with | Some o when List.mem ~equal:Output_internal.equal_element_t (fst3 o) Output_internal.OReset -> true | _ -> false) in
                      if (ol_includes Output_internal.OIllegal ||
                        (* ol_includes Output_internal.OMaybeDiverge || *)
                        ol_includes Output_internal.OUnsupported) then
                          failwith (sprintf "Shouldn't happen:\n%s\n%s" (List.to_string ~f:Input.show il) (List.to_string ~f:Output_internal.show ol))
                      else
                        (let open Float in
                          (* If trace is not complete or we picked "next" with decreasing prob, we go next *)
                          (if (not (is_last_reset ol)) || Random.float_range 0.0 1.0 <=
                              (1.0 /. (2.0 ** (ol_cnt Output_internal.OReset))) then
                                (match List.random_element options with
                                | None -> `Stop
                                | Some i -> i)
                          else
                              `Stop)
                        )
                  )
                    spec_dfa il ol)
                () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpPAC.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            PACOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned *)
          else if String.equal oracle_name "pac" then
            let oracle = PACOracle.make
                ?round_limit
                ~epsilon:epsilon
                ~delta:delta
                ~next_input:(fun _ il ol ->
                  (* Generates a good input with probablility 1 - bad_prob, a random one with probability bad_prob *)
                  if Float.(<=) (Random.float_range 0.0 1.0) bad_prob then
                    `Next (List.random_element_exn complete_input_alphabet)
                  else
                    Inputgen.generate_next spec_dfa il ol
                )
                (* ~next_input:(fun _ il ol ->
                  if List.mem (List.concat (List.map ~f:fst3 ol)) OIllegal ~equal:Output_internal.equal_element_t then
                    `Stop
                  else
                    List.random_element_exn (List.map ~f:(fun i -> `Next i) complete_input_alphabet)
                  (* Inputgen.generate_next
                    ~choose:(fun _ ol options ->
                        let ol_includes o = List.count ol ~f:(fun oi -> List.mem (fst3 oi) ~equal:Poly.equal o) >= pac_bound in
                        let is_last_reset ol = (match List.last ol with | Some o when List.mem ~equal:Output_internal.equal_element_t (fst3 o) Output_internal.OReset -> true | _ -> false) in
                        if (ol_includes Output_internal.OReset && is_last_reset ol) then
                            `Stop
                        else
                        (match List.random_element options with
                          | None -> `Stop
                          | Some i -> i)
                    )
                    spec_dfa il ol *)
                  ) *)
                () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpPAC.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            PACOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned
          else if String.equal oracle_name "exhaustive" then
            (* Exhaustive tries them all! *)
            let oracle = ExhaustiveOracle.make
            ~next_options:(
              fun _ _ ->
                List.map ~f:(fun i -> `Next i) complete_input_alphabet
                (* These are the legal options
                let spec_dfa', options = Inputgen.get_options spec_dfa is os in
                (* These are the "illegal" ones *)
                let illegal =
                  List.map ~f:(fun i -> `Next i) (match spec_dfa'.mode with
                  | `Finished | `Invalid -> []
                  | `Enclave -> alphabet_attacker
                  | _ -> alphabet_enclave) in
                (*
                  We also try the illegal options when looking for a counterexample,
                  so that we avoid "wrong" state merging
                *)
                illegal@options *)
            )
            ~stop_cond:(fun available is os ->
              List.is_empty available ||
              List.mem is (INoInput) ~equal:Input.equal ||
              (* List.mem is (IAttacker CRstNZ) ~equal:Input.equal ||
              List.mem is (IAttacker CRst) ~equal:Input.equal || *)
              List.mem (List.concat (List.map os ~f:fst3)) (Output_internal.OIllegal) ~equal:Output_internal.equal_element_t
            )
            () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpExh.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            ExhaustiveOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned
       (*    else if String.equal oracle_name "incremental" then
            let oracle = IncrementalOracle.make
            ~next_options:(fun is os -> snd (Inputgen.get_options spec_dfa is os))
            ~stop_cond:(fun available is _ -> List.is_empty available ||
            List.mem is (INoInput) ~equal:Input.equal ||
            List.mem is (IAttacker CRstNZ) ~equal:Input.equal ||
            List.mem is (IAttacker CRst) ~equal:Input.equal)
            () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpIncrExh.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            IncrementalOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned *)
          (* else if String.equal oracle_name "hybrid" then
            let oracle = HybridOracle.make
            ~step_limit:step_limit
            ~reset_prob:reset_prob
            ~next_input:(fun _ il ol ->
              match Inputgen.generate_next spec_dfa il ol with
              | `Stop -> Input.INoInput
              | `Next i -> i
            )
            () in
            (* (4) learn *)
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned =
              if dry then
                IOInteropInternal.IIOMealy.make
                  ~states:(IOInteropInternal.IIOMealy.SSet.singleton 0)
                  ~s0:0
                  ~input_alphabet:IOInteropInternal.IIOMealy.ISet.empty
                  ~transition:IOInteropInternal.IIOMealy.TransitionMap.empty
              else
                IIBLSharpHybrid.lsharp_run oracle sul complete_input_alphabet in
            let open Int63 in
            HybridOracle.get_stats oracle,
            Time_now.nanoseconds_since_unix_epoch () - start,
            learned *)
          else failwith "Unknown oracle!"
        in
        (* and, finally, (5) to produce the output *)
        if report then
          eprintf "%s, %d, %f, %f, %d, %f, %d, %d, %d, %d, %d, %f, %f, %Ld\n"
            oracle_name
            pac_bound
            epsilon
            delta
            step_limit
            reset_prob
            sul_reset_cnt
            sul_step_cnt
            sul_step_dry_cnt
            outputquery_cnt
            equivquery_cnt
            avg_len
            sigmasq_len
            (Int63.to_int64 (Int63.(/) time (Int63.of_int 1000000)));
          (* Logs.app (fun m -> m
              (
              "\n===  STATS FOR [%s] ===\
              \n+-----------------------+--------+\
              \n| # Resets              | %6d |\
              \n| # SUL steps (non-dry) | %6d |\
              \n| # SUL steps (dry)     | %6d |\
              \n| # output_query calls  | %6d |\
              \n| # equiv_query calls   | %6d |\
              \n| Avg. path len         | %6f |\
              \n+-----------------------+--------+\n")
                (List.last_exn (String.split resfile ~on:'/'))
                sul_reset_cnt
                sul_step_cnt
                sul_step_dry_cnt
                outputquery_cnt
                equivquery_cnt
                avgpath_len
            ) else (printf "\n"); *)
        let final_model = filter_model learned in
        let graph = IOInteropInternal.dot_of_t final_model in
        let basename = sprintf "%s" resfile in
        let dot_dest = basename in
        IOInteropInternal.Dot.output_graph (Stdlib.open_out_bin dot_dest) graph;
          Logs.debug (fun m -> m "\n=== Graph written to %s\n" basename)
    )

let () = Command_unix.run command
