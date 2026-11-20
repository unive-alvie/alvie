(* Abstract input and output symbols, as the learner sees them.

   Both are plain strings: an input is the name declared in the `inputs`
   section, and an output is the symbol built by the first matching `observe`
   rule, such as `OK` or `DATA(op-4471)`. They satisfy [Learninglib.Elttype.EltType]. *)
open! Core

module T = struct
  type t = string [@@deriving equal, compare, sexp, hash]
end

include T
include Comparator.Make (T)

let pp fmt s = Format.pp_print_string fmt s
let show s = s

(* Never produced by a specification: the random-walk oracle treats it as "no input". *)
let default = ""

(* Output of an input that the `session` expression does not allow at this point.
   The input is not sent, and every later input in the same query yields it too. *)
let illegal = "ILLEGAL"

(* Output when the service closes the connection. *)
let disconnected = "DISCONNECTED"

let reserved_outputs = [ illegal; disconnected ]
