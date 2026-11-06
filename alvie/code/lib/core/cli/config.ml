(*
  The command-line options of a backend, generated from the configuration parameters of its manifest
  (alvie-plugin.yaml, config:): one --<name> option for each, with the documentation of the manifest.

  - string, path, int and enum parameters take a value; a required one must be given, the others have the
    manifest's default (or none);
  - a bool parameter is a flag without a value, false unless given.

  Values are checked against their type (an integer in its range, one of the values of an enumeration) before the
  command runs, with a message that names the option.
*)

open Core
open Alvie_plugin

type t = (string * string) list (* name -> value, for the parameters that have one *)

let get (t : t) name = List.Assoc.find t ~equal:String.equal name
let get_exn (t : t) name = match get t name with Some v -> v | None -> failwithf "no value for the parameter %s" name ()
let flag_set (t : t) name = Option.equal String.equal (get t name) (Some "true")

let arg_type (p : Manifest_file.param) : string Command.Arg_type.t =
  let fail fmt = Printf.ksprintf (fun m -> failwithf "--%s: %s" p.pname m ()) fmt in
  match p.ptype with
  | P_string | P_path | P_bool -> Command.Arg_type.Export.string
  | P_int (lo, hi) ->
    Command.Arg_type.create (fun s ->
        match Option.try_with (fun () -> Int.of_string s) with
        | Some i when i >= lo && i <= hi -> s
        | Some _ -> fail "%s is out of range %d..%d" s lo hi
        | None -> fail "%S is not an integer" s)
  | P_enum vs ->
    Command.Arg_type.create ~complete:(fun _ ~part -> List.filter vs ~f:(String.is_prefix ~prefix:part)) (fun s ->
        if List.mem vs s ~equal:String.equal then s else fail "%S is not one of %s" s (Diag.enumerate vs))

let doc (p : Manifest_file.param) =
  let arg = match p.ptype with
    | P_string -> "value" | P_path -> "path" | P_int _ -> "n" | P_enum vs -> String.concat ~sep:"|" vs | P_bool -> "" in
  let default = match p.default, p.ptype with
    | Some d, (P_string | P_path | P_int _ | P_enum _) -> sprintf " (default: %s)" d
    | _ -> "" in
  String.strip (arg ^ " " ^ Option.value p.pdoc ~default:"" ^ default)

let param_of (p : Manifest_file.param) : (string * string) option Command.Param.t =
  let open Command.Param in
  let name = "--" ^ p.pname in
  let doc = doc p in
  match p.ptype, p.required, p.default with
  | P_bool, _, _ -> map (flag name no_arg ~doc) ~f:(fun b -> Some (p.pname, Bool.to_string b))
  | _, true, _ -> map (flag name (required (arg_type p)) ~doc) ~f:(fun v -> Some (p.pname, v))
  | _, false, Some d -> map (flag name (optional_with_default d (arg_type p)) ~doc) ~f:(fun v -> Some (p.pname, v))
  | _, false, None -> map (flag name (optional (arg_type p)) ~doc) ~f:(Option.map ~f:(fun v -> (p.pname, v)))

(* The options of all the parameters of the manifest *)
let param (m : Manifest_file.t) : t Command.Param.t =
  List.fold_right m.config ~init:(Command.Param.return []) ~f:(fun p acc ->
      Command.Param.map2 (param_of p) acc ~f:(fun v rest -> Option.to_list v @ rest))
