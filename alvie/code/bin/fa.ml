(*
  fa.exe: compares the four models of an experiment (secret 0 and 1, with and without interrupts) with the
  comparison engine of ALVIE/Core (Ltscompare), and with what the attacker sees as plugins/sancus declares it: the
  hooks of the engine are derived from the plugin files (Ltscompare.Plugin_hooks).
*)
open Sancus
open Interop
open Core

module IOInterop = Interop (Sancus.Input) (Sancus.Output_internal)

(* The model name used in the logs: the file name without the directory and the .dot extension *)
let filename s = String.chop_suffix_if_exists (Filename.basename s) ~suffix:".dot"

(* The secret of a model, from its name: <commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-int|-nint].dot *)
let secret_of_name file =
  let parts = String.split (filename file) ~on:'-' in
  let parts = match List.rev parts with ("int" | "nint") :: rest -> List.rev rest | _ -> parts in
  match List.rev parts with
  | _delta :: _eps :: secret :: _ -> Some secret
  | _ -> None

let compare ~plugin ~secret_values ~tmpdir ~cex_file ~limit ~m1_int_file ~m2_int_file ~m1_nint_file ~m2_nint_file =
  let module H = Ltscompare.Plugin_hooks.Make (struct let plugin = plugin let secret_values = secret_values end) in
  let module C = Ltscompare.Cexfinder.Make (H) in
  let view = Ltscompare.View.make plugin in
  (* A model as a Mealy machine of the comparison: each observation of a step is split into its parts, one
     transition each, with the input of the step (or the interrupt, for the parts that are one) *)
  let load file : C.IIOMealy.t =
    let m = IOInterop.t_of_dot_file IOInterop.IIOMealy.ISet.empty file in
    let input_of (i : Input.t) : H.Input.t =
      match i, Generic_inputgen.atom_of_input i with
      | Input.IAttacker _, Some atom -> Atom { cls = "attacker"; low = true; atom }
      | Input.IEnclave _, Some atom -> Atom { cls = "enclave"; low = false; atom }
      | _ -> No_input in
    let states, transition, _ = Map.fold m.transition
        ~init:(m.states, C.IIOMealy.TransitionMap.empty, Set.max_elt_exn m.states)
        ~f:(fun ~key:(s, i) ~data:((ol, _, _), s') (states, tr, last) ->
            let parts = List.concat_map ol ~f:(fun o -> Ltscompare.View.parts view (Generic_inputgen.observation o)) in
            let n = List.length parts in
            List.foldi parts ~init:(states, tr, last) ~f:(fun idx (states, tr, last) (part, interrupt) ->
                let start = if idx = 0 then s else last in
                let stop = if idx = n - 1 then s' else last + 1 in
                let states = if stop > last then Set.add states stop else states in
                let input = if interrupt then H.Input.Interrupt else input_of i in
                (states, Map.add_exn tr ~key:(start, input) ~data:(part, stop), Int.max last stop))) in
    { s0 = 0; states; transition; pred_map = C.IIOMealy.PredMap.empty; input_alphabet = C.IIOMealy.ISet.empty } in
  let m1_int, m2_int = C.i_lts_of_mealy (load m1_int_file), C.i_lts_of_mealy (load m2_int_file) in
  let nint_witnesses = match m1_nint_file, m2_nint_file with
    | Some m1, Some m2 ->
      (* The witnesses already there without interrupts *)
      trd3 (C.find_all_cex_sym ~to_remove:[] ?limit ~tmpdir ~m1_name:(filename m1) ~m2_name:(filename m2)
              ~m1:(C.i_lts_of_mealy (load m1)) ~m2:(C.i_lts_of_mealy (load m2)) ())
    | _ -> [] in
  let count, graph, _ =
    C.find_all_cex_sym ?limit ~to_remove:nint_witnesses ~tmpdir ~m1_name:(filename m1_int_file) ~m2_name:(filename m2_int_file)
      ~m1:m1_int ~m2:m2_int () in
  C.ILTS.Dot.output_graph (Stdlib.open_out_bin (sprintf "%s_int.dot" cex_file)) (C.ILTS.to_dot graph);
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
        compare ~plugin:(Lazy.force Generic_inputgen.plugin) ~secret_values ~tmpdir ~cex_file ~limit ~m1_int_file ~m2_int_file ~m1_nint_file ~m2_nint_file))

let () = Command_unix.run command
