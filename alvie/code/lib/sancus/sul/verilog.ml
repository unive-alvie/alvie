(*
  The SUL of ALVIE/Sancus for the learner: the Sancus backend (Simulator) behind the adapter of ALVIE/Core
  (Alvie_backend.Sul), with the Sancus types as inputs and outputs, so that model files keep their format.

  Core checks that each input is legal, gives the simulator the programs of the sections, and handles dry steps
  (Backend.restore); the bookkeeping is the code still to analyse and the number of the last instruction analysed,
  which Output_internal.t carries and its equality ignores.
*)

open Core

include Step_sul

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
