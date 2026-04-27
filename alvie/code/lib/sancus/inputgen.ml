open! Core

open Testdl
open Input

open Attacker
open Enclave

type observable_t = In of Input.t | Out of Output_internal.t [@@deriving show]

type spec_dfa = {
  interrupted : enclave_t;
  spec : test_spec_t;
  current : test_spec_t;
  (* The following are used to track the evolution of the DFA *)
  mode : [`ISR_toPM | `ISR_toUM | `Prepare | `Cleanup | `Enclave | `Invalid | `Finished];
} [@@deriving ord,sexp]

let mode_show = [%derive.show: [ `Cleanup | `Enclave | `ISR_toPM | `ISR_toUM | `Invalid | `Prepare | `Finished ]]
let list_observable_t_show = [%derive.show: observable_t list]
let get_enclave_spec (a, _, _, _) = a
let upd_enclave_spec (_, b, c, d) a = (a, b, c, d)

let rec intersperse_lists il ol =
  match il, ol with
  | [], [] -> []
  | i::il, [] -> List.map (i::il) ~f:(fun i -> In i)
  | [], o::ol -> List.map (o::ol) ~f:(fun o -> Out o)
  | i::il, o::ol -> (In i)::(Out o)::(intersperse_lists il ol)

(*
  Ideally, this function builds the a DFA for the given attack specification.
  Four DFAs are built, one for each section (isr, prepare, cleanup) and one for the victim (just one "self-looping" state) and link them together observing that some actions (Outputs) cause the switch from a DFA to another (inspired by alpha traces in Busi et al./TOPLAS'21 paper):
    - prep -> victim: jin (jmpin)
    - victim -> isr: interrupt observed (handle)
    - isr_toPM -> victim: reti observed (reti)
    - isr_toUM -> cleanup: reti observed (reti) after a jmp out
    - victim -> cleanup: (jmpout)

  The keep things simpler, we do not build DFAs but use Brzozowski derivatives and use the spec directly.
*)
let build_spec_dfa (spec : test_spec_t) =
  {
    spec = spec;
    current = spec;
    mode = `Prepare;
    interrupted = get_enclave_spec spec
  }

let transition_nomemo (sd, o : spec_dfa * observable_t) : spec_dfa =
  let (Enclave enclave_curr, ISR isr_curr, Prepare prepare_curr, Cleanup cleanup_curr) = sd.current in
  let rst who ~curr:(Enclave ce, ISR ci, Prepare cp, Cleanup cc) ~orig:(Enclave oe, ISR oi, Prepare op, Cleanup oc) =
    match who with
    | `Enclave -> (Enclave oe, ISR ci, Prepare cp, Cleanup cc)
    | `ISR -> (Enclave ce, ISR oi, Prepare cp, Cleanup cc)
    | `Prepare -> (Enclave ce, ISR ci, Prepare op, Cleanup cc)
    | `Cleanup -> (Enclave ce, ISR ci, Prepare cp, Cleanup oc) in
  let ol_transition sd ((ol, _, _) : Output_internal.t) =
    List.fold ol ~init:sd ~f:(fun acc_sd o ->
      match acc_sd.mode, o with
      | `Finished, _ | _, OMaybeDiverge -> { sd with mode = `Finished }
      | `Invalid, _ | _, OIllegal | _, OUnsupported -> {sd with mode = `Invalid}
      | _, (OTime _ | OSilent) -> acc_sd
      | `Enclave, (OReset | OJmpOut _) -> { acc_sd with current = acc_sd.spec; mode = `Cleanup; }
      | (`Cleanup|`Prepare| `ISR_toPM | `ISR_toUM), OReset -> {acc_sd with current = acc_sd.spec; mode = `Prepare; }
      | _, OJmpIn _ -> {acc_sd with current = rst `Enclave ~curr:acc_sd.current ~orig:acc_sd.spec; mode = `Enclave}
      | _, OJmpOut _ -> { acc_sd with current = rst `Cleanup ~curr:acc_sd.current ~orig:acc_sd.spec; mode = `Cleanup; }
      (* | `ISR_toPM, OReti _ -> {acc_sd with mode = `Enclave }
      | `ISR_toUM, OReti _ -> {acc_sd with mode = `Cleanup } post-poned jump-out: a RETI that returns to UM! *)
      | _, OJmpOut_Handle _ -> {acc_sd with interrupted = get_enclave_spec acc_sd.current; current = rst `ISR ~curr:acc_sd.current ~orig:acc_sd.spec; mode = `ISR_toUM }
      | _, OTime_Handle _ -> {acc_sd with interrupted = get_enclave_spec acc_sd.current; current = rst `ISR ~curr:acc_sd.current ~orig:acc_sd.spec; mode = `ISR_toPM }
      | _, OReti p ->
        if (Output_internal.equal_mode_t p.mode PM) then {acc_sd with current = upd_enclave_spec acc_sd.current acc_sd.interrupted; mode = `Enclave }
        else {acc_sd with current = upd_enclave_spec acc_sd.current acc_sd.interrupted; mode = `Cleanup } (* post-poned jump-out: a RETI that returns to UM! *)
  ) in
  match sd.mode, o with
    | (`Finished | `Invalid), _ -> sd
    | _, Out ol -> ol_transition sd ol
    (* Input: Prepare *)
    | `Prepare, In (IAttacker ca) ->
        { sd with
            current = (Enclave enclave_curr, ISR isr_curr, Prepare (Attacker.derive prepare_curr ca), Cleanup cleanup_curr) }
    | `Prepare, _ ->
        {sd with mode = `Invalid}
    (* Input: Enclave *)
    | `Enclave, In (IEnclave ca) ->
      { sd with
          current = (Enclave (Enclave.derive enclave_curr ca), ISR isr_curr, Prepare prepare_curr, Cleanup cleanup_curr) }
    | `Enclave, _ ->
        {sd with mode = `Invalid}
    (* Input: ISR_toPM *)
    | `ISR_toPM, In (IAttacker ca) ->
        { sd with current = (Enclave enclave_curr, ISR (Attacker.derive isr_curr ca), Prepare prepare_curr, Cleanup cleanup_curr) }
    | `ISR_toPM, _ ->
        {sd with mode = `Invalid}
    (*  Input: ISR_JmpOut *)
    | `ISR_toUM, In (IAttacker ca) ->
        { sd with current = (Enclave enclave_curr, ISR (Attacker.derive isr_curr ca), Prepare prepare_curr, Cleanup cleanup_curr) }
    | `ISR_toUM, _ ->
        {sd with mode = `Invalid}
    (*  Input: Cleanup *)
    | `Cleanup, In (IAttacker ca) ->
        { sd with current = (Enclave enclave_curr, ISR isr_curr, Prepare prepare_curr, Cleanup (Attacker.derive cleanup_curr ca)) }
    | `Cleanup, _ ->
      {sd with mode = `Invalid}

let transition sd o = (Memo.general transition_nomemo) (sd, o)

(* This is based on two facts:
  1. forall (b : body_t) (a : ca_atom_t list), (forall w, not (b ~ aw)) <=> E(lderive b a):
    - (definition of ~) forall w, aw not in language(b)
    - { w | aw in language(r) } = emptyset
    - (def of derivative) language (lderive b a) = emptyset
    - (2.) E(lderive b a)
  2. forall b, E(b) <=> language(b) = emptyset (by induction)

  Thus, suppose we have a string w and we want to append a to it.
  If we want to check that wa is a prefix of an acceptable string (i.e., if exists w' s.t. waw' is accepted by some b) we can take b' = lderive b w (implemented below by List.fold over obsl), then we can compute is_empty (derive b' a) and use 1. to check whether wa is the prefix of some acceptable string.

  Given a spec, a sequence of inputs and corresponding outputs, we randomly generate a new input among those allowed by the spec.
*)
let get_options
  ?(force_encl : [ `Next of t | `Stop ] option)
  (spec : spec_dfa)
  (il : Input.t list)
  (ol : Output_internal.t list) : spec_dfa * [`Stop | `Next of Input.t] list =
  (* CRUCIAL: here we assume that il and ol are valid prefixes, i.e., that matchable spec il ol returns true! *)
  (* il and ol should have the same length here since we are here required to generate an Input! *)
  assert (List.length il = List.length ol);
  let full_history = intersperse_lists il ol in
  let curr_spec_dfa = List.fold full_history ~init:spec ~f:transition in
  let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = curr_spec_dfa.current in
  (* This is for any attacker sections, except for ISR *)
  let attack_next b =
    let options = Set.filter
      (Attacker.get_atoms b)
      ~f:(fun ca -> not (Attacker.is_empty (Attacker.derive b ca))) in
    let options = List.map ~f:(fun i -> `Next (IAttacker i)) (Set.to_list options) in
      options in
  (* ISR section can be re-executed, so it's special *)
  let isr_next b =
    (* We assume to be in ISR_* mode *)
    (* We look through the history if it exists a "complete" ISR run, i.e., one going from Handle back to PM (via Reti or JmpIn) *)
    let open Output_internal in
    let is_handle (l, _, _) = List.exists l ~f:(fun o -> match o with OJmpOut_Handle _ | OTime_Handle _ -> true | _ -> false) in
    let is_reti (l, _, _) = List.exists l ~f:(fun o -> match o with OReti _ | OJmpIn _ -> true | _ -> false) in
    let full_isr = List.drop_while full_history ~f:(fun io -> match io with Out l -> not (is_handle l) | _ -> true) in
    let full_isr = List.fold_until (List.drop full_isr 1) ~init:[] ~f:(fun acc io -> match io with Out l when is_reti l -> Stop (acc @ [io]) | _ -> Continue (acc @ [io])) ~finish:(fun a -> a) in
    (* full_isr now is of the form OHandle* OTime ... OTime ... o with o either a [... OReti] or [... OSilent]; *)
    match List.last full_isr with
    | Some (Out l) when is_reti l ->
      (* We found a previously-completed ISR, we need to follow it! *)
      (* For that, see what we already did *)
      let since_last_handle = List.take_while (List.rev full_history) ~f:(fun io -> match io with Out l -> not (is_handle l) | _ -> true) in
      (* Drop it, and return the first of the remaining ISR actions *)
      let remaning = List.drop full_isr (List.length since_last_handle) in
        (match List.hd remaning with
        | Some (In i) -> [`Next i]
        | _ -> failwith "Inputgen.matchable.isr_acceptable: should never happen!")
    | _ ->
      (* Otherwise, no previously-completed ISR, we can use attacker_next *)
      Logs.debug (fun m -> m "Found no previous complete ISR!");
      attack_next b in
  (* Enclave sections can be re-executed too, so deal with them similarly to ISR: *)
  let enclave_next b =
    let _enclave_next b =
      let options = Set.filter
        (Enclave.get_atoms b)
        ~f:(fun ca -> not (Enclave.is_empty (Enclave.derive b ca))) in
      let options = List.map ~f:(fun i -> `Next (IEnclave i)) (Set.to_list options) in
        options in
    (* We assume to be in Enclave mode here *)
    (* We look through the history if it exists a previous enclave run starting with a JmpIn *)
    let open Output_internal in
    let is_jmpin (l, _, _) = List.exists l ~f:(fun o -> match o with OJmpIn _ -> true | _ -> false) in
    let curr_enclave, prev_enclave = List.fold_until (List.rev full_history) ~init:([], [], true) ~f:(fun (acc_curr, acc_prev, is_curr) io ->
      match io with
      | Out l when is_jmpin l -> if is_curr then Continue (io::acc_curr, acc_prev, false) else Stop (acc_curr, io::acc_prev)
      | _ -> if is_curr then Continue (io::acc_curr, acc_prev, true) else Continue (acc_curr, io::acc_prev, false)
    ) ~finish:(fun (acc_curr, acc_prev, _) -> (acc_curr, acc_prev)) in
    match List.hd prev_enclave with
    | Some (Out l) when is_jmpin l ->
      (* In this case, we have a previous JmpIn, we must consume all those that we've already seen and compare the first one of the remainder with the current one. Note that outputs may differ, but they are the same in number! *)
      let prev_enclave_input = List.filter prev_enclave ~f:(fun io -> match io with In (IEnclave _) -> true | _ -> false) in
      let curr_enclave_input = List.filter curr_enclave ~f:(fun io -> match io with In (IEnclave _) -> true | _ -> false) in
      let remaning = List.drop prev_enclave_input (List.length curr_enclave_input) in
      (* Logs.debug (fun p -> p "remaining: %s" (list_observable_t_show remaning)); *)
      (* If there are remaining enclave actions that still need to be consumed, return the first of these; Otherwise fallback to classical _enclave_next *)
      (match List.hd remaning with
      | Some (In i) -> [`Next i]
      | None -> _enclave_next b
      | Some hd -> failwith (sprintf "Inputgen.matchable.enclave_acceptable: should never happen Some (%s)!" (show_observable_t hd)))
    | _ ->
      (* This is the first time executing an enclave (no previous JmpIn), generate it from scratch *)
      _enclave_next b
  in
  (*
     Depending on the current mode we can choose to:
  *)
  match curr_spec_dfa.mode with
    | `Finished -> curr_spec_dfa, []
    | `Invalid -> curr_spec_dfa, [`Stop]
    (* ... return the list of Enclave inputs (singleton if forcing) *)
    | `Enclave -> (match force_encl with None -> curr_spec_dfa, enclave_next enclave | Some v -> curr_spec_dfa, [v])
    (* ... return the available Inputs for the current attacker mode according to spec *)
    | `Prepare -> curr_spec_dfa, attack_next prepare
    | `ISR_toPM | `ISR_toUM -> curr_spec_dfa, isr_next isr
    | `Cleanup -> curr_spec_dfa, attack_next cleanup

let generate_next
  ?(choose=(fun _ _ options -> if List.length options = 0 then `Stop else List.random_element_exn options))
  ?(force_encl : [ `Next of t | `Stop ] option)
  (spec : spec_dfa)
  (il : Input.t list)
  (ol : Output_internal.t list) : [`Stop | `Next of Input.t] =
    choose il ol (snd (get_options ?force_encl spec il ol))

(* A sequence of alternating I/O observables is said to be *matchable* with a spec if there exists a way to extend the I/O sequence in such a way that the resulting extended sequence is accepted by the spec.  *)
let matchable (spec : spec_dfa) (next : Input.t) (il : Input.t list) (ol : Output_internal.t list) : spec_dfa * bool =
  let spec, options = get_options spec il ol in
    Logs.debug (fun m -> m "Available options: %s" ([%derive.show: [ `Next of t | `Stop ] list] options));
    spec, List.mem options (`Next next) ~equal:Poly.equal
