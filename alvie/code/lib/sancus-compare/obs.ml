open Core
open Sancus

open Common
open Attacker
open Enclave

module InputExt = struct
  type t = INoInput | IInterrupt | IAttacker of Attacker.atom_t | IEnclave of Enclave.atom_t [@@deriving hash,show { with_path = false },eq,ord,sexp]
  let default = INoInput

  let of_input i = match i with
    | Sancus.Input.INoInput -> INoInput
    | Sancus.Input.IAttacker a -> IAttacker a
    | Sancus.Input.IEnclave a -> IEnclave a

  include (val Comparator.make ~compare ~sexp_of_t)
end

module OutputExt = struct
  type payload_t = { k : int; gie : bool; umem_val : word_t; reg_val : word_t; timerA_counter : word_t; mode : Output_internal.mode_t } [@@deriving ord,sexp,hash]
  let equal_payload_t p p' = Bool.equal p.gie p'.gie && p.umem_val = p'.umem_val && p.reg_val = p'.reg_val && p.timerA_counter = p'.timerA_counter && Output_internal.equal_mode_t p.mode p'.mode

  let pp_payload_t fmt p = Format.fprintf fmt "(k = %d, gie = %b, umem_val = %#x, reg_val = %#x, timerA_counter = %d, mode = %s)" p.k p.gie p.umem_val p.reg_val p.timerA_counter (Output_internal.show_mode_t p.mode)
  let show_payload_t p = ignore (Format.flush_str_formatter); pp_payload_t Format.str_formatter p; Format.flush_str_formatter ()

  let prj_payload ({ k; gie; umem_val; reg_val; timerA_counter; mode } : Output_internal.payload_t) =
    { k; gie; umem_val; reg_val; timerA_counter; mode }

  type t =
  | ODiverge
  | OIllegal (* never appears in dumped models *)
  | OUnsupported
  | OJmpIn of payload_t
  | OJmpOut (* This is just a "tag" to state that the instruction is a jmpout, the meta information is carried as a payload by OTime *)
  | OReti of payload_t
  | OHandle of payload_t
  | OException
  | OReset
  | OTime of payload_t
  | OSilent [@@deriving eq,ord,sexp,hash,show { with_path = false }]

  let default = OIllegal

  let of_output o = match o with
  | Sancus.Output_internal.OMaybeDiverge -> ODiverge
  | Sancus.Output_internal.OIllegal -> OIllegal
  | Sancus.Output_internal.OJmpIn p -> OJmpIn (prj_payload p)
  | Sancus.Output_internal.OReti p -> OReti (prj_payload p)
  | Sancus.Output_internal.OReset -> OReset
  | Sancus.Output_internal.OTime p -> OTime (prj_payload p)
  | Sancus.Output_internal.OSilent -> OSilent
  | Sancus.Output_internal.OUnsupported -> OUnsupported
  | (Sancus.Output_internal.OJmpOut _ | Sancus.Output_internal.OJmpOut_Handle (_, _) | Sancus.Output_internal.OTime_Handle (_, _)) -> failwith (sprintf "Compare.OutputExt.of_output: unexpected output: %s" (Output_internal.show_element_t o))

  include (val Comparator.make ~compare ~sexp_of_t)
end

