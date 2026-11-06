(*
  tt_plugin: the plugin files of ALVIE/Core and the generic spec language, on the Sancus plugin.

  - The Sancus plugin files load, and the JSON Schemas checked in under schemas/ are up to date.
  - Every spec of spec-lib parses, with the plugin's grammar, to the values of what testdl.ml parses today.
  - Atoms survive printing then parsing, for random atoms of every class.
  - Errors in plugin files and specs are reported where they are, with a useful message.

  It needs no external tool. Run it from alvie/code: dune exec tt_plugin -- test
*)

open Core
open Alvie_plugin
open Sancus

(* The repository: the directory above alvie/code *)
let code_dir =
  let rec up dir n =
    if n = 0 then failwith "run tt_plugin from alvie/code (cannot find plugins/sancus)"
    else if Sys_unix.file_exists_exn (Filename.concat dir "plugins/sancus/alvie-plugin.yaml") then dir
    else up (Filename.dirname dir) (n - 1) in
  up (Sys_unix.getcwd ()) 6

let plugin_dir = Filename.concat code_dir "plugins/sancus"
let spec_lib = Filename.concat code_dir "../../spec-lib"

let sancus =
  lazy (match Plugin.load plugin_dir with
      | Ok p -> p
      | Error es -> failwith ("the Sancus plugin does not load:\n" ^ Diag.list_to_string es))

let diag_strings ds = List.map ds ~f:Diag.to_string

(* The plugin files *)

let test_sancus_loads () =
  let p = Lazy.force sancus in
  Alcotest.(check string) "name" "sancus" p.manifest.name;
  Alcotest.(check (list string)) "sections" [ "enclave"; "isr"; "prepare"; "cleanup" ] (Sections_file.names p.sections);
  Alcotest.(check string) "initial" "prepare" (Sections_file.initial p.sections).name;
  Alcotest.(check int) "kinds" 11 (List.length p.observations.kinds)

let test_schemas_up_to_date () =
  let dir = Filename.concat code_dir "schemas" in
  List.iter (Plugin.file_schemas ()) ~f:(fun (name, schema) ->
      let expected = Yojson.Safe.pretty_to_string schema ^ "\n" in
      let path = Filename.concat dir name in
      let actual = try In_channel.read_all path with Sys_error _ -> "" in
      if not (String.equal expected actual) then
        Alcotest.failf "%s is not up to date: run dune exec tt_plugin -- schemas (from alvie/code) and commit the result" path)

