open Core
open Graph

module LTS
  (S : sig type t [@@deriving eq,ord,sexp,hash,show] end)
  (O : sig
    type t [@@deriving ord,sexp]
    val default : t
    val is_silent : t -> bool
    val edge_attributes : t -> Graphviz.DotAttributes.edge list
  end) = struct
  module LTSMap = Map.Make (struct type t = S.t * O.t [@@deriving ord,sexp] end) [@@deriving sexp]
  module LTSSSet = Set.Make (struct type t = S.t [@@deriving ord,sexp] end) [@@deriving sexp]

  type lts_map_t = LTSSSet.t LTSMap.t [@@deriving sexp,eq]
  type t = {
    initial : S.t;
    states : LTSSSet.t;
    transition : lts_map_t
  } [@@deriving eq]

  (* Ugly hack, sorry *)
  let _ = S.pp

  let get_silent_obs (lts : t) = Map.fold lts.transition ~f:(fun ~key:(_, obs) ~data:_ acc -> if O.is_silent obs then obs::acc else acc) ~init:[]

  module G = Graph.Persistent.Digraph.ConcreteLabeled (S) (O)

  module Dot = Graph.Graphviz.Dot(struct
    include G
    let edge_attributes ((_, o, _) : edge) = O.edge_attributes o
    let default_edge_attributes _ = []
    let get_subgraph _ = None
    let vertex_attributes _ = [`Shape `Circle]
    let vertex_name v = S.show v
    let default_vertex_attributes _ = []
    let graph_attributes _ = []
  end)

  module B = struct
    module G = G

    include G

    let empty () = G.empty
    let copy g = g
  end

  let to_dot ({ initial; states; transition } : t) : B.t =
    let g = Set.fold (Set.add states initial) ~init:G.empty ~f:G.add_vertex in
    let g' =
      Map.fold transition ~init:g ~f:(fun ~key:(s, o) ~data:s'_set g_acc ->
        Set.fold s'_set ~init:g_acc ~f:(fun g_acc_acc s' -> G.add_edge_e g_acc_acc (s, o, s'))) in
      g'

  let get_states (m : t) (trace : O.t list) : LTSSSet.t =
    List.fold trace
      ~init:(LTSSSet.singleton m.initial)
      ~f:(fun acc_s obs ->
          Set.fold acc_s
          ~init:LTSSSet.empty
          ~f:(fun acc el ->
            match Map.find m.transition (el, obs) with
            | None -> acc
            | Some succ -> Set.union acc succ
          )
      )
end