(*
  The Sancus hooks of the comparison engine (see lib/core/compare/hooks.ml). TEMPORARY: M5 replaces them with the
  declarative attacker view of the Sancus plugin files.
*)
module Hooks = struct
  module Input = InputExt
  module Output = OutputExt

  (* The attacker chooses its own actions and when interrupts arrive *)
  let is_low_input = function InputExt.IAttacker _ | InputExt.IInterrupt -> true | _ -> false

  (* The attacker sees the outputs of unprotected mode and the ones that stop or leave the enclave *)
  let is_hidden o =
    let open OutputExt in
    match o with
    | (ODiverge | OIllegal | OException | OReset | OJmpOut) -> false
    | (OJmpIn p | OReti p | OHandle p | OTime p) when Output_internal.equal_mode_t p.mode UM -> false
    | _ -> true

  let is_final o = OutputExt.equal o OReset || OutputExt.equal o ODiverge

  (* Two payloads of protected mode look the same; otherwise the attacker sees everything but the cycle count k *)
  let equal_public_payload_t (p : OutputExt.payload_t)  (p' : OutputExt.payload_t) = let open Sancus.Output_internal in (equal_mode_t p.mode PM && equal_mode_t p'.mode PM) || (Bool.(=) p.gie p'.gie && p.umem_val = p'.umem_val && p.reg_val = p'.reg_val && p.timerA_counter = p'.timerA_counter && equal_mode_t p.mode p'.mode)

  let public_equal e e' =
    let open OutputExt in
    match e, e' with
    | OIllegal, OIllegal | OReset, OReset | OSilent, OSilent | OUnsupported, OUnsupported | OJmpOut, OJmpOut -> true
    | ODiverge, _ | _, ODiverge -> false (* this is always interesting, since something may be wrong *)
    | OReti p, OReti p' | OTime p, OTime p' | OHandle p, OHandle p' -> (equal_public_payload_t p p')
    | _ -> false

  let in_victim (o : OutputExt.t) =
    let open OutputExt in
    let open Sancus.Output_internal in
    match o with | (OReti p | OTime p | OHandle p) -> equal_mode_t p.mode PM | _ -> false

  (* The enclave code of a run: its enclave instructions until the run leaves the enclave (an interrupt, reti or a jump out) *)
  let encl_prefix p = List.take_while p ~f:(function
            | (_, OutputExt.OHandle _) | (_, OutputExt.OReti _)  -> false
            | (_, OutputExt.OJmpOut)  -> false
            | _ -> true)

  let encl_inputs p = List.filter_map p ~f:(function
            | (InputExt.IEnclave _, OutputExt.OHandle _)  -> None
            | (InputExt.IEnclave i, _) -> Some (InputExt.IEnclave i)
            | _ -> None)

  let victim_code run = encl_inputs (encl_prefix run)

  (* FIXME: this is a bit ad-hoc but we easily reimplement if we keep track of S_SECRET in the inputs *)
  let victim_code_up_to_secret run =
    let rm_secret t = List.filter_map t ~f:(fun io -> match io with
    | (InputExt.IEnclave (CInst (I_CMP (S_IMM _, D_R (R 4)))), _)  -> None
    | (InputExt.IEnclave _, _)  -> Some io
    | _ -> None) in
    victim_code (rm_secret run)

  let human_show (i : InputExt.t) (o : OutputExt.t) =
    let open Attacker in
    let open Enclave in
    let rec human_att_atom (a : Attacker.atom_t) = (match a with
      | CRst -> "rst"
      | CRstNZ -> "rst_nz"
      | CJmpIn s -> "jin " ^ s
      | CCreateEncl _ -> "create"
      | CTimerEnable t -> sprintf "timer_enable %d" t
      | CStartCounting t -> sprintf "start_counting %d" t
      | CReti -> "reti"
      | CIfZ (l, r) -> sprintf "ifz [%s], [%s]"
        (List.fold l ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_att_atom i)))
        (List.fold r ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_att_atom i)))
      | CInst i -> Common.show_instruction_t i) in
    let rec human_encl_atom (a : Enclave.atom_t) = (match a with
      | CUbr -> "ubr"
      | CRst -> "rst"
      | CIfZ (l, r) -> sprintf "ifz [%s], [%s]"
        (List.fold l ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_encl_atom i)))
        (List.fold r ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (human_encl_atom i)))
      | CBalancedIfZ il ->
        sprintf "balanced_ifz [%s]"
          (List.fold il ~init:"" ~f:(fun acc i -> sprintf "%s %s;" acc (Common.show_instruction_t i)))
      | CInst i -> Common.show_instruction_t i) in
    let human_input i =
      let open InputExt in
        (match i with
        | INoInput -> "ε"
        | IInterrupt -> "IRQ"
        (* | IJmpOut -> "jmpout" *)
        | IAttacker a -> human_att_atom a
        | IEnclave a -> human_encl_atom a) in
    let human_output o =
      let open OutputExt in
        (match o with
        | OIllegal -> failwith "Never happens"
        | OUnsupported -> sprintf "Unsupported"
        | OJmpIn p -> sprintf "JmpIn %s" (show_payload_t p)
        | OJmpOut -> sprintf "JmpOut"
        | OReti p -> sprintf "Reti %s" (show_payload_t p)
        | OHandle p -> sprintf "HandleIRQ %s" (show_payload_t p)
        | OException -> "Exception"
        | OReset -> "Reset"
        | OTime p -> sprintf "Time %s" (show_payload_t p)
        | ODiverge -> "⇑"
        | OSilent -> "τ") in
    sprintf "%s/%s" (human_input i) (human_output o)

end

(* The observations of the compared models: they label the transitions of model and witness graphs *)
module Obs = Ltscompare.Obs.Make (Hooks)
