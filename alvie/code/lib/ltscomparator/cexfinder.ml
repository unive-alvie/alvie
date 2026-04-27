open Learninglib
open Lts

open Shexp_process
open Core
open Obs

module IIOMealy = Learninglib.Mealy.Mealy (Showableint.ShowableInt) (InputExt) (OutputExt)

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
              let alt_states = Map.fold (Map.filter_keys acc_lts.transition ~f:(fun (s, o) -> s = el && (match o, obs with | IO (i, _, _), IO (i', _, _) -> InputExt.equal i i'))) ~init:ILTS.LTSSSet.empty ~f:(fun ~key:_ ~data alt_acc -> Set.union alt_acc data) in
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

let all_acyclic_cexs ~attributes (m : i_lts_t) (cex : Obs.t list): Obs.t list list =
  let att_inputs p = List.filter_map p ~f:(function Obs.IO (InputExt.IAttacker i, _, _) -> Some (InputExt.IAttacker i) | Obs.IO (InputExt.IInterrupt, _, _) -> Some (InputExt.IInterrupt) | _ -> None) in
  let same_att_inputs ol ol' = not (List.is_empty ol) && not (List.is_empty ol') && List.is_prefix ~equal:InputExt.equal (att_inputs ol) ~prefix:(att_inputs ol') || List.is_prefix ~equal:InputExt.equal (att_inputs ol') ~prefix:(att_inputs ol) in
  let q = Queue.create () in
  let visited = ref ILTS.LTSSSet.empty in
  let all : Obs.t list list ref = ref [] in
  Queue.enqueue q (m.initial, []);

  while not (Queue.is_empty q) do
    let curr_state, curr_path = Queue.dequeue_exn q in
    let is_final = match List.last curr_path with
      | Some Obs.IO(_, o, _) -> OutputExt.equal o OReset || OutputExt.equal o ODiverge
      | _ -> false
    in
    if is_final || Set.mem !visited curr_state || not (Map.existsi m.transition ~f:(fun ~key:(cand_curr, _) ~data:_ -> cand_curr = curr_state)) then
      (
        (* Logs.debug (fun p -> p "[all_acyclic_cexs] curr_path:");
        List.iter curr_path ~f:(fun o -> Logs.debug (fun p -> p "\t\t%s" (Obs.human_show o))); *)
        if
          same_att_inputs curr_path cex
        then
          all := curr_path :: !all
        else
          ()
      )
    else
      (
        visited := Set.add !visited curr_state;
        Map.iteri m.transition ~f:(fun ~key:(cand_curr, obs) ~data:cand_next ->
          let IO (i, o, _) = obs in
          let obs = Obs.make ~attributes i o in
          if cand_curr = curr_state then
            Queue.enqueue_all q (List.map ~f:(fun next -> (next, curr_path @ [obs])) (Set.to_list cand_next))
          else
            ()
        )
      )
  done;
  !all

let encl_prefix p = List.take_while p ~f:(function
          | Obs.IO (_, OutputExt.OHandle _, _) | Obs.IO (_, OutputExt.OReti _, _)  -> false
          | Obs.IO (_, OutputExt.OJmpOut, _)  -> false
          | _ -> true)

let encl_inputs p = List.filter_map p ~f:(function
          | Obs.IO (InputExt.IEnclave _, OutputExt.OHandle _, _)  -> None
          | Obs.IO (InputExt.IEnclave i, _, _) -> Some (InputExt.IEnclave i)
          | _ -> None)

