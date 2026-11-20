(* The transport of Vaultlink.Service over TCP: a VaultLink service at host:port, one command per line *)

let transport ?(timeout = 5.0) ~host ~port () : Vaultlink.Service.transport =
  let describe = Printf.sprintf "%s:%d" host port in
  let conn = ref None in
  let disconnect () =
    Option.iter (fun (ic, oc) -> (try close_out oc with _ -> ()); (try close_in ic with _ -> ())) !conn;
    conn := None in
  (* One response line, or None if the connection closed *)
  let read_line ic =
    match input_line ic with
    | line -> Some line
    | exception End_of_file -> None
    | exception Sys_blocked_io -> raise (Vaultlink.Service.Service_error (Printf.sprintf "no response from %s within %.1fs" describe timeout))
    | exception Sys_error _ -> None in
  let connect () =
    disconnect ();
    let ic, oc =
      try Conn.connect ~host ~port ~timeout
      with Conn.Failed msg -> raise (Vaultlink.Service.Service_error msg) in
    conn := Some (ic, oc);
    read_line ic in
  let send line =
    match !conn with
    | None -> None
    | Some (ic, oc) ->
      match output_string oc (line ^ "\n"); flush oc with
      | () -> read_line ic
      | exception Sys_error _ -> None in
  { describe; connect; send; disconnect }

(* Serves the service in memory of the kind on port of localhost, one client at a time, until killed: every
   connection gets a new controller, which starts in IDLE. For practising with a target over TCP. *)
let serve ~port kind =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen sock 8;
  Printf.printf "Serving the %s service on 127.0.0.1:%d\n%!"
    (fst (List.find (fun (_, k) -> Vaultlink.Memory_service.equal_kind k kind) Vaultlink.Memory_service.kinds)) port;
  while true do
    let fd, _ = Unix.accept sock in
    let ic = Unix.in_channel_of_descr fd and oc = Unix.out_channel_of_descr fd in
    let service = Vaultlink.Memory_service.transport kind in
    let reply = function Some l -> output_string oc (l ^ "\n"); flush oc; true | None -> false in
    (try
       if reply (service.connect ()) then
         let rec loop () =
           match input_line ic with
           | line -> if reply (service.send line) then loop ()
           | exception End_of_file -> () in
         loop ()
     with Sys_error _ | Unix.Unix_error _ -> ());
    (try Unix.close fd with _ -> ())
  done
