(*
  tt_tiny: Tiny, the reference platform of ALVIE/Core (plugins/tiny, lib/core/tiny), and the generic commands of
  Core on it (Alvie_cli.Runner): its semantics, the conformance kit (which must pass on Tiny and fail on broken
  variants of it), and learning. Nothing outside OCaml is needed; the fixtures, which need mCRL2, are
  `alvie tiny fixtures` (CI runs them in the image job).
*)

open Core
open Alvie_plugin
module G = Alvie_inputgen.Generator
module Tiny = Alvie_tiny.Tiny

let code_dir = Sys_unix.getcwd () (* dune runs tests from the test directory: see fixture *)

let fixture name =
  (* From _build/default/test, where dune runs the test, or from alvie/code *)
  let candidates = [ "plugins/tiny/fixtures/" ^ name; "../plugins/tiny/fixtures/" ^ name; "../../../plugins/tiny/fixtures/" ^ name ] in
  match List.find candidates ~f:Sys_unix.file_exists_exn with
  | Some f -> f
  | None -> failwithf "cannot find the fixture %s from %s" name code_dir ()

module R = Alvie_cli.Runner.Make (Tiny.Native)

let spec ?(secret = "0") name = R.load_spec ~files:[ fixture name ] ~secret:(Some secret)
let spec_of_text text = match Spec.parse (Lazy.force Tiny.plugin) [ ("test", text) ] with Ok s -> s | Error ds -> failwith (Diag.list_to_string ds)

(* Runs atoms (as a spec writes them) from a fresh test, and returns what each observed; each atom is of the class
   of the section the test is in, as the observations before it moved it *)
