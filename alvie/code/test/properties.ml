(*
  tt_properties: the property catalogue of ALVIE/Core (Ltscompare.Properties) on small models of the toy plugin
  (test/fixtures/toy), with the hooks derived from its files. It needs mCRL2 (ltscompare, lts2pbes, pbes2bool),
  but no simulator.

  The two models run the same inputs: call x enters the victim, put 1 runs in it (silent: the view hides Ok), and
  ret leaves it. They differ only in what ret shows: Leave in the first, Ret(mode = low) in the second.
*)

open Core
open Alvie_plugin

let code_dir =
  let rec up dir n =
    if n = 0 then failwith "run tt_properties from alvie/code"
    else if Sys_unix.file_exists_exn (Filename.concat dir "test/fixtures/toy/alvie-plugin.yaml") then dir
    else up (Filename.dirname dir) (n - 1) in
  up (Sys_unix.getcwd ()) 6

let plugin =
  match Plugin.load (Filename.concat code_dir "test/fixtures/toy") with
  | Ok p -> p
  | Error es -> failwith (Diag.list_to_string es)

module H = Ltscompare.Plugin_hooks.Make (struct let plugin = plugin let secret_values = [ "0"; "1" ] end)
module P = Ltscompare.Properties.Make (H)

let atom text = Result.ok_or_failwith (Result.map_error (Grammar.parse_value plugin.grammar ~file:"atom" ~ty:"ops" text) ~f:Diag.to_string)
let input ~low text = H.Input.Atom { cls = "ops"; low; atom = atom text }

(* A chain of transitions from state 0 *)
let model (steps : (H.Input.t * Value.t) list) : P.C.i_lts_t =
  let transition = List.foldi steps ~init:P.C.IIOMealy.TransitionMap.empty ~f:(fun n acc (i, o) -> Map.set acc ~key:(n, i) ~data:(o, n + 1)) in
  P.C.i_lts_of_mealy { s0 = 0; states = P.C.IIOMealy.SSet.of_list (List.init (List.length steps + 1) ~f:Fn.id); transition;
                       pred_map = P.C.IIOMealy.PredMap.empty; input_alphabet = P.C.IIOMealy.ISet.empty }

let run_ ~ret_output =
  model [ (input ~low:true "call x", Value.Node ("Enter", [ ("target", Value.Int 1) ]));
          (input ~low:false "put 1", Value.Node ("Ok", []));
          (input ~low:false "ret", ret_output) ]

let m_leave = run_ ~ret_output:(Value.Node ("Leave", []))
let m_ret = run_ ~ret_output:(Value.Node ("Ret", [ ("mode", Value.Sym "low") ]))

let tmpdir = lazy (Filename_unix.temp_dir "tt_properties" "")

let test_equivalence () =
  let tmpdir = Lazy.force tmpdir in
  Alcotest.(check bool) "a model is equivalent to itself" true (Poly.equal (P.equivalence ~tmpdir m_leave m_leave) `Equivalent);
  match P.equivalence ~tmpdir m_leave m_ret with
  | `Only_in_first trace -> Alcotest.(check int) "the trace that only the first has" 3 (List.length trace)
  | _ -> Alcotest.fail "the models differ in what ret shows"

let test_noninterference () =
  let tmpdir = Lazy.force tmpdir in
  let count, _, _ = P.noninterference ~tmpdir ~names:("leave", "ret") m_leave m_ret in
  Alcotest.(check int) "one witness" 1 count;
  let count, _, _ = P.noninterference ~tmpdir ~names:("leave", "ret") ~baseline:(m_leave, m_ret) m_leave m_ret in
  Alcotest.(check int) "none once the baseline has it" 0 count

let test_formula () =
  let tmpdir = Lazy.force tmpdir in
  let check name formula expected =
    let file = Filename.concat tmpdir (name ^ ".mcf") in
    Out_channel.write_all file ~data:formula;
    match P.formula ~tmpdir m_leave ~formula_file:file with
    | Ok b -> Alcotest.(check bool) name expected b
    | Error e -> Alcotest.fail e in
  check "something can happen first" "<true>true" true;
  check "the run ends" "[true*]<true>true" false

let () =
  if Sys_unix.command "command -v ltscompare >/dev/null && command -v lts2pbes >/dev/null && command -v pbes2bool >/dev/null" <> 0 then (
    eprintf "tt_properties needs mCRL2 (ltscompare, lts2pbes, pbes2bool) on PATH\n";
    exit 2);
  Alcotest.run "ALVIE properties" [
    ("catalogue", [
        Alcotest.test_case "equivalence and inclusion" `Quick test_equivalence;
        Alcotest.test_case "noninterference with a baseline" `Quick test_noninterference;
        Alcotest.test_case "mu-calculus formulas" `Quick test_formula ]) ]
