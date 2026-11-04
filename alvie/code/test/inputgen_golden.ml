(*
  Golden corpus for the input generator.

  The corpus records, for input/output histories taken from the checked-in learned models, the input options
  that Inputgen.get_options offers after each prefix. It pins down the current behaviour of the input
  generator, so that a reimplementation can be compared with it.

  The histories are random walks (with a fixed seed) on the models in results/: every prefix of a walk is a
  history that the learner actually observed, so it needs neither the simulator nor mCRL2.

  - `generate` writes the corpus;
  - `check` recomputes the options of every recorded prefix and reports the differences.
*)
open Core
open Sancus

module IOInterop = Interop.Interop (Input) (Output_internal)

type option_t = [ `Stop | `Next of Input.t ] [@@deriving sexp, equal]

(* A walk on one model: the inputs, the observations of each step, and the options before each step and after the last *)
type walk_t = {
  model : string;
  inputs : Input.t list;
  outputs : Output_internal.element_t list list;
  options : option_t list list;
} [@@deriving sexp]

(* Walks end early when the model has no transition for the options offered: identical walks are kept once *)
(* Input problems are reported in one line with exit code 2, as the other ALVIE tools do *)
let fail_input fmt = ksprintf (fun msg -> eprintf "ALVIE error: %s\n" msg; exit 2) fmt

let walks_per_model = 8
let max_walk_length = 40

(* Only the observations matter to the input generator: the bookkeeping of the outputs is left empty *)
let output_of_elements ol : Output_internal.t = (ol, [], 0)

(* <commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-<int|nint>].dot *)
let spec_files_of_model ~root model =
  let base = Filename.chop_extension (Filename.basename model) in
  let subdir = Filename.basename (Filename.dirname model) in
  let specdir = if String.equal subdir "results" then root ^/ "spec-lib" else root ^/ "spec-lib" ^/ subdir in
  match String.split base ~on:'-' with
  | _commit :: attacker :: rest ->
      let rest = List.rev rest in
      let rest = (match rest with ("int" | "nint") :: r -> r | r -> r) in
      (match rest with
       | _delta :: _eps :: secret :: enclave_rev ->
           let enclave = String.concat ~sep:"-" (List.rev enclave_rev) in
           (specdir ^/ attacker ^ ".atdl", specdir ^/ enclave ^ ".etdl", secret)
       | _ -> fail_input "unexpected model name %s: expected <commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-int|-nint].dot" base)
  | _ -> fail_input "unexpected model name %s: expected <commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-int|-nint].dot" base

let spec_dfa_of_model ~root model =
  let attacker_fn, enclave_fn, secret = spec_files_of_model ~root model in
  List.iter [model; attacker_fn; enclave_fn] ~f:(fun fn ->
    if not (Sys_unix.file_exists_exn fn) then fail_input "%s not found. Is --root (default: ../..) the repository root?" fn);
  let source = In_channel.read_all enclave_fn ^ " " ^ In_channel.read_all attacker_fn in
  match Testdl.Parser.parse_spec source with
  | Error e -> fail_input "specification of %s: %s" model e
  | Ok (Testdl.Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) ->
      let enclave = Enclave.Enclave.expand_secret secret enclave in
      Inputgen.build_spec_dfa (Testdl.Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup)

let options spec_dfa inputs outputs =
  snd (Inputgen.get_options spec_dfa inputs (List.map outputs ~f:output_of_elements))

let walk ~rng ~spec_dfa ~(m : IOInterop.IIOMealy.t) ~model =
  let rec go state rev_inputs rev_outputs rev_options n =
    let inputs, outputs = List.rev rev_inputs, List.rev rev_outputs in
    let opts = options spec_dfa inputs outputs in
    let rev_options = opts :: rev_options in
    let candidates = List.filter_map opts ~f:(function
      | `Next i -> Option.map (Map.find m.transition (state, i)) ~f:(fun (o, s') -> (i, o, s'))
      | `Stop -> None) in
    if n >= max_walk_length || List.is_empty candidates then
      { model; inputs; outputs; options = List.rev rev_options }
    else
      let i, ((ol, _, _) : Output_internal.t), s' = List.nth_exn candidates (Random.State.int rng (List.length candidates)) in
      go s' (i :: rev_inputs) (ol :: rev_outputs) rev_options (n + 1)
  in
  go m.s0 [] [] [] 0

