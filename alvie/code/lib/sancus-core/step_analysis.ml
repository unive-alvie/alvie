(*
  From the instructions of a step to its observations: the part of the analysis that does not depend on the target
  that ran the step (Simulator.target).

  A target finds the instructions of the step's input in its trace (the simulator in the VCD dump, the FPGA in the
  trace it sends back over the serial port) and gives, for each one, the signals below; or a reset, when the trace
  ends before the next instruction. This module turns each instruction into an observation, packs observations of
  the same kind, composes the ones of an interrupt and drops the silent ones, as analyse_dump always did.
*)
open! Core

type label = string * string [@@deriving sexp, ord]

(* The signals of one instruction *)
type instruction = {
  mode_s : Output_internal.mode_t; (* the CPU mode at the start of the instruction *)
  mode_e : Output_internal.mode_t; (* the CPU mode at the start of the next one *)
  e_states : int list; (* the values of Sancus's e_state during the instruction, in order, without repetitions *)
  gie : bool;
  r4 : int;
  umem : int; (* the word of unprotected memory that the observations show *)
  timerA : int;
  k : int; (* clock cycles *)
}

(* What a target found in its trace *)
type found =
  | Nothing of { diverges : bool } (* no instruction of the input ran *)
  | Instructions of {
      last_inst_number : int; (* the number of the last instruction analysed *)
      left_labels : label list; (* the labels whose code did not run *)
      instructions : [ `Instruction of instruction | `Reset ] list;
    }

(*
  e_state:
    0x00 - 0x0F -> non-SM
    0x10        -> SM_IRQ_REGS
    0x11        -> SM_IRQ_WAIT
    0x12        -> SM_RETI_REGS
    0x13        -> SM_IRQ_PAD
    0x14        -> SM_RETI_PAD
*)
let classify_e_states e_states =
  if List.for_all e_states ~f:(fun e_state -> e_state <= 0x0F) then `NO_SM
  else
    let rec classify = function
      | [] -> `OTHER
      | 0x12 :: 0x14 :: _ | 0x12 :: _ -> `RETI
      | 0x10 :: 0x13 :: 0x11 :: _ | 0x10 :: 0x11 :: _ -> `HANDLE
      | _ :: rest -> classify rest in
    classify e_states

let output_of_instruction (i : instruction) : [ `Out of Output_internal.element_t | `OHandle of Output_internal.payload_t ] =
  let payload : Output_internal.payload_t = {
    k = i.k;
    gie = i.gie;
    reg_val = i.r4 % 8; (* We limit the register to 3 bits to avoid useless looping *)
    umem_val = i.umem;
    timerA_counter = i.timerA;
    mode = i.mode_e;
  } in
  match i.mode_s, i.mode_e, classify_e_states i.e_states with
  | PM, PM, `NO_SM -> `Out (Output_internal.OTime payload)
  | UM, PM, `NO_SM -> `Out (Output_internal.OJmpIn payload)
  | UM, _, `RETI -> `Out (Output_internal.OReti payload) (* ! FIXME: this is actually a RETI? *)
  | PM, UM, `NO_SM -> `Out (Output_internal.OJmpOut payload)
  | _, UM, `HANDLE -> `OHandle payload
  | UM, UM, _ -> `Out (Output_internal.OTime payload)
  | PM, UM, `OTHER -> failwith "output_of_signals: found `PM, `UM, `OTHER. It may be a bug!"
  | UM, PM, `OTHER -> failwith "output_of_signals: found `UM, `PM, `OTHER. It may be a bug!"
  | PM, PM, `OTHER -> failwith "output_of_signals: found `PM, `PM, `OTHER. It may be a bug!"
  | PM, PM, `HANDLE -> failwith "output_of_signals: found `PM, `PM, `HANDLE. It may be a bug!"
  | UM, PM, `HANDLE -> failwith "output_of_signals: found `UM, `PM, `HANDLE. It may be a bug!"
  | PM, UM, `RETI -> failwith "output_of_signals: found `PM, `UM, `RETI. It may be a bug!"
  | PM, PM, `RETI -> failwith "output_of_signals: found `PM, `PM, `RETI. It may be a bug!"

(* The observations of a step, with its bookkeeping: the number of the last instruction analysed and the labels
   still to analyse. last_inst_number is the one before the step. *)
let observations ~last_inst_number (found : found) : int * label list * Output_internal.element_t list =
  match found with
  (* After a divergence, only the inputs of the loop can run: an input whose code did not run was illegal *)
  | Nothing { diverges = true } -> last_inst_number, [], [ Output_internal.OMaybeDiverge ]
  | Nothing { diverges = false } ->
    Logs.debug (fun p -> p "FIXME: Could not find the instruction in the trace, please check your specification. The cause is usually an unsupported action, e.g., a jump from an enclave to another, an interrupt in unprotected mode, ... --- Returning Unsupported");
    last_inst_number, [], [ Output_internal.OUnsupported ]
  | Instructions { last_inst_number = last_inst_number'; left_labels = left_labels'; instructions } ->
    let res = List.map instructions ~f:(function
      | `Reset -> `Out Output_internal.OReset
      | `Instruction i -> output_of_instruction i) in
    (*
      For each pair of labels we have an output.
        - If a Reset or a Exception is in the list, just return such element
        - Otherwise:
          + If the list has length 1, it means that the original action was a single instruction (CInst, CReti for attackers or any instruction for enclaves), and we just need to extract this single element;
          + If the length is >1 then the original action was something different (CJmpIn, CCreateEnclave, CTimerEnable):
              * CJmpIn: we expect the sequence to be OSilent ... OSilent OJmpIn: just return OJmpIn
              * CTimerEnable/CCreateEnclave: this will be a sequence OSilent ... OSilent : return OSilent
              * CJmpOut: we sum the timings of the instructions composing it into k and return CJmpOut k
          Overall: we can always return the last observable of the res list (if any)
    *)
    let int_o_equal o o' = match o, o' with `OHandle k, `OHandle k' -> Output_internal.equal_payload_t k k' | `Out o, `Out o' -> Output_internal.equal_element_t o o' | _ -> false in
    let int_o_show o = match o with `OHandle k -> sprintf "`OHandle %s" (Output_internal.show_payload_t k) | `Out o -> sprintf "`Out %s" (Output_internal.show_element_t o) in
    if List.mem res (`Out Output_internal.OReset) ~equal:int_o_equal then
      last_inst_number, [], [ Output_internal.OReset ]
    else (
      (* res is a list of observables, ideally one for each instruction. We now "pack together" observables of the
         same kind, updating their field *)
      Logs.debug (fun p -> p "Step_analysis: complete out: %s" (List.to_string ~f:int_o_show res));
      let merge_int_obs o o' =
        let open Output_internal in
        match o, o' with
        | `Out (OJmpOut k), `Out (OJmpOut k') -> Some (`Out (OJmpOut (merge_payload ~older:k ~newer:k')))
        | `Out (OReti k), `Out (OReti k') -> Some (`Out (OReti (merge_payload ~older:k ~newer:k')))
        | `OHandle k, `OHandle k' -> Some (`OHandle (merge_payload ~older:k ~newer:k'))
        | `Out (OTime k), `Out (OTime k') -> Some (`Out (OTime (merge_payload ~older:k ~newer:k')))
        | `Out OSilent, `Out OSilent -> Some (`Out OSilent)
        | _, _ -> None in
      let last, packed_no_last = List.foldi (List.drop res 1) ~init:(List.hd_exn res, [])
          ~f:(fun idx (curr_kind, acc_packed) o ->
            if List.length res = idx + 1 then (o, acc_packed @ [ curr_kind ])
            else
              match merge_int_obs curr_kind o with
              | Some kind -> (kind, acc_packed)
              | None -> (o, acc_packed @ [ curr_kind ])) in
      let packed = packed_no_last @ [ last ] in
      Logs.debug (fun p -> p "Step_analysis: packed out: %s" (List.to_string ~f:int_o_show packed));
      let composed =
        let open Output_internal in
        List.foldi packed ~init:[] ~f:(fun i acc_composite curr ->
          let prev, next = List.nth packed (i - 1), List.nth packed (i + 1) in
          match prev, curr, next with
          | _, `Out (OJmpOut k), Some (`OHandle h) -> acc_composite @ [ OJmpOut_Handle (k, h) ]
          | _, `Out (OTime k), Some (`OHandle h) -> acc_composite @ [ OTime_Handle (k, h) ]
          | Some (`Out (OJmpOut _)), `OHandle _, _ | Some (`Out (OTime _)), `OHandle _, _ -> acc_composite
          | _, `Out ao, _ -> acc_composite @ [ ao ]
          (* A Handle right after a reti: we are in PM, so it is an OTime_Handle with 0 cycles in PM *)
          | _, `OHandle p, _ -> acc_composite @ [ OTime_Handle ({ p with k = 0; mode = PM }, p) ]) in
      let no_silent = List.drop_while (List.drop_last_exn composed) ~f:(Output_internal.equal_element_t OSilent) @ [ List.last_exn composed ] in
      (* The labels that were expected but were not found in the execution: they are kept only while handling an
         interrupt (i.e., during a Handle, and after it until a Reti) *)
      match List.last_exn no_silent with
      | OJmpOut_Handle _ | OTime_Handle _ | OSilent -> last_inst_number', left_labels', no_silent
      | _ -> last_inst_number', [], no_silent)
