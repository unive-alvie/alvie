(*
  The commands of ALVIE/VaultLink: alvie vaultlink learn | compare | replay (formerly vl_learn, vl_compare and
  vl_replay of the VaultLink variant).

  A service is either --target host:port, over TCP, when the program can open connections (tcp: the native ALVIE),
  or --service reference|firmware, a service in memory (Memory_service), which every build has, a browser's too.
  Exit status: 0 on success (compare: the models agree), 1 when compare finds differences, 2 for a problem the user
  can fix (the specification, an option, a file), 3 if the service is not reachable or misbehaves.
*)
open Core

module S = Service.Sul
module RW = Learninglib.Randomwalkoracle.RandomWalkOracle (Symbol) (Symbol) (S)
module PAC = Learninglib.Pacoracle.PACOracle (Symbol) (Symbol) (S)
module Wm = Learninglib.Wmethodoracle.WMethodOracle (Symbol) (Symbol) (S)
module LRW = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Randomwalkoracle.RandomWalkOracle)
module LPAC = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Pacoracle.PACOracle)
module LWm = Learninglib.Lsharp.LSharp (Symbol) (Symbol) (S) (Learninglib.Wmethodoracle.WMethodOracle)

let user_error fmt = Printf.ksprintf (fun msg -> eprintf "ALVIE/VaultLink: %s\n%!" msg; exit 2) fmt
let service_failed msg = eprintf "\nALVIE/VaultLink: %s\n%!" msg; exit 3

let load_spec file =
  let text = try In_channel.read_all file with Sys_error msg -> user_error "cannot read the specification: %s" msg in
  match Vtdl.parse_result text with
  | Error e -> user_error "%s:%s" file (Vtdl.error_message e)
  | Ok spec ->
    List.iter (Vtdl.warnings spec) ~f:(fun w -> eprintf "warning: %s\n%!" w);
    spec

type tcp = host:string -> port:int -> Service.transport

(* The flags that choose the service, and the transport they give *)
let service_param ~(tcp : tcp option) =
  let open Command.Let_syntax in
  let services = String.concat ~sep:"|" (List.map Memory_service.kinds ~f:fst) in
  [%map_open
    let target = match tcp with
      | Some _ -> flag "--target" (optional string) ~doc:"host:port Address of the VaultLink service"
      | None -> return None
    and service = flag "--service" (optional string) ~doc:(sprintf "%s A service in memory (instead of --target)" services) in
    fun () ->
      match target, service, tcp with
      | Some _, Some _, _ -> user_error "give either --target or --service, not both"
      | Some target, None, Some tcp ->
        (match String.rsplit2 target ~on:':' with
         | Some (host, port) when not (String.is_empty host) ->
           (match (Option.try_with (fun () -> Int.of_string port)) with
            | Some p when p > 0 && p < 65536 -> tcp ~host ~port:p
            | _ -> user_error "--target: %S is not a valid port" port)
         | _ -> user_error "--target must look like host:port, for example localhost:9101")
      | None, Some name, _ ->
        (match List.Assoc.find Memory_service.kinds ~equal:String.equal name with
         | Some kind -> Memory_service.transport kind
         | None -> user_error "--service must be %s, not %S" services name)
      | _ -> user_error (if Option.is_some tcp then "give the service: --target host:port, or --service %s" else "give the service: --service %s") services]