let models ~root =
  let dot_files dir =
    Sys_unix.ls_dir dir
    |> List.filter ~f:(fun f -> String.is_suffix f ~suffix:".dot")
    |> List.map ~f:(fun f -> dir ^/ f) in
  List.sort ~compare:String.compare (dot_files (root ^/ "results") @ dot_files (root ^/ "results" ^/ "example"))

(* Model paths are stored relative to the repository root *)
let relative ~root path = Option.value ~default:path (String.chop_prefix path ~prefix:(root ^ "/"))

let generate ~root ~out =
  let walks = List.concat_map (models ~root) ~f:(fun model ->
    let m = IOInterop.t_of_dot_file IOInterop.IIOMealy.ISet.empty model in
    let spec_dfa = spec_dfa_of_model ~root model in
    let rng = Random.State.make [| String.hash (relative ~root model) |] in
    List.init walks_per_model ~f:(fun _ -> walk ~rng ~spec_dfa ~m ~model:(relative ~root model))
    |> List.dedup_and_sort ~compare:(fun w w' -> [%compare: Input.t list] w.inputs w'.inputs)) in
  Out_channel.with_file out ~f:(fun oc ->
    List.iter walks ~f:(fun w -> Out_channel.output_string oc (Sexp.to_string_mach (sexp_of_walk_t w)); Out_channel.newline oc));
  printf "Wrote %d walks (%d prefixes) to %s\n" (List.length walks)
    (List.sum (module Int) walks ~f:(fun w -> List.length w.options)) out

let read_corpus corpus =
  if not (Sys_unix.file_exists_exn corpus) then
    fail_input "corpus %s not found. Run from alvie/code, or pass --corpus; `tt_inputgen_golden generate` writes it." corpus;
  List.mapi (In_channel.read_lines corpus) ~f:(fun n l ->
    try walk_t_of_sexp (Sexp.of_string l)
    with exn -> fail_input "%s, line %d: not a walk (%s)" corpus (n + 1) (Exn.to_string exn))

let check ~root ~corpus =
  let walks = read_corpus corpus in
  let spec_dfas = String.Table.create () in
  let differences = ref 0 and prefixes = ref 0 in
  List.iter walks ~f:(fun w ->
    let spec_dfa = Hashtbl.find_or_add spec_dfas w.model ~default:(fun () -> spec_dfa_of_model ~root (root ^/ w.model)) in
    List.iteri w.options ~f:(fun n expected ->
      incr prefixes;
      let actual = options spec_dfa (List.take w.inputs n) (List.take w.outputs n) in
      if not (List.equal equal_option_t expected actual) then (
        incr differences;
        let show l = Sexp.to_string_hum (List.sexp_of_t sexp_of_option_t l) in
        eprintf "%s, prefix of length %d:\n  expected: %s\n  actual:   %s\n" w.model n (show expected) (show actual))));
  printf "Checked %d walks (%d prefixes): %d differences\n" (List.length walks) !prefixes !differences;
  if !differences > 0 then exit 1

let root_flag = Command.Param.(flag "--root" (optional_with_default "../.." string) ~doc:"dir repository root (default: ../..)")
let corpus_flag = Command.Param.(flag "--corpus" (optional_with_default "test/golden/inputgen.sexp" string) ~doc:"file the corpus (default: test/golden/inputgen.sexp)")

let () =
  Command_unix.run (Command.group ~summary:"Golden corpus of the input generator" [
    "generate", Command.basic ~summary:"Write the corpus from the learned models in results/"
      (let%map_open.Command root = root_flag and out = corpus_flag in fun () -> generate ~root ~out);
    "check", Command.basic ~summary:"Check the input generator against the corpus"
      (let%map_open.Command root = root_flag and corpus = corpus_flag in fun () -> check ~root ~corpus);
  ])
