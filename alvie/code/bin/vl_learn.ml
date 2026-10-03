(* Learns a Mealy machine of a VaultLink service over TCP with the L# algorithm.

   The `.vtdl` specification fixes the input alphabet, the observables, and the
   input sequences worth exploring. Exit status: 0 on success, 2 for a problem
   the user can fix (a bad specification or option), 3 if the service is not
   reachable or misbehaves. *)
open Core
open Vaultlink

module S = Service.Sul
module RW = Learninglib.Randomwalkoracle.RandomWalkOracle (Symbol) (Symbol) (S)
module PAC = Learninglib.Pacoracle.PACOracle (Symbol) (Symbol) (S)
module Wm = Learninglib.Wmethodoracle.WMethodOracle (Symbol) (Symbol) (S)
module LRW = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Randomwalkoracle.RandomWalkOracle)
module LPAC = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Pacoracle.PACOracle)
module LWm = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Wmethodoracle.WMethodOracle)

let user_error fmt = Printf.ksprintf (fun msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 2) fmt

let load_spec file =
  let text = try In_channel.read_all file with Sys_error msg -> user_error "cannot read the specification: %s" msg in
  match Vtdl.parse_result text with
  | Error e -> user_error "%s:%s" file (Vtdl.error_message e)
  | Ok spec ->
    List.iter (Vtdl.warnings spec) ~f:(fun w -> eprintf "warning: %s\n%!" w);
    spec

let parse_target target =
  match String.rsplit2 target ~on:':' with
  | Some (host, port) when not (String.is_empty host) ->
    (match Int.of_string_opt port with
     | Some p when p > 0 && p < 65536 -> host, p
     | _ -> user_error "--target: %S is not a valid port" port)
  | _ -> user_error "--target must look like host:port, for example localhost:9101"

let command =
  Command.basic
    ~summary:"Learns a Mealy machine of a VaultLink service with L#, driven by a .vtdl specification"
    (let%map_open.Command spec_file = flag "--spec" (required string) ~doc:"file Specification (.vtdl)"
     and target = flag "--target" (required string) ~doc:"host:port Address of the VaultLink service"
     and res = flag "--res" (required string) ~doc:"file Where the learned model is written, in DOT"
     and oracle = flag "--oracle" (optional_with_default "wmethod" string) ~doc:"oracle wmethod (default), randomwalk, or pac"
     and step_limit = flag "--step-limit" (optional_with_default 500 int) ~doc:"n randomwalk: steps per equivalence query (default 500)"
     and reset_prob = flag "--reset-probability" (optional_with_default 0.05 float) ~doc:"p randomwalk: chance of restarting the walk after each step (default 0.05)"
     and epsilon = flag "--epsilon" (optional_with_default 0.001 float) ~doc:"e pac: error bound (default 0.001)"
     and delta = flag "--delta" (optional_with_default 0.001 float) ~doc:"d pac: confidence parameter (default 0.001)"
     and round_limit = flag "--round-limit" (optional int) ~doc:"n pac: maximum number of rounds (default: no limit)"
     and extra_states = flag "--extra-states" (optional_with_default 2 int) ~doc:"k wmethod: the service may have up to k more states than the hypothesis (default 2)"
     and max_tests = flag "--max-tests" (optional int) ~doc:"n wmethod: stop each equivalence check after n tests, giving up the guarantee (default: no limit)"
     and seed = flag "--seed" (optional_with_default 0 int) ~doc:"n Seed of the random exploration (default 0)"
     and debug = flag "--debug" no_arg ~doc:"Log every step"
     in
     fun () ->
       Logs.set_reporter (Logs_fmt.reporter ());
       Logs.set_level (Some (if debug then Logs.Debug else Logs.App));
       Random.init seed;
       if not (List.mem [ "randomwalk"; "pac"; "wmethod" ] oracle ~equal:String.equal) then
         user_error "--oracle must be randomwalk, pac, or wmethod, not %S" oracle;
       if extra_states < 0 then user_error "--extra-states must not be negative";
       Option.iter max_tests ~f:(fun n -> if n <= 0 then user_error "--max-tests must be positive");
       if step_limit <= 0 then user_error "--step-limit must be positive";
       if Float.(reset_prob < 0. || reset_prob > 1.) then user_error "--reset-probability must be between 0 and 1";
       if Float.(epsilon <= 0. || epsilon >= 1. || delta <= 0. || delta >= 1.) then
         user_error "--epsilon and --delta must be strictly between 0 and 1";
       let spec = load_spec spec_file in
       let host, port = parse_target target in
       let alphabet = List.map spec.inputs ~f:fst in
       (match Service.make ~host ~port spec with
        | exception Service.Service_error msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 3
        | sul ->
          let next_good il = match Service.allowed_inputs spec il with [] -> None | l -> Some (List.random_element_exn l) in
          let start = Time_now.nanoseconds_since_unix_epoch () in
          let learned =
            try
              match oracle with
              | "randomwalk" ->
                let o = RW.make ~step_limit ~reset_prob
                    ~next_input:(fun _ il _ -> Option.value (next_good il) ~default:Symbol.default) () in
                LRW.lsharp_run o sul alphabet
              | "pac" ->
                let o = PAC.make ?round_limit ~epsilon ~delta
                    ~next_input:(fun _ il _ -> match next_good il with Some i -> `Next i | None -> `Stop) () in
                LPAC.lsharp_run o sul alphabet
              | _ ->
                let o = Wm.make ~extra_states ?max_tests () in
                LWm.lsharp_run o sul alphabet
            with Service.Service_error msg -> eprintf "\nALVIE/VaultLink: %s\n%!" msg; exit 3
          in
          let elapsed = Int63.to_float (Int63.( - ) (Time_now.nanoseconds_since_unix_epoch ()) start) /. 1e9 in
          let model = Model.renumber (Model.drop_illegal learned) in
          Out_channel.write_all res ~data:(Model.to_dot model);
          printf "\nLearned a model with %d states and %d transitions in %.1fs (%d commands sent): %s\n"
            (Set.length model.states) (Map.length model.transition) elapsed (Service.steps sul) res;
          (match oracle, max_tests with
           | "wmethod", None ->
             printf "The model is exact if the service has at most %d more states than it, for the inputs your session allows.\n" extra_states
           | "wmethod", Some n ->
             printf "Each equivalence check was cut after %d tests, so the model is not guaranteed to be exact.\n" n
           | _ -> printf "This oracle samples behaviour: the model may miss rare behaviour. Use --oracle wmethod for a check with a guarantee.\n")))

let () = Command_unix.run command
