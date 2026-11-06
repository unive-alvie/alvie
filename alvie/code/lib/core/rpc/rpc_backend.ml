(*
  An external plugin as a native one (Alvie_backend.Native.S): its backend is a program that speaks the protocol of
  Core (Protocol), started from the plugin's directory with the command of its manifest.

  - Each backend (make) is one process; its clones are instances in the same process.
  - Every answer must come within a timeout (ALVIE_RPC_TIMEOUT, in seconds; 60 by default). A plugin that does not
    answer is killed; one that stops, answers with an error or with something that is not an answer, fails the
    command with Backend.Failed, a message that says what happened, and the end of the plugin's log.
  - The plugin's standard error is its log, in <tmp>/alvie-<plugin>-<pid>-<n>.log (ALVIE_RPC_LOG_DIR to choose the
    directory); it stays when the plugin fails.
  - ALVIE_RPC_RECORD=FILE records every request and answer of every backend in FILE (JSON lines);
    ALVIE_RPC_REPLAY=FILE answers from such a recording without starting the plugin, and fails at the first
    request that differs from it: to reproduce a run, or to test Core without the plugin's runtime.
  - At exit, Core asks each plugin to shut down, and kills it after a second.
*)

open Core
open Alvie_plugin
module Backend = Alvie_backend.Backend

let default_timeout = 60.

let timeout () =
  match Sys.getenv "ALVIE_RPC_TIMEOUT" with
  | None -> default_timeout
  | Some s ->
    (match Option.try_with (fun () -> Float.of_string s) with
     | Some t when Float.(t > 0.) -> t
     | _ -> raise (Backend.Failed (sprintf "ALVIE_RPC_TIMEOUT must be a number of seconds greater than zero, not %S" s)))

type transport =
  | Process of Proc.t
  | Replay of { mutable answers : (Yojson.Safe.t * Yojson.Safe.t) list; file : string }

type conn = {
  plugin : string;
  transport : transport;
  session : int; (* the number of the backend in this run, for recordings *)
  mutable next_id : int;
  mutable closed : bool;
}

let failf fmt = Printf.ksprintf (fun m -> raise (Backend.Failed m)) fmt

(* Recording *)

let record_channel =
  lazy (Option.map (Sys.getenv "ALVIE_RPC_RECORD") ~f:(fun f -> Out_channel.create f))

let record conn ~request ~(answer : Yojson.Safe.t) =
  Option.iter (Lazy.force record_channel) ~f:(fun oc ->
      Out_channel.output_string oc (Yojson.Safe.to_string (`Assoc [ ("session", `Int conn.session); ("request", request); ("answer", answer) ]));
      Out_channel.newline oc;
      Out_channel.flush oc)

let replay_sessions : (int, (Yojson.Safe.t * Yojson.Safe.t) list) Hashtbl.t Lazy.t =
  lazy (
    let t = Hashtbl.create (module Int) in
    Option.iter (Sys.getenv "ALVIE_RPC_REPLAY") ~f:(fun file ->
        let lines = try In_channel.read_lines file with Sys_error m -> failf "cannot read the recording ALVIE_RPC_REPLAY: %s" m in
        List.iteri lines ~f:(fun n line ->
            match Yojson.Safe.from_string line with
            | `Assoc fs ->
              (match List.Assoc.find fs ~equal:String.equal "session", List.Assoc.find fs ~equal:String.equal "request", List.Assoc.find fs ~equal:String.equal "answer" with
               | Some (`Int s), Some req, Some ans -> Hashtbl.add_multi t ~key:s ~data:(req, ans)
               | _ -> failf "%s:%d: not a line of a recording (session, request, answer)" file (n + 1))
            | _ | (exception Yojson.Json_error _) -> failf "%s:%d: not a line of a recording" file (n + 1));
        Hashtbl.map_inplace t ~f:List.rev);
    t)

(* Live connections, shut down at exit *)

let live : conn list ref = ref []
let sessions = ref 0

let tail_of = function
  | Process p ->
    (match Proc.stderr_tail p ~lines:15 with
     | [] -> sprintf " Its log (%s) is empty." p.stderr_file
     | ls -> sprintf "\nThe end of its log (%s):\n  %s" p.stderr_file (String.concat ~sep:"\n  " ls))
  | Replay _ -> ""

