(*
  The contract between ALVIE/Core and a backend (version 2).

  A backend runs inputs on the platform and observes what happens. Core owns everything else: which inputs are
  legal, the programs of the sections (the prefix rule), when a step is known already and needs no run (a dry
  step), and which part of what the backend returns is compared.

  - pre starts a test from the initial state of the platform.
  - step runs one input. Core gives the programs of all the sections, with the input included, and where the input
    is: its section, its position in the section's current run and its atom. The input is an occurrence of
    the program of its section at that position; when a section runs again, Core gives the same occurrence again.
    The backend generates the code of the programs, runs it up to the end of the input, and returns the
    observations of this step (values of observations.yaml) and its bookkeeping.
  - restore is a dry step: Core already knows the observations of the step (from an earlier test with the same
    prefix) and gives them back with the bookkeeping the backend returned then. The backend updates its state as if
    it had run the step, without running it.
  - clone makes an independent copy, for learning in parallel.
  - post ends a test.

  Bookkeeping is the part of a step's result that is not an observation: what the backend needs to continue the
  test (Sancus: the code still to analyse, the number of the last instruction analysed). Core stores it and gives
  it back, but never compares it: two steps are equal when their observations are.
*)

open Core
open Alvie_plugin

type capability = Restore | Clone | Parallel [@@deriving sexp, equal, compare]

type step = {
  programs : (string * Value.t list) list; (* the program of each section (Generator.programs) *)
  section : string;
  position : int; (* in the current run of the section, from 0 *)
  atom : Value.t;
  key : string Lazy.t; (* where the test is in the spec after the input (Generator.key) *)
  silent : bool; (* the learner does not want progress output for this step *)
}

(* The identifier of the occurrence of the step's input, e.g. to label its code: unique in a program *)
let occurrence_id (s : step) = sprintf "%s_%d" s.section s.position

module type S = sig
  type t
  type bookkeeping [@@deriving sexp]

  val capabilities : capability list
  val pre : t -> unit
  val step : t -> step -> Value.t list * bookkeeping
  val restore : t -> step -> observations:Value.t list -> bookkeeping -> unit
  val clone : t -> t
  val post : t -> unit
end

(* A backend that cannot go on (e.g. an external plugin that crashed or did not answer): the message says why, and
   the commands report it as an error of the backend *)
exception Failed of string
