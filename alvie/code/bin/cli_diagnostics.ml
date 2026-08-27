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

let protect ~debug f =
  try f () with
  | User_error message ->
    eprintf "ALVIE error: %s\n" message;
    eprintf "For help or a bug report, see %s\n" bug_report_url;
    Stdlib.exit 2
  | Sys_error message ->
    eprintf "ALVIE error: %s\n" message;
    eprintf "For help or a bug report, see %s\n" bug_report_url;
    Stdlib.exit 2
  | exn ->
    eprintf "ALVIE failed unexpectedly: %s\n" (Exn.to_string exn);
    if debug then Printexc.print_backtrace stderr;
    eprintf "Re-run with --debug and report the command, specifications, and logs at %s\n" bug_report_url;
    Stdlib.exit 1
