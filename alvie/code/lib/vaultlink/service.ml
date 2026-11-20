(* System under learning: a VaultLink service, reached through a transport (TCP, or a service in memory).

   The service speaks one command per line and answers with one line. A query
   starts with `pre`, which sends the transport command RESET so that every
   query begins in the initial state of the service.

   Inputs the `session` expression does not allow are never sent: they yield
   [Symbol.illegal], and so does every later input of the same query.
   [Vtdl.t.session] is therefore part of the system the learner observes, as
   TestDL is for ALVIE/Sancus. If the service closes the connection, the
   input that was being answered yields [Symbol.disconnected]. *)
open! Core

(* How the commands reach a service: over TCP (Vaultlink_unix.Tcp), or to a service in the same program
   (Memory_service), as in a browser. *)
type transport = {
  describe : string;  (* for messages: host:port, or the name of the service *)
  connect : unit -> string option;  (* opens the connection and returns the banner; None if it closed at once *)
  send : string -> string option;  (* sends a command line; its response line, None if the connection closed *)
  disconnect : unit -> unit;
}

type t = {
  spec : Vtdl.t;
  transport : transport;
  mutable connected : bool;
  mutable remaining : Session.t;  (* what the session still allows in this query *)
  mutable dead : bool;  (* an earlier input was illegal or the service disconnected *)
  mutable steps : int;  (* commands sent, for statistics *)
}

exception Service_error of string

let service_error fmt = Printf.ksprintf (fun msg -> raise (Service_error msg)) fmt

let disconnect t =
  if t.connected then t.transport.disconnect ();
  t.connected <- false

let connect t =
  (match t.transport.connect () with
   | Some banner when String.is_prefix banner ~prefix:"VaultLink" -> ()
   | Some other -> service_error "%s is not a VaultLink service (it said %S)" t.transport.describe other
   | None -> service_error "%s closed the connection immediately" t.transport.describe);
  t.connected <- true

let send_line t line =
  if not t.connected then connect t;
  match t.transport.send line with
  | Some l -> Some (String.strip l)
  | None -> None

let make (transport : transport) (spec : Vtdl.t) : t =
  let t = { spec; transport; connected = false; remaining = spec.session; dead = false; steps = 0 } in
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
     | _ -> service_error "%s does not answer RESET" t.transport.describe)

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

(* Whether the session may end after [history] (its expression accepts the empty sequence there) *)
let may_end (spec : Vtdl.t) (history : Symbol.t list) : bool =
  Session.nullable (List.fold history ~init:spec.session ~f:(fun r i -> Session.derive i r))

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
