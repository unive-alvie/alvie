open Core

(* The errors and their report are those of every command (Alvie_cli.Errors); this module adds those of Sancus *)
exception User_error = Alvie_cli.Errors.User_error

let bug_report_url = Alvie_cli.Errors.bug_report_url
let fail = Alvie_cli.Errors.fail
let require_file = Alvie_cli.Errors.require_file
let require_directory = Alvie_cli.Errors.require_directory
let prepare_directory = Alvie_cli.Errors.prepare_directory
let read_file = Alvie_cli.Errors.read_file

let parse_spec ~enclave_spec ~attacker_spec =
  match Sancus.Testdl.Parser.parse_spec (enclave_spec ^ " " ^ attacker_spec) with
  | Ok spec -> spec
  | Error message ->
    fail "Could not parse the TestDL specifications: %s. Check --encl-spec and --att-spec." message

(*
  Parses the specs with the grammar of plugins/sancus (ALVIE/Core's spec language), which also reads constraint
  blocks, and gives them as well in the form of testdl.ml, for the simulator.
*)
let parse_spec_files ~enclave_spec_file ~attacker_spec_file =
  let plugin = Lazy.force Sancus.Generic_inputgen.plugin in
  match Alvie_plugin.Spec.parse_files plugin [ enclave_spec_file; attacker_spec_file ] with
  | Error diags ->
    fail "Could not parse the TestDL specifications (--encl-spec and --att-spec):\n%s" (Alvie_plugin.Diag.list_to_string diags)
  | Ok spec ->
    (match Sancus.Atom_value.to_test_spec spec with
     | Ok old -> (spec, old)
     | Error m -> fail "The specifications use something that the simulator does not support: %s." m)

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

let report = Alvie_cli.Errors.report

let classify_failure message =
  if String.is_substring message ~substring:"Stimulus did not complete" then
    Some ("ALVIE incomplete", "the simulator did not finish. Inspect the run log and retry in a fresh namespace.", 3)
  else if String.is_substring message ~substring:"Could not clone Sancus repository"
       || String.is_substring message ~substring:"Could not check out Sancus commit"
       || String.is_substring message ~substring:"returned" then
    Some ("ALVIE backend error", message, 1)
  else
    None

let protect ~debug f = Alvie_cli.Errors.protect ~classify:classify_failure ~debug f