(* Sends a request and returns the result of its answer *)
let call ?timeout:t conn ~meth (params : Yojson.Safe.t) : Yojson.Safe.t =
  if conn.closed then failf "plugin %s: %s after the plugin was shut down (a bug)" conn.plugin meth;
  let id = conn.next_id in
  conn.next_id <- id + 1;
  let request = Alvie_backend.Protocol.request ~id ~meth params in
  let answer_json =
    match conn.transport with
    | Replay r ->
      (match r.answers with
       | (req, ans) :: rest when Yojson.Safe.equal req request -> r.answers <- rest; ans
       | (req, _) :: _ -> failf "the run differs from the recording %s (session %d) at request %d:\n  recorded: %s\n  now:      %s" r.file conn.session id (Yojson.Safe.to_string req) (Yojson.Safe.to_string request)
       | [] -> failf "the recording %s (session %d) has no request %d: %s" r.file conn.session id (Yojson.Safe.to_string request))
    | Process p ->
      let stopped what =
        let how = match Proc.status p with Some s -> Proc.describe_status s | None -> "it closed its standard output" in
        failf "plugin %s stopped %s (%s).%s" conn.plugin what how (tail_of conn.transport) in
      (match Proc.send p (Yojson.Safe.to_string request) with
       | Error _ -> stopped (sprintf "before %s" meth)
       | Ok () -> ());
      let timeout = Option.value t ~default:(timeout ()) in
      (match Proc.read_line p ~timeout with
       | `Timeout ->
         Proc.stop p ~grace:0.;
         failf "plugin %s did not answer %s within %gs (ALVIE_RPC_TIMEOUT), and was stopped.%s" conn.plugin meth timeout (tail_of conn.transport)
       | `Eof -> stopped (sprintf "during %s" meth)
       | `Line line ->
         (match Yojson.Safe.from_string line with
          | j -> j
          | exception Yojson.Json_error _ ->
            failf "plugin %s answered %s with a line that is not JSON: %S\n  (a plugin writes only protocol messages on its standard output: write logs to standard error)%s"
              conn.plugin meth (String.prefix line 200) (tail_of conn.transport))) in
  record conn ~request ~answer:answer_json;
  match Alvie_backend.Protocol.answer_of_json ~id answer_json with
  | Error why -> failf "plugin %s answered %s with something that is not an answer: %s.%s" conn.plugin meth why (tail_of conn.transport)
  | Ok (Result r) -> r
  | Ok (Error { message; data; _ }) ->
    Option.iter data ~f:(fun d -> Logs.err (fun m -> m "plugin %s, %s: %s" conn.plugin meth (match d with `String s -> s | d -> Yojson.Safe.to_string d)));
    failf "plugin %s failed in %s: %s%s" conn.plugin meth message (tail_of conn.transport)

