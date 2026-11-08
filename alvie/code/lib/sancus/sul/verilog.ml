(*
  The SUL of ALVIE/Sancus for the learner: the Sancus backend (Simulator) behind the adapter of ALVIE/Core
  (Alvie_backend.Sul), with the Sancus types as inputs and outputs, so that model files keep their format.

  Core checks that each input is legal, gives the simulator the programs of the sections, and handles dry steps
  (Backend.restore); the bookkeeping is the code still to analyse and the number of the last instruction analysed,
  which Output_internal.t carries and its equality ignores.
*)

open Core
module G = Alvie_inputgen.Generator

module Backend = struct
  type t = Simulator.t
  type bookkeeping = (string * string) list * int [@@deriving sexp]

  let capabilities = Alvie_backend.Backend.[ Restore; Clone; Parallel ]
  let pre = Simulator.pre
  let post = Simulator.post
  let clone = Simulator.clone

  let step t s =
    let ol, labels, n = Simulator.run t s in
    (List.map ol ~f:Generic_inputgen.observation, (labels, n))

  let restore t s ~observations (labels, n) =
    Simulator.restore t s (List.map observations ~f:Generic_inputgen.element_of_observation, labels, n)
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

(* The SUL for the spec (of plugins/sancus, its secret expanded); the other arguments are those of Simulator.make *)
let make ~spec ~sancus_repo ~sancus_master_key ~commit ~workingdir ~tmpdir ~basename ~verilog_compile ~get_symbolpos
    ~pmem_script ~simulate_script ~submitfile ~templatefile ~pmem_elf ~filledfile ~dumpfile ~ignore_interrupts
    ?sim_cycle_ratio ?collapse_reentries ?target () =
  let backend =
    Simulator.make ~sancus_repo ~sancus_master_key ~commit ~workingdir ~tmpdir ~basename ~verilog_compile ~get_symbolpos
      ~pmem_script ~simulate_script ~submitfile ~templatefile ~pmem_elf ~filledfile ~dumpfile ~ignore_interrupts
      ?sim_cycle_ratio ?collapse_reentries ?target () in
  S.make ~backend ~gen:(G.make (Lazy.force Generic_inputgen.plugin) spec)

let pre = S.pre
let post = S.post
let clone = S.clone
let step = S.step

(* The VCD dump of the last simulation *)
let dumpfile (s : t) = !(s.S.backend).Simulator.dumpfile