let run ?(config = []) ?variant spec_ atoms =
  let p = Lazy.force Tiny.plugin in
  let gen = G.make p spec_ in
  let b = Tiny.Native.make ~config ~variant in
  Tiny.Native.B.pre b;
  let _, out = List.fold atoms ~init:(G.initial gen, []) ~f:(fun (st, acc) text ->
      let section = G.current st in
      let cls = Option.value_exn (Plugin.atoms_of p section) in
      let atom = Result.ok_or_failwith (Result.map_error (Grammar.parse_value p.grammar ~file:"test" ~ty:cls text) ~f:Diag.to_string) in
      let i = { G.section; atom } in
      if not (G.legal gen st i) then failwithf "the spec does not allow %s" (R.show_input i) ();
      let st', step = R.backend_step gen st i in
      let os, _ = Tiny.Native.B.step b step in
      (G.observe gen st' os, R.show_obs os :: acc)) in
  List.rev out

let semantics_spec = spec_of_text "prepare { (timer 1 | timer 2 | timer 3 | eps); call };\nenclave { mov r0, ?; bz r0; pad r0; ret };\nisr { reti };\ncleanup { halt };\n"

let expand v = match Spec.expand_secret (Lazy.force Tiny.plugin) semantics_spec ~value:v with Ok s -> s | Error d -> failwith (Diag.to_string d)

let test_time () =
  (* bz takes 2 cycles on 0, pad 1: with ret, 1 + 2 + 1 + 1 cycles; on 1: 1 + 1 + 2 + 1 *)
  let atoms v = [ "call"; sprintf "mov r0, %s" v; "bz r0"; "pad r0"; "ret"; "halt" ] in
  Alcotest.(check (list string)) "secret 0" [ "[Enter]"; "[Run]"; "[Run]"; "[Run]"; "[Exit(time = 5)]"; "[Done]" ] (run (expand "0") (atoms "0"));
  Alcotest.(check (list string)) "secret 1" [ "[Enter]"; "[Run]"; "[Run]"; "[Run]"; "[Exit(time = 5)]"; "[Done]" ] (run (expand "1") (atoms "1"))

let test_interrupt () =
  (* timer 2: mov takes 1 cycle; bz on 0 takes 2, so the timer expires in its first cycle (latency 1); on 1 bz takes
     1 cycle, and the timer expires at its end (latency 0) *)
  let atoms v rest = [ "timer 2"; "call"; sprintf "mov r0, %s" v; "bz r0" ] @ rest in
  Alcotest.(check (list string)) "secret 0" [ "[Ok]"; "[Enter]"; "[Run]"; "[Irq(latency = 1)]"; "[Resume]"; "[Run]"; "[Exit(time = 2)]" ]
    (run (expand "0") (atoms "0" [ "reti"; "pad r0"; "ret" ]));
  Alcotest.(check (list string)) "secret 1" [ "[Ok]"; "[Enter]"; "[Run]"; "[Irq(latency = 0)]"; "[Resume]"; "[Run]"; "[Exit(time = 3)]" ]
    (run (expand "1") (atoms "1" [ "reti"; "pad r0"; "ret" ]));
  Alcotest.(check (list string)) "no interrupts" [ "[Ok]"; "[Enter]"; "[Run]"; "[Run]"; "[Run]"; "[Exit(time = 5)]" ]
    (run ~variant:"no-interrupts" (expand "0") (atoms "0" [ "pad r0"; "ret" ]));
  Alcotest.(check (list string)) "constant time" [ "[Ok]"; "[Enter]"; "[Run]"; "[Irq(latency = 1)]"; "[Resume]"; "[Run]"; "[Exit(time = 3)]" ]
    (run ~config:[ ("mitigation", "constant-time") ] (expand "1") (atoms "1" [ "reti"; "pad r0"; "ret" ]))

let test_config_errors () =
  Alcotest.check_raises "unknown variant" (Failure "Tiny: unknown variant \"fast\" (expected no-interrupts)") (fun () ->
      ignore (Tiny.make ~config:[] ~variant:(Some "fast")));
  Alcotest.(check (result (list (pair string string)) string)) "a fixture's config is checked"
    (Error "mitigation: \"fast\" is not one of none or constant-time")
    (Alvie_cli.Config.of_assoc (Lazy.force Tiny.plugin).manifest [ ("mitigation", "fast") ]);
  Alcotest.(check (result (list (pair string string)) string)) "and has the defaults" (Ok [ ("mitigation", "none") ])
    (Alvie_cli.Config.of_assoc (Lazy.force Tiny.plugin).manifest [])

(* Conformance *)

let failures (checks : R.check list) = List.filter_map checks ~f:(fun c -> Option.map c.failure ~f:(fun _ -> c.name))

let test_conformance name () =
  let checks, steps, _ = R.conformance ~config:[] ~variant:None ~spec:(spec name) ~tests:40 ~length:30 ~seed:0 in
  Alcotest.(check (list string)) "no check fails" [] (failures checks);
  Alcotest.(check bool) "every check ran" true (List.for_all checks ~f:(fun c -> c.runs > 0));
  Alcotest.(check bool) "tests ran" true (steps > 40)

(* Broken variants of Tiny: each breaks one part of the contract, which the kit must find *)
type mutation = Shared_clone | Restore_nothing | Sticky_pre | Undeclared_observation | Rejects_nop | Stale_cache | Random_time

module Mutant (M : sig val mutation : mutation end) : Alvie_backend.Native.S = struct
  let plugin = Tiny.plugin

  module B = struct
    type t = { tiny : Tiny.t; cache : (string * int, Value.t list) Hashtbl.t; rng : Random.State.t }
    type bookkeeping = unit [@@deriving sexp]

    let capabilities = Tiny.capabilities
    let pre t = match M.mutation with Sticky_pre -> () | _ -> Tiny.pre t.tiny
    let post t = Tiny.post t.tiny
    let clone t = match M.mutation with Shared_clone -> t | _ -> { t with tiny = Tiny.clone t.tiny }

    let step t (s : Alvie_backend.Backend.step) =
      match M.mutation with
      | Undeclared_observation when Option.equal String.equal (Value.tag s.atom) (Some "ret") -> ignore (Tiny.step t.tiny s); ([ Value.Node ("Exit", [ ("time", Bool true) ]) ], ())
      | Rejects_nop when String.equal s.section "enclave" && Option.equal String.equal (Value.tag s.atom) (Some "nop") -> ([ Value.Node ("Illegal", []) ], ())
      | Random_time when Option.equal String.equal (Value.tag s.atom) (Some "ret") -> ignore (Tiny.step t.tiny s); ([ Value.Node ("Exit", [ ("time", Int (Random.State.int t.rng 9)) ]) ], ())
      | Stale_cache ->
        (* a cache keyed without the atom: a later test with another atom at the same place observes the old one *)
        (match Hashtbl.find t.cache (s.section, s.position) with
         | Some os -> ignore (Tiny.step t.tiny s); (os, ())
         | None -> let os, () = Tiny.step t.tiny s in Hashtbl.set t.cache ~key:(s.section, s.position) ~data:os; (os, ()))
      | _ -> Tiny.step t.tiny s

    let restore t s ~observations bk = match M.mutation with Restore_nothing -> () | _ -> Tiny.restore t.tiny s ~observations bk
  end

  let none = ()
  let make ~config ~variant =
    { B.tiny = Tiny.make ~config ~variant; cache = Hashtbl.Poly.create (); rng = Random.State.make_self_init () }
end

let test_mutant ?(length = 30) mutation expected () =
  let module N = Mutant (struct let mutation = mutation end) in
  let module R = Alvie_cli.Runner.Make (N) in
  let spec_ = R.load_spec ~files:[ fixture (if Poly.equal mutation Rejects_nop then "safe-no-branch.spec" else "leak-interrupt.spec") ] ~secret:(Some "0") in
  let checks, _, _ = R.conformance ~config:[] ~variant:None ~spec:spec_ ~tests:40 ~length ~seed:0 in
  let failed = List.filter_map checks ~f:(fun c -> Option.map c.failure ~f:(fun _ -> c.name)) in
  Alcotest.(check bool) (sprintf "%s fails (failed: %s)" expected (String.concat ~sep:", " failed)) true (List.mem failed expected ~equal:String.equal)

(* Learning *)

let test_learning_is_deterministic () =
  let learn () = (R.learn ~config:[] ~variant:None ~spec:(spec "leak-time.spec") ~oracle:(Pac { epsilon = 0.01; delta = 0.01; round_limit = None }) ~seed:0 ()).model in
  let a = learn () and b = learn () in
  Alcotest.(check int) "the same states" (Set.length a.states) (Set.length b.states);
  Alcotest.(check bool) "the same transitions" true (Map.equal (fun (o, s) (o', s') -> R.O.equal o o' && s = s') a.transition b.transition);
  Alcotest.(check bool) "no illegal transitions" true (Map.for_all a.transition ~f:(fun (o, _) -> not (R.O.equal o R.Codec.illegal)))

let test_model_files () =
  let dir = Core_unix.mkdtemp (Filename.concat (Filename.temp_dir_name) "tt_tiny") in
  let file = Filename.concat dir "m.dot" in
  let m = (R.learn ~config:[] ~variant:None ~spec:(spec "safe-no-branch.spec") ~oracle:(Pac { epsilon = 0.01; delta = 0.01; round_limit = None }) ~seed:0 ()).model in
  R.write_model file m;
  Alcotest.(check string) "the header" "// alvie-model format 1; plugin tiny 2026.10; core 1" (List.hd_exn (In_channel.read_lines file));
  let m' = R.read_model ~what:"M" file in
  Alcotest.(check int) "read back" (Map.length m.transition) (Map.length m'.transition);
  Out_channel.write_all (Filename.concat dir "other.dot") ~data:"// alvie-model format 1; plugin sancus 2026.10; core 1\ndigraph G {\n}\n";
  Alcotest.check_raises "a model of another plugin" (Alvie_cli.Errors.User_error (sprintf "M: %s/other.dot is a model of plugin sancus, not of tiny." dir))
    (fun () -> ignore (R.read_model ~what:"M" (Filename.concat dir "other.dot")))

(* L# learns a model of a model back: the backend that replays the model of leak-interrupt gives a model with the
   same states, and the two agree on random tests of the spec *)
let test_model_backend () =
  let spec_ = spec "leak-interrupt.spec" in
  let oracle = R.Pac { epsilon = 0.01; delta = 0.01; round_limit = None } in
  let m = (R.learn ~config:[] ~variant:None ~spec:spec_ ~oracle ~seed:0 ()).model in
  let module MN = R.Model_native (struct let model = m end) in
  let module R2 = Alvie_cli.Runner.Make (MN) in
  let m' = (R2.learn ~config:[] ~variant:None ~spec:spec_ ~oracle:(R2.Pac { epsilon = 0.01; delta = 0.01; round_limit = None }) ~seed:1 ()).model in
  Alcotest.(check int) "the same number of states" (Set.length m.states) (Set.length m'.states);
  Alcotest.(check int) "the same number of transitions" (Map.length m.transition) (Map.length m'.transition);
  (* random walks on both *)
  let walk (model : R.IO.IIOMealy.t) choices =
    List.fold choices ~init:(Some model.s0, []) ~f:(fun (q, acc) k ->
        match q with
        | None -> (None, acc)
        | Some q ->
          let out = Map.to_alist (Map.filter_keys model.transition ~f:(fun (q', _) -> q' = q)) in
          (match out with
           | [] -> (None, acc)
           | _ -> let (_, i), (o, q') = List.nth_exn out (k mod List.length out) in (Some q', (R.I.show i, R.O.show o) :: acc))) in
  let walk' (model : R2.IO.IIOMealy.t) choices =
    List.fold choices ~init:(Some model.s0, []) ~f:(fun (q, acc) k ->
        match q with
        | None -> (None, acc)
        | Some q ->
          let out = Map.to_alist (Map.filter_keys model.transition ~f:(fun (q', _) -> q' = q)) in
          (match out with
           | [] -> (None, acc)
           | _ -> let (_, i), (o, q') = List.nth_exn out (k mod List.length out) in (Some q', (R2.I.show i, R2.O.show o) :: acc))) in
  let rng = Random.State.make [| 7 |] in
  for _ = 1 to 300 do
    let choices = List.init 12 ~f:(fun _ -> Random.State.int rng 1000) in
    Alcotest.(check (list (pair string string))) "the same run" (snd (walk m choices)) (snd (walk' m' choices))
  done

let () =
  Alcotest.run "Tiny"
    [ ("semantics", [ Alcotest.test_case "the time of the enclave" `Quick test_time;
                      Alcotest.test_case "interrupts and their latency" `Quick test_interrupt;
                      Alcotest.test_case "configuration and variants" `Quick test_config_errors ]);
      ("conformance", List.map [ "leak-time.spec"; "leak-interrupt.spec"; "safe-no-branch.spec" ] ~f:(fun f ->
           Alcotest.test_case ("Tiny passes on " ^ f) `Quick (test_conformance f)));
      ("mutants", [ Alcotest.test_case "a clone that shares its state" `Quick (test_mutant Shared_clone "clone");
                    Alcotest.test_case "a restore that does nothing" `Quick (test_mutant Restore_nothing "restore");
                    (* a test that halts leaves Tiny as it was: tests of 4 steps stop in the enclave *)
                    Alcotest.test_case "a pre that keeps the state" `Quick (test_mutant ~length:4 Sticky_pre "reset");
                    Alcotest.test_case "an observation not in observations.yaml" `Quick (test_mutant Undeclared_observation "observations");
                    Alcotest.test_case "a legal input made invalid" `Quick (test_mutant Rejects_nop "phases");
                    Alcotest.test_case "a cache keyed without the atom" `Quick (test_mutant Stale_cache "reset");
                    Alcotest.test_case "a random observation" `Quick (test_mutant Random_time "determinism") ]);
      ("learning", [ Alcotest.test_case "deterministic, without illegal transitions" `Quick test_learning_is_deterministic;
                     Alcotest.test_case "model files" `Quick test_model_files;
                     Alcotest.test_case "a model learned back from its replay" `Quick test_model_backend ]) ]
