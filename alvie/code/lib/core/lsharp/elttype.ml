open! Base

module type EltType = sig
    type t [@@deriving eq,ord,sexp_of,of_sexp,hash,show]
    type comparator_witness

    val comparator : (t, comparator_witness) Comparator.comparator

    val default : t
end