let learn ~tcp =
  Command.basic
    ~summary:"Learn a Mealy machine of a VaultLink service with L#, driven by a .vtdl specification"
    (let%map_open.Command spec_file = flag "--spec" (required string) ~doc:"file Specification (.vtdl)"
     and transport = service_param ~tcp
     and res = flag "--res" (required string) ~doc:"file Where the learned model is written, in DOT"
     and oracle = flag "--oracle" (optional_with_default "wmethod" string) ~doc:"oracle wmethod (default), randomwalk, or pac"
     and step_limit = flag "--step-limit" (optional_with_default 500 int) ~doc:"n randomwalk: steps per equivalence query (default 500)"
     and reset_prob = flag "--reset-probability" (optional_with_default 0.05 float) ~doc:"p randomwalk: chance of restarting the walk after each step; pac: chance of ending a test where the session may end (default 0.05)"
     and epsilon = flag "--epsilon" (optional_with_default 0.001 float) ~doc:"e pac: error bound (default 0.001)"
     and delta = flag "--delta" (optional_with_default 0.001 float) ~doc:"d pac: confidence parameter (default 0.001)"
     and round_limit = flag "--round-limit" (optional int) ~doc:"n pac: maximum number of rounds (default: no limit)"
     and extra_states = flag "--extra-states" (optional_with_default 2 int) ~doc:"k wmethod: the service may have up to k more states than the hypothesis (default 2)"
     and max_tests = flag "--max-tests" (optional int) ~doc:"n wmethod: stop each equivalence check after n tests, giving up the guarantee (default: no limit)"
     and seed = flag "--seed" (optional_with_default 0 int) ~doc:"n Seed of the random exploration (default 0)"
     and debug = flag "--debug" no_arg ~doc:"Log every step" in
     fun () ->
       Logs.set_reporter (Logs_fmt.reporter ());
       Logs.set_level (Some (if debug then Logs.Debug else Logs.App));
       Learninglib.Rng.init seed;
       if not (List.mem [ "randomwalk"; "pac"; "wmethod" ] oracle ~equal:String.equal) then
         user_error "--oracle must be randomwalk, pac, or wmethod, not %S" oracle;
       if extra_states < 0 then user_error "--extra-states must not be negative";
       Option.iter max_tests ~f:(fun n -> if n <= 0 then user_error "--max-tests must be positive");
       if step_limit <= 0 then user_error "--step-limit must be positive";
       if Float.(reset_prob < 0. || reset_prob > 1.) then user_error "--reset-probability must be between 0 and 1";
       if Float.(epsilon <= 0. || epsilon >= 1. || delta <= 0. || delta >= 1.) then
         user_error "--epsilon and --delta must be strictly between 0 and 1";
       let spec = load_spec spec_file in
       let alphabet = List.map spec.inputs ~f:fst in
       match Service.make (transport ()) spec with
       | exception Service.Service_error msg -> service_failed msg
       | sul ->
         let next_good il = match Service.allowed_inputs spec il with [] -> None | l -> Some (Learninglib.Rng.random_element_exn l) in
         let start = Time_now.nanoseconds_since_unix_epoch () in
         let learned =
           try
             match oracle with
             | "randomwalk" ->
               let o = RW.make ~step_limit ~reset_prob ~next_input:(fun _ il _ -> Option.value (next_good il) ~default:Symbol.default) () in
               LRW.lsharp_run o sul alphabet
             | "pac" ->
               (* A test of PAC ends when the session allows no more input, or, where the session may end, with
                  the probability of --reset-probability: a session such as (a | b)* would not end otherwise *)
               let next il =
                 match Service.allowed_inputs spec il with
                 | [] -> `Stop
                 | l when Service.may_end spec il && Float.(Learninglib.Rng.float_range 0.0 1.0 < reset_prob) -> ignore l; `Stop
                 | l -> `Next (Learninglib.Rng.random_element_exn l) in
               let o = PAC.make ?round_limit ~epsilon ~delta ~next_input:(fun _ il _ -> next il) () in
               LPAC.lsharp_run o sul alphabet
             | _ ->
               let o = Wm.make ~extra_states ?max_tests () in
               LWm.lsharp_run o sul alphabet
           with Service.Service_error msg -> service_failed msg in
         let elapsed = Int63.to_float (Int63.( - ) (Time_now.nanoseconds_since_unix_epoch ()) start) /. 1e9 in
         let model = Model.renumber (Model.drop_illegal learned) in
         Out_channel.write_all res ~data:(Model.to_dot model);
         printf "\nLearned a model with %d states and %d transitions in %.1fs (%d commands sent): %s\n"
           (Set.length model.states) (Map.length model.transition) elapsed (Service.steps sul) res;
         match oracle, max_tests with
         | "wmethod", None ->
           printf "The model is exact if the service has at most %d more states than it, for the inputs your session allows.\n" extra_states
         | "wmethod", Some n -> printf "Each equivalence check was cut after %d tests, so the model is not guaranteed to be exact.\n" n
         | _ -> printf "This oracle samples behaviour: the model may miss rare behaviour. Use --oracle wmethod for a check with a guarantee.\n")

let load_model file =
  let text = try In_channel.read_all file with Sys_error msg -> user_error "%s" msg in
  try Model.of_dot text
  with Model.Parse_error (line, msg) -> user_error "%s, line %d: %s" file line msg

let compare =
  Command.basic
    ~summary:"Print the shortest input sequences on which two learned models give different outputs"
    (let%map_open.Command left = anon ("LEFT.dot" %: string)
     and right = anon ("RIGHT.dot" %: string)
     and limit = flag "--limit" (optional_with_default 10 int) ~doc:"n Maximum number of sequences to print (default 10)" in
     fun () ->
       let a = load_model left and b = load_model right in
       match Model.differences ~limit a b with
       | [] -> printf "No difference: the models agree on every input sequence.\n"
       | diffs ->
         printf "%d distinguishing sequence%s (shortest first):\n" (List.length diffs) (if List.length diffs = 1 then "" else "s");
         List.iteri diffs ~f:(fun n d ->
           printf "\n#%d\n" (n + 1);
           let w = List.fold d.inputs ~init:0 ~f:(fun acc i -> Int.max acc (String.length i)) in
           List.iteri d.inputs ~f:(fun k i ->
             let l = List.nth_exn d.left k and r = List.nth_exn d.right k in
             let mark = if String.equal l r then "  " else "<>" in
             printf "  %-*s  %s  %s | %s\n" w i mark l r));
         exit 1)

let replay ~tcp =
  Command.basic
    ~summary:"Replay a sequence of inputs against a VaultLink service and print the raw responses"
    ~readme:(fun () ->
      "Example:  alvie vaultlink replay --spec my.vtdl --service reference HELLO ID_SELF AUDIT\n\
       Inputs may be separate arguments or one quoted, space- or comma-separated list.")
    (let%map_open.Command spec_file = flag "--spec" (required string) ~doc:"file Specification (.vtdl) that declares the inputs"
     and transport = service_param ~tcp
     and inputs = anon (sequence ("INPUT" %: string)) in
     fun () ->
       let spec = load_spec spec_file in
       let inputs =
         List.concat_map inputs ~f:(String.split_on_chars ~on:[ ' '; ','; '\t'; '\n' ]) |> List.filter ~f:(Fn.non String.is_empty) in
       if List.is_empty inputs then
         user_error "no inputs given; the specification declares: %s" (String.concat ~sep:", " (List.map spec.inputs ~f:fst));
       List.iter inputs ~f:(fun i ->
         if not (List.Assoc.mem spec.inputs ~equal:String.equal i) then
           user_error "input %S is not declared in %s; it declares: %s" i spec_file (String.concat ~sep:", " (List.map spec.inputs ~f:fst)));
       try
         let sul = Service.make (transport ()) spec in
         let steps = Service.replay sul inputs in
         let wi = List.fold steps ~init:0 ~f:(fun a r -> Int.max a (String.length r.input)) in
         let wc = List.fold steps ~init:0 ~f:(fun a r -> Int.max a (String.length r.command)) in
         List.iter steps ~f:(fun r ->
           match r.response with
           | Some line -> printf "%-*s  %-*s  ->  %s    [%s]\n" wi r.input wc r.command line r.output
           | None -> printf "%-*s  %-*s  ->  (connection closed)    [%s]\n" wi r.input wc r.command r.output)
       with Service.Service_error msg -> service_failed msg)

(* alvie vaultlink: the group, with TCP when the program has it (tcp), and its server of the services in memory
   (serve) *)
let group ?tcp ?serve () =
  let serve = match serve with
    | None -> []
    | Some serve ->
      [ ("serve",
         Command.basic ~summary:"Serve a service in memory over TCP on localhost, for practising with --target"
           (let%map_open.Command service = flag "--service" (required string) ~doc:"reference|firmware The service"
            and port = flag "--port" (optional_with_default 9101 int) ~doc:"n The port (default 9101)" in
            fun () ->
              match List.Assoc.find Memory_service.kinds ~equal:String.equal service with
              | Some kind -> serve ~port kind
              | None -> user_error "--service must be reference or firmware, not %S" service)) ] in
  Command.group ~summary:"ALVIE/VaultLink: learn and compare models of services that speak a line-based text protocol"
    ([ ("learn", learn ~tcp); ("compare", compare); ("replay", replay ~tcp) ] @ serve)
