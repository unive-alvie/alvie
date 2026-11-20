(*
  VaultLink services in the same program, for learning without a network (in a browser, or in tests): the transport
  of Service to a vault controller that speaks the protocol of VaultLink, one command per line.

  The protocol (as the reference of the participants documents it):

    HELLO      opens the session                          ID <id>    declares the identity of the operator
    PASS <pw>  authenticates the session                  AUDIT      notes the access in the register
    OPEN       opens the door of the vault of the identity READ       reads the contents
    CLOSE      seals the session (for good)
    RESET (back to IDLE), HELP and QUIT are commands of the transport.

  Answers: OK ..., ERR <reason> (any ERR ends the session: start again from HELLO), DATA vault=<id> contents=<...>.

  - reference: the documented controller. Its session is linear: HELLO, ID, PASS, AUDIT, OPEN, then READ (any number of
    times) and CLOSE.
  - firmware: a controller for training, which behaves as the reference except for one behaviour that the
    documentation does not have. It is not the service of the VaultLink challenge.

  Operators: alice (password correct-horse) and bob (password battery-staple).
*)

open! Core

type kind = Reference | Firmware [@@deriving equal]

let kinds = [ ("reference", Reference); ("firmware", Firmware) ]

let operators = [ ("alice", ("correct-horse", "letters from bob")); ("bob", ("battery-staple", "the plans of the vault")) ]

type state =
  | Idle
  | Greeted
  | Identified of string
  | Authenticated of string
  | Audited of string
  | Opened of string
  | Closed
  | Audited_twice of string  (* the firmware only *)

let banner = "VaultLink v3.0 - in-memory vault controller. Type HELP."

(* The answer to a command of the protocol in a state, and the next state *)
let execute kind state cmd arg =
  let err reason = (sprintf "ERR %s" reason, Idle) in
  let data id = sprintf "DATA vault=%s contents=%s" id (snd (List.Assoc.find_exn operators ~equal:String.equal id)) in
  match state, cmd with
  | Closed, _ -> ("ERR closed", Closed)
  | Idle, "HELLO" -> ("OK hello", Greeted)
  | Greeted, "ID" ->
    let id = Option.value arg ~default:"" in
    if List.Assoc.mem operators ~equal:String.equal id then ("OK identified", Identified id) else err "unknown-id"
  | Identified id, "PASS" ->
    if String.equal (Option.value arg ~default:"") (fst (List.Assoc.find_exn operators ~equal:String.equal id))
    then ("OK authenticated", Authenticated id)
    else err "bad-password"
  | Authenticated id, "AUDIT" -> ("OK audited", Audited id)
  | Audited id, "AUDIT" when equal_kind kind Firmware -> ("OK audited", Audited_twice id)
  | (Audited id | Audited_twice id), "OPEN" -> ("OK opened", Opened id)
  | Audited_twice id, "READ" -> (data id, Audited_twice id)
  | Opened id, "READ" -> (data id, Opened id)
  | Opened _, "CLOSE" -> ("OK closed", Closed)
  | _ -> err "out-of-order"

let with_arg = [ "ID"; "PASS" ]
let no_arg = [ "HELLO"; "AUDIT"; "OPEN"; "READ"; "CLOSE" ]

(* A transport to a new controller of the kind; each connection starts in IDLE *)
let transport kind : Service.transport =
  let name = fst (List.find_exn kinds ~f:(fun (_, k) -> equal_kind k kind)) in
  let state = ref None in
  let connect () = state := Some Idle; Some banner in
  let send line =
    match !state with
    | None -> None
    | Some s ->
      let line = String.strip line in
      let cmd, arg = match String.lsplit2 line ~on:' ' with
        | Some (c, a) -> (String.uppercase c, Some (String.strip a))
        | None -> (String.uppercase line, None) in
      if String.equal cmd "QUIT" then (state := None; Some "OK bye")
      else if String.equal cmd "RESET" then (state := Some Idle; Some "OK reset")
      else if String.equal cmd "HELP" then Some "INFO commands: HELLO | ID <id> | PASS <pw> | AUDIT | OPEN | READ | CLOSE"
      else if List.mem with_arg cmd ~equal:String.equal && Option.is_none arg then Some "ERR missing-argument"
      else if not (List.mem with_arg cmd ~equal:String.equal || List.mem no_arg cmd ~equal:String.equal) then
        Some "ERR unknown-command"
      else
        let answer, s' = execute kind s cmd (if List.mem no_arg cmd ~equal:String.equal then None else arg) in
        state := Some s';
        Some answer in
  { describe = sprintf "the %s service in memory" name; connect; send; disconnect = (fun () -> state := None) }
