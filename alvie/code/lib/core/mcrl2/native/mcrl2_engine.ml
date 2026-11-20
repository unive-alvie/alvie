(* Runs the tools of mCRL2 (see mcrl2_engine.mli) *)
open Core

let available = true

let remove_unless_debug dir =
  match Logs.level () with Some Debug -> () | _ -> ignore (Sys_unix.command (sprintf "rm -rf %s" (Filename.quote dir)))

let weak_trace_counterexample ~tmpdir ~silent ~m1 ~m2 =
  let dir = Core_unix.mkdtemp (tmpdir ^ "/") in
  Logs.debug (fun m -> m "[mcrl2] Created temporary directory: %s" dir);
  Out_channel.write_all (dir ^ "/m1.aut") ~data:m1;
  Out_channel.write_all (dir ^ "/m2.aut") ~data:m2;
  let cex = dir ^ "/cex.trc" in
  let cmd = sprintf "ltscompare %s/m1.aut %s/m2.aut --strategy=b --counter-example --counter-example-file=%s --preorder=weak-trace-ac --tau=%s -q >/dev/null"
      dir dir cex (Filename.quote (String.concat ~sep:"," silent)) in
  Logs.debug (fun m -> m "[find_cex] Running the comparison");
  ignore (Sys_unix.command cmd);
  let result =
    match Sys_unix.file_exists cex with
    | `Yes ->
      Some Shexp_process.(eval (pipe (run "tracepp" [ cex; "-fplain" ])
                                  (fold_lines ~init:[] ~f:(fun acc l -> return (String.strip l :: acc)))))
      |> Option.map ~f:List.rev
    | _ -> None in
  remove_unless_debug dir;
  result

let formula ~tmpdir ~aut ~spec ~actions ~formula_file =
  let dir = Core_unix.mkdtemp (tmpdir ^ "/") in
  let aut_file = dir ^ "/model.aut" and spec_file = dir ^ "/actions.mcrl2" and pbes = dir ^ "/model.pbes" in
  Out_channel.write_all aut_file ~data:aut;
  Out_channel.write_all spec_file ~data:spec;
  Out_channel.write_all (dir ^ "/actions.txt") ~data:actions;
  let run_tool prog args =
    let log = dir ^ "/" ^ prog ^ ".log" in
    match Sys_unix.command (String.concat ~sep:" " (List.map (prog :: args) ~f:Filename.quote) ^ " > " ^ Filename.quote log ^ " 2>&1") with
    | 0 -> Ok ()
    | code -> Error (sprintf "%s failed with exit code %d: see %s (keep it with --debug)" prog code log) in
  let result =
    Result.bind (run_tool "lts2pbes" [ "-f"; formula_file; "-m"; spec_file; aut_file; pbes ]) ~f:(fun () ->
        match Shexp_process.(eval (run "pbes2bool" [ pbes ] |> capture_unit [ Stdout ])) with
        | out -> (match String.strip out with "true" -> Ok true | "false" -> Ok false | o -> Error (sprintf "pbes2bool answered %S" o))
        | exception e -> Error (sprintf "pbes2bool failed: %s" (Exn.to_string e))) in
  (match Logs.level (), result with
   | Some Debug, _ -> Logs.app (fun p -> p "The files of mCRL2 are in %s (actions.txt lists the actions)" dir)
   | _, Error _ -> ()
   | _ -> remove_unless_debug dir);
  result
