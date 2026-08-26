open! Core
open Common

module Attacker : sig
  type ti_t = word_t [@@deriving hash,eq,ord,sexp,show { with_path = false }]

  type atom_t =
    | CRst
    | CRstNZ
    | CJmpIn of string
    | CCreateEncl of enclave_layout_t
    | CTimerEnable of ti_t
    | CStartCounting of ti_t
    | CReti
    | CIfZ of (atom_t list) * (atom_t list)
    | CInst of instruction_t [@@deriving hash,eq,ord,sexp,show { with_path = false }]

  module AtomSet : Set.S with type Elt.t = atom_t

  type body_t =
    | Empty (* This is just in the abstract syntax, no concrete counterpart! *)
    | Epsilon
    | Choice of body_t * body_t
    | Atom of atom_t
    | Seq of body_t * body_t
    | Star of body_t [@@deriving eq,ord,sexp,show,fold,hash]

  type t = a_isr_t * a_prepare_t * a_cleanup_t [@@deriving eq,ord,sexp]
    and a_isr_t = C_ISR of ((atom_t annot) list) [@@deriving eq,ord,sexp]
    and a_prepare_t = C_Prepare of ((atom_t annot) list) [@@deriving eq,ord,sexp]
    and a_cleanup_t = C_Cleanup of ((atom_t annot) list) [@@deriving eq,ord,sexp]

  val compile : ignore_interrupts:bool -> t -> (string * string) list * string list * string list * string list
  val derive : body_t -> atom_t -> body_t
  val is_empty : body_t -> bool
  val get_atoms : body_t -> AtomSet.t

end = struct
type ti_t = word_t [@@deriving hash,eq,ord,sexp,show { with_path = false }]

type atom_t =
  | CRst
  | CRstNZ
  | CJmpIn of string
  | CCreateEncl of enclave_layout_t
  | CTimerEnable of ti_t
  | CStartCounting of ti_t
  | CReti
  | CIfZ of (atom_t list) * (atom_t list)
  | CInst of instruction_t [@@deriving hash,eq,ord,sexp,show { with_path = false }]

type body_t =
  | Empty
  | Epsilon
  | Choice of body_t * body_t
  | Atom of atom_t
  | Seq of body_t * body_t
  | Star of body_t [@@deriving eq,ord,sexp,show,fold,hash]

type t = a_isr_t * a_prepare_t * a_cleanup_t [@@deriving eq,ord,sexp]
  and a_isr_t = C_ISR of ((atom_t annot) list) [@@deriving eq,ord,sexp]
  and a_prepare_t = C_Prepare of ((atom_t annot) list) [@@deriving eq,ord,sexp]
  and a_cleanup_t = C_Cleanup of ((atom_t annot) list) [@@deriving eq,ord,sexp]

let rec atom_compile ~(ignore_interrupts : bool) (atom : atom_t) : string list =
  let at_cc = match atom with
  | CRst ->
      [
        "mov #0x0, &WDTCTL"
      ]
  | CRstNZ  ->
      let now = Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ())) in
      [
        sprintf "jz rst_%s" now;
        "mov #0x0, &WDTCTL";
        sprintf "rst_%s:\n" now;
      ]
  | CJmpIn ts ->
      [
        "mov #0x4, &TACTL"; (* Stops and resets the timer *)
        "add #2, &TACCR0"; (* This takes care of the timing of jump in *)
        "mov #0x0, &TACCTL0";
        "mov &tactl_val, &TACTL"; (* Here the timer starts as soon as reti starts, if timer_enable was called! *)
        sprintf "br #%s" ts;
      ]
  | CCreateEncl (ts, te, ds, de) ->
      let now = Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ())) in
      [
        sprintf "sancus_enable #%s, #%s, #%s, #%s, #%s" ts ts te ds de;
        "cmp #0, r15"; (* If r15 is 0, then there's a failure *)
        sprintf "jnz ok_%s" now;
        "mov #0x0, &WDTCTL";
        sprintf "ok_%s:\n" now;
      ]
  | CTimerEnable ti ->
      let tactl_val = (if ignore_interrupts then "0x214" else "0x212") in
      [
        "dint";
        "mov #0x4, &TACTL";
        sprintf "mov #%d, &TACCR0" ti;
        sprintf "mov #%s, &tactl_val" tactl_val; (* Signals that timer_enable was executed! -- raises an interrupt once ti is reached *)
        "eint";
      ]
  | CStartCounting ti ->
      let ti_correct = ti - 2 in (* This is to account for the +2 in the jmpin *)
      [
        sprintf "mov #%d, &TACCR0" ti_correct;
        "mov #0x214, &tactl_val"; (* Enables the timer, up mode, no interrupt *)
      ]
  | CReti ->
      [
        "mov #0x4, &TACTL"; (* Stops and resets the timer *)
        "mov #0x0, &TACCTL0";
        "mov &tactl_val, &TACTL"; (* timer starts as soon as reti starts, if timer_enable was issued! *)
        "reti"
      ]
  | CIfZ (il1, il2) ->
    (* No nested CIfZ, sorry :) *)
    assert (List.for_all il1 ~f:(function CIfZ _ -> false | _ -> true));
    assert (List.for_all il2 ~f:(function CIfZ _ -> false | _ -> true));

    let now = Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ())) in
    [ sprintf "jnz else_%s" now ]
    @
    List.concat (List.map ~f:(atom_compile ~ignore_interrupts) il1)
    @
    [
      sprintf "jmp end_%s" now;
      sprintf "else_%s:" now
    ]
    @
    List.concat (List.map ~f:(atom_compile ~ignore_interrupts) il2)
    @
    [
      sprintf "end_%s:" now
    ];
  | CInst inst -> [ Common.show_instruction_t inst ] in
  (sprintf "; %s" (String.substr_replace_all ~pattern:"\n" ~with_:" " (show_atom_t atom)))::at_cc


