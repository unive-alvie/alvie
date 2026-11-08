(*
  The errors of ALVIE's commands, and how they are reported (the same for every plugin):

  - a mistake in the command or the files (User_error, a file that cannot be read, a model of a later format, a
    plugin file with problems): "ALVIE error: <message>", exit status 2;
  - a backend that cannot go on (Backend.Failed, e.g. an external plugin that crashed): "ALVIE backend error",
    exit status 1;
  - anything else is unexpected: "ALVIE failed unexpectedly", with the backtrace under --debug, exit status 1.

  A plugin can classify some failures of its own (classify): e.g. ALVIE/Sancus reports a simulation that did not
  finish with exit status 3.

  Exit status 4 is not an error: the property that a command checks does not hold.
*)
open Core

exception User_error of string

let bug_report_url = "https://github.com/unive-alvie/alvie/issues/new?template=bug-report.yml"
let does_not_hold = 4

let fail format = Printf.ksprintf (fun message -> raise (User_error message)) format

let require_file ~option path =
  match Sys_unix.file_exists path with
  | `Yes ->
    if Sys_unix.is_file_exn path then path
    else fail "%s must name a file, but %S is not a file." option path
  | `No -> fail "%s names a file that does not exist: %S." option path
  | `Unknown -> fail "Cannot inspect %s at %S." option path

let require_directory ~option path =
  match Sys_unix.file_exists path with
  | `Yes ->
    if Sys_unix.is_directory_exn path then path
    else fail "%s must name a directory, but %S is not a directory." option path
  | `No -> fail "%s names a directory that does not exist: %S." option path
  | `Unknown -> fail "Cannot inspect %s at %S." option path

let prepare_directory ~option path =
  if String.is_empty path then fail "%s cannot be empty." option;
  let path = String.rstrip path ~drop:(Char.equal '/') in
  let path = if String.is_empty path then "/" else path in
  match Sys_unix.file_exists path with
  | `No -> Core_unix.mkdir_p path; path
  | `Yes when Sys_unix.is_directory_exn path -> path
  | `Yes -> fail "%s must name a directory, but %S is not a directory." option path
  | `Unknown -> fail "Cannot inspect %s at %S." option path

let read_file ~option path =
  let path = require_file ~option path in
  try In_channel.read_all path with
  | Sys_error message -> fail "Could not read %s at %S: %s" option path message

let report ~heading ~message ~status =
  eprintf "%s: %s\n" heading message;
  eprintf "For help or a bug report, see %s\n" bug_report_url;
  Stdlib.exit status

let unexpected ~debug message =
  eprintf "ALVIE failed unexpectedly: %s\n" message;
  if debug then Printexc.print_backtrace stderr;
  eprintf "Re-run with --debug and report the command, specifications, and logs at %s\n" bug_report_url;
  Stdlib.exit 1

(* Runs f, reporting its errors; classify gives the heading, message and status of a Failure that the plugin
   recognizes *)
let protect ?(classify = fun _ -> None) ~debug f =
  if debug then Printexc.record_backtrace true;
  try f () with
  | User_error message | Sys_error message | Interop.Unsupported_format message ->
    report ~heading:"ALVIE error" ~message ~status:2
  | Alvie_backend.Backend.Failed message -> report ~heading:"ALVIE backend error" ~message ~status:1
  | Failure message ->
    (match classify message with
     | Some (heading, message, status) -> report ~heading ~message ~status
     | None -> unexpected ~debug message)
  | exn -> unexpected ~debug (Exn.to_string exn)

(* Logging on stderr: debug-level with --debug, otherwise warnings only *)
let setup_logs ~debug =
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some (if debug then Logs.Debug else Logs.Warning))
