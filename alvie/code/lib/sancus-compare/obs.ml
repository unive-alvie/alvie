open Graph
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

module Obs : sig
  module EdgeAttributes : sig type t = Graphviz.DotAttributes.edge list end
  type edge_attributes_t = EdgeAttributes.t

  type t = IO of InputExt.t * OutputExt.t * edge_attributes_t [@@deriving sexp,ord,eq]
  val default : t
  val make : ?attributes:edge_attributes_t -> InputExt.t -> OutputExt.t -> t
  val is_silent : t -> bool
  val edge_attributes : t -> Graphviz.DotAttributes.edge list

  val show : t -> string
  val pp : Format.formatter -> t -> unit
  val parse : string -> t
  val human_show : t -> string
end =
struct
  module EdgeAttributes = struct
    type t = Graphviz.DotAttributes.edge list

    let sexp_of_t (_ : t) = Sexp.unit
    let t_of_sexp (_ : Sexp.t) = []

    let compare _ _ = 0
    let equal _ _ = true
  end
  type edge_attributes_t = EdgeAttributes.t

  type t = IO of InputExt.t * OutputExt.t * EdgeAttributes.t [@@deriving sexp,ord,eq]
  let default = IO (InputExt.default, OutputExt.default, [])
  let make ?(attributes = []) i o = IO (i, o, attributes)

  let to_mcrl2_name (s : string) =
    let replacements = [('(', "["); (')', "]")] in
    let cnl = List.map (String.to_list s) ~f:(fun c ->
      match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
      | None -> String.of_char c | Some (_, e) -> e) in
    (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl)

  let of_mcrl2_name (s : string) =
    let replacements = [('[', "("); (']', ")")] in
    let cnl = List.map (String.to_list s) ~f:(fun c ->
      match List.find replacements ~f:(fun (s, _) -> Char.equal s c) with
      | None -> String.of_char c | Some (_, e) -> e) in
    (List.fold ~init:"" ~f:(fun str s -> str ^ s) cnl)

  let show io = to_mcrl2_name (Sexp.to_string_mach (sexp_of_t io))
  let pp fmt io = Format.fprintf fmt "%s" (show io)
  let parse s = Sexp.of_string_conv_exn (of_mcrl2_name s) t_of_sexp

  let is_silent io =
    match io with
    | IO (_, (ODiverge | OIllegal | OException | OReset | OJmpOut), _) -> false
    | IO (_, (OJmpIn p | OReti p | OHandle p | OTime p), _) when Output_internal.equal_mode_t p.mode UM -> false
    | _ -> true

  let human_show (IO(i, o, _)) =
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

  let edge_attributes obs =
    let (IO(_, _, attr)) = obs in (`Label (human_show obs))::attr
end
