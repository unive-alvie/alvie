(* Compares two learned VaultLink models and prints shortest distinguishing input sequences. *)
open Core
open Vaultlink

let load file =
  let text = try In_channel.read_all file with Sys_error msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 2 in
  try Model.of_dot text
  with Model.Parse_error (line, msg) -> eprintf "ALVIE/VaultLink: %s, line %d: %s\n%!" file line msg; exit 2

let command =
  Command.basic
    ~summary:"Prints the shortest input sequences on which two learned models give different outputs"
    (let%map_open.Command left = anon ("LEFT.dot" %: string)
     and right = anon ("RIGHT.dot" %: string)
     and limit = flag "--limit" (optional_with_default 10 int) ~doc:"n Maximum number of sequences to print (default 10)"
     in
     fun () ->
       let a = load left and b = load right in
       match Model.differences ~limit a b with
       | [] -> printf "No difference: the models agree on every input sequence.\n"
       | diffs ->
         printf "%d distinguishing sequence%s (shortest first):\n" (List.length diffs) (if List.length diffs = 1 then "" else "s");
         List.iteri diffs ~f:(fun n d ->
           printf "\n#%d\n" (n + 1);
           let w = List.fold d.inputs ~init:0 ~f:(fun acc i -> Int.max acc (String.length i)) in
           List.iteri d.inputs ~f:(fun k i ->
             let l = List.nth_exn d.left k and r = List.nth_exn d.right k in
             let mark = if String.equal l r then "  " else "<>" in
             printf "  %-*s  %s  %s | %s\n" w i mark l r));
         exit 1)

let () = Command_unix.run command
