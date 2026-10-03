(* Sends a sequence of inputs to a VaultLink service and prints the raw conversation.

   This is the counterpart of `exec.exe` in ALVIE/Sancus: after `vl_compare`
   reports a sequence on which two models differ, replay it, or a variation of
   it, against the real service. Inputs are the names declared in the `.vtdl`
   file; the `session` expression is not enforced here. *)
open Core
open Vaultlink

let user_error fmt = Printf.ksprintf (fun msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 2) fmt

let command =
  Command.basic
    ~summary:"Replays a sequence of inputs against a VaultLink service and prints the raw responses"
    ~readme:(fun () ->
      "Example:  vl_replay --spec my.vtdl --target localhost:9101 HELLO ID_SELF AUDIT\n\
       Inputs may be separate arguments or one quoted, space- or comma-separated list.")
    (let%map_open.Command spec_file = flag "--spec" (required string) ~doc:"file Specification (.vtdl) that declares the inputs"
     and target = flag "--target" (required string) ~doc:"host:port Address of the VaultLink service"
     and inputs = anon (sequence ("INPUT" %: string))
     in
     fun () ->
       let text = try In_channel.read_all spec_file with Sys_error msg -> user_error "cannot read the specification: %s" msg in
       let spec =
         match Vtdl.parse_result text with
         | Ok spec -> spec
         | Error e -> user_error "%s:%s" spec_file (Vtdl.error_message e)
       in
       let inputs =
         List.concat_map inputs ~f:(String.split_on_chars ~on:[ ' '; ','; '\t'; '\n' ])
         |> List.filter ~f:(Fn.non String.is_empty)
       in
       if List.is_empty inputs then
         user_error "no inputs given; the specification declares: %s" (String.concat ~sep:", " (List.map spec.inputs ~f:fst));
       List.iter inputs ~f:(fun i ->
         if not (List.Assoc.mem spec.inputs ~equal:String.equal i) then
           user_error "input %S is not declared in %s; it declares: %s" i spec_file
             (String.concat ~sep:", " (List.map spec.inputs ~f:fst)));
       let host, port =
         match String.rsplit2 target ~on:':' with
         | Some (h, p) when not (String.is_empty h) && Option.is_some (Int.of_string_opt p) -> h, Int.of_string p
         | _ -> user_error "--target must look like host:port, for example localhost:9101"
       in
       try
         let sul = Service.make ~host ~port spec in
         let steps = Service.replay sul inputs in
         let wi = List.fold steps ~init:0 ~f:(fun a r -> Int.max a (String.length r.input)) in
         let wc = List.fold steps ~init:0 ~f:(fun a r -> Int.max a (String.length r.command)) in
         List.iter steps ~f:(fun r ->
           match r.response with
           | Some line -> printf "%-*s  %-*s  ->  %s    [%s]\n" wi r.input wc r.command line r.output
           | None -> printf "%-*s  %-*s  ->  (connection closed)    [%s]\n" wi r.input wc r.command r.output)
       with Service.Service_error msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 3)

let () = Command_unix.run command
