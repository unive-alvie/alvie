open Core
open Attacker
open Enclave

type t = INoInput | IAttacker of Attacker.atom_t | IEnclave of Enclave.atom_t [@@deriving hash,show { with_path = false },eq,ord,sexp]

let default = INoInput

include (val Comparator.make ~compare ~sexp_of_t)