let share_code_encl w w' = List.is_prefix ~equal:InputExt.equal (encl_inputs (encl_prefix w)) ~prefix:(encl_inputs (encl_prefix w')) || List.is_prefix ~equal:InputExt.equal (encl_inputs (encl_prefix w')) ~prefix:(encl_inputs (encl_prefix w))

let equal_public_payload_t (p : OutputExt.payload_t)  (p' : OutputExt.payload_t) = let open Sancus.Output_internal in (equal_mode_t p.mode PM && equal_mode_t p.mode PM) || (Bool.(=) p.gie p'.gie && p.umem_val = p'.umem_val && p.reg_val = p'.reg_val && p.timerA_counter = p'.timerA_counter && equal_mode_t p.mode p'.mode)

(* FIXME: this is a bit ad-hoc but we easily reimplement if we keep track of S_SECRET in the inputs *)
let share_code_encl_up_to_secret w w' =
  let rm_secret t = List.filter_map t ~f:(fun io -> match io with
  | Obs.IO (InputExt.IEnclave (CInst (I_CMP (S_IMM _, D_R (R 4)))), _, _)  -> None
  | Obs.IO (InputExt.IEnclave _, _, _)  -> Some io
  | _ -> None) in
  share_code_encl (rm_secret w) (rm_secret w')

let outputext_public_equal e e' =
  let open OutputExt in
  match e, e' with
  | OIllegal, OIllegal | OReset, OReset | OSilent, OSilent | OUnsupported, OUnsupported | OJmpOut, OJmpOut -> true
  | ODiverge, _ | _, ODiverge -> false (* this is always interesting, since something may be wrong *)
  | OReti p, OReti p' | OTime p, OTime p' | OHandle p, OHandle p' -> (equal_public_payload_t p p')
  | _ -> false

let is_PM io =
  let open OutputExt in
  let open Sancus.Output_internal in
  match io with | Obs.IO (_, (OReti p | OTime p | OHandle p), _) -> equal_mode_t p.mode PM | _ -> false



(* We avoid recursion here, since we may go too deep *)
let find_all_cex ?limit ~to_remove ~tmpdir ~m1_name ~m2_name ~m1 ~m2 () : int * i_lts_t * (Obs.t list * Obs.t list) list =
  let all_witnesses = ref [] in
  let cex_graph = ref ({ initial = 0; states = ILTS.LTSSSet.singleton 0; transition = ILTS.LTSMap.empty } : i_lts_t) in
  let cex_count = ref 0 in
  let finished = ref false in
  let m1r, m2r = ref m1, ref m2 in
  while not !finished && (match limit with None -> true | Some limit -> !cex_count < limit) do
    Logs.debug (fun p -> p "===== FINDALL ITERATION START =====");
    (match find_cex_aut ~tmpdir !m1r !m2r with
    | None  ->
        Logs.debug (fun p -> p "[find_all_cex] %s ⊆ %s : true" m1_name m2_name);
        finished := true
    | Some aut_cex ->
        Logs.debug (fun p -> p "[find_all_cex] %s ⊆ %s : false" m1_name m2_name);
        let cand_m1 = all_acyclic_cexs ~attributes:[`Color 0x000000; `Style `Dashed; `Fontcolor 0x000000;] !m1r aut_cex in
        let cand_m2 = all_acyclic_cexs ~attributes:[`Color 0xA40000; `Style `Dotted; `Fontcolor 0xA40000;] !m2r aut_cex in
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
              (let  IO(_, lo, _), IO(_, ro, _) = l, r in
                if (Obs.is_silent l && Obs.is_silent r) || outputext_public_equal lo ro then
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

                    (1) is guaranteed by all_acyclic_cexs: it is a bit too weak and introduces a few false posivites, mitigated by share_code_encl_up_to_secret, but be careful!
                    (2) is given by the checkCheck that (curr_m1, curr_m2) is not in to_remove (it includes interfering witnesses from original system) implies (2)
                    (3) Is guaranteed by complete_witness + condition is_PM in the next if
                  *)
                  let lc1, lc2 = List.last_exn curr_m1, List.last_exn curr_m2 in
                  if not (List.mem to_remove (curr_m1, curr_m2) ~equal:(fun (r1, r2) (c1, c2) -> share_code_encl r1 c1 && share_code_encl r2 c2)) && share_code_encl_up_to_secret curr_m1 curr_m2 && not (is_PM lc1) && not (is_PM lc2) then
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
