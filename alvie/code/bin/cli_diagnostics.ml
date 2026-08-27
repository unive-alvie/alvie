open Core

exception User_error of string

let bug_report_url = "https://github.com/unive-alvie/alvie/issues/new?template=bug-report.yml"

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

let parse_spec ~enclave_spec ~attacker_spec =
  match Sancus.Testdl.Parser.parse_spec (enclave_spec ^ " " ^ attacker_spec) with
  | Ok spec -> spec
  | Error message ->
    fail "Could not parse the TestDL specifications: %s. Check --encl-spec and --att-spec." message

let validate_oracle oracle =
  if not (List.mem ["randomwalk"; "pac"; "exhaustive"] oracle ~equal:String.equal) then
    fail "Unknown --oracle value %S. Choose randomwalk, pac, or exhaustive." oracle

let validate_probability ~option value =
  if Float.is_nan value || Float.(value < 0.0 || value > 1.0) then
    fail "%s must be between 0 and 1, but got %g." option value

let validate_open_probability ~option value =
  if Float.is_nan value || Float.(value <= 0.0 || value >= 1.0) then
    fail "%s must be greater than 0 and smaller than 1, but got %g." option value

let validate_positive ~option value =
  if value <= 0 then fail "%s must be greater than zero, but got %d." option value

let validate_learning_options ~oracle ~epsilon ~delta ~step_limit ~reset_probability ~bad_probability ~round_limit =
  validate_oracle oracle;
  validate_open_probability ~option:"--epsilon" epsilon;
  validate_open_probability ~option:"--delta" delta;
  validate_positive ~option:"--step-limit" step_limit;
  validate_probability ~option:"--reset-probability" reset_probability;
  validate_probability ~option:"--bad-probability" bad_probability;
  Option.iter round_limit ~f:(validate_positive ~option:"--round-limit")

let require_secret_if_needed enclave secret =
  if Option.is_none secret && Sancus.Enclave.Enclave.has_secret enclave then
    fail "The enclave specification uses ?. Supply --secret <value>."

let require_optional_pair ~first_option first ~second_option second =
  match first, second with
  | None, None | Some _, Some _ -> ()
  | Some _, None -> fail "%s requires %s." first_option second_option
  | None, Some _ -> fail "%s requires %s." second_option first_option

let report ~heading ~message ~status =
  eprintf "%s: %s\n" heading message;
  eprintf "For help or a bug report, see %s\n" bug_report_url;
  Stdlib.exit status

let classify_failure message =
  if String.is_substring message ~substring:"Stimulus did not complete" then
    Some ("ALVIE incomplete", "the simulator did not finish. Inspect the run log and retry in a fresh namespace.", 3)
  else if String.is_substring message ~substring:"Could not clone Sancus repository"
       || String.is_substring message ~substring:"Could not check out Sancus commit"
       || String.is_substring message ~substring:"returned" then
    Some ("ALVIE backend error", message, 1)
  else
    None

let protect ~debug f =
  if debug then Printexc.record_backtrace true;
  try f () with
  | User_error message ->
    report ~heading:"ALVIE error" ~message ~status:2
  | Sys_error message ->
    report ~heading:"ALVIE error" ~message ~status:2
  | Failure message ->
    (match classify_failure message with
     | Some (heading, message, status) -> report ~heading ~message ~status
     | None ->
       eprintf "ALVIE failed unexpectedly: %s\n" message;
       if debug then Printexc.print_backtrace stderr;
       eprintf "Re-run with --debug and report the command, specifications, and logs at %s\n" bug_report_url;
       Stdlib.exit 1)
  | exn ->
    eprintf "ALVIE failed unexpectedly: %s\n" (Exn.to_string exn);
    if debug then Printexc.print_backtrace stderr;
    eprintf "Re-run with --debug and report the command, specifications, and logs at %s\n" bug_report_url;
    Stdlib.exit 1
