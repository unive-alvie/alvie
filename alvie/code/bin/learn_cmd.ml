(* alvie learn (learn.exe) on the simulator: see Sancus_cmd.Learn_cmd *)
include Sancus_cmd.Learn_cmd.Make (Sancus.Native) (struct let native = true end)
