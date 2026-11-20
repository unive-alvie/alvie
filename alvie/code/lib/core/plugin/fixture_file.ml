(*
  A fixture of a plugin (in the directory that the manifest's fixtures: names): a spec with the verdict of
  noninterference that the plugin must give on it. ALVIE learns a model of the spec for each value of the secret
  (and of the baseline variant, if any), compares them, and checks the verdict.

    format: 1
    doc: The time of bz tells the secret            # optional
    spec: leak-time.spec                            # or a list of files; relative to the fixture
    secrets: [0, 1]
    config: { mitigation: none }                    # optional: the values of the backend's parameters
    baseline: no-interrupts                         # optional: a variant whose witnesses do not count
    expect: leak                                    # leak or no-leak
*)

open Core
open Shape

type expect = Leak | No_leak [@@deriving sexp, equal]

type t = {
  doc : string option;
  spec : string list; (* as written: relative to the fixture *)
  secrets : string * string;
  config : (string * string) list;
  baseline : string option;
  expect : expect;
}

let shape : t Shape.t =
  let open Obj in
  Shape.map_result
    (obj ~what:"a fixture"
       (let+ _ = req "format" (Shape.int ~min:1 ~max:1 ()) ~doc:"The version of the format of this file: 1"
        and+ doc = opt "doc" (Shape.string ()) ~doc:"What the fixture checks"
        and+ spec = req "spec" (Shape.one_or_list (Shape.string ())) ~doc:"The spec: a file, or a list of files, relative to the fixture"
        and+ secrets = req "secrets" (Shape.list (Shape.string ())) ~doc:"The two values of the secret to compare"
        and+ config = dflt "config" [] (Shape.map (Shape.string ())) ~doc:"The values of the configuration parameters of the backend"
        and+ baseline = opt "baseline" (Shape.string ()) ~doc:"A variant of the system (alvie-plugin.yaml) whose witnesses do not count"
        and+ expect = req "expect" (Shape.enum [ ("leak", Leak); ("no-leak", No_leak) ]) ~doc:"The verdict: leak (some witness) or no-leak (none)" in
        (doc, spec, secrets, config, baseline, expect)))
    ~f:(fun n (doc, spec, secrets, config, baseline, expect) ->
        match secrets with
        | [ a; b ] when not (String.equal a b) ->
          Ok { doc; spec; secrets = (a, b); config = List.map config ~f:(fun (k, _, v) -> (k, v)); baseline; expect }
        | _ -> fail n "secrets: give two different values of the secret")

let load ~file = Shape.parse_file shape file
