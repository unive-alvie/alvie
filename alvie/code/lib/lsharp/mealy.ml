open Core
open Elttype

module Mealy (S : EltType) (I : EltType) (O : EltType) = struct
  (* Set instantiation on State *)
  module SSet = Set.Make_using_comparator (S)
  module ISet = Set.Make_using_comparator (I)

  module SIPair = struct
    type t = (S.t * I.t) [@@deriving eq,ord,sexp]

    include (Comparator.Make (struct type t = (S.t * I.t) [@@deriving ord,sexp_of,of_sexp] end))
  end

  module TransitionMap = Map.Make_using_comparator (SIPair) [@@deriving sexp]
  type transition_map_t = (O.t * S.t) TransitionMap.t [@@deriving sexp]

  type sset_t = SSet.t [@@deriving sexp_of]
  type iset_t = ISet.t [@@deriving sexp_of]

  module PredMap = Map.Make_using_comparator (S) [@@deriving sexp_of]
  type pred_map_t = SIPair.t PredMap.t [@@deriving sexp_of]

  (* The type of the Mealy automaton, with the additional pred_map just used in ObservationTrees *)
  type t = {
    states : sset_t;
    s0 : S.t;
    input_alphabet : iset_t;
    transition : transition_map_t;
    pred_map : pred_map_t;
  }[@@deriving sexp_of]


  let make ~(states : sset_t) ~(s0:S.t) ~(input_alphabet:iset_t) ~(transition : transition_map_t) : t =
    { states=states; s0=s0; input_alphabet=input_alphabet; transition=transition; pred_map = PredMap.empty }

  let step m s i : S.t option =
    match Map.find m.transition (s, i) with
      | Some (_, s') -> Some s'
      | _ -> None

  let output m s i : O.t option =
    match Map.find m.transition (s, i) with
      | Some (o, _) -> Some o
      | _ -> None

  let transition m (s, i) : (O.t * S.t) option = Map.find m.transition (s, i)
  let rec transition_all m s ilist : (O.t * S.t) option =
    match ilist with
    | [] ->
        None
    | i::is ->
      match transition m (s, i) with
      | None -> None
      | Some (o, s') ->
        (if List.length is = 0 then
          Some (o, s')
        else
          transition_all m s' is)

  let input_alphabet m = m.input_alphabet
end