let shutdown conn =
  if not conn.closed then begin
    (try ignore (call ~timeout:1. conn ~meth:"shutdown" (`Assoc [])) with _ -> ());
    conn.closed <- true;
    match conn.transport with Process p -> Proc.stop p ~grace:1. | Replay _ -> ()
  end

let () = at_exit (fun () -> List.iter !live ~f:shutdown)

let log_dir () = Option.value (Sys.getenv "ALVIE_RPC_LOG_DIR") ~default:Filename.temp_dir_name

(* Starts the plugin of the manifest in dir (or follows the recording), and shakes hands *)
let connect ~dir ~(manifest : Manifest_file.t) ~config ~variant : conn =
  let session = !sessions in
  incr sessions;
  let transport =
    match Sys.getenv "ALVIE_RPC_REPLAY" with
    | Some file ->
      Replay { answers = Option.value (Hashtbl.find (Lazy.force replay_sessions) session) ~default:[]; file }
    | None ->
      let prog, args = match manifest.kind with
        | External (prog :: args) -> (prog, args)
        | External [] | Native -> failf "plugin %s is not external: it has no command" manifest.name in
      (* A program given with a directory is relative to the plugin's directory; a bare name is looked up in PATH *)
      let prog = if String.mem prog '/' && Filename.is_relative prog then Filename.concat dir prog else prog in
      Core_unix.mkdir_p (log_dir ());
      let stderr_file = Filename.concat (log_dir ()) (sprintf "alvie-%s-%d-%d.log" manifest.name (Pid.to_int (Core_unix.getpid ())) session) in
      (match Proc.start ~cwd:dir ~prog ~args ~stderr_file with
       | p -> Process p
       | exception Core_unix.Unix_error (e, _, _) ->
         failf "cannot start plugin %s with %s (from %s): %s" manifest.name (String.concat ~sep:" " (prog :: args)) dir (Core_unix.Error.message e)
       | exception Caml_unix.Unix_error (e, _, _) ->
         failf "cannot start plugin %s with %s (from %s): %s" manifest.name (String.concat ~sep:" " (prog :: args)) dir (Caml_unix.error_message e)) in
  let conn = { plugin = manifest.name; transport; session; next_id = 0; closed = false } in
  live := conn :: !live;
  let hello = call conn ~meth:"initialize" (Alvie_backend.Protocol.initialize_params ~core:manifest.core ~plugin:manifest.name ~config ~variant) in
  (match Alvie_backend.Protocol.hello_of_result hello with
   | Error why -> failf "plugin %s did not shake hands: %s.%s" manifest.name why (tail_of transport)
   | Ok h ->
     if not (String.equal h.name manifest.name) then failf "the program of plugin %s says it is plugin %s" manifest.name h.name;
     if not (String.equal h.plugin_version manifest.version) then
       failf "the program of plugin %s is version %s, but its manifest is version %s" manifest.name h.plugin_version manifest.version;
     let declared = List.filter_map manifest.capabilities ~f:(function Restore -> Some "restore" | Clone -> Some "clone" | Parallel -> None) in
     let missing = List.filter declared ~f:(fun c -> not (List.mem h.capabilities c ~equal:String.equal)) in
     if not (List.is_empty missing) then
       failf "the manifest of plugin %s declares %s, which its program does not have" manifest.name (Diag.enumerate missing));
  conn

(* The backend of an external plugin *)

type t = { conn : conn; instance : int }

let protocol_step instance (s : Backend.step) : Alvie_backend.Protocol.step =
  { instance; section = s.section; position = s.position; atom = s.atom; programs = s.programs }

let expect_ok conn meth r = match Alvie_backend.Protocol.step_of_result r with Ok x -> x | Error why -> failf "plugin %s answered %s: %s" conn.plugin meth why

(* The plugin of the directory dir, whose manifest says it is external *)
let native ~dir : (module Alvie_backend.Native.S) =
  let plugin =
    lazy (match Plugin.load dir with
        | Ok p -> p
        | Error ds -> raise (Alvie_cli.Errors.User_error (sprintf "the plugin in %s has %d problem%s:\n%s" dir (List.length ds) (if List.length ds = 1 then "" else "s") (Diag.list_to_string ds)))) in
  (module struct
    let plugin = plugin

    module B = struct
      type nonrec t = t
      type bookkeeping = string [@@deriving sexp] (* the JSON of the plugin's bookkeeping *)

      (* those of the manifest, which the handshake checks; the plugin files are read here, when the commands are
         made *)
      let capabilities =
        List.filter_map (Lazy.force plugin).manifest.capabilities ~f:(function
            | Manifest_file.Restore -> Some Backend.Restore | Clone -> Some Backend.Clone | Parallel -> None)

      let instance_call t meth = ignore (call t.conn ~meth (Alvie_backend.Protocol.instance_params t.instance))
      let pre t = instance_call t "pre"
      let post t = instance_call t "post"

      let step t (s : Backend.step) =
        let os, bk = expect_ok t.conn "step" (call t.conn ~meth:"step" (Alvie_backend.Protocol.step_params (protocol_step t.instance s))) in
        (os, Yojson.Safe.to_string bk)

      let restore t (s : Backend.step) ~observations bk =
        let bookkeeping = try Yojson.Safe.from_string bk with Yojson.Json_error _ -> `Null in
        ignore (call t.conn ~meth:"restore" (Alvie_backend.Protocol.restore_params (protocol_step t.instance s) ~observations ~bookkeeping))

      let clone t =
        match Alvie_backend.Protocol.instance_of_result (call t.conn ~meth:"clone" (Alvie_backend.Protocol.instance_params t.instance)) with
        | Ok instance -> { t with instance }
        | Error why -> failf "plugin %s answered clone: %s" t.conn.plugin why
    end

    let none = "null"
    let make ~config ~variant = { conn = connect ~dir ~manifest:(Lazy.force plugin).manifest ~config ~variant; instance = 0 }
  end)
