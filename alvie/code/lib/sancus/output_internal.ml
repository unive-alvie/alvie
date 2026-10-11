open! Core
open Common

type mode_t = UM | PM  [@@deriving eq,ord,sexp,hash,show { with_path = false }]

type payload_t = { k : int; gie : bool; umem_val : word_t; (* pmem_val : word_t; *) reg_val : word_t; timerA_counter : word_t; mode : mode_t } [@@deriving eq,ord,sexp,hash,show { with_path = false }]

type element_t =
  | OMaybeDiverge
  | OIllegal
  (* | OException *)
  | OReset
  | OJmpIn of payload_t
  | OJmpOut of payload_t
  | OReti of payload_t
  | OJmpOut_Handle of payload_t*payload_t
  | OTime_Handle of payload_t*payload_t
  (* | OHandle of int *)
  | OTime of payload_t
  | OSilent
  | OUnsupported [@@deriving eq,ord,sexp,hash,show { with_path = false }]

type t = (element_t list) * ((string*string) list) * int [@@deriving eq,ord,sexp,hash,show { with_path = false }]

let default : t = ([OIllegal], [], 0)

(*
  Only the first component is an observation. The other two are bookkeeping that lets the SUL
  restore its state on steps whose output is already known (see Verilog.step): the labels of the code
  segments that have not run yet, and the number of the last instruction analysed. Comparing them
  would make states with the same observable future apart only because of how they were reached:
  through a different number of instructions (e.g., when an attacker can re-enter an enclave
  repeatedly, as in B3), or with different (or repeated) pending segments, such as the branch of an
  ifz that was not taken or ISR code that has not run yet. When the bookkeeping does affect the
  future, the outputs that follow differ and the learner tells the states apart anyway, so equality,
  ordering and hashing ignore it.
*)
let observation ((obs, _, _) : t) = obs
let equal a b = [%derive.eq: element_t list] (observation a) (observation b)
let compare a b = [%derive.ord: element_t list] (observation a) (observation b)
let hash_fold_t st a = [%hash_fold: element_t list] st (observation a)
let hash a = Ppx_hash_lib.Std.Hash.run hash_fold_t a

let merge_payload ~older ~newer = { newer with k = older.k + newer.k }

include (val Comparator.make ~compare ~sexp_of_t)
