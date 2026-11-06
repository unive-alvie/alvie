(*
  Observations: the labels of the LTSs that the engine compares, an input with its output (and the Graphviz
  attributes of the edge, used to colour the runs in witness graphs; they are ignored by equality, comparison and
  serialization).
*)

open Graph
open Core

module Make (H : Hooks.S) = struct
  module EdgeAttributes = struct
    type t = Graphviz.DotAttributes.edge list

    let sexp_of_t (_ : t) = Sexp.unit
    let t_of_sexp (_ : Sexp.t) = []

    let compare _ _ = 0
    let equal _ _ = true
  end
  type edge_attributes_t = EdgeAttributes.t

  type t = IO of H.Input.t * H.Output.t * EdgeAttributes.t [@@deriving sexp,ord,eq]
  let default = IO (H.Input.default, H.Output.default, [])
  let make ?(attributes = []) i o = IO (i, o, attributes)

  (* mCRL2 action names cannot contain parentheses: s-expressions are written with brackets *)
  let to_mcrl2_name (s : string) =
    let replacements = [('(', "["); (')', "]")] in
    let cnl = List.map (String.to_list s) ~f:(fun c ->
      match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
      | None -> String.of_char c | Some (_, e) -> e) in
    (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl)

  let of_mcrl2_name (s : string) =
    let replacements = [('[', "("); (']', ")")] in
    let cnl = List.map (String.to_list s) ~f:(fun c ->
      match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
      | None -> String.of_char c | Some (_, e) -> e) in
    (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl)

  let show io = to_mcrl2_name (Sexp.to_string_mach (sexp_of_t io))
  let pp fmt io = Format.fprintf fmt "%s" (show io)
  let parse s = Sexp.of_string_conv_exn (of_mcrl2_name s) t_of_sexp

  let input (IO (i, _, _)) = i
  let output (IO (_, o, _)) = o
  let to_pair (IO (i, o, _)) = (i, o)

  let is_silent (IO (_, o, _)) = H.is_hidden o

  let human_show (IO (i, o, _)) = H.human_show i o

  let edge_attributes obs =
    let (IO(_, _, attr)) = obs in (`Label (human_show obs))::attr
end
