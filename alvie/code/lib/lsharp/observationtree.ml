open Core

open Mealy
open Elttype

module ObservationTree (S : EltType) (I : EltType) (O : EltType) = struct
  include Mealy (S) (I) (O)

  (* module ApartCache = Hashtbl.Make (struct type t = S.t*S.t [@@deriving hash,ord,sexp] end)
  type apart_cache_t = (I.t list) ApartCache.t [@@deriving sexp] *)

  (* Raises an exception if a key has multiple predecessors,
      i.e., enforces the tree property at making time! *)
  let build_predecessor_map (transition : transition_map_t) =
    let empty_map : pred_map_t = PredMap.empty  in
      Map.fold transition ~init:empty_map ~f:(fun ~key ~data pred_map ->
        let (_, sf) = data in
        Map.add_exn pred_map ~key:sf ~data:key)

  let make ~(states : sset_t) ~(s0:S.t) ~(input_alphabet:iset_t) ~(transition : transition_map_t) : t =
    { states=states; s0=s0; input_alphabet=input_alphabet; transition=transition; pred_map = build_predecessor_map transition }

  let transfer_sequence (ot : t) (sfrom : S.t) (sto : S.t) : I.t list =
    let rec _transfer_sequence (ot : t) (sfrom : S.t) (sto : S.t) (acc : I.t list) : I.t list =
      if S.equal sfrom sto then acc
      else (
        let (s_pred, i) = (Map.find_exn ot.pred_map sto) in
          _transfer_sequence ot sfrom s_pred (i::acc)
      ) in
    _transfer_sequence ot sfrom sto []

  let access (ot : t) (s : S.t) : I.t list = transfer_sequence ot ot.s0 s

  let update (ot : t) (s : S.t) (i : I.t) (o : O.t) (s' : S.t) : t =
    make
      ~states:(Set.add ot.states s')
      ~s0:(ot.s0)
      ~input_alphabet:(ot.input_alphabet)
      ~transition:(let upd = Map.remove ot.transition (s, i) in Map.add_exn upd ~key:(s, i) ~data:(o, s'))

  (* Returns `NotApart if s and s' are not apart in ot; Otherwise returns `Apart w, with w a witness of apartness. *)
  let apart_with_witness (ot : t) (s : S.t) (s' : S.t) =
    let ia_list = Set.to_list ot.input_alphabet in
    let rec _apart_with_witness (queue : (S.t * S.t) Fqueue.t) =
      (match Fqueue.dequeue queue with
      | None -> `NotApart
      | Some ((first, second), queue') ->
        let transition_res = List.filter_map ia_list
          ~f:(fun i ->
            match (transition ot (first, i), transition ot (second, i)) with
            | None, _ | _, None -> None
            | Some r, Some r' -> Some (i, r, r')) in
        let result = List.fold_until
          transition_res
          ~init:queue'
          ~f:(fun qacc (i, (o, sr), (o', sr')) ->
            if O.equal o o' then (* If the output is the same, enqueue the new pair of states *)
              Continue (Fqueue.enqueue qacc (sr, sr'))
            else (* If not, then we found a witness of apartness, return it *)
              Stop (`Finished ((transfer_sequence ot s first) @ [i]))
            )
          ~finish:(fun acc -> `NotFinished acc) in
        match result with
        | `Finished i -> `Apart i
        | `NotFinished queue'' -> _apart_with_witness queue'') in
    _apart_with_witness (Fqueue.singleton (s, s'))

  (* Returns a boolean telling if s and s' are apart in ot. *)
  let apart (ot : t) (s : S.t) (s' : S.t) =
    match (apart_with_witness ot s s') with
    | `NotApart -> false | `Apart _ -> true
end
