(* The commands of ALVIE/Core on Sancus, with its codec: learn.exe, fa.exe and alvie property use them *)
module R = Alvie_cli.Runner.Make_codec (Sancus.Native) (Sancus.Native.Codec)

(* The commands of Core on ALVIE/Sancus-FPGA (the board), with the same codec: alvie sancus-fpga ... *)
module Fpga_r = Alvie_cli.Runner.Make_codec (Sancus_fpga.Native) (Sancus_fpga.Native.Codec)