(* The schemas of the values of a plugin (for the external protocol) refer only to definitions they have *)
let test_value_schemas () =
  let p = Lazy.force sancus in
  let check name (schema : Yojson.Safe.t) =
    let defs = match Yojson.Safe.Util.member "$defs" schema with `Assoc d -> List.map d ~f:fst | _ -> [] in
    let rec refs (j : Yojson.Safe.t) = match j with
      | `Assoc ms -> List.concat_map ms ~f:(fun (k, v) -> match k, v with "$ref", `String r -> [ r ] | _ -> refs v)
      | `List js -> List.concat_map js ~f:refs
      | _ -> [] in
    List.iter (refs schema) ~f:(fun r ->
        match String.chop_prefix r ~prefix:"#/$defs/" with
        | Some d when List.mem defs d ~equal:String.equal -> ()
        | _ -> Alcotest.failf "%s: the reference %s has no definition" name r) in
  check "atom values" (Grammar.json_schema p.grammar);
  check "observation values" (Observations_file.json_schema p.observations)

(* spec-lib *)

let spec_files dir ext =
  Sys_unix.ls_dir dir |> List.filter ~f:(String.is_suffix ~suffix:ext) |> List.sort ~compare:String.compare
  |> List.map ~f:(Filename.concat dir)

let body_testable = Alcotest.testable (fun fmt b -> Sexp.pp_hum fmt (Spec.sexp_of_body b)) Spec.equal_body

(* Every pair of an enclave spec and an attacker spec in the same directory, as learn.exe would read them *)
let test_spec_lib_matches_testdl () =
  let p = Lazy.force sancus in
  let dirs = [ spec_lib; Filename.concat spec_lib "fast"; Filename.concat spec_lib "example" ] in
  let count = ref 0 in
  List.iter dirs ~f:(fun dir ->
      List.iter (spec_files dir ".etdl") ~f:(fun etdl ->
          List.iter (spec_files dir ".atdl") ~f:(fun atdl ->
              let old = match Testdl.Parser.parse_spec (In_channel.read_all etdl ^ " " ^ In_channel.read_all atdl) with
                | Ok s -> Atom_value.of_test_spec s
                | Error e -> Alcotest.failf "testdl.ml does not parse %s and %s: %s" etdl atdl e in
              match Spec.parse_files p [ etdl; atdl ] with
              | Error es -> Alcotest.failf "the plugin grammar does not parse %s and %s:\n%s" etdl atdl (Diag.list_to_string es)
              | Ok spec ->
                incr count;
                List.iter old ~f:(fun (name, body) ->
                    Alcotest.check body_testable (sprintf "%s, %s: %s" etdl atdl name) body (Option.value_exn (Spec.body_of spec name))))));
  Alcotest.(check bool) "all of spec-lib is checked" true (!count >= 11)

(* Printing a spec and parsing it again gives the same spec *)
let test_spec_lib_print_parse () =
  let p = Lazy.force sancus in
  List.iter (spec_files spec_lib ".atdl") ~f:(fun atdl ->
      let etdl = Filename.concat spec_lib "enclave-complete.etdl" in
      let spec = Result.ok_or_failwith (Result.map_error (Spec.parse_files p [ etdl; atdl ]) ~f:Diag.list_to_string) in
      let printed = Spec.print p spec in
      match Spec.parse p [ ("printed", printed) ] with
      | Error es -> Alcotest.failf "the printed spec does not parse:\n%s\n%s" printed (Diag.list_to_string es)
      | Ok again ->
        List.iter2_exn spec again ~f:(fun (s : Spec.section) (s' : Spec.section) ->
            Alcotest.check body_testable (atdl ^ ": " ^ s.name) s.body s'.body))

let test_secret_expansion () =
  let p = Lazy.force sancus in
  let etdl = Filename.concat spec_lib "enclave-complete.etdl" and atdl = Filename.concat spec_lib "b1.atdl" in
  let spec = Result.ok_or_failwith (Result.map_error (Spec.parse_files p [ etdl; atdl ]) ~f:Diag.list_to_string) in
  Alcotest.(check bool) "the enclave has the secret" true (Spec.has_secret (Option.value_exn (Spec.body_of spec "enclave")));
  let expanded = Result.ok_or_failwith (Result.map_error (Spec.expand_secret p spec ~value:"1") ~f:Diag.to_string) in
  let old = match Testdl.Parser.parse_spec (In_channel.read_all etdl ^ " " ^ In_channel.read_all atdl) with
    | Ok (Enclave e, _, _, _) -> Atom_value.of_enclave_body (Enclave.Enclave.expand_secret "1" e)
    | Error e -> failwith e in
  Alcotest.check body_testable "as Enclave.expand_secret" old (Option.value_exn (Spec.body_of expanded "enclave"));
  Alcotest.(check bool) "no hole left" false (Spec.has_secret (Option.value_exn (Spec.body_of expanded "enclave")))

(* Random atoms *)

(* Symbols that cannot be read as something else: a symbol r5 after & would be the register r5 *)
let gen_symbol =
  QCheck.Gen.(map2 (fun c rest -> String.of_char c ^ rest) (char_range 'a' 'q') (string_size ~gen:(oneof_list [ 'a'; 'z'; '0'; '9'; '_' ]) (int_bound 5)))

let rec gen_arg (g : Grammar.t) depth (ty : Grammar.arg_type) : Value.t QCheck.Gen.t =
  let open QCheck.Gen in
  match ty with
  | Int (lo, hi) -> map (fun i -> Value.Int i) (oneof [ return lo; return hi; int_range lo hi ])
  | Symbol -> map (fun s -> Value.Sym s) gen_symbol
  | Ref name -> gen_type g depth ~exclude:[] name
  | List { elem; exclude; _ } -> map (fun vs -> Value.List vs) (list_size (int_range 1 3) (gen_type g (depth - 1) ~exclude elem))

and gen_type g depth ~exclude name : Value.t QCheck.Gen.t =
  let open QCheck.Gen in
  let t = Option.value_exn (Grammar.find_type g name) in
  let alts = List.filter t.alts ~f:(fun a ->
      (not (List.mem exclude a.tag ~equal:String.equal))
      && (depth > 0 || List.for_all a.args ~f:(fun (_, ty) -> match ty with Grammar.List _ -> false | _ -> true))) in
  oneof_list alts >>= fun (a : Grammar.alt) ->
  if Option.is_some a.secret then return (Value.Hole Grammar.secret_name)
  else
    let rec fields = function
      | [] -> return []
      | (n, ty) :: rest -> gen_arg g depth ty >>= fun v -> fields rest >|= fun vs -> (n, v) :: vs in
    fields a.args >|= fun fs -> Value.Node (a.tag, fs)

let test_atoms_print_parse () =
  let p = Lazy.force sancus in
  let g = p.grammar in
  List.iter (Grammar.classes g) ~f:(fun cls ->
      let arb = QCheck.make ~print:(Grammar.print_atom g ~cls:cls.name) (gen_type g 2 ~exclude:[] cls.name) in
      QCheck.Test.check_exn
        (QCheck.Test.make ~count:2000 ~name:("print then parse: " ^ cls.name) arb (fun v ->
             (match Grammar.check_ty g cls v with Ok () -> () | Error e -> QCheck.Test.fail_reportf "generated an ill-typed value: %s" e);
             match Grammar.parse_value g ~file:"atom" ~ty:cls.name (Grammar.print_atom g ~cls:cls.name v) with
             | Ok v' -> Value.equal v v'
             | Error d -> QCheck.Test.fail_reportf "%s" (Diag.to_string d))))

(* Values of Sancus atoms are the same after going through attacker.ml/enclave.ml and back *)
let test_atom_value_round_trip () =
  let p = Lazy.force sancus in
  let g = p.grammar in
  let check name gen back =
    QCheck.Test.check_exn
      (QCheck.Test.make ~count:2000 ~name (QCheck.make ~print:Value.to_string gen) (fun v ->
           match back v with Ok v' -> Value.equal v v' | Error e -> QCheck.Test.fail_reportf "%s" e)) in
  check "attacker atoms" (gen_type g 2 ~exclude:[] "attacker") (fun v -> Result.map (Atom_value.to_attacker v) ~f:Atom_value.of_attacker);
  check "enclave atoms" (gen_type g 2 ~exclude:[] "enclave") (fun v -> Result.map (Atom_value.to_enclave v) ~f:Atom_value.of_enclave)

let test_value_json_round_trip () =
  let p = Lazy.force sancus in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:2000 ~name:"JSON" (QCheck.make ~print:Value.to_string (gen_type p.grammar 2 ~exclude:[] "attacker")) (fun v ->
         match Value.of_json (Value.to_json v) with Ok v' -> Value.equal v v' | Error e -> QCheck.Test.fail_reportf "%s" e))

(* The example of docs/reference/plugin-files.md *)
let test_value_json_example () =
  let p = Lazy.force sancus in
  let v = Result.ok_or_failwith (Result.map_error (Grammar.parse_value p.grammar ~file:"atom" ~ty:"enclave" "mov r5, r6") ~f:Diag.to_string) in
  Alcotest.(check string) "JSON"
    {|{"inst":{"i":{"mov":{"src":{"reg":{"r":{"reg":{"i":5}}}},"dst":{"reg":{"r":{"reg":{"i":6}}}}}}}}|}
    (Yojson.Safe.to_string (Value.to_json v))

let test_interning () =
  let a = Value.Node ("mov", [ ("src", Value.Int 1) ]) and b = Value.Node ("mov", [ ("src", Value.Int 1) ]) in
  let c = Value.Node ("mov", [ ("src", Value.Int 2) ]) in
  let ia, ib, ic = Value.Interned.(intern a, intern b, intern c) in
  Alcotest.(check bool) "equal values share an id" true (Value.Interned.equal ia ib);
  Alcotest.(check bool) "different values do not" false (Value.Interned.equal ia ic);
  Alcotest.(check int) "the order is the structural one" (Value.compare a c) (Value.Interned.compare ia ic)

(* Interned values compare as their values, whether they were preloaded or not *)
let test_interned_order () =
  let p = Lazy.force sancus in
  let gen = gen_type p.grammar 2 ~exclude:[] "attacker" in
  let rng = Stdlib.Random.State.make [| 1 |] in
  let preloaded = List.init 200 ~f:(fun _ -> QCheck.Gen.generate1 ~rand:rng gen) in
  Value.Interned.preload preloaded;
  let later = List.init 200 ~f:(fun _ -> QCheck.Gen.generate1 ~rand:rng gen) in
  let all = preloaded @ later in
  List.iter all ~f:(fun a ->
      List.iter all ~f:(fun b ->
          let expected = Int.sign (Value.compare a b) and actual = Int.sign (Value.Interned.(compare (intern a) (intern b))) in
          if not (Sign.equal expected actual) then
            Alcotest.failf "%s and %s compare differently when interned" (Value.to_string a) (Value.to_string b)))

(* Errors *)

let atoms_error source expected () =
  match Atoms_file.load_string ~file:"atoms.yaml" source with
  | Ok _ -> Alcotest.failf "expected an error"
  | Error es -> Alcotest.(check (list string)) "errors" expected (diag_strings es)

let test_atoms_errors = [
  ("unknown field, with a suggestion",
   atoms_error "format: 1\natoms:\n  a:\n    rst: { sytnax: rst }\n"
     [ "atoms.yaml:4:12: unknown field \"sytnax\"\n  hint: did you mean \"syntax\"?"; "atoms.yaml:4:10: the field \"syntax\" is missing" ]);
  ("YAML 1.1 boolean",
   atoms_error "format: 1\natoms:\n  a:\n    on: { syntax: rst }\n"
     [ "atoms.yaml:4:5: \"on\" is ambiguous in YAML: YAML 1.1 reads it as a boolean, YAML 1.2 as a string\n  hint: quote it (\"on\") if you mean the word, or write true or false for a boolean" ]);
  ("argument not shown by the syntax",
   atoms_error "format: 1\natoms:\n  a:\n    jin: { syntax: jin, args: { s: symbol } }\n"
     [ "atoms.yaml:4:5: the syntax \"jin\" of jin does not show the argument {s}" ]);
  ("unknown type, with a suggestion",
   atoms_error "format: 1\ntypes:\n  reg: { syntax: \"r{i}\", args: { i: int } }\natoms:\n  a:\n    push: { syntax: \"push {r}\", args: { r: rge } }\n"
     [ "atoms.yaml:6:5: unknown type rge\n  hint: did you mean \"reg\"?" ]);
  ("left recursion",
   atoms_error "format: 1\natoms:\n  e:\n    plus: { syntax: \"{l} + {r}\", args: { l: e, r: e } }\n    one: { syntax: \"1\" }\n"
     [ "atoms.yaml:3:3: e is left-recursive: one of its syntaxes starts with an argument that can start with e again" ]);
  ("duplicate key",
   atoms_error "format: 1\natoms:\n  a:\n    rst: { syntax: rst }\n    rst: { syntax: rst }\n"
     [ "atoms.yaml:5:5: the key \"rst\" appears twice in this mapping" ]);
]

(* A copy of the Sancus plugin with one file replaced, to check the errors across files *)
let with_file name contents f =
  let dir = Filename_unix.temp_dir "tt_plugin" "" in
  List.iter (Sys_unix.ls_dir plugin_dir) ~f:(fun file ->
      Out_channel.write_all (Filename.concat dir file) ~data:(In_channel.read_all (Filename.concat plugin_dir file)));
  Out_channel.write_all (Filename.concat dir name) ~data:contents;
  Exn.protect ~f:(fun () -> f dir) ~finally:(fun () -> ignore (Sys_unix.command (sprintf "rm -rf %s" (Filename.quote dir))))

let cross_error name contents expected () =
  with_file name contents (fun dir ->
      match Plugin.load dir with
      | Ok _ -> Alcotest.failf "expected an error"
      | Error es -> Alcotest.(check (list string)) "errors" expected (List.map es ~f:(fun d -> Diag.to_string { d with pos = Option.map d.pos ~f:(fun p -> { p with file = Filename.basename p.file }) })))

let test_cross_errors = [
  ("phase rule with an unknown kind and section",
   cross_error "phases.yaml" "format: 1\nrules:\n  - { match: JmpInn, do: [{ enter: enclav }] }\n"
     [ "phases.yaml:3:5: unknown kind of observation JmpInn\n  hint: did you mean \"JmpIn\"?"; "phases.yaml:3:5: unknown section enclav\n  hint: did you mean \"enclave\"?" ]);
  ("field that the kind does not have, and a wrong constant",
   cross_error "view.yaml" "format: 1\nrules:\n  - { match: Reset, when: { mode: PM }, show: hidden }\n  - { match: Reti, when: { mode: XM }, show: tag }\n"
     [ "view.yaml:3:29: the kind Reset has no field mode";
       "view.yaml:4:34: XM is not a value of the field mode of Reti: expected one of UM or PM" ]);
  ("section with an unknown atom class",
   cross_error "sections.yaml" "format: 1\nsections:\n  enclave: { role: victim, atoms: enclav }\n  isr: { role: attacker, atoms: attacker }\n  prepare: { role: attacker, atoms: attacker, initial: true }\n  cleanup: { role: attacker, atoms: attacker }\n"
     [ "sections.yaml:3:3: the section enclave uses the atom class enclav, which atoms.yaml does not declare\n  hint: did you mean \"enclave\"?" ]);
]

let spec_error source expected () =
  let p = Lazy.force sancus in
  match Spec.parse p [ ("spec", source) ] with
  | Ok _ -> Alcotest.failf "expected an error"
  | Error es -> Alcotest.(check (list string)) "errors" expected (diag_strings es)

let complete_rest = "isr { reti };\nprepare { jin enc_s };\ncleanup { eps };\n"

let test_spec_errors = [
  ("missing separator",
   spec_error ("enclave { nop nop };\n" ^ complete_rest)
     [ "spec:1:15: expected \"*\", \";\", \"|\" or \"}\", found \"nop\"" ]);
  ("register out of range",
   spec_error ("enclave { mov #1, r15 };\n" ^ complete_rest)
     [ "spec:1:20: 15 is out of range: expected an integer from 0 to 14" ]);
  ("unknown section",
   spec_error "enclav { nop };\n"
     [ "spec:1:1: unknown section enclav\n  hint: did you mean \"enclave\"?" ]);
  ("missing section",
   spec_error "enclave { nop };\nisr { reti };\nprepare { jin enc_s };\n"
     [ "the spec has no cleanup section\n  hint: add cleanup { ... }; (write cleanup { eps }; for an empty one)" ]);
  ("reserved block",
   spec_error ("constraint { disjoint(isr, enclave) };\nenclave { nop };\n" ^ complete_rest)
     [ "spec:1:1: constraint blocks (constraints between sections) are reserved for a later version of ALVIE and are not supported yet\n  hint: remove the block" ]);
]

let () =
  match Sys.get_argv () with
  | [| _; "schemas" |] ->
    (* Regenerates the JSON Schemas of the plugin files *)
    let dir = Filename.concat code_dir "schemas" in
    Core_unix.mkdir_p dir;
    List.iter (Plugin.file_schemas ()) ~f:(fun (name, schema) ->
        Out_channel.write_all (Filename.concat dir name) ~data:(Yojson.Safe.pretty_to_string schema ^ "\n");
        printf "wrote %s\n" (Filename.concat dir name))
  | _ ->
    let cases l = List.map l ~f:(fun (name, f) -> Alcotest.test_case name `Quick f) in
    Alcotest.run "ALVIE plugin files" [
      ("Sancus plugin", [
          Alcotest.test_case "loads" `Quick test_sancus_loads;
          Alcotest.test_case "JSON Schemas are up to date" `Quick test_schemas_up_to_date;
          Alcotest.test_case "schemas of values" `Quick test_value_schemas ]);
      ("spec-lib", [
          Alcotest.test_case "parses as testdl.ml does" `Quick test_spec_lib_matches_testdl;
          Alcotest.test_case "print then parse" `Quick test_spec_lib_print_parse;
          Alcotest.test_case "secret expansion" `Quick test_secret_expansion ]);
      ("values", [
          Alcotest.test_case "atoms: print then parse" `Quick test_atoms_print_parse;
          Alcotest.test_case "atoms: through attacker.ml and enclave.ml" `Quick test_atom_value_round_trip;
          Alcotest.test_case "JSON" `Quick test_value_json_round_trip;
          Alcotest.test_case "JSON of the documented example" `Quick test_value_json_example;
          Alcotest.test_case "interning" `Quick test_interning;
          Alcotest.test_case "interned values keep the order" `Quick test_interned_order ]);
      ("atoms.yaml errors", cases test_atoms_errors);
      ("errors across files", cases test_cross_errors);
      ("spec errors", cases test_spec_errors);
    ]
