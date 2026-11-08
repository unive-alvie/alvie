(*
  ALVIE/Sancus-FPGA as a native plugin of ALVIE/Core (Alvie_backend.Native.S): the files of plugins/sancus-fpga
  (which shares the specs, inputs and observations of plugins/sancus) and the Sancus backend with the board as its
  target (Fpga.target), for the commands alvie sancus-fpga ...

  Its learner works on the types of Sancus, with the codec of ALVIE/Sancus (Sancus.Native.Codec): its models have
  the format of the simulator's, and compare with them.
*)
open Core

let plugin =
  lazy (match Alvie_plugin.Plugin.load_embedded ~dir:"plugins/sancus-fpga" Sancus_fpga_plugin_files.files with
      | Ok p -> p
      | Error es -> failwith ("the embedded Sancus-FPGA plugin files do not load (a bug):\n" ^ Alvie_plugin.Diag.list_to_string es))

module B = Sancus.Native.B

let none = Sancus.Native.none

let make ~config ~variant =
  let port = match List.Assoc.find config ~equal:String.equal "fpga-port" with
    | Some p -> p
    | None -> failwith "Sancus-FPGA: no value for fpga-port" in
  Sancus.Native.make_with ~target:(Fpga.target ~port) ~config ~variant ()

module Codec = Sancus.Native.Codec
