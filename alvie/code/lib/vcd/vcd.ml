(*
  A native parser for (four-state) VCD files.

  It follows the semantics of the Verilog_VCD Python module previously used through ocaml-py
  (https://github.com/zylin/Verilog_VCD): only the $scope, $upscope, $var, $enddefinitions and
  $timescale keywords are interpreted, signal full names are the dot-separated scope path followed
  by the (space-stripped) reference name, and times are taken verbatim from #<time> lines.
*)

open Core

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

let normalize_signal_name s = Option.value (String.chop_prefix s ~prefix:"TOP.") ~default:s

(* If [signals] is given, only the time/value pairs of those signals are kept (names are compared modulo the TOP. prefix) *)
let parse_channel ?signals (ic : In_channel.t) : vcd_t =
  let wanted =
    Option.map signals ~f:(fun l -> String.Set.of_list (List.map l ~f:normalize_signal_name)) in
  let is_wanted full_name =
    match wanted with None -> true | Some w -> Set.mem w (normalize_signal_name full_name) in
  (* code -> list of full names (in declaration order, reversed) *)
  let nets : (string, string list) Hashtbl.t = Hashtbl.create (module String) in
  (* code -> time/value changes (reversed) *)
  let tvs : (string, (int * string) list) Hashtbl.t = Hashtbl.create (module String) in
  let codes_in_order = Queue.create () in
  let hier = Stack.create () in
  let time = ref 0 in
  let record code value =
    match Hashtbl.find tvs code with
    | Some l -> Hashtbl.set tvs ~key:code ~data:((!time, value) :: l)
    | None -> if Hashtbl.mem nets code then Hashtbl.set tvs ~key:code ~data:[ (!time, value) ]
  in
  let words line = String.split_on_chars line ~on:[ ' '; '\t' ] |> List.filter ~f:(fun w -> not (String.is_empty w)) in
  let rec loop () =
    match In_channel.input_line ic with
    | None -> ()
    | Some line ->
      let line = String.strip line in
      (if String.is_empty line then ()
       else
         match line.[0] with
         | 'b' | 'B' | 'r' | 'R' ->
           (match words (String.drop_prefix line 1) with
            | [ value; code ] -> record code value
            | _ -> failwithf "Vcd: malformed vector value change: %s" line ())
         | '0' | '1' | 'x' | 'X' | 'z' | 'Z' ->
           record (String.drop_prefix line 1) (String.prefix line 1)
         | '#' -> time := Int.of_string (String.drop_prefix line 1)
         | _ ->
           if String.is_substring line ~substring:"$enddefinitions" then ()
           else if String.is_substring line ~substring:"$timescale" then (
             (* Times are kept in the units of the file; just skip the (possibly multi-line) statement *)
             let rec skip l = if not (String.is_substring l ~substring:"$end") then Option.iter (In_channel.input_line ic) ~f:skip in
             skip line)
           else if String.is_substring line ~substring:"$scope" then
             (match words line with
              | _ :: _ :: name :: _ -> Stack.push hier name
              | _ -> failwithf "Vcd: malformed $scope: %s" line ())
           else if String.is_substring line ~substring:"$upscope" then ignore (Stack.pop_exn hier)
           else if String.is_substring line ~substring:"$var" then
             (match words line with
              | _ :: _ :: _ :: code :: rest when List.length rest >= 1 ->
                let name = String.concat (List.drop_last_exn rest) in
                let path = String.concat ~sep:"." (List.rev (Stack.to_list hier)) in
                let full_name = path ^ "." ^ name in
                if is_wanted full_name then
                (match Hashtbl.find nets code with
                 | None -> Queue.enqueue codes_in_order code; Hashtbl.set nets ~key:code ~data:[ full_name ]
                 | Some l -> if not (List.mem l full_name ~equal:String.equal) then Hashtbl.set nets ~key:code ~data:(full_name :: l))
              | _ -> failwithf "Vcd: malformed $var: %s" line ()));
      loop ()
  in
  loop ();
  let full_names_to_tv =
    Queue.to_list codes_in_order
    |> List.concat_map ~f:(fun code ->
      match Hashtbl.find tvs code with
      | None -> [] (* Signals that never change carry no time/value pairs *)
      | Some l ->
        (* Later changes at the same time override earlier ones *)
        let tv = Int.Map.of_alist_reduce (List.rev l) ~f:(fun _ newer -> newer) in
        List.rev_map (Hashtbl.find_exn nets code) ~f:(fun n -> (n, tv)))
  in
  { full_names_to_tv }

let vcd ?signals (filename : string) = In_channel.with_file filename ~f:(parse_channel ?signals)

let matches signal (fn, _) =
  String.equal fn signal || String.equal (normalize_signal_name fn) (normalize_signal_name signal)

let has_signal (v : vcd_t) (signal : string) = List.exists v.full_names_to_tv ~f:(matches signal)

let get_signal (v : vcd_t) (signal : string) =
  let _, tv =
    List.find_exn v.full_names_to_tv ~f:(matches signal)
  in
    Signal.make ~tv:tv
