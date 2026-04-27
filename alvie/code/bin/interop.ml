open Core

open Learninglib.Mealy
open Learninglib.Showableint
open Learninglib.Elttype

module Interop (I : EltType) (O : EltType) = struct

  module IIOMealy = Mealy (ShowableInt) (I) (O)

  module IOEdge = struct
    type t = I.t * O.t [@@deriving eq,ord,sexp_of,of_sexp]

    include (Comparator.Make (struct type t = I.t * O.t [@@deriving ord,sexp] end))

    let default = (I.default, O.default)
  end

  module G = Graph.Persistent.Digraph.ConcreteLabeled (ShowableInt) (IOEdge)

  module Dot = Graph.Graphviz.Dot(struct
    include G
    let edge_attributes ((_, l, _) : edge) = [`Label (Sexp.to_string (IOEdge.sexp_of_t l))]
    let default_edge_attributes _ = []
    let get_subgraph _ = None
    let vertex_attributes _ = [`Shape `Circle]
    let vertex_name v = ShowableInt.show v
    let default_vertex_attributes _ = []
    let graph_attributes _ = []
  end)

  module B = struct
    module G = G

    include G
    let empty () = G.empty
    let copy g = g

  end

  module Parse = Graph.Dot.Parse (B) (struct
    let node (id, _) _ =
      let open Graph.Dot_ast in
        match id with | Ident s | Number s | String s | Html s -> Int.of_string s
    let edge (attrs : Graph.Dot_ast.attr list) =
      let open Graph.Dot_ast in
      let flat_attrs = List.concat attrs in
      let v = Option.value_exn (snd (List.last_exn (List.filter flat_attrs ~f:(fun attr -> match attr with Ident k, Some _ -> String.equal k "label" | _ -> false)))) in
        match v with
        | String s ->
          (* Logs.debug (fun m -> m "Converting to S-exp: %s" s); *)
          IOEdge.t_of_sexp (Sexp.of_string s)
        | _ -> failwith "Unexpected value while parsing an edge!"
  end)

  let t_of_dot_file (input_alphabet : IIOMealy.ISet.t) (fn : string) : IIOMealy.t =
    let dot = Parse.parse fn in
      let states = IIOMealy.SSet.of_list (B.fold_vertex (fun v acc -> v::acc) dot []) in
      let transition = IIOMealy.TransitionMap.of_alist_exn (B.fold_edges_e (fun (s, (i, o), e) acc -> ((s, i), (o, e))::acc) dot []) in
        { states=states; s0=0; input_alphabet=input_alphabet; transition=transition; pred_map=IIOMealy.PredMap.empty }


  let dot_of_t ({ states; s0; input_alphabet=_; transition; pred_map=_; } : IIOMealy.t) : B.t =
    let g = Set.fold (Set.add states s0) ~init:G.empty ~f:G.add_vertex in
    let g' = Map.fold transition ~init:g ~f:(fun ~key:(s, i) ~data:(o, s') g_acc ->
      let e : G.edge = (s, (i, o), s') in
      G.add_edge_e g_acc e) in
      g'

  (* let coq_of_dot (dot : B.t) (name : string) : string =
    let rec _rm_seq ?(prev="") (rm : string) (s : string list) = match s with
    | [] -> []
    | curr::s' -> (if String.equal curr prev && String.equal prev rm then "" else curr) :: (_rm_seq ~prev:curr rm s') in
    let _to_coq_name ?(kind="") (s : string) =
        let replacements = [('(', ""); (')', ""); (' ', "_"); (',', ""); ('@', "_AT_"); ('&', "_ADDR_"); ('?', ""); ('!', ""); ('#', "_IMM_"); ('"', ""); ('\n', "")] in
        let cnl = String.to_list (String.uppercase s) in
        let cnl = List.map cnl ~f:(fun c ->
          match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
          | None -> String.of_char c | Some (_, e) -> e) in
        let cnl = _rm_seq "_" cnl in
          kind ^ (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl) in

    let header = Format.sprintf "Require Import String.\nOpen Scope string_scope.\n\nRequire Import vulcanus.ISASemantics.\n\nModule %s <: AUTOMATON.\n" name in

    let all_outputs = List.dedup_and_sort ~compare:O.compare (B.fold_edges_e (fun (_, (_, o), _) acc -> acc @ [ o ]) dot []) in
    let output_dt =
      "\tInductive internal_Obs :=" ^
      (List.fold
        ~init:""
        ~f:(fun acc o -> acc ^ (Format.sprintf "\n\t\t| %s" (_to_coq_name ~kind:"O_" (O.show o))))
        all_outputs
      ) ^
      ".\n\tDefinition Obs := internal_Obs.\n" in

    let all_inputs = List.dedup_and_sort ~compare:I.compare (B.fold_edges_e (fun (_, (i, _), _) acc -> acc @ [ i ]) dot []) in
    let input_dt =
      "\tInductive internal_Σ :=" ^
      (List.fold
        ~init:""
        ~f:(fun acc i -> acc ^ (Format.sprintf "\n\t\t| %s" (_to_coq_name ~kind:"I_" (I.show i))))
        all_inputs
      ) ^
      ".\n\tDefinition Σ := internal_Σ.\n" in

    let state_dt =
      "\tInductive internal_state :=" ^
      (B.fold_vertex
        (fun state acc -> acc ^ (Format.sprintf "\n\t\t| %s" (_to_coq_name ~kind:"S_" (Int.to_string state))))
        dot
        ""
      ) ^
      ".\n\tDefinition state := internal_state." ^
      Format.sprintf "\n\tDefinition s0 := %s.\n" (_to_coq_name ~kind:"S_" "0") in

    let transition_fun =
      "\tDefinition δ (s : state) (a : Σ) : option (state * Obs) :=\n" ^
      "\tmatch (s, a) with" ^
      (B.fold_edges_e
      (fun (s, (i, o), s') acc ->
        acc ^
        (Format.sprintf "\n\t\t| (%s, %s) =>\n\t\t\t\tSome (%s, %s)"
          (_to_coq_name ~kind:"S_" (Int.to_string s))
          (_to_coq_name ~kind:"I_" (I.show i))
          (_to_coq_name ~kind:"S_" (Int.to_string s'))
          (_to_coq_name ~kind:"O_" (O.show o))
        )
      )
      dot
      "") ^
      "\n\t\t| _ => None" ^
      "\n\tend.\n" in

    let footer = Format.sprintf "End %s." name in

    header ^ output_dt ^ input_dt ^ state_dt ^ transition_fun ^ footer *)
end
