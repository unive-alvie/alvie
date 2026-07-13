open Core
open Learninglib.Lsharp
open Learninglib.Elttype
open Learninglib.Sul

open Interop

type in_op = OpR of int | OpW of int*int [@@deriving hash,show { with_path = false },eq,ord,sexp]
type in_who = WAttacker | WVictim [@@deriving hash,show { with_path = false },eq,ord,sexp]
type in_t = INoInput | IOp of in_op * in_who [@@deriving hash,show { with_path = false },eq,ord,sexp]

(* This module defines the set of all possible inputs of the SUL. In this simple case we have NoInput, Read and Write *)
module SimpleInput : (EltType with type t = in_t) = struct
  type t = in_t [@@deriving hash,show { with_path = false },eq,ord,sexp]

  let default = INoInput

  include (val Comparator.make ~compare ~sexp_of_t)
end

type out_t = OMiss of int | OHit of int [@@deriving hash,show { with_path = false },eq,ord,sexp] (* The integer denotes the number of cycles taken by the operation, be it a miss or a hit *)

(* ... similarly for outputs *)
module SimpleOutput : (EltType with type t = out_t)  = struct
  type t = out_t [@@deriving hash,show { with_path = false },eq,ord,sexp]

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
                OMiss 3
                (* if r = 1 then OHit r else OMiss 3 *)
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
module RWOracle = Learninglib.Randomwalkoracle.RandomWalkOracle (SimpleInput) (SimpleOutput) (SimpleSUL)


module IOInteropInternal = Interop (SimpleInput) (SimpleOutput)

let filter_model (m : IOInteropInternal.IIOMealy.t) =
  let _filtered_transition =
    IOInteropInternal.IIOMealy.TransitionMap.filteri
      m.transition
      ~f:(fun ~key ~data ->
        match key, data with
        | (_, INoInput), _ -> false
        |  _ -> true
      )
  in
  let _filtered_states =
    IOInteropInternal.IIOMealy.SSet.filter
      m.states
      ~f:(fun s ->
        (* Returns true if the state appears in at least one transition *)
        IOInteropInternal.IIOMealy.TransitionMap.existsi
          _filtered_transition
          ~f:(fun ~key:(s', _) ~data:(_, s'') -> s' = s || s'' = s)
      )
  in
  { m with transition = _filtered_transition; states = _filtered_states }




let command =
  Command.basic
    ~summary:"Minimal learning command using L# algorithm with SimpleSUL"
    (let%map_open.Command
        report =
          flag "--report" no_arg ~doc:"Prints a report table with statistics about the learning"
        and tmpdir =
          flag "--tmpdir" (required string) ~doc:"Temporary directory where intermediate results will be stored"
        and oracle_name =
          flag "--oracle" (required string) ~doc:"Oracle for equivalence check: randomwalk, pac, pacprefix"
        and dbg =
          flag "--debug" no_arg ~doc:"Enables debug-level logging"
        and info =
          flag "--info" no_arg ~doc:"Enables info-level logging"
        and step_limit =
          flag "--step-limit" (optional_with_default 500 int)
            ~doc:"Maximum number of steps for the equivalence oracle before giving up (default: 500)"
        and resfile =
          flag "--res" (required string) ~doc:"File where the final learned model will be stored"
      in
      fun () ->
        Random.init 0;
        Logs.set_reporter (Logs_fmt.reporter ());

        if dbg then Logs.set_level (Some Logs.Debug)
        else if info then Logs.set_level (Some Logs.Info)
        else Logs.set_level (Some Logs.App);

        let tmpdir =
          if Char.equal tmpdir.[String.length tmpdir - 1] '/'
          then String.drop_suffix tmpdir 1
          else tmpdir
        in
        (match Sys_unix.file_exists tmpdir with
        | `No -> Core_unix.mkdir_p tmpdir
        | _ -> ());

        let resdir =
          String.drop_suffix resfile (String.length (List.last_exn (String.split ~on:'/' resfile)))
        in
        (match Sys_unix.file_exists resdir with
        | `No -> Core_unix.mkdir_p resdir
        | _ -> ());

        let sul = ref (Array.create ~len:1024 0) in
        let complete_input_alphabet = [
          INoInput;
          IOp(OpR 0, WAttacker);
          IOp(OpW (0,1), WAttacker)
        ] in
        SimpleSUL.pre sul;

        let (outputquery_cnt, equivquery_cnt, sul_reset_cnt, sul_step_cnt, sul_step_dry_cnt, avg_len, sigmasq_len), time, learned =
          if String.equal oracle_name "randomwalk" then
            let oracle = RWOracle.make
                ~step_limit
                ~reset_prob:0.05
                ~next_input:(fun _ _ _ ->
                  (* let idx = Random.int 1024 in *)
                  if Random.int 2 = 0 then
                    IOp (OpR 0 (* idx *), WAttacker)
                  else
                    (* let v = Random.int 128 in *)
                    IOp (OpW (0, 1) (* (idx, v) *), WAttacker)
                ) ()
            in
            let start = Time_now.nanoseconds_since_unix_epoch () in
            let learned = IIBLSharpRW.lsharp_run oracle sul complete_input_alphabet in
            RWOracle.get_stats oracle,
            (Int63.to_int_exn (Time_now.nanoseconds_since_unix_epoch ()) - Int63.to_int_exn start),
            learned
          else failwith "Unknown oracle!"
        in

        if report then begin
          Printf.printf "\nStatistics:\n";
          Printf.printf "Output queries: %d\n" outputquery_cnt;
          Printf.printf "Equivalence queries: %d\n" equivquery_cnt;
          Printf.printf "SUL steps: %d\n" sul_step_cnt;
          Printf.printf "Average length: %f\n" avg_len;
        end;

        let final_model = filter_model learned in
        let graph = IOInteropInternal.dot_of_t final_model in
        let dot_dest = resfile in
        IOInteropInternal.Dot.output_graph (Stdlib.open_out_bin dot_dest) graph;
        Logs.debug (fun m -> m "\n=== Graph written to %s\n" dot_dest)
    )

(* Assicurati che questa sia l'ultima riga del file! *)
let () = Command_unix.run command
