(* The comparison engine of alvie-core, with the Sancus hooks (see obs.ml) *)
include Ltscompare.Cexfinder.Make (Obs.Hooks)
