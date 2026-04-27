open Core
open Learninglib.Lsharp
open Sancus
open Enclave

open Attacker
(* open Enclave *)
open Interop

module IIBLSharpExh = LSharp (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog) (Learninglib.Exhaustiveoracle.ExhaustiveOracle)
module IOInteropInternal = Interop (Sancus.Input) (Sancus.Output_internal)

module ExhaustiveOracle = Learninglib.Exhaustiveoracle.ExhaustiveOracle (Sancus.Input) (Sancus.Output_internal) (Sancus.Verilog)

let rec human_att_atom a =
  let open Sancus.Attacker.Attacker in
  (match a with
  | CRst -> "rst"
  | CRstNZ -> "rst_nz"
  | CJmpIn s -> "jin " ^ s
  | CCreateEncl _ -> "create"
  | CTimerEnable t -> sprintf "timer_enable %d" t
  | CStartCounting t -> sprintf "start_counting %d" t
  | CReti -> "reti"
  | CIfZ (l, r) -> sprintf "ifz [%s], [%s]"
    (List.fold l ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_att_atom i)))
    (List.fold r ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_att_atom i)))
  | CInst i -> Common.show_instruction_t i)

let rec human_encl_atom a =
  let open Sancus.Enclave.Enclave in
  (match a with
  | CUbr -> "ubr"
  | CRst -> "rst"
  | CIfZ (l, r) -> sprintf "ifz [%s], [%s]"
    (List.fold l ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_encl_atom i)))
    (List.fold r ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_encl_atom i)))
  | CBalancedIfZ il ->
    sprintf "balanced_ifz [%s]"
      (List.fold il ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (Common.show_instruction_t i)))
| CInst i -> Common.show_instruction_t i)

let human_input i =
  let open Input in
    (match i with
    | INoInput -> "ε"
    (* | IInterrupt -> "IRQ"
    | IJmpOut -> "jmpout" *)
    | IAttacker a -> human_att_atom a
    | IEnclave a -> human_encl_atom a)

let human_prog is =
  List.fold ~init:"" is ~f:(fun acc i -> sprintf "%s %s;" acc (human_input i))

let spec_parse_or_fail spec =
  match Testdl.Parser.parse_spec spec with
  | Result.Ok r -> r
  | Result.Error e -> failwith e