(*
compile_spec compiles the given concrete attack into an actual attacker.
In doing that, it also declares a list of start/end labels to each instruction of the current action, so to facilitate
the analysis.
It may seem a problem, but jumping works even with labels:
- [[ JMP r ]] = S_i: JMP r\n\t E_i:;
- Assuming that such a jump is the k-th instruction to be executed. In the trace we can look for it by using the
  addresses of S_i and E_i, extract k and use it to analyse the signals
*)
let compile ~(ignore_interrupts : bool) ((C_ISR ai_list, C_Prepare ap_list, C_Cleanup ac_list) : t) =
  let lbl_isr, cl_isr = List.unzip (List.map ~f:(Common.annot_compile (atom_compile ~ignore_interrupts)) ai_list) in
  let lbl_prepare, cl_prepare = List.unzip (List.map ~f:(Common.annot_compile (atom_compile ~ignore_interrupts)) ap_list) in
  let lbl_cleanup, cl_cleanup = List.unzip (List.map ~f:(Common.annot_compile (atom_compile ~ignore_interrupts)) ac_list) in
  let c_isr, c_prepare, c_cleanup = List.concat cl_isr, List.concat cl_prepare, List.concat cl_cleanup in
    (List.concat (lbl_isr @ lbl_prepare @ lbl_cleanup), c_isr, c_prepare, c_cleanup)

(* The following definitions are useful when generating attackers according to a specification *)
module AtomSet = Set.Make (struct type t = atom_t [@@deriving ord,sexp] end)

let nu_nonrec nu (b : body_t) =
  let intersection b b' = match b, b' with
    | Epsilon, Epsilon -> Epsilon
    | _, Empty | Empty, _ -> Empty
    | _ -> failwith "Never happens" in
  let union b b' = match b, b' with
    | Empty, Empty -> Empty
    | _, Epsilon | Epsilon, _ -> Epsilon
    | _ -> failwith "Never happens" in
  match b with
  | Epsilon -> Epsilon
  | Empty -> Empty
  | Atom _ -> Empty
  | Seq (r, s) -> intersection (nu r) (nu s)
  | Choice (r, s) -> union (nu r) (nu s)
  | Star _ -> Epsilon

let nu = Memo.recursive ~hashable:Hashtbl.Poly.hashable nu_nonrec

let derive_nonrec derive (b, a : body_t * atom_t) : body_t =
  (* Logs.debug (fun m -> m "Attacker.derive_nonrec: start"); *)
  let res = match b with
  | Empty -> Empty
  | Epsilon -> Empty
  | Atom a' -> if equal_atom_t a' a then Epsilon else Empty
  | Seq (r, s) -> Choice (Seq (derive (r, a), s), Seq (nu r, derive (s, a)))
  | Star r -> Seq (derive (r, a), Star r)
  | Choice (r, s) -> Choice (derive (r, a), derive (s, a)) in
    (* Logs.debug (fun m -> m "Attacker.derive_nonrec: end"); *)
    res

let derive_mem = Memo.recursive ~hashable:Hashtbl.Poly.hashable derive_nonrec
let derive b a = derive_mem (b, a)

let rec is_empty (b : body_t) =
  match b with
  | Empty -> true
  | Epsilon | Atom _ | Star _ -> false
  | Seq (b', b'')  -> is_empty b' || is_empty b''
  | Choice (b', b'') -> is_empty b' && is_empty b''

let get_atoms_nonrec get_atoms (b : body_t) : AtomSet.t =
  match b with
  | Choice (b, b') | Seq (b, b') -> Set.union (get_atoms b) (get_atoms b')
  | Star b -> get_atoms b
  | Atom ca -> AtomSet.singleton ca
  | Empty | Epsilon -> AtomSet.empty

let get_atoms = Memo.recursive ~hashable:Hashtbl.Poly.hashable get_atoms_nonrec


end
