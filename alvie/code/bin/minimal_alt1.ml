(*
  Alternativa 1: Questo non ha le constraint sul module type
*)

open Core
open Learninglib.Lsharp
open Learninglib.Elttype
open Learninglib.Sul

open Interop


(* This module defines the set of all possible inputs of the SUL. In this simple case we have NoInput, Read and Write *)
module SimpleInput (* : EltType *) = struct
  type op = OpR of int | OpW of int*int [@@deriving hash,show { with_path = false },eq,ord,sexp]
  type who = WAttacker | WVictim [@@deriving hash,show { with_path = false },eq,ord,sexp]
  type t = INoInput | IOp of op * who [@@deriving hash,show { with_path = false },eq,ord,sexp]

  let default = INoInput

  include (val Comparator.make ~compare ~sexp_of_t)
end

(* ... similarly for outputs *)
module SimpleOutput (* : EltType *) = struct
  type t = OMiss of int | OHit of int [@@deriving hash,show { with_path = false },eq,ord,sexp] (* The integer denotes the number of cycles taken by the operation, be it a miss or a hit *)

  let default = OMiss 0

  include (val Comparator.make ~compare ~sexp_of_t)
end

(* we need an interface with the SUL *)
module SimpleSUL (* : SUL *) = struct
  (* t is the type of the state of the sul, might be e.g., a function mapping addresses into values  *)
  (* type _t = int -> int
  type t = _t ref *)
  type t = int array ref

  type input_t = SimpleInput.t
  type output_t = SimpleOutput.t

  (* Deep-copies the given SUL *)
  let clone (cfg : t) = ref !cfg

  (* Performs the initialization of the given SUL *)
  (* let pre (cfg : t) : unit = cfg := (fun _ -> 0) *)
  (* Performs the initialization of the given SUL, placing in cache random values at odd position
      and 0 at even positions
  *)
  let pre (cfg : t) : unit =
    Random.self_init ();
    cfg := Array.init 1024 ~f:(fun i ->
      if i mod 2 = 0 then 0 else Random.int 128)


  (* Perform the specified input step on the given SUL and returns the result *)
  (* let step ?(silent=false) ?(dry_output : output_t option) (cfg : t) (i : input_t) : output_t =
    match i with
    | INoInput -> SimpleOutput.default
    | IOp (OpR a, _) ->(* esempio: se c'è una hit return OHit 42 else OMiss 3 *)
    | IOp (OpW (a, v), _) -> esempio: aggiorna la memoria e poi se c'è una hit return OHit 42 else OMiss 3 *)

  let step ?(silent=false) ?(dry_output : output_t option) (cfg : t) (i : input_t) : output_t =
    match i with
    | INoInput -> SimpleOutput.default
    | IOp (OpR a, _) ->
          if a < 0 || a >= Array.length !cfg then
                failwith "Invalid address"
              else if a mod 2 = 1 then
                (* Odd index *)
                OHit (!cfg).(a)
              else (
                let r = Random.int 2 in
                (!cfg).(a) <- r;
                if r = 1 then OHit r else OMiss 3
              )
    | IOp (OpW (a, v), _) ->
        if a < 0 || a >= Array.length !cfg then
          failwith "Invalid address"
        else (
          (!cfg).(a) <- v;
          OHit v
        )

  (* Performs the cleanup of the given SUL *)
  let post _ = ()
end

(* This is the actual learning module *)
module IIBLSharpRW = LSharp (SimpleInput) (SimpleOutput) (SimpleSUL) (Learninglib.Randomwalkoracle.RandomWalkOracle)
