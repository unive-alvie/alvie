(*
  The process of an external plugin: started with pipes for its standard input and output, and its standard error
  in a file; lines read with a timeout. Plain Stdlib and Unix.
*)

type t = {
  pid : int;
  input : out_channel; (* the plugin's standard input *)
  output : Unix.file_descr; (* its standard output *)
  buf : Buffer.t;
  stderr_file : string;
  mutable alive : bool;
}

let () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore (* a write to a plugin that exited fails, instead of killing ALVIE *)

let start ~cwd ~prog ~args ~stderr_file =
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err = Unix.openfile stderr_file [ O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC ] 0o644 in
  let here = Sys.getcwd () in
  let pid =
    Fun.protect ~finally:(fun () -> Sys.chdir here) (fun () ->
        Sys.chdir cwd;
        Unix.create_process prog (Array.of_list (prog :: args)) in_r out_w err) in
  Unix.close in_r; Unix.close out_w; Unix.close err;
  { pid; input = Unix.out_channel_of_descr in_w; output = out_r; buf = Buffer.create 4096; stderr_file; alive = true }

let send t line =
  try output_string t.input line; output_char t.input '\n'; flush t.input; Ok ()
  with Sys_error m -> Error m

(* The next line of the plugin's output, without the newline *)
let rec read_line t ~timeout =
  let s = Buffer.contents t.buf in
  match String.index_opt s '\n' with
  | Some i ->
    Buffer.clear t.buf;
    Buffer.add_string t.buf (String.sub s (i + 1) (String.length s - i - 1));
    `Line (String.sub s 0 i)
  | None ->
    let start = Unix.gettimeofday () in
    (match Unix.select [ t.output ] [] [] timeout with
     | [], _, _ -> `Timeout
     | _ ->
       let chunk = Bytes.create 65536 in
       (match Unix.read t.output chunk 0 65536 with
        | 0 -> `Eof
        | n ->
          Buffer.add_subbytes t.buf chunk 0 n;
          read_line t ~timeout:(Float.max 0. (timeout -. (Unix.gettimeofday () -. start))))
     | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_line t ~timeout)

(* How the process ended, if it has *)
let status t =
  match Unix.waitpid [ Unix.WNOHANG ] t.pid with
  | 0, _ -> None
  | _, s -> t.alive <- false; Some s
  | exception Unix.Unix_error _ -> None

let describe_status = function
  | Unix.WEXITED n -> Printf.sprintf "it exited with status %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "it was killed by signal %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "it was stopped by signal %d" n

(* Waits a little for the process to end, then kills it *)
let stop t ~grace =
  if t.alive then begin
    (try close_out t.input with _ -> ());
    let deadline = Unix.gettimeofday () +. grace in
    let rec wait () =
      match status t with
      | Some _ -> ()
      | None when Unix.gettimeofday () < deadline -> Unix.sleepf 0.01; wait ()
      | None -> (try Unix.kill t.pid Sys.sigkill with _ -> ()); (try ignore (Unix.waitpid [] t.pid) with _ -> ()); t.alive <- false in
    wait ();
    (try Unix.close t.output with _ -> ())
  end

(* The last lines of the plugin's standard error *)
let stderr_tail t ~lines =
  let read file =
    let ic = open_in_bin file in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic)) in
  match read t.stderr_file with
  | text ->
    let all = List.filter (fun l -> l <> "") (String.split_on_char '\n' text) in
    let n = List.length all in
    List.filteri (fun i _ -> i >= n - lines) all
  | exception Sys_error _ -> []