(*
let filter_model (m : IOInteropInternal.IIOMealy.t) =
  let _filtered_transition = IOInteropInternal.IIOMealy.TransitionMap.filteri
    m.transition
    ~f:(fun ~key ~data ->
          match key, data with
          | (_, Input.INoInput), _ | _, (([Output_internal.OIllegal], _, _), _) -> false
          | _ -> true
    ) in
  let _filtered_states = IOInteropInternal.IIOMealy.SSet.filter
    m.states
    ~f:(fun s ->
      (* Returns true if the state appears in at least one transition *)
      IOInteropInternal.IIOMealy.TransitionMap.existsi
      _filtered_transition
      ~f:(fun ~key:(s', _) ~data:(_, s'') -> s' = s || s'' = s)
    ) in
  { m with transition = _filtered_transition; states = _filtered_states } *)

let do_reset sul = Verilog.post sul; Verilog.pre sul

(* let rec gen_all_rec ?(res=[]) spec_dfa sul is os =
  let available = Inputgen.get_options spec_dfa is os in
  (* If we finished, accumulate the result *)
  if List.is_empty available ||
    List.mem is (INoInput) ~equal:Input.equal ||
    List.mem is (IAttacker CRstNZ) ~equal:Input.equal ||
    List.mem is (IAttacker CRst) ~equal:Input.equal then
      is::res
  else
    List.fold available ~init:res ~f:(fun acc new_i ->
      match new_i with
      | `Stop -> failwith (sprintf "<<<<< `Stop: %s; `Stop" (human_prog is))
      | `Next new_i -> (
        let sul = Verilog.clone sul in
          let o = Verilog.step ~silent:true sul new_i in
            gen_all_rec spec_dfa sul (is@[new_i]) (os@[o]) ~res:acc
        )
    ) *)

let cloner obj = Obj.obj (Obj.dup (Obj.repr obj))

let gen_init sul =
  let q = Queue.create () in
  let sul' = cloner sul in do_reset sul';
  Queue.enqueue q (sul', [], []);
  q

let gen_next available q =
(* let gen_next spec_dfa q = *)
  let gen_input = ref None in
  while not (Queue.is_empty q) && Option.is_none !gen_input do
    let sul, is, os = Queue.dequeue_exn q in
    (* let available = snd (Inputgen.get_options spec_dfa is os) in *)
    (* If we finished, accumulate the result *)
    (* (Logs.debug (fun p -> p "Available: %s" ([%derive.show: [`Next of Input.t | `Stop] list] available)); *)
    (* if List.is_empty available || List.mem (List.concat (List.map os ~f:fst3)) (Output_internal.OIllegal) ~equal:Output_internal.equal_element_t then
      gen_input := Some is
    else *)
    let all_illegal = List.fold ~init:true available ~f:(fun prev_all_illegal new_i ->
      match new_i with
      | `Stop -> failwith
        (
          failwith (sprintf "<<<<< `Stop: %s\n%s\n%s"
            (human_prog is)
            (Sexp.to_string (List.sexp_of_t Input.sexp_of_t is))
            (Sexp.to_string (List.sexp_of_t Output_internal.sexp_of_t os)));
        )
      | `Next new_i ->
        (
          let sul = cloner sul in
          let o = Verilog.step ~silent:true sul new_i in
          let is_illegal = List.mem (fst3 o) (Output_internal.OIllegal) ~equal:Output_internal.equal_element_t in
          if not is_illegal then Queue.enqueue q (sul, is@[new_i], os@[o]) else ();
          prev_all_illegal && is_illegal
        )
    ) in
    if all_illegal then (* We are done! *) gen_input := Some is
    else ()
  done;
  !gen_input, q


let command =
  Command.basic
    ~summary:"Learns Sancus Mealy machine using the L# algorithm and the specified attacker and enclave spec"
    (let%map_open.Command
    enclave_spec_fn =
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
    (* and resfile =
      flag
        "--res"
        (required string)
        ~doc:"filename File where the final learned model will be stored" *)
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
    and secret =
      flag
        "--secret"
        (optional string)
        ~doc:"value This is the value of the secret. It will be substituted inside the enclave."
    in
    fun () ->
        (* Random.self_init (); *)
        Random.init 0;
        (* Logs.set_reporter (Logs_fmt.reporter ());
        Logs.set_level (Some Logs.Debug); *)

        let cwd = Sys_unix.getcwd () in
        Logs.debug (fun m -> m "Current directory: %s" cwd);
        (* Create tmpdir if not present *)
        (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
        let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
        (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
        (* Create resultdir if not present *)
        (* let resdir = String.drop_suffix resfile (String.length (List.last_exn (String.split resfile ~on:'/'))) in *)
        (* Logs.debug (fun m -> m "Result directory: %s" resdir); *)
        (* (match Sys_unix.file_exists resdir with | `No -> Core_unix.mkdir_p resdir | _ -> ()); *)
        (* Basic sanity checks on the repo *)
        assert (Sys_unix.file_exists_exn sancus_core_gap_dir);
        assert (Sys_unix.is_directory_exn sancus_core_gap_dir);
        (* (1) load the spec *)
        let enclave_spec_str = In_channel.read_all enclave_spec_fn in
        let attacker_spec_str = In_channel.read_all attacker_spec_fn in
        let spec_w_secret = spec_parse_or_fail (enclave_spec_str ^ " " ^ attacker_spec_str) in
        let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = spec_w_secret in
        (* Secret must be expanded *)
        let enclave = match secret with | None -> assert (not (Enclave.has_secret enclave)); enclave | Some secret -> Enclave.expand_secret secret enclave in
        let complete_spec = let open Testdl in (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) in
        (* let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = complete_spec in *)
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
            () in
        (* (3) prepare the oracle *)
        let attacker_atoms =
          List.fold [isr; prepare; cleanup] ~init:[] ~f:(fun acc b -> acc @ (Set.to_list (Attacker.get_atoms b))) in
        let enclave_atoms = Set.to_list (Enclave.get_atoms enclave) in
        let alphabet_attacker = List.map attacker_atoms ~f:(fun ca -> Input.IAttacker ca) in
        let alphabet_enclave = List.map enclave_atoms ~f:(fun i -> Input.IEnclave i) in
        let complete_input_alphabet = Input.INoInput :: alphabet_attacker @ alphabet_enclave in
        (* Setup the oracle *)
        (* let oracle = ExhaustiveOracle.make
          ~next_options:(fun _ il ol -> Inputgen.get_options spec_dfa il ol)
          () in *)
        let start = Time_now.nanoseconds_since_unix_epoch () in
        (* let learned = IIBLSharpExh.lsharp_run oracle sul complete_input_alphabet in *)
        let q = ref (gen_init sul) in
        let res = ref (Some []) in
        while not (Option.is_none !res) do
          (* let next, q_next = gen_next spec_dfa (!q) in *)
          let next, q_next = gen_next (List.map ~f:(fun i -> `Next i) complete_input_alphabet) (!q) in
          res := next;
          q := q_next;
          match next with | None -> () | Some is -> (Format.printf "%s\n" (human_prog is); Out_channel.flush stdout)
        done;
        let open Int63 in
        let time = Time_now.nanoseconds_since_unix_epoch () - start in
        Format.printf "=== RESULTS in %Ld ===\n\n" (Int63.to_int64 (Int63.(/) time (Int63.of_int 1000000)));
        (* List.iter res ~f:(fun is ->

          Out_channel.flush stdout;
        ); *)
        (* List.iter all
        ~f:(fun is -> Format.printf "%s\n\n" (human_prog is)); *)

        (* let outputquery_cnt, equivquery_cnt, sul_reset_cnt, sul_step_cnt, sul_step_dry_cnt, avg_len, sigmasq_len = ExhaustiveOracle.get_stats oracle in
        (* and, finally, (5) to produce the output *)
        if report then
          Logs.app (fun m -> m
              (
              "\n===  STATS ===\
              \n+-----------------------+--------+\
              \n| # Resets              | %6d |\
              \n| # SUL steps (non-dry) | %6d |\
              \n| # SUL steps (dry)     | %6d |\
              \n| # output_query calls  | %6d |\
              \n| # equiv_query calls   | %6d |\
              \n| Avg. path len         | %6f |\
              \n| Var. path len         | %6f |\
              \n| Learning time         | %Ld |\
              \n+-----------------------+--------+\n")
                sul_reset_cnt
                sul_step_cnt
                sul_step_dry_cnt
                outputquery_cnt
                equivquery_cnt
                avg_len
                sigmasq_len
                (Int63.to_int64 (Int63.(/) time (Int63.of_int 1000000)))
            ) else (printf "\n");
        let final_model = filter_model learned in
        let graph = IOInteropInternal.dot_of_t final_model in
        let basename = sprintf "%s" resfile in
        let dot_dest = basename in
        IOInteropInternal.Dot.output_graph (Stdlib.open_out_bin dot_dest) graph;
        Logs.debug (fun m -> m "\n=== Graph written to %s\n" basename) *)
    )

let () = Command_unix.run command
