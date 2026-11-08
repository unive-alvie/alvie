(*
  A native plugin: its files and its backend, linked with Core. Core's generic commands (learn, compare, property,
  exec, conformance, fixtures) run any plugin given as this module (Alvie_cli.Runner.Make).

  - plugin: the plugin files, usually embedded in the executable (Plugin.load_embedded), so that a run does not
    depend on the directory it starts from;
  - make: a backend, for the values of the configuration parameters of the manifest (by name; every parameter with
    a default or given on the command line has one) and the variant of the system to run, if any (one of the
    manifest's variants: e.g. a baseline without interrupts);
  - none: the bookkeeping of a step that did not run (an illegal input).
*)

open Alvie_plugin

module type S = sig
  val plugin : Plugin.t Lazy.t

  module B : Backend.S

  val none : B.bookkeeping
  val make : config:(string * string) list -> variant:string option -> B.t
end
