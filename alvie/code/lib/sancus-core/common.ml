open! Core

(*
  This module implements what's in common between attackers and victims (i.e., words, registers, basic instructions)
*)
type enclave_layout_t = string * string * string * string  [@@deriving show { with_path = false },eq,ord,sexp,hash]

type word_t = int [@@deriving eq,ord,sexp,hash]
let pp_word_t fmt w = Format.fprintf fmt "#%#x" w

type reg_t = R of int [@@deriving eq,ord,sexp,hash]
let pp_reg_t fmt r = match r with R i -> Format.fprintf fmt "r%d" i

type op_src_t = S_R of reg_t | S_IMM of string | S_AT of reg_t | S_AMP of string | S_SECRET [@@deriving eq,ord,sexp,hash]
let pp_op_src_t fmt x = match x with
  | S_R r -> pp_reg_t fmt r
  | S_IMM w -> Format.fprintf fmt "#%s" w
  | S_AMP w -> Format.fprintf fmt "&%s" w
  | S_SECRET -> Format.fprintf fmt "UNEXPANDED_SECRET"
  | S_AT r -> Format.fprintf fmt "@"; pp_reg_t fmt r

type jmp_dst_t = J_R of reg_t | J_LBL of string  [@@deriving eq,ord,sexp,hash]
let pp_jmp_dst_t fmt x = match x with
  | J_R r -> pp_reg_t fmt r
  | J_LBL l -> Format.fprintf fmt "%s" l

type op_dst_t = D_R of reg_t | D_AMP of reg_t | D_AMP_MEM of string [@@deriving eq,ord,sexp,hash]
let pp_op_dst_t fmt x = match x with
  | D_R r -> pp_reg_t fmt r
  | D_AMP_MEM w -> Format.fprintf fmt "&%s" w
  | D_AMP r -> Format.fprintf fmt "&"; pp_reg_t fmt r


let cycles_of_double_operands s d =
  match s, d with
  (* Source is register *)
  | S_R _, D_R (R 0) -> 2
  | S_R _, D_R _ -> 1
  | S_R _, (D_AMP _ | D_AMP_MEM _) -> 4
  (* Source is immediate/secret *)
  | (S_IMM _ | S_SECRET), D_R (R 0) -> 3
  | (S_IMM _ | S_SECRET), D_R _ -> 2
  | (S_IMM _ | S_SECRET), (D_AMP _ | D_AMP_MEM _) -> 5
  (* Source is @Rx *)
  | S_AT _, D_R (R 0) -> 3
  | S_AT _, D_R _ -> 2
  | S_AT _, (D_AMP _ | D_AMP_MEM _) -> 5
  (* Source is &EDE *)
  | S_AMP _, D_R (R 0) -> 3
  | S_AMP _, D_R _ -> 3
  | S_AMP _, (D_AMP _ | D_AMP_MEM _) -> 6

type instruction_t =
  | I_NOP
  | I_DINT
  | I_NAMED of string * instruction_t
  | I_MOV of op_src_t * op_dst_t
  | I_ADD of op_src_t * op_dst_t
  | I_CMP of op_src_t * op_dst_t
  | I_JZ of jmp_dst_t
  | I_JNZ of jmp_dst_t
  | I_PUSH of op_src_t
  | I_JMP of op_src_t [@@deriving eq,ord,sexp,hash]
let rec pp_instruction_t fmt inst =
  match inst with
  | I_NOP -> Format.fprintf fmt "nop"
  | I_DINT -> Format.fprintf fmt "dint"
  | I_MOV (src, dst) -> Format.fprintf fmt "mov "; pp_op_src_t fmt src; Format.fprintf fmt ", "; pp_op_dst_t fmt dst
  | I_ADD (src, dst) -> Format.fprintf fmt "add "; pp_op_src_t fmt src; Format.fprintf fmt ", "; pp_op_dst_t fmt dst
  | I_CMP (src, dst) -> Format.fprintf fmt "cmp "; pp_op_src_t fmt src; Format.fprintf fmt ", "; pp_op_dst_t fmt dst
  | I_JMP l -> Format.fprintf fmt "br "; pp_op_src_t fmt l
  | I_JNZ l -> Format.fprintf fmt "jnz "; pp_jmp_dst_t fmt l
  | I_JZ l -> Format.fprintf fmt "jz "; pp_jmp_dst_t fmt l
  | I_PUSH src -> Format.fprintf fmt "push "; pp_op_src_t fmt src
  | I_NAMED (l, i) -> Format.fprintf fmt "%s: " l; pp_instruction_t fmt i
let show_instruction_t = [%derive.show: instruction_t]

let rec cycles_of_inst i =
  (* This is taken from the OpenMSP430 Manual! *)
  match i with
  | I_NOP -> (* This is a MOV #0, R3 so... *) 1
  | I_DINT -> 2
  | I_NAMED (_, i') -> cycles_of_inst i'
  | I_MOV (s,d) | I_ADD (s, d) | I_CMP (s, d) -> cycles_of_double_operands s d
  | I_JZ _ | I_JNZ _ | I_JMP _  -> 2
  | I_PUSH (S_R _) -> 3
  | I_PUSH S_SECRET | I_PUSH (S_IMM _) -> 4
  | I_PUSH (S_AT _) -> 4
  | I_PUSH (S_AMP _) -> 5

type 'a annot = NoLabel of 'a | Label of 'a [@@deriving eq,ord,sexp,show { with_path = false },hash]

let last_used_idx = ref (-1)

let reset_last_used_idx () = (last_used_idx := -1)

let annot_compile (compile : 'a -> string list) (ac : 'a annot) =
    let _annotate (compiled : string list) : ((string * string) list) * (string list) =
      let start_lbl i = sprintf "S_%d" i in
      let end_lbl i = sprintf "E_%d" i in
        List.fold
          compiled
          ~init:([], [])
          ~f:(fun (lbls, annot_insts) inst ->
                incr last_used_idx;
                lbls @ [(start_lbl !last_used_idx, end_lbl !last_used_idx)], annot_insts @ [start_lbl !last_used_idx ^ ":"; inst; end_lbl !last_used_idx ^ ":"]
          ) in
    match ac with NoLabel c -> [], snd (_annotate (compile c)) | Label c -> _annotate (compile c)


let annot_unwrap w = match w with NoLabel u | Label u -> u
