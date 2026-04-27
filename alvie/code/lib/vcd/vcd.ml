(*
  This module wraps our modified Verilog_VCD Python module.
  Wrt to previous version this should be simpler and a bit more efficient!

  Sooner or later I will regret not rewriting this in OCaml :)

  Using:
  - https://github.com/zshipko/ocaml-py
  - https://github.com/zylin/Verilog_VCD
*)

open Core
open Py

type vcd_t = { full_names_to_tv : (string * string Core.Int.Map.t) list }

module Signal = struct
  type t = {
    tv : string Int.Map.t;
  } [@@deriving make]

  let at_time signal time =
    match Map.closest_key signal.tv `Less_or_equal_to time with
    | None -> failwith "Signal.at_time: time not found, maybe < 0 or > signal.endtime?"
    | Some (_, v) -> v
end

let vcd (filename : string) =
  let extract_tv o = match Py.Object.to_array (fun x -> x) o with [| e1; e2 |] -> Py.Object.to_int e1, Py.Object.to_string e2 | _ -> failwith "vcd.get_signal.extract_tv: o is not a valid tv!" in
  let extract_tv_list o = (Int.Map.of_alist_exn (Object.to_list extract_tv o)) in
  let extract_nets o = Py.Object.to_list (fun d -> (Py.Object.to_string (d $. (String "__getitem__") $ [String "hier"])) ^ "." ^ (Py.Object.to_string (d $. (String "__getitem__") $ [String "name"]))) o in
  let nets_and_tv_map_l vcd_dump = PyDict.items Py.Object.to_string
    (fun n -> String.Map.of_alist_exn (PyDict.items
                Py.Object.to_string
                (fun e -> e)
                n))
    vcd_dump in
  let fn_to_tv vcd_dump = List.concat (List.map (nets_and_tv_map_l vcd_dump)
    ~f:(fun (_, m) -> let fnl, tv = extract_nets (Map.find_exn m "nets"), extract_tv_list (Map.find_exn m "tv") in List.map fnl ~f:(fun n -> (n, tv)))) in
  {
    full_names_to_tv = fn_to_tv ((PyModule.import "Verilog_VCD.Verilog_VCD") $. (String "parse_vcd") $ [(String filename)])
  }

let get_signal (v : vcd_t) (signal : string) =
  let normalize_signal_name s = Option.value (String.chop_prefix s ~prefix:"TOP.") ~default:s in
  List.iter v.full_names_to_tv ~f:(fun (fn, _) -> Logs.debug (fun p -> p "(looking %s) %s\n" signal fn));
  let _, tv =
    List.find_exn v.full_names_to_tv ~f:(fun (fn, _) ->
      String.equal fn signal ||
      String.equal (normalize_signal_name fn) (normalize_signal_name signal))
  in
    Signal.make ~tv:tv
