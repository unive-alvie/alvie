(*
  The adapter from a backend (Backend.S) to the SUL of the learner (Learninglib.Sul.SUL), so that L# and the
  oracles do not change.

  The adapter follows the test with the input generator: it checks that each input is legal, computes the programs
  of the sections for the backend, and feeds the observations to the phase rules. An input that the spec does not
  allow, or any input after the test has stopped (it finished, became invalid, or got no input), is answered with
  the codec's illegal output, without running the backend.

  A dry step (the learner passes the output it already knows) becomes Backend.restore. A known output without
  observations cannot be restored: the step is run.

  The codec translates between the input and output types the learner works with and Core's values. A backend
  whose learner works on values directly uses Codec_values; ALVIE/Sancus keeps its own types, so that its model
  files keep their format.
*)

open Core
open Alvie_plugin
module G = Alvie_inputgen.Generator

module type CODEC = sig
  type bookkeeping
  type input
  type output

  (* The input in the current section, or None for an input that is not one of the spec (e.g. "no input") *)
  val input_to_core : section:string -> input -> G.input option
  val output_of_core : Value.t list -> bookkeeping -> output
  val output_to_core : output -> Value.t list * bookkeeping
  val illegal : output
end

module Make (B : Backend.S) (C : CODEC with type bookkeeping = B.bookkeeping) = struct
  type input_t = C.input
  type output_t = C.output

  type t = {
    backend : B.t;
    gen : G.t;
    mutable st : G.state;
    mutable stopped : bool;
  }

  let make ~backend ~gen = { backend; gen; st = G.initial gen; stopped = false }

  let clone s = { s with backend = B.clone s.backend }

  let pre s =
    B.pre s.backend;
    s.st <- G.initial s.gen;
    s.stopped <- false

  let post s = B.post s.backend

  let step ?(silent = false) ?dry_output s (i : input_t) : output_t =
    if s.stopped then C.illegal
    else
      match C.input_to_core ~section:(G.current s.st) i with
      | None -> s.stopped <- true; C.illegal
      | Some ci when not (G.legal s.gen s.st ci) -> s.stopped <- true; C.illegal
      | Some ci ->
        let position = G.position s.st ci.section in
        let st' = G.input s.gen s.st ci in
        let step = { Backend.programs = G.programs s.gen st'; section = ci.section; position; atom = ci.atom; key = lazy (G.key st'); silent } in
        let known = Option.map dry_output ~f:C.output_to_core in
        let observations, bookkeeping = match known with
          | Some ((_ :: _ as observations), bookkeeping) ->
            B.restore s.backend step ~observations bookkeeping;
            (observations, bookkeeping)
          | Some ([], _) | None -> B.step s.backend step in
        s.st <- G.observe s.gen st' observations;
        (match s.st.status with Running -> () | Finished | Invalid -> s.stopped <- true);
        C.output_of_core observations bookkeeping

  (* The state of the input generator of the current test *)
  let generator_state s = s.st
end

(*
  The codec of a learner that works on values: inputs are the generator's inputs (and None, no input), outputs are
  the observations with the bookkeeping, compared on the observations only.
*)
module Values (B : sig type bookkeeping [@@deriving sexp] val none : bookkeeping end) = struct
  module Input = struct
    type t = G.input option [@@deriving sexp, equal, compare, hash]
    let pp fmt = function
      | Some (i : G.input) -> Format.fprintf fmt "%s:%s" i.section (Value.to_string i.atom)
      | None -> Format.fprintf fmt "-"
    let show i = Format.asprintf "%a" pp i
    let default = None
    include Comparator.Make (struct type nonrec t = t let compare = compare let sexp_of_t = sexp_of_t end)
  end

  module Output = struct
    type t = { observations : Value.t list; bookkeeping : B.bookkeeping } [@@deriving sexp]
    let equal a b = List.equal Value.equal a.observations b.observations
    let compare a b = List.compare Value.compare a.observations b.observations
    let hash_fold_t st a = List.fold a.observations ~init:st ~f:Value.hash_fold_t
    let hash a = Hash.run hash_fold_t a
    let pp fmt a = Format.fprintf fmt "[%s]" (String.concat ~sep:"; " (List.map a.observations ~f:Value.to_string))
    let show a = Format.asprintf "%a" pp a
    let default = { observations = [ Value.Node ("Illegal", []) ]; bookkeeping = B.none }
    include Comparator.Make (struct type nonrec t = t let compare = compare let sexp_of_t = sexp_of_t end)
  end

  type bookkeeping = B.bookkeeping
  type input = Input.t
  type output = Output.t

  let input_to_core ~section:_ (i : input) = i
  let output_of_core observations bookkeeping = { Output.observations; bookkeeping }
  let output_to_core (o : output) = (o.observations, o.bookkeeping)
  let illegal = Output.default
end

(*
  The codec of a learner whose inputs are atoms of a class, as a spec writes them: an attacker atom is the same
  input whichever attacker section it runs in (the section is the current one), so models have one input per atom.
  An atom of a class that the current section does not run is illegal. Outputs are those of Values.
*)
module Atoms (P : sig val plugin : Plugin.t Lazy.t end) (B : sig type bookkeeping [@@deriving sexp] val none : bookkeeping end) = struct
  module Input = struct
    type atom = { cls : string; atom : Value.t } [@@deriving sexp, equal, compare, hash]
    type t = atom option [@@deriving sexp, equal, compare, hash]

    let show = function
      | Some { cls; atom } -> Grammar.print_atom (Lazy.force P.plugin).grammar ~cls atom
      | None -> "-"
    let pp fmt i = Format.pp_print_string fmt (show i)
    let default = None
    include Comparator.Make (struct type nonrec t = t let compare = compare let sexp_of_t = sexp_of_t end)
  end

  module V = Values (B)
  module Output = V.Output

  type bookkeeping = B.bookkeeping
  type input = Input.t
  type output = Output.t

  let input_to_core ~section (i : input) : G.input option =
    match i with
    | Some { cls; atom } when Option.equal String.equal (Plugin.atoms_of (Lazy.force P.plugin) section) (Some cls) -> Some { G.section; atom }
    | _ -> None
  let output_of_core = V.output_of_core
  let output_to_core = V.output_to_core
  let illegal = V.illegal
end
