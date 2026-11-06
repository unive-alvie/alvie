(*
  The template of alvie plugin new: a native plugin that works from the start, for its author to change.

    plugins/<name>/         the plugin files, and two fixtures (a leak and no leak)
    lib/plugins/<name>/     the backend (<name>.ml), and alvie-<name>, the commands of Core on it

  The platform of the template is a stand-in: a victim whose instruction wait n takes n cycles, so wait ? leaks the
  secret through the time the victim takes. In the texts, @NAME@ is the name of the plugin and @MODULE@ that of its
  OCaml module.
*)

let manifest = {|# yaml-language-server: $schema=../../schemas/alvie-plugin.schema.json
# The manifest of the plugin @NAME@ (made by alvie plugin new: change it to describe your platform).
format: 1
name: @NAME@
version: "0.1"
core: "1"
kind: native
description: >-
  A stand-in platform: the attacker calls the victim, whose instruction wait n takes n cycles, and sees how long it
  ran when it returns. Replace it with your platform: the files here, and the backend in lib/plugins/@NAME@.
config:
  slowdown:
    type: int
    range: [1, 4]
    default: "1"
    doc: How many cycles a cycle of wait takes (an example of a parameter of the backend)
capabilities: [restore, clone]
fixtures: fixtures
|}

let sections = {|# yaml-language-server: $schema=../../schemas/sections.schema.json
# A test starts in prepare, calls the victim, and goes on in cleanup once the victim has returned (phases.yaml).
format: 1
sections:
  prepare:
    role: attacker
    atoms: attacker
    initial: true
    doc: What the attacker does before calling the victim
  victim:
    role: victim
    atoms: victim
    doc: The code of the victim; ? in it is the secret
  cleanup:
    role: attacker
    atoms: attacker
    doc: What the attacker does after the victim has returned
secret:
  hole: true
|}

let atoms = {|# yaml-language-server: $schema=../../schemas/atoms.schema.json
# The atoms of the specs of @NAME@: what each section's code can do.
format: 1
types:
  val:
    variants:
      lit:    { syntax: "{num}", args: { num: { int: [0, 3] } } }
      secret: { syntax: "?", secret: { expand: "{value}" }, doc: The secret; it becomes a number }
atoms:
  attacker:
    nop:  { syntax: nop, doc: Does nothing }
    call: { syntax: call, doc: Calls the victim }
    halt: { syntax: halt, doc: Ends the test }
  victim:
    nop:  { syntax: nop, doc: One cycle }
    wait: { syntax: "wait {v}", args: { v: val }, doc: Waits for v cycles }
    ret:  { syntax: ret, doc: Returns to the attacker }
|}

let observations = {|# yaml-language-server: $schema=../../schemas/observations.schema.json
# What the backend of @NAME@ observes after each input.
format: 1
kinds:
  Ok: { doc: An instruction of the attacker ran }
  Run: { doc: An instruction of the victim ran }
  Enter: { doc: The victim was called }
  Exit: { fields: { time: int }, doc: "The victim returned, after running time cycles" }
  Done: { doc: The test ended (halt) }
  Illegal: { doc: The input cannot run here }
|}

let phases = {|# yaml-language-server: $schema=../../schemas/phases.schema.json
# How the observations of @NAME@ move a test between its sections.
format: 1
rules:
  - { match: Done, do: [{ stop: finished }] }
  - { match: Illegal, do: [{ stop: invalid }] }
  - { match: [Ok, Run], do: [] }
  - { match: Enter, do: [{ enter: victim }] }
  - { match: Exit, do: [{ enter: cleanup }] }
|}

let view = {|# yaml-language-server: $schema=../../schemas/view.schema.json
# What the attacker of @NAME@ sees: how long the victim ran, when it returns.
format: 1
rules:
  - { match: [Ok, Run], show: hidden }
  - { match: [Enter, Done, Illegal], show: tag }
  - { match: Exit, show: all }
|}

let leak_spec = {|// wait ? takes as many cycles as the secret: the time of the victim tells it.
prepare { (nop | eps); call };
victim { wait ?; ret };
cleanup { halt };
|}

let leak_fixture = {|# yaml-language-server: $schema=../../../schemas/fixture.schema.json
format: 1
doc: The time of wait ? tells the secret
spec: leak.spec
secrets: [0, 2]
expect: leak
|}

let safe_spec = {|// The victim waits as long whatever the secret.
prepare { (nop | eps); call };
victim { wait 1; nop; ret };
cleanup { halt };
|}

let safe_fixture = {|# yaml-language-server: $schema=../../../schemas/fixture.schema.json
format: 1
doc: A victim that does not use the secret leaks nothing
spec: safe.spec
secrets: [0, 2]
expect: no-leak
|}

