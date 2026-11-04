(*
  The comparison engine: learned models as LTSs, trace inclusion checked with mCRL2 (ltscompare), witnesses (pairs
  of runs that the attacker tells apart) and witness graphs. It is generic in the inputs and outputs of the models:
  the backend gives its view of them through Hooks.S (see hooks.ml), and fa.exe of ALVIE/Sancus instantiates it in
  lib/sancus-compare.
*)

open Learninglib
open Lts

open Shexp_process
open Core

module Make (H : Hooks.S) = struct

module Obs = Obs.Make (H)

module IIOMealy = Learninglib.Mealy.Mealy (Showableint.ShowableInt) (H.Input) (H.Output)

module I = struct type t = Int.t [@@deriving eq,ord,sexp,hash,show] end
module ILTS = LTS (I) (Obs)
module ObsSet = Set.Make (Obs)
type i_lts_t = ILTS.t

module Parse = Graph.Dot.Parse (ILTS.B) (struct
  let node (id, _) _ =
    let open Graph.Dot_ast in
      (* A bit hacky *)
      match id with | Ident s | Number s | String s | Html s ->
        if Char.equal (String.get s 0) 'S' then Int.of_string (String.drop_prefix s 1)
        else Int.of_string s

  let edge (attrs : Graph.Dot_ast.attr list) =
    let open Graph.Dot_ast in
    let flat_attrs = List.concat attrs in
    let v = Option.value_exn (snd (List.last_exn (List.filter flat_attrs ~f:(fun attr -> match attr with Ident k, Some _ -> String.equal k "label" | _ -> false)))) in
      match v with
      | String s ->
        (* Logs.debug (fun m -> m "[cexfinder.Parse.edge] Converting from S-exp: %s" s); *)
        Obs.parse s
      | _ -> failwith "[cexfinder.Parse.edge] Unexpected value while parsing an edge!"
end)

