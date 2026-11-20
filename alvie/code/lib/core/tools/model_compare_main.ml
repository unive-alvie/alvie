(*
  alvie-model-compare: whether two learned models are the same machine up to the numbering of their states.

    alvie-model-compare [--observations-only] A.dot B.dot

  Exit codes: 0 isomorphic, 1 different (the first difference is printed, with the path to it), 2 a file cannot be
  read. --observations-only ignores the bookkeeping in the outputs of ALVIE/Sancus models (the code still to analyse
  and the number of the last instruction), which learning does not compare either.
*)

open Core

(* An output of ALVIE/Sancus is (observations labels instruction-number): keep the observations *)
let observations_only label =
  match Sexp.of_string label with
  | Sexp.List [ input; Sexp.List [ observations; _labels; _number ] ] -> Sexp.to_string (Sexp.List [ input; observations ])
  | _ -> label
  | exception _ -> label

let () =
  let open Command.Let_syntax in
  Command_unix.run
    (Command.basic ~summary:"Check that two learned models are the same machine, up to the numbering of their states"
       (let%map_open observations = flag "--observations-only" no_arg ~doc:" ignore the bookkeeping of ALVIE/Sancus outputs"
        and initial = flag "--initial" (optional_with_default "0" string) ~doc:"state the initial state of both models (default 0)"
        and a = anon ("A.dot" %: string)
        and b = anon ("B.dot" %: string) in
        fun () ->
          List.iter [ a; b ] ~f:(fun f -> if not (Sys_unix.file_exists_exn f) then (eprintf "ALVIE error: %s does not exist\n" f; exit 2));
          let relabel = if observations then observations_only else Fn.id in
          match Model_compare.isomorphic ~relabel ~initial a b with
          | Ok n -> printf "isomorphic: %d states\n" n
          | Error d ->
            printf "different: %s\n  after: %s\n" d.reason (match d.path with [] -> "(the initial state)" | p -> String.concat ~sep:" ; " p);
            (* The shortest inputs on which the models answer differently, if the labels are (input output) *)
            let split label =
              match Sexp.of_string label with
              | Sexp.List [ i; o ] -> (Sexp.to_string i, Sexp.to_string o)
              | _ | (exception _) -> (label, "") in
            (match Model_compare.distinguish ~relabel ~split ~initial a b with
             | None -> printf "  the models answer every input sequence the same way: they differ only in how their states are merged\n"
             | Some (path, i, oa, ob) ->
               let show = function Some o -> o | None -> "(no transition)" in
               printf "  shortest distinguishing inputs: %s ; %s\n  first model: %s\n  second model: %s\n"
                 (match path with [] -> "(the initial state)" | p -> String.concat ~sep:" ; " p) i (show oa) (show ob));
            exit 1))
