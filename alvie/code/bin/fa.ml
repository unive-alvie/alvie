open Sancus
open Interop
open Ltscomparator.Obs
open Ltscomparator.Cexfinder

open Learninglib.Mealy
open Learninglib.Showableint

open Core

module IOInterop = Interop (Sancus.Input) (Sancus.Output_internal)
module IIOMealyExt = Mealy (ShowableInt) (InputExt) (OutputExt)

let filename s = List.hd_exn (String.split (List.last_exn (String.split s ~on:'/')) ~on:'.')

(* Load models from the filesystem *)
let load_and_convert fn : IIOMealyExt.t =
  let mint = IOInterop.t_of_dot_file IOInterop.IIOMealy.ISet.empty fn in
  let convert (mint : IOInterop.IIOMealy.t) : IIOMealyExt.t =
    let decompose ol = List.fold ol ~init:[] ~f:(fun decomposed o ->
      match o with
      | Output_internal.OTime_Handle (p, p') ->
          decomposed @ [OutputExt.OTime (OutputExt.prj_payload p); OutputExt.OHandle (OutputExt.prj_payload p')]
      | Output_internal.OJmpOut_Handle (p, p') -> decomposed @ [OutputExt.OTime (OutputExt.prj_payload p); OutputExt.OJmpOut; OutputExt.OHandle (OutputExt.prj_payload p')]
      | Output_internal.OJmpOut p -> decomposed @ [OutputExt.OTime (OutputExt.prj_payload p); OutputExt.OJmpOut]
      | _ -> decomposed @ [OutputExt.of_output o]) in
    (* We to split each OTime_Handle and OJmpOut_Handle into different obs! *)
    let ext_states, ext_tr, _ = Map.fold
      mint.transition
      ~init:(mint.states, IIOMealyExt.TransitionMap.empty, Set.max_elt_exn mint.states)
      ~f:(
        fun ~key:(s, i) ~data:((ol, _, _), s') (acc_states, acc_tr, last_used) ->
          let decomposed = decompose ol in
          let decomposed_len = List.length decomposed in
          List.foldi decomposed ~init:(acc_states, acc_tr, last_used) ~f:(fun idx (acc_states, acc_tr, last_used) o ->
            let start_s = (if idx = 0 then s else last_used) in
            let end_s = (if idx = decomposed_len - 1 then s' else last_used+1) in
            let acc_states' = if end_s > last_used then Set.add acc_states end_s else acc_states in
            let last_used' = Int.max last_used end_s in
              match o with
              | OutputExt.OHandle _  ->
                  (acc_states', Map.add_exn acc_tr ~key:(start_s, InputExt.IInterrupt) ~data:(o, end_s), last_used')
              | _ -> (acc_states', Map.add_exn acc_tr ~key:(start_s, InputExt.of_input i) ~data:(o, end_s),  last_used')
          )
      ) in {
        s0 = 0;
        states = ext_states;
        transition = ext_tr;
        pred_map = IIOMealyExt.PredMap.empty;
        input_alphabet = IIOMealyExt.ISet.empty;
      } in
  (* silent_to_halt (convert mint) *)
  convert mint

let command =
  Command.basic
    ~summary:"Given two Sancus models compares them using mCRL2 and shows witnesses of non-equivalence."
    (let%map_open.Command
      cex_file =
        flag "--witness-file-basename"
        (required string)
        ~doc:"file The file the counterexamples will be written to (in LTS form, dot file)"
      and dbg =
      flag
          "--debug"
          no_arg
          ~doc:"Enables debug-level logging"
      and m1_int_file =
      flag
          "--m1-int"
          (required string)
          ~doc:"filename Uses the specified dot file as the first model with interrupts in the comparison"
      and m2_int_file =
      flag
          "--m2-int"
          (required string)
          ~doc:"filename Uses the specified dot file as the second model with interrupts in the comparison"
      and m1_nint_file =
      flag
          "--m1-nint"
          (optional string)
          ~doc:"filename Uses the specified dot file as the first model w/o interrupts in the comparison"
      and m2_nint_file =
      flag
          "--m2-nint"
          (optional string)
          ~doc:"filename Uses the specified dot file as the second model w/o interrupts in the comparison"
      and tmpdir =
      flag
        "--tmpdir"
        (required string)
        ~doc:"directory Temporary directory where intermediate results will be stored"
      and limit =
      flag
        "--cex-limit"
        (optional int)
        ~doc:"limit Maximum number of counterexamples to extract before giving up (default: no limit)"
      in
      fun () ->
        (if dbg then Logs.set_level (Some Logs.Debug)
        else Logs.set_level (Some Logs.App));
        Logs.set_reporter (Logs_fmt.reporter ());
        (* Create tmpdir if not present *)
        (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
        let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
        (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
        (* Create res directory, if not present *)
        let cex_dir =
          String.drop_suffix cex_file (String.length (List.last_exn (String.split cex_file ~on:'/'))) in
        Logs.info (fun m -> m "Result directory: %s" cex_dir);
        (match Sys_unix.file_exists cex_dir with | `No -> Core_unix.mkdir_p cex_dir | _ -> ());
        let m1_int, m1_int_name = i_lts_of_mealy (load_and_convert (sprintf "%s" m1_int_file)), filename m1_int_file in
        let m2_int, m2_int_name = i_lts_of_mealy (load_and_convert (sprintf "%s" m2_int_file)), filename m2_int_file in
        let cex_nint_witnesses = (
          match m1_nint_file, m2_nint_file with
          | Some m1_nint_file, Some m2_nint_file ->
            let m1_nint, m1_nint_name =
              i_lts_of_mealy (load_and_convert (sprintf "%s" m1_nint_file)), filename m1_nint_file in
            let m2_nint, m2_nint_name =
              i_lts_of_mealy (load_and_convert (sprintf "%s" m2_nint_file)), filename m2_nint_file in
            (* Compute interferences in the non-interruptible system *)
            trd3 (find_all_cex ~to_remove:[] ?limit ~tmpdir:tmpdir ~m1_name:m1_nint_name ~m2_name:m2_nint_name ~m1:m1_nint ~m2:m2_nint ())
          | _ -> []) in
        (* Extract also those that are violations of RNI in the models wo interrupts *)
        let cex_int_cnt, cex_int_graph, _ =
          find_all_cex ?limit ~to_remove:cex_nint_witnesses ~tmpdir:tmpdir ~m1_name:m1_int_name ~m2_name:m2_int_name ~m1:m1_int ~m2:m2_int () in
        (* Output the results :) *)
        let graph_int = ILTS.to_dot cex_int_graph in
        ILTS.Dot.output_graph (Stdlib.open_out_bin (sprintf "%s_int.dot" cex_file)) graph_int;
        (* let graph_nint = ILTS.to_dot cex_nint_graph in
        ILTS.Dot.output_graph (Stdlib.open_out_bin (sprintf "%s_nint.dot" cex_file)) graph_nint; *)
        (* Logs.info (fun m -> m "\n\n=== Results: found %d RNI violations (of which %d also in non-interrupt enabled models). See %s_{int,nint}.dot for details." cex_int_cnt cex_nint_cnt cex_file) *)
        Logs.info (fun m -> m "\n\n=== Results: found %d FA violations. See %s_int.dot for details." cex_int_cnt cex_file)
    )

let () = Command_unix.run command