let i_lts_of_mealy (m : IIOMealy.t) : i_lts_t =
  let states = ILTS.LTSSSet.of_list (Set.to_list m.states) in
  let transition = Map.fold m.transition
    ~init:ILTS.LTSMap.empty
    ~f:(fun ~key:(s, i) ~data:(o, s') acc_tr ->
        let change_or_add tr ~key ~data =
          if Map.mem tr key then
              Map.change tr key ~f:(fun old_d -> match old_d with Some old_d -> Some (Set.add old_d data) | _ -> None)
          else Map.add_exn tr ~key:key ~data:(ILTS.LTSSSet.singleton data)
        in
          change_or_add acc_tr ~key:(s, Obs.make i o) ~data:s')
  in { initial = m.s0; states; transition }

(* Returns the string of the LTS in aldebaran format and a list of novel silent actions *)
let i_lts_to_checkable_aldebaran ({ initial; states; transition } : i_lts_t) : string =
  let additional_tr = ref 0 in
  let state_to_int = List.foldi (initial::(Set.elements (Set.remove states initial))) ~init:(fun _ -> failwith "i_lts_to_checkable_aldebaran: Unknown state") ~f:(fun i acc s -> (fun s' -> (if s' = s then i else acc s'))) in
  let last_used = ref (Set.length states - 1) in
  let aut_edges = Map.fold transition
      ~init:""
      ~f:(fun ~key:(s, o) ~data:s'_set acc_s ->
          (Set.fold s'_set ~init:acc_s
            ~f:(fun acc_s' s' -> acc_s' ^ sprintf "(%d, \"%s\", %d)\n" (state_to_int s) (Obs.show o) (state_to_int s')))
      ) in
    let aut_header = sprintf "des (0, %d, %d)\n" (!additional_tr + Map.length transition) (1 + !last_used) in
    aut_header ^ aut_edges


let find_cex_aut ~tmpdir (m1 : i_lts_t) (m2 : i_lts_t) : Obs.t list option =
  (* Generate file names for: m, m', the counterexample and their containing tmp folder *)
  let r_tmpdir = Core_unix.mkdtemp (tmpdir ^ "/") in
  Logs.debug (fun m -> m "[find_cex] Created temporary directory: %s" r_tmpdir);
  (* Write m and m' to file *)
  let m1_ald, m2_ald = i_lts_to_checkable_aldebaran m1, i_lts_to_checkable_aldebaran m2 in
    Out_channel.write_all (sprintf "%s/m1.aut" r_tmpdir) ~data:m1_ald;
    Out_channel.write_all (sprintf "%s/m2.aut" r_tmpdir) ~data:m2_ald;
  Logs.debug (fun m -> m "[find_cex] Written LTSs to disk");
  let silent = List.dedup_and_sort (ILTS.get_silent_obs m1 @ ILTS.get_silent_obs m2) ~compare:Obs.compare in
  let silent_str = String.drop_suffix (List.fold silent ~f:(fun acc o -> sprintf "%s,%s" (Obs.show o) acc) ~init:"") 1 in
  (* And prepare the cmd lines *)
  let cmd_ltscompare = sprintf "ltscompare %s/m1.aut %s/m2.aut --strategy=b --counter-example --counter-example-file=%s/cex.trc --preorder=weak-trace-ac --tau=\"%s\" -q >/dev/null" r_tmpdir r_tmpdir r_tmpdir silent_str in
  (* Logs.debug (fun p -> p "Compare: %s" cmd_ltscompare); *)
  let cmd_tracepp_args = [sprintf "%s/cex.trc" r_tmpdir; "-fplain"] in
  let cex_found () = match Sys_unix.file_exists (sprintf "%s/cex.trc" r_tmpdir) with | `Yes -> true | _ -> false in
    ignore (Sys_unix.command (sprintf "rm -f %s/*.trc" r_tmpdir));
    Logs.debug (fun m -> m "[find_cex] Running the comparison");
    ignore (Sys_unix.command cmd_ltscompare);
    if cex_found () then
      (
        let aut_cex = (eval (pipe (run "tracepp" cmd_tracepp_args) (fold_lines ~init:[] ~f:(fun acc curr -> return (acc @ [Obs.parse curr]))))) in
          (match Logs.level () with | Some Debug -> () | _ -> ignore (Sys_unix.command (sprintf "rm -rf %s" r_tmpdir)));
          Some aut_cex
      )
    else
      (
        (match Logs.level () with | Some Debug -> () | _ -> ignore (Sys_unix.command (sprintf "rm -rf %s" r_tmpdir)));
        None
      )

(* Removes cex and all its suffixes from m, but *not* the prefix *)
let remove_cex_heur (m : i_lts_t) (cex : Obs.t list) : i_lts_t =
  let cex_front, cex_last = List.drop_last_exn cex, List.last_exn cex in
  let candidate_states = ILTS.get_states m cex_front in
  (* Logs.debug (fun p -> p "[remove_cex_heur] cand: %s" (List.to_string ~f:Int.to_string (Set.to_list candidate_states))); *)
  let upd_tr =
    Set.fold candidate_states ~init:m.transition ~f:(fun acc_tr s ->
      let acc = Map.remove acc_tr (s, cex_last) in
        acc
    ) in
    { m with transition = upd_tr }

(* Given a counterexample cex integrates it into m *)
let integrate_cex ~up_to_silent (m : i_lts_t) (cex : Obs.t list) : i_lts_t =
  let (_, _, upd) =
    List.fold cex
    ~init:(Set.max_elt_exn m.states, (ILTS.LTSSSet.singleton m.initial), m)
    ~f:(
      fun (last_used, acc_s, acc_lts) obs ->
        let successors = Set.fold acc_s
                          ~init:ILTS.LTSSSet.empty
                          ~f:(fun acc el ->
                            Set.union (match Map.find acc_lts.transition (el, obs) with
                            | None -> acc
                            | Some succ -> Set.union acc succ)
                            (if up_to_silent && Obs.is_silent obs then ILTS.LTSSSet.singleton el
                            else ILTS.LTSSSet.empty)
                          ) in
        if Set.is_empty successors then
          ( (* Logs.debug (fun p -> p "[integrate_cex] Empty succ set!"); *)
            let fresh_state = last_used + 1 in
            let additional_transitions =
                List.map (Set.to_list acc_s) ~f:(fun el -> ((el, obs), ILTS.LTSSSet.singleton fresh_state))  in
                (fresh_state,
                (ILTS.LTSSSet.singleton fresh_state),
                { acc_lts with
                  states = Set.add acc_lts.states fresh_state;
                  transition = List.fold additional_transitions
                    ~init:acc_lts.transition
                    ~f:(fun new_tr (k, v) -> (Map.add_exn new_tr ~key:k ~data:v))
                }) (* We need to add a fresh state and create the transition *)
          )
        else
          (last_used, successors, acc_lts) (* No changes needed, just keep track of the progress *)
        ) in upd

(* Updates cex_lts and integrates all paths in all_paths_m1 and all_paths_m2 into it *)
let update_cex_graph (cex_lts : i_lts_t) (path_m1 : Obs.t list) (path_m2 : Obs.t list) : i_lts_t =
  (* Logs.debug (fun p -> p "Integrating path_m1:\n\t%s" (List.to_string ~f:Obs.show path_m1)); *)
  let upd_m1 = integrate_cex ~up_to_silent:false cex_lts path_m1 in
  let (_, _, upd) = List.fold
    path_m2
    ~init:(Set.max_elt_exn upd_m1.states, (ILTS.LTSSSet.singleton upd_m1.initial), upd_m1)
    ~f:(fun (last_used, acc_s, acc_lts) obs ->
          let successors, alt_successors = Set.fold
            acc_s
            ~init:(ILTS.LTSSSet.empty, ILTS.LTSSSet.empty)
            ~f:(fun (acc, alt_acc) el ->
              (* Collect the set of successors of el s.t. they have the same input as obs, but possibly different outputs. *)
              let alt_states = Map.fold (Map.filter_keys acc_lts.transition ~f:(fun (s, o) -> s = el && H.Input.equal (Obs.input o) (Obs.input obs))) ~init:ILTS.LTSSSet.empty ~f:(fun ~key:_ ~data alt_acc -> Set.union alt_acc data) in
              (match Map.find acc_lts.transition (el, obs) with
              | None -> acc
              | Some succ -> Set.union acc succ), Set.union alt_acc alt_states
            ) in
          if Set.is_empty successors then
            ((* Logs.debug (fun p -> p "[update_cex_graph] Empty succ set on path_m2!"); *)
            (* We have two cases, either there exists an observable with the same input part and we can re-use the existing target state(s), or it does not, and we must fall back to the integrate_cex code *)
            if Set.is_empty alt_successors then
              let fresh_state = last_used + 1 in
              let additional_transitions = List.map (Set.to_list acc_s) ~f:(fun el -> ((el, obs), ILTS.LTSSSet.singleton fresh_state)) in
                  (fresh_state,
                  (ILTS.LTSSSet.singleton fresh_state),
                  { acc_lts with
                    states = Set.add acc_lts.states fresh_state;
                    transition = List.fold additional_transitions
                      ~init:acc_lts.transition
                      ~f:(fun new_tr (k, v) -> (Map.add_exn new_tr ~key:k ~data:v))
                  }) (* We need to add a fresh state and create the transition *)
            else
              let additional_transitions =
                List.map (Set.to_list acc_s) ~f:(fun s -> ((s, obs), alt_successors)) in
                (last_used,
                alt_successors,
                { acc_lts with
                  transition = List.fold additional_transitions
                    ~init:acc_lts.transition
                    ~f:(fun new_tr (k, v) -> (Map.add_exn new_tr ~key:k ~data:v))
                }) (* We need to add a fresh state and create the transition *)
              )
          else
            (last_used, successors, acc_lts) (* No changes needed, just keep track of the progress *)
          ) in
          upd

(*
  All the maximal paths of m without repeated states whose attacker inputs agree with the ones of cex
  (one is a prefix of the other). A path ends at a reset or a divergence, at a state without
  successors, or when it would enter a state it has already visited. Paths are simple, so their
  length is bounded by the number of states of m.

  A state is "visited" only for the path that visited it: different paths may share a state (and
  do so more often in minimal models), and stopping a path there would truncate it artificially,
  i.e., make it look like the behavior ends there.
*)
let all_acyclic_cexs ~attributes (m : i_lts_t) (cex : Obs.t list): Obs.t list list =
  let att_inputs p = List.filter_map p ~f:(fun (Obs.IO (i, _, _)) -> if H.is_low_input i then Some i else None) in
  let cex_att = att_inputs cex in
  let compatible att = List.is_prefix ~equal:H.Input.equal att ~prefix:cex_att || List.is_prefix ~equal:H.Input.equal cex_att ~prefix:att in
  let same_att_inputs ol = not (List.is_empty ol) && not (List.is_empty cex) && compatible (att_inputs ol) in
  let successors = Map.fold m.transition ~init:Int.Map.empty ~f:(fun ~key:(s, obs) ~data acc ->
    let Obs.IO (i, o, _) = obs in
    Map.add_multi acc ~key:s ~data:(Obs.make ~attributes i o, data)) in
  let all : Obs.t list list ref = ref [] in
  let record path = if same_att_inputs path then all := path :: !all in
  (* Depth-first, keeping the states on the current path (on_path); rev_path and rev_att are the path and its attacker inputs, reversed *)
  let rec visit curr_state on_path rev_path rev_att =
    let is_final = match rev_path with
      | Obs.IO(_, o, _) :: _ -> H.is_final o
      | [] -> false in
    match Map.find successors curr_state with
    | None -> record (List.rev rev_path)
    | Some _ when is_final -> record (List.rev rev_path)
    | Some succ ->
      List.iter (List.rev succ) ~f:(fun (obs, next_set) ->
        let rev_att' = match obs with
          | Obs.IO (i, _, _) when H.is_low_input i -> i :: rev_att
          | _ -> rev_att in
        (* Extensions of a path whose attacker inputs disagree with cex's are all discarded: stop early *)
        if compatible (List.rev rev_att') then
          Set.iter next_set ~f:(fun next ->
            if Set.mem on_path next then record (List.rev (obs :: rev_path))
            else visit next (Set.add on_path next) (obs :: rev_path) rev_att'))
  in
  visit m.initial (ILTS.LTSSSet.singleton m.initial) [] [];
  !all

(* Whether two runs execute the same victim code (one is a prefix of the other), according to code *)
let same_code a b = List.is_prefix ~equal:H.Input.equal a ~prefix:b || List.is_prefix ~equal:H.Input.equal b ~prefix:a

let victim_code run = H.victim_code (List.map run ~f:Obs.to_pair)
let victim_code_up_to_secret run = H.victim_code_up_to_secret (List.map run ~f:Obs.to_pair)

let in_victim obs = H.in_victim (Obs.output obs)

(* In a witness graph, the run of the first model is black and dashed, the run of the second one red and dotted *)
let m1_attributes = [`Color 0x000000; `Style `Dashed; `Fontcolor 0x000000;]
let m2_attributes = [`Color 0xA40000; `Style `Dotted; `Fontcolor 0xA40000;]

(*
  Returns the witnesses of the traces of m1 that m2 does not have (m1 ⊆ m2 fails), as pairs (run of m1, run of m2),
  with their number and their graph. See find_all_cex_sym for the symmetric check.
  We avoid recursion here, since we may go too deep.
*)
let find_all_cex ?limit ~to_remove ~tmpdir ~m1_name ~m2_name ~m1 ~m2 () : int * i_lts_t * (Obs.t list * Obs.t list) list =
  let all_witnesses = ref [] in
  let cex_graph = ref ({ initial = 0; states = ILTS.LTSSSet.singleton 0; transition = ILTS.LTSMap.empty } : i_lts_t) in
  let cex_count = ref 0 in
  let finished = ref false in
  let m1r, m2r = ref m1, ref m2 in
  let to_remove_code = List.map to_remove ~f:(fun (r1, r2) -> (victim_code r1, victim_code r2)) in
  while not !finished && (match limit with None -> true | Some limit -> !cex_count < limit) do
    Logs.debug (fun p -> p "===== FINDALL ITERATION START =====");
    (match find_cex_aut ~tmpdir !m1r !m2r with
    | None  ->
        Logs.debug (fun p -> p "[find_all_cex] %s ⊆ %s : true" m1_name m2_name);
        finished := true
    | Some aut_cex ->
        Logs.debug (fun p -> p "[find_all_cex] %s ⊆ %s : false" m1_name m2_name);
        let cand_m1 = all_acyclic_cexs ~attributes:m1_attributes !m1r aut_cex in
        let cand_m2 = all_acyclic_cexs ~attributes:m2_attributes !m2r aut_cex in
        List.iter cand_m1 ~f:(fun curr_m1 ->
          List.iter cand_m2 ~f:(fun curr_m2 ->
          let until_next_um t =
            let hd, tl = List.take_while t ~f:Obs.is_silent, List.drop_while t ~f:Obs.is_silent in
            match tl with
            | x::_ -> hd@[x]
            | [] -> [] in
          (*
            Since some witnesses may be incomplete, we make sure that the last observable is not silent in both witnesses!
          *)
          let rec complete_witness (ls : Obs.t list) (rs : Obs.t list) =
            match ls, rs with
            | [], [] -> None
            | [], _ | _, [] -> Some (until_next_um ls, until_next_um rs)
            | l::ls, r::rs ->
              (let Obs.IO(_, lo, _), Obs.IO(_, ro, _) = l, r in
                if (Obs.is_silent l && Obs.is_silent r) || H.public_equal lo ro then
                  (* Keep them and continue recursively *)
                  match complete_witness ls rs with
                  | Some (ls', rs') -> Some (l::ls', r::rs')
                  | None -> None
                else
                  (
                    match until_next_um (l::ls), until_next_um (r::rs) with
                    | [], _ | _, [] -> None
                    | l', r' -> Some (l', r')
                  )
              )
            in
            if List.is_empty curr_m1 || List.is_empty curr_m2 then
              ()
            else
              (
                match complete_witness curr_m1 curr_m2 with
                | Some (curr_m1, curr_m2) ->
                  (*
                    Since we are looking for the preservation, we need to check: (1) same attacker (2) enclaves originally non-interferent (3) different public outputs.

                    (1) is guaranteed by all_acyclic_cexs: it is a bit too weak and introduces a few false posivites, mitigated by the victim code up to the secret, but be careful!
                    (2) is given by the check that (curr_m1, curr_m2) does not run the same victim code as a witness in to_remove (it includes interfering witnesses from original system)
                    (3) Is guaranteed by complete_witness + condition in_victim in the next if
                  *)
                  let lc1, lc2 = List.last_exn curr_m1, List.last_exn curr_m2 in
                  let c1, c2 = victim_code curr_m1, victim_code curr_m2 in
                  if not (List.exists to_remove_code ~f:(fun (r1, r2) -> same_code c1 r1 && same_code c2 r2)) && same_code (victim_code_up_to_secret curr_m1) (victim_code_up_to_secret curr_m2) && not (in_victim lc1) && not (in_victim lc2) then
                    (
                      cex_graph := update_cex_graph !cex_graph curr_m1 curr_m2;
                      all_witnesses := (curr_m1, curr_m2)::!all_witnesses;
                      incr cex_count
                    )
                  else
                    (
                      Logs.debug (fun m -> m "Found a NI which was already there. Skipping")
                    )
                | None ->
                    Logs.debug (fun m -> m "cleanup_witness found no evidence of difference, except for the example length. Skipping")
              )
          );
        );
        m1r := remove_cex_heur !m1r aut_cex
    );
    Logs.debug (fun p -> p "===== FINDALL ITERATION END =====\n\n");
  done;
  !cex_count, !cex_graph, !all_witnesses


module WitnessSet = Set.Make (struct type t = Obs.t list * Obs.t list [@@deriving ord, sexp] end)

(*
  Noninterference is symmetric: a trace of m2 that m1 does not have distinguishes the two models as much as a trace
  of m1 that m2 does not have, but find_all_cex finds only the latter. This runs find_all_cex in both directions
  and returns the union of the witnesses, always as pairs (run of m1, run of m2) and in the colours of m1 and m2.
  to_remove is given in the same form, and is swapped for the reverse direction.

  Each witness is counted once: find_all_cex can report the same witness in several rounds, and a witness can be
  found in both directions (the edge attributes are not compared). A limit applies to each direction as in
  find_all_cex: the search stops after the round that reaches it, and a round can find several witnesses. The info log gives the numbers of each direction, the debug log every witness and
  the directions that found it.
*)
let find_all_cex_sym ?limit ~to_remove ~tmpdir ~m1_name ~m2_name ~m1 ~m2 () : int * i_lts_t * (Obs.t list * Obs.t list) list =
  let swap = List.map ~f:(fun (w1, w2) -> (w2, w1)) in
  let restyle attributes w = List.map w ~f:(fun (Obs.IO (i, o, _)) -> Obs.make ~attributes i o) in
  let _, _, forward = find_all_cex ?limit ~to_remove ~tmpdir ~m1_name ~m2_name ~m1 ~m2 () in
  let _, _, reverse = find_all_cex ?limit ~to_remove:(swap to_remove) ~tmpdir ~m1_name:m2_name ~m2_name:m1_name ~m1:m2 ~m2:m1 () in
  let reverse = List.map reverse ~f:(fun (w2, w1) -> (restyle m1_attributes w1, restyle m2_attributes w2)) in
  (* find_all_cex returns the most recent witness first: keep the order in which the witnesses were found *)
  let _, rev_union = List.fold (List.rev forward @ List.rev reverse) ~init:(WitnessSet.empty, []) ~f:(fun (seen, acc) w ->
    if Set.mem seen w then (seen, acc) else (Set.add seen w, w :: acc)) in
  let union = List.rev rev_union in
  let distinct ws = Set.length (WitnessSet.of_list ws) in
  Logs.info (fun m -> m "[find_all_cex_sym] %s vs %s: %d witnesses found in the forward direction (%d distinct), %d in the reverse direction (%d distinct), %d distinct in all"
    m1_name m2_name (List.length forward) (distinct forward) (List.length reverse) (distinct reverse) (List.length union));
  let in_forward = WitnessSet.of_list forward and in_reverse = WitnessSet.of_list reverse in
  List.iter union ~f:(fun ((w1, w2) as w) ->
    let found_in = match Set.mem in_forward w, Set.mem in_reverse w with
      | true, true -> "both directions" | true, false -> "forward direction only" | _ -> "reverse direction only" in
    let show run = String.concat ~sep:"; " (List.map run ~f:Obs.human_show) in
    Logs.debug (fun m -> m "[find_all_cex_sym] witness (%s):\n  %s: %s\n  %s: %s" found_in m1_name (show w1) m2_name (show w2)));
  let empty_graph : i_lts_t = { initial = 0; states = ILTS.LTSSSet.singleton 0; transition = ILTS.LTSMap.empty } in
  let graph = List.fold union ~init:empty_graph ~f:(fun g (w1, w2) -> update_cex_graph g w1 w2) in
  List.length union, graph, List.rev union

end
