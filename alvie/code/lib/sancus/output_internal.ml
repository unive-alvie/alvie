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
  The last component is the number of the last instruction analysed by the SUL: it is bookkeeping
  that lets the SUL restore its state on steps whose output is already known (see Verilog.step), not
  an observation. Comparing it would make states with the same observable future apart only because
  they were reached through a different number of instructions (e.g., when an attacker can re-enter
  an enclave repeatedly, as in B3), so equality, ordering and hashing ignore it.
*)
let without_inst_number ((obs, labels, _) : t) = (obs, labels)
let equal a b = [%derive.eq: element_t list * (string * string) list] (without_inst_number a) (without_inst_number b)
let compare a b = [%derive.ord: element_t list * (string * string) list] (without_inst_number a) (without_inst_number b)
let hash_fold_t st a = [%hash_fold: element_t list * (string * string) list] st (without_inst_number a)
let hash a = Ppx_hash_lib.Std.Hash.run hash_fold_t a

let merge_payload ~older ~newer = { newer with k = older.k + newer.k }

include (val Comparator.make ~compare ~sexp_of_t)
