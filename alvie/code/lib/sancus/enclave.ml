open! Core

open Common

module Enclave : sig
  type atom_t =
  | CInst of instruction_t
  | CUbr
  | CRst
  | CIfZ of (atom_t list * atom_t list)
  | CBalancedIfZ of (instruction_t list) [@@deriving eq,ord,sexp,show { with_path = false },hash]

  type body_t =
  | Empty
  | Epsilon
  | Choice of body_t * body_t
  | Atom of atom_t
  | Seq of body_t * body_t
  | Star of body_t [@@deriving eq,ord,sexp,show,fold,hash]

  type t = C_Enclave of ((atom_t annot) list) [@@deriving eq,ord,sexp,show { with_path = false },hash]

  module AtomSet : Set.S with type Elt.t = atom_t

  val compile : t -> (string * string) list * string list
  val derive : body_t -> atom_t -> body_t
  val is_empty : body_t -> bool
  val get_atoms : body_t -> AtomSet.t
  val atom_expand_secret : string -> atom_t -> atom_t
  val expand_secret : string -> body_t -> body_t
  val has_secret : body_t -> bool
end = struct
  type atom_t =
  | CInst of instruction_t
  | CUbr
  | CRst
  | CIfZ of (atom_t list * atom_t list)
  | CBalancedIfZ of (instruction_t list) [@@deriving eq,ord,sexp,show { with_path = false },hash]

  type body_t =
    | Empty
    | Epsilon
    | Choice of body_t * body_t
    | Atom of atom_t
    | Seq of body_t * body_t
    | Star of body_t [@@deriving eq,ord,sexp,show,fold,hash]

  type t = C_Enclave of ((atom_t annot) list) [@@deriving eq,ord,sexp,show { with_path = false },hash]
  include (val Comparator.make ~compare ~sexp_of_t)

  let rec atom_compile (atom : atom_t) : string list =
    match atom with
    | CUbr ->
      [
        "jnz enc_e";
        "mov #0x42, &DMEM_242";
        "jmp enc_e";
      ]
    | CRst ->
      [
        "mov #0x0, &WDTCTL"
      ]
    | CIfZ (il1, il2) ->
      (* No nested jumps, sorry :) *)
      assert (List.for_all il1 ~f:(function CIfZ _ | CBalancedIfZ _ | CUbr -> false | _ -> true));
      assert (List.for_all il2 ~f:(function CIfZ _ | CBalancedIfZ _ | CUbr -> false | _ -> true));

      let now = Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ())) in
      [ sprintf "jnz else_%s" now ]
      @
      List.concat (List.map ~f:atom_compile il1)
      @
      [
        sprintf "jmp end_%s" now;
        sprintf "else_%s:" now
      ]
      @
      List.concat (List.map ~f:atom_compile il2)
      @
      [
        sprintf "jmp end_%s" now;
        sprintf "end_%s:" now
      ];
    | CBalancedIfZ il ->
      let n = List.fold ~init:0 ~f:(fun acc i -> cycles_of_inst i + acc) il in
      let now = Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ())) in
      [
        sprintf "jz zero_%s" now; (* 2n skips the NOPs, 2 skips the jmp enc_e *)
      ]
      @
      List.init n ~f:(fun _ -> "nop")
      @
      [
        "jmp enc_e";
        sprintf "zero_%s:" now;
      ]
      @
      List.map ~f:Common.show_instruction_t il;
      @
      [
        "jmp enc_e";
      ]
    | CInst inst -> [ Common.show_instruction_t inst ]

  let compile (C_Enclave e : t) : (string * string) list * string list =
    let ll, cl = List.unzip (List.map ~f:(Common.annot_compile atom_compile) e) in
      List.concat ll, List.concat cl

  (* The following definitions are useful when generating enclaves according to a specification *)
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
    match b with
    | Empty -> Empty
    | Epsilon -> Empty
    | Atom a' -> if equal_atom_t a' a then Epsilon else Empty
    | Seq (r, s) -> Choice (Seq (derive (r, a), s), Seq (nu r, derive (s, a)))
    | Star r -> Seq (derive (r, a), Star r)
    | Choice (r, s) -> Choice (derive (r, a), derive (s, a))

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

  let src_expand_secret v src =
    match src with
    | S_SECRET -> S_IMM v
    | _ -> src

  let rec inst_expand_secret (v : string) (i : Common.instruction_t) =
    match i with
    | I_NOP | I_DINT | I_JZ _ | I_JNZ _  -> i
    | I_NAMED (s, i') -> I_NAMED (s, inst_expand_secret v i')
    | I_MOV (src, dst) -> I_MOV (src_expand_secret v src, dst)
    | I_ADD (src, dst) -> I_ADD (src_expand_secret v src, dst)
    | I_CMP (src, dst) -> I_CMP (src_expand_secret v src, dst)
    | I_PUSH src -> I_PUSH (src_expand_secret v src)
    | I_JMP src -> I_JMP (src_expand_secret v src)

  let rec atom_expand_secret (v : string) a =
    match a with
    | CUbr | CRst -> a
    | CInst i -> CInst (inst_expand_secret v i)
    | CIfZ (l, r) -> CIfZ (List.map l ~f:(atom_expand_secret v), List.map r ~f:(atom_expand_secret v))
    | CBalancedIfZ il -> CBalancedIfZ (List.map il ~f:(inst_expand_secret v))

  let rec expand_secret v b =
    match b with
    | Empty | Epsilon -> b
    | Choice (l, r) -> Choice (expand_secret v l, expand_secret v r)
    | Seq (l, r) -> Seq (expand_secret v l, expand_secret v r)
    | Star b' -> Star (expand_secret v b')
    | Atom a -> Atom (atom_expand_secret v a)

  let rec inst_has_secret (i : Common.instruction_t) =
    match i with
    | I_NAMED (_, i') -> inst_has_secret i'
    | I_MOV (S_SECRET, _) | I_ADD (S_SECRET, _) | I_CMP (S_SECRET, _) | I_PUSH S_SECRET | I_JMP S_SECRET -> true
    | _ -> false

  let rec atom_has_secret a =
    match a with
    | CUbr | CRst -> false
    | CInst i -> inst_has_secret i
    | CIfZ (l, r) -> List.exists l ~f:atom_has_secret || List.exists r ~f:atom_has_secret
    | CBalancedIfZ il -> List.exists il ~f:inst_has_secret

  let rec has_secret b =
    match b with
    | Empty | Epsilon -> false
    | Choice (l, r) | Seq (l, r) -> has_secret l || has_secret r
    | Star b' -> has_secret b'
    | Atom a -> atom_has_secret a
end

