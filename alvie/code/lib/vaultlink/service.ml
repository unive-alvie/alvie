(* System under learning: a VaultLink service reached over TCP.

   The service speaks one command per line and answers with one line. A query
   starts with `pre`, which sends the transport command RESET so that every
   query begins in the initial state of the service.

   Inputs the `session` expression does not allow are never sent: they yield
   [Symbol.illegal], and so does every later input of the same query.
   [Vtdl.t.session] is therefore part of the system the learner observes, as
   TestDL is for ALVIE/Sancus. If the service closes the connection, the
   input that was being answered yields [Symbol.disconnected]. *)
open! Core

type t = {
  spec : Vtdl.t;
  host : string;
  port : int;
  timeout : float;  (* seconds to wait for each response *)
  mutable conn : (In_channel.t * Out_channel.t) option;
  mutable remaining : Session.t;  (* what the session still allows in this query *)
  mutable dead : bool;  (* an earlier input was illegal or the service disconnected *)
  mutable steps : int;  (* commands sent, for statistics *)
}

exception Service_error of string

let service_error fmt = Printf.ksprintf (fun msg -> raise (Service_error msg)) fmt

let disconnect t =
  Option.iter t.conn ~f:(fun (ic, oc) ->
    (try Out_channel.close oc with _ -> ());
    (try In_channel.close ic with _ -> ()));
  t.conn <- None

(* Reads one response line, treating a closed connection as [None]. *)
let read_line t ic =
  match In_channel.input_line ic with
  | line -> Option.map line ~f:String.strip
  | exception Sys_blocked_io -> service_error "no response from %s:%d within %.1fs" t.host t.port t.timeout
  | exception Sys_error _ -> None

let connect t =
  let ic, oc =
    try Conn.connect ~host:t.host ~port:t.port ~timeout:t.timeout
    with Conn.Failed msg -> service_error "%s" msg
  in
  t.conn <- Some (ic, oc);
  (* The banner is the first line sent by the service. *)
  match read_line t ic with
  | Some banner when String.is_prefix banner ~prefix:"VaultLink" -> ()
  | Some other -> service_error "%s:%d is not a VaultLink service (it said %S)" t.host t.port other
  | None -> service_error "%s:%d closed the connection immediately" t.host t.port

let send_line t line =
  let ic, oc =
    match t.conn with
    | Some c -> c
    | None -> connect t; Option.value_exn t.conn
  in
  match Out_channel.output_string oc (line ^ "\n"); Out_channel.flush oc with
  | () -> read_line t ic
  | exception Sys_error _ -> None

let make ?(timeout = 5.0) ~host ~port (spec : Vtdl.t) : t =
  let t = { spec; host; port; timeout; conn = None; remaining = spec.session; dead = false; steps = 0 } in
  connect t;
  t

let steps t = t.steps

(* --- Learninglib.Sul.SUL, instantiated by the functor below --- *)

let pre t =
  t.remaining <- t.spec.session;
  t.dead <- false;
  let reset () = send_line t "RESET" in
  match reset () with
  | Some "OK reset" -> ()
  | Some other -> service_error "unexpected answer to RESET: %S" other
  | None ->
    (* The service dropped an idle connection; reconnect once. *)
    disconnect t;
    (match reset () with
     | Some "OK reset" -> ()
     | _ -> service_error "%s:%d does not answer RESET" t.host t.port)

let post (_ : t) = ()

let step ?silent:(_ = false) ?dry_output:(_ : Symbol.t option) t (input : Symbol.t) : Symbol.t =
  if t.dead then Symbol.illegal
  else if not (Session.allows t.remaining input) then (
    t.dead <- true;
    Symbol.illegal)
  else
    match List.Assoc.find t.spec.inputs ~equal:String.equal input with
    | None -> service_error "input %S is not declared in the specification" input
    | Some command ->
      t.remaining <- Session.derive input t.remaining;
      t.steps <- t.steps + 1;
      (* A known answer ([dry_output]) does not let us skip the command: the service must still advance. *)
      (match send_line t command with
       | None ->
         t.dead <- true;
         disconnect t;
         Symbol.disconnected
       | Some line ->
         (match Observe.classify t.spec.observe line with
          | Some symbol -> symbol
          | None -> service_error "no 'observe' rule matches %S; add a catch-all rule" line))

let clone _ = failwith "Service.clone: a connection cannot be copied"

module Sul : Learninglib.Sul.SUL with type t = t and type input_t = Symbol.t and type output_t = Symbol.t = struct
  type nonrec t = t
  type input_t = Symbol.t
  type output_t = Symbol.t

  let clone = clone
  let pre = pre
  let step = step
  let post = post
end

(* The inputs the oracle may send next after [history], in specification order. *)
let allowed_inputs (spec : Vtdl.t) (history : Symbol.t list) : Symbol.t list =
  let r = List.fold history ~init:spec.session ~f:(fun r i -> Session.derive i r) in
  List.filter_map spec.inputs ~f:(fun (name, _) -> if Session.allows r name then Some name else None)

(* --- Replay --- *)

type replayed = {
  input : Symbol.t;
  command : string;  (* what was sent *)
  response : string option;  (* the raw line, [None] if the service disconnected *)
  output : Symbol.t;  (* the abstract output, as the learner would see it *)
}

(* Sends the given inputs to the service in order and returns the raw
   conversation. Unlike [step], this ignores the `session` expression: a
   replay may deviate from what was explored during learning. It stops after a
   disconnect. *)
let replay t (inputs : Symbol.t list) : replayed list =
  pre t;
  let rec go acc = function
    | [] -> List.rev acc
    | input :: rest ->
      (match List.Assoc.find t.spec.inputs ~equal:String.equal input with
       | None -> service_error "input %S is not declared in the specification" input
       | Some command ->
         t.steps <- t.steps + 1;
         (match send_line t command with
          | None ->
            disconnect t;
            List.rev ({ input; command; response = None; output = Symbol.disconnected } :: acc)
          | Some line ->
            let output = Option.value (Observe.classify t.spec.observe line) ~default:Symbol.default in
            go ({ input; command; response = Some line; output } :: acc) rest))
  in
  go [] inputs
