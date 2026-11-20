(*
  The SUL of ALVIE/Sancus for the learner: the step of the Sancus backend (Step), whatever its target, behind the
  adapter of ALVIE/Core (Alvie_backend.Sul), with the Sancus types as inputs and outputs, so that model files keep
  their format. Verilog makes it on the simulator, Wasm_target on the simulator in WebAssembly.

  Core checks that each input is legal, gives the simulator the programs of the sections, and handles dry steps
  (Backend.restore); the bookkeeping is the code still to analyse and the number of the last instruction analysed,
  which Output_internal.t carries and its equality ignores.
*)

open Core
module G = Alvie_inputgen.Generator

module Backend = struct
  type t = Step.t
  type bookkeeping = (string * string) list * int [@@deriving sexp]

  let capabilities = Alvie_backend.Backend.[ Restore; Clone; Parallel ]
  let pre = Step.pre
  let post = Step.post
  let clone = Step.clone

  let step t s =
    let ol, labels, n = Step.run t s in
    (List.map ol ~f:Generic_inputgen.observation, (labels, n))

  let restore t s ~observations (labels, n) =
    Step.restore t s (List.map observations ~f:Generic_inputgen.element_of_observation, labels, n)
end

module Codec = struct
  type bookkeeping = Backend.bookkeeping
  type input = Input.t
  type output = Output_internal.t

  let input_to_core ~section (i : input) =
    Option.map (Generic_inputgen.atom_of_input i) ~f:(fun atom -> { G.section; atom })

  let output_of_core observations (labels, n) : output =
    (List.map observations ~f:Generic_inputgen.element_of_observation, labels, n)

  let output_to_core ((ol, labels, n) : output) = (List.map ol ~f:Generic_inputgen.observation, (labels, n))
  let illegal = Output_internal.default
end

module S = Alvie_backend.Sul.Make (Backend) (Codec)

type t = S.t
type input_t = Input.t
type output_t = Output_internal.t

