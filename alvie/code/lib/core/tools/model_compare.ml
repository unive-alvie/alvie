(*
  Comparing two learned models (Mealy machines in .dot files) up to the numbering of their states.

  Learning numbers states by the nodes of its observation tree, so two runs that ask different queries give
  different numbers to the same machine. Two models are isomorphic when a bijection between their states maps the
  initial states to each other and every transition to one with the same label. The models are deterministic, so
  a walk from the initial states finds the bijection, or the first place where they differ.

  A label is the text of the edge (input and output). relabel can drop the part of a label that should not count,
  e.g. the bookkeeping of a Sancus output.
*)

open Core

(* state -> (label -> target), from the edges "s -> t [label="..."]" of a .dot file *)
let load file : (string * string, string) Hashtbl.t * string list =
  let edges = Hashtbl.Poly.create () in
  let states = ref [] in
  let re_edge = Str.regexp {|^ *\([0-9]+\) *-> *\([0-9]+\) *\[\(.*\)label="\(\([^"\\]\|\\.\)*\)"|} in
  let re_node = Str.regexp {|^ *\([0-9]+\) *\[|} in
  List.iter (In_channel.read_lines file) ~f:(fun line ->
      if Str.string_match re_edge line 0 then
        Hashtbl.set edges ~key:(Str.matched_group 1 line, Str.matched_group 4 line) ~data:(Str.matched_group 2 line)
      else if Str.string_match re_node line 0 then states := Str.matched_group 1 line :: !states);
  (edges, !states)

type difference = { path : string list; reason : string }

(* The labels of the edges of each state *)
let by_state edges =
  let t = Hashtbl.create (module String) in
  Hashtbl.iteri edges ~f:(fun ~key:(s, label) ~data:target -> Hashtbl.add_multi t ~key:s ~data:(label, target));
  t

let isomorphic ?(relabel = Fn.id) ~initial a_file b_file : (int, difference) Result.t =
  let a_edges, _ = load a_file and b_edges, _ = load b_file in
  let relabelled edges = by_state (Hashtbl.Poly.of_alist_exn (List.map (Hashtbl.to_alist edges) ~f:(fun ((s, l), t) -> ((s, relabel l), t)))) in
  let a = relabelled a_edges and b = relabelled b_edges in
  let forward = Hashtbl.create (module String) and backward = Hashtbl.create (module String) in
  let out t s = List.sort (Option.value (Hashtbl.find t s) ~default:[]) ~compare:[%compare: string * string] in
  let exception Differ of difference in
  let rec visit path s s' =
    match Hashtbl.find forward s with
    | Some m -> if not (String.equal m s') then raise (Differ { path = List.rev path; reason = "the same path leads to different states" })
    | None ->
      if Hashtbl.mem backward s' then raise (Differ { path = List.rev path; reason = "two states of the first model match one of the second" });
      Hashtbl.set forward ~key:s ~data:s';
      Hashtbl.set backward ~key:s' ~data:s;
      let ea = out a s and eb = out b s' in
      let la = List.map ea ~f:fst and lb = List.map eb ~f:fst in
      if not (List.equal String.equal la lb) then (
        let only l l' = List.filter l ~f:(fun x -> not (List.mem l' x ~equal:String.equal)) in
        raise (Differ { path = List.rev path; reason = sprintf "different transitions: only in the first model %s; only in the second %s"
                                                         (String.concat ~sep:", " (only la lb)) (String.concat ~sep:", " (only lb la)) }));
      List.iter ea ~f:(fun (label, t) -> visit (label :: path) t (List.Assoc.find_exn eb ~equal:String.equal label)) in
  match visit [] initial initial with
  | () -> Ok (Hashtbl.length forward)
  | exception Differ d -> Error d

(*
  The shortest sequence of inputs after which the two models answer differently, searched breadth first on their
  product: labels split into input and output with split. Returns the path (labels of the first model), the input
  and the outputs of the two models (None when a model has no transition for the input).
*)
let distinguish ?(relabel = Fn.id) ~split ~initial a_file b_file : (string list * string * string option * string option) option =
  let a_edges, _ = load a_file and b_edges, _ = load b_file in
  let index edges =
    let t = Hashtbl.create (module String) in
    Hashtbl.iteri edges ~f:(fun ~key:(s, label) ~data:target ->
        let i, o = split (relabel label) in
        Hashtbl.update t s ~f:(fun m -> Map.set (Option.value m ~default:String.Map.empty) ~key:i ~data:(o, target, label)));
    t in
  let a = index a_edges and b = index b_edges in
  let seen = Hash_set.Poly.create () in
  let queue = Queue.create () in
  Queue.enqueue queue (initial, initial, []);
  let result = ref None in
  while Option.is_none !result && not (Queue.is_empty queue) do
    let s, s', path = Queue.dequeue_exn queue in
    if not (Hash_set.mem seen (s, s')) then (
      Hash_set.add seen (s, s');
      let ma = Option.value (Hashtbl.find a s) ~default:String.Map.empty and mb = Option.value (Hashtbl.find b s') ~default:String.Map.empty in
      let inputs = List.dedup_and_sort (Map.keys ma @ Map.keys mb) ~compare:String.compare in
      List.iter inputs ~f:(fun i ->
          if Option.is_none !result then
            match Map.find ma i, Map.find mb i with
            | Some (o, t, label), Some (o', t', _) ->
              if String.equal o o' then Queue.enqueue queue (t, t', label :: path)
              else result := Some (List.rev path, i, Some o, Some o')
            | oa, ob -> result := Some (List.rev path, i, Option.map oa ~f:fst3, Option.map ob ~f:fst3)))
  done;
  !result
