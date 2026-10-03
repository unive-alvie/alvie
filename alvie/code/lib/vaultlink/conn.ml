(* TCP connection helper. This module deliberately does not open Core, so that
   [Unix] is the real Unix library rather than Core's deprecated shadow. *)

exception Failed of string

(* Connects to [host]:[port] and returns buffered channels. Reads fail with
   [Sys_blocked_io] after [timeout] seconds without data. *)
let connect ~host ~port ~timeout : in_channel * out_channel =
  let addr =
    match Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
    | ai :: _ -> ai.Unix.ai_addr
    | [] -> raise (Failed (Printf.sprintf "cannot resolve %s" host))
  in
  let fd = Unix.socket (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
  (try Unix.connect fd addr
   with Unix.Unix_error (e, _, _) ->
     Unix.close fd;
     raise (Failed (Printf.sprintf "cannot connect to %s:%d: %s" host port (Unix.error_message e))));
  Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
  Unix.in_channel_of_descr fd, Unix.out_channel_of_descr fd