let dune = {|; The backend of the plugin @NAME@ (made by alvie plugin new), and alvie-@NAME@: the commands of ALVIE/Core on it
(library
 (name @MODULE@)
 (modules @MODULE@ @MODULE@_files)
 (preprocess (pps ppx_jane))
 (libraries core alvie_plugin alvie_backend))

(executable
 (name main)
 (public_name alvie-@NAME@)
 (package alvie-core)
 (modules main)
 (libraries core core_unix.command_unix alvie_cli @MODULE@))

; The plugin files of plugins/@NAME@, embedded in the executable
(rule
 (targets @MODULE@_files.ml)
 (deps (glob_files %{project_root}/plugins/@NAME@/*.yaml))
 (action
  (with-stdout-to %{targets}
   (system "printf 'let files = [\n'; for f in %{deps}; do printf '  (\"%s\", {alvie_yaml|' \"$(basename $f)\"; cat $f; printf '|alvie_yaml});\n'; done; printf ']\n'"))))
|}

let main = {|(* alvie-@NAME@: the commands of ALVIE/Core (learn, compare, property, exec, conformance, fixtures) on the
   plugin @NAME@ *)
let () = Command_unix.run (Alvie_cli.Runner.commands (module @CAPMODULE@.Native))
|}

let backend = {|(*
  The backend of the plugin @NAME@ (made by alvie plugin new): a stand-in platform, for you to replace with yours.

  Core gives each step: the programs of the sections, the section of the input, its position and its atom (a value
  of atoms.yaml). The backend runs it and returns the observations of the step (values of observations.yaml) and its
  bookkeeping (what it needs to continue a test, which Core keeps but does not compare; none here).

  Check it with: alvie-@NAME@ conformance --spec plugins/@NAME@/fixtures/leak.spec --secret 0
*)

open Core
open Alvie_plugin
module Backend = Alvie_backend.Backend

let plugin =
  lazy (match Plugin.load_embedded ~dir:"plugins/@NAME@" @CAPMODULE@_files.files with
      | Ok p -> p
      | Error es -> failwith ("the plugin files of @NAME@ do not load:\n" ^ Diag.list_to_string es))

type t = {
  slowdown : int;
  mutable in_victim : bool;
  mutable cycles : int; (* run by the victim since it was called *)
}

type bookkeeping = unit [@@deriving sexp]

let obs ?(fields = []) kind = Value.Node (kind, fields)

let make ~config ~variant:_ =
  let slowdown = Int.of_string (Option.value (List.Assoc.find config ~equal:String.equal "slowdown") ~default:"1") in
  { slowdown; in_victim = false; cycles = 0 }

let pre t = t.in_victim <- false; t.cycles <- 0
let post _ = ()
let clone t = { t with in_victim = t.in_victim }

let step t (s : Backend.step) =
  let o = match t.in_victim, Value.tag s.atom with
    | false, Some "nop" -> obs "Ok"
    | false, Some "call" -> t.in_victim <- true; t.cycles <- 0; obs "Enter"
    | false, Some "halt" -> obs "Done"
    | true, Some "nop" -> t.cycles <- t.cycles + 1; obs "Run"
    | true, Some "wait" ->
      (match Value.path s.atom [ "v"; "num" ] with
       | Some (Int n) -> t.cycles <- t.cycles + (n * t.slowdown); obs "Run"
       | _ -> obs "Illegal")
    | true, Some "ret" -> t.in_victim <- false; obs "Exit" ~fields:[ ("time", Int (t.cycles + 1)) ]
    | _ -> obs "Illegal" in
  ([ o ], ())

(* A dry step: Core knows the observations already; update the state as if the step ran *)
let restore t s ~observations:_ () = ignore (step t s)

module Native : Alvie_backend.Native.S = struct
  let plugin = plugin

  module B = struct
    type nonrec t = t
    type nonrec bookkeeping = bookkeeping [@@deriving sexp]

    let capabilities = Backend.[ Restore; Clone ]
    let pre = pre
    let step = step
    let restore = restore
    let clone = clone
    let post = post
  end

  let none = ()
  let make = make
end
|}

let files ~name =
  let modname = "alvie_" ^ String.map (fun c -> if Char.equal c '-' then '_' else c) name in
  let sub s =
    s |> Core.String.substr_replace_all ~pattern:"@NAME@" ~with_:name
    |> Core.String.substr_replace_all ~pattern:"@CAPMODULE@" ~with_:(String.capitalize_ascii modname)
    |> Core.String.substr_replace_all ~pattern:"@MODULE@" ~with_:modname in
  let p f = Filename.concat (Filename.concat "plugins" name) f and l f = Filename.concat (Filename.concat "lib/plugins" name) f in
  Core.List.map ~f:(fun (path, text) -> (path, sub text))
    [ (p "alvie-plugin.yaml", manifest); (p "sections.yaml", sections); (p "atoms.yaml", atoms); (p "observations.yaml", observations);
      (p "phases.yaml", phases); (p "view.yaml", view);
      (p "fixtures/leak.spec", leak_spec); (p "fixtures/leak.yaml", leak_fixture);
      (p "fixtures/safe.spec", safe_spec); (p "fixtures/safe.yaml", safe_fixture);
      (l "dune", dune); (l "main.ml", main); (l (modname ^ ".ml"), backend) ]
