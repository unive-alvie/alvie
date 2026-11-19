(*
  The commands of ALVIE/Core for a native plugin (Alvie_backend.Native.S): everything is generic, from the plugin
  files and the backend.

    learn        learns a model of the backend under a spec (L#, with the PAC or random-walk oracle)
    compare      noninterference: the witnesses that tell apart two models that differ only in the secret
    property     inclusion, equivalence, or a formula (Property_cmd)
    exec         runs a sequence of atoms on the backend and prints what it observes
    conformance  checks that the backend keeps the contract of Core (Conformance)
    fixtures     learns and compares the plugin's fixtures, and checks their expected verdicts (Fixtures)

  The codec (MODEL_CODEC) says what the learner's inputs and outputs are, and so the alphabet and the model files.
  Make uses Atoms_codec: inputs are atoms of a class (an attacker atom is the same input in every attacker section),
  and outputs the observations, values of observations.yaml. A plugin can bring its own (Make_codec): ALVIE/Sancus
  keeps its types, so that its models keep their format and learn.exe learns them as it always did.
*)
open Core
open Alvie_plugin
module G = Alvie_inputgen.Generator
module Native = Alvie_backend.Native

(* What the learner works on, and how it maps to Core: the codec of the adapter (Alvie_backend.Sul.CODEC), and *)
module type MODEL_CODEC = sig
  type bookkeeping
  module Input : Learninglib.Elttype.EltType
  module Output : Learninglib.Elttype.EltType
  type input = Input.t
  type output = Output.t
  val input_to_core : section:string -> input -> G.input option
  val output_of_core : Value.t list -> bookkeeping -> output
  val output_to_core : output -> Value.t list * bookkeeping
  val illegal : output
  val input_of_core : G.input -> input (* an option of the generator, as an input of the learner *)
  val no_input : input (* the input of the random walk where the spec offers none *)
  val alphabet : Spec.t -> input list (* the inputs of the learner for a spec (secret expanded) *)
  val observations : output -> Value.t list
  val keep : input -> output -> bool (* whether a learned transition stays in the model file *)
  val contains_illegal : output -> bool
  val atom_of_input : input -> (string * Value.t) option (* its class and atom *)
  val legacy_models : bool (* whether model files without a header line are read (format 0) *)
  val default_bad_probability : float option (* the default of learn --bad-probability (None: no input outside the spec) *)
end

(* The codec of most plugins: inputs are atoms of a class (None: no input), outputs the observations *)
module Atoms_codec (N : Native.S) = struct
  include Alvie_backend.Sul.Atoms (struct let plugin = N.plugin end) (struct
      type bookkeeping = N.B.bookkeeping [@@deriving sexp]
      let none = N.none
    end)

  let class_of section = Plugin.atoms_of (Lazy.force N.plugin) section
  let input_of_core (i : G.input) : Input.t = Option.map (class_of i.section) ~f:(fun cls -> { Input.cls; atom = i.atom })
  let no_input : Input.t = None

  (* The atoms of the spec's sections, by class *)
  let alphabet (spec : Spec.t) : Input.t list =
    List.concat_map spec.sections ~f:(fun s ->
        match class_of s.name with
        | Some cls -> List.map (Spec.atoms s.body) ~f:(fun atom -> Some { Input.cls; atom })
        | None -> [])
    |> List.dedup_and_sort ~compare:Input.compare

  let observations (o : Output.t) = o.observations
  let keep (i : Input.t) o = Option.is_some i && not (Output.equal o illegal)
  let contains_illegal o = Output.equal o illegal
  let atom_of_input (i : Input.t) = Option.map i ~f:(fun { cls; atom } -> (cls, atom))
  let legacy_models = false
  let default_bad_probability = None
end

module Make_codec (N : Native.S) (Codec : MODEL_CODEC with type bookkeeping = N.B.bookkeeping) = struct
  let plugin () = Lazy.force N.plugin
  let manifest () = (plugin ()).manifest

  module Codec = Codec
  module Sul = Alvie_backend.Sul.Make (N.B) (Codec)
  module I = Codec.Input
  module O = Codec.Output
  module IO = Interop.Interop (I) (O)
  module Rw = Learninglib.Randomwalkoracle.RandomWalkOracle (I) (O) (Sul)
  module Pac = Learninglib.Pacoracle.PACOracle (I) (O) (Sul)
  module Exh = Learninglib.Exhaustiveoracle.ExhaustiveOracle (I) (O) (Sul)
  module L_rw = Learninglib.Lsharp.LSharp (I) (O) (Sul) (Learninglib.Randomwalkoracle.RandomWalkOracle)
  module L_pac = Learninglib.Lsharp.LSharp (I) (O) (Sul) (Learninglib.Pacoracle.PACOracle)
  module L_exh = Learninglib.Lsharp.LSharp (I) (O) (Sul) (Learninglib.Exhaustiveoracle.ExhaustiveOracle)
  module Wm = Learninglib.Wmethodoracle.WMethodOracle (I) (O) (Sul)
  module L_wm = Learninglib.Lsharp.LSharp (I) (O) (Sul) (Learninglib.Wmethodoracle.WMethodOracle)

  let class_of section = Plugin.atoms_of (plugin ()) section

  (* Specs *)

  (* The spec of the files, with the secret expanded; a spec with a secret needs one *)
  let load_spec ~files ~secret : Spec.t =
    let p = plugin () in
    List.iter files ~f:(fun f -> ignore (Errors.require_file ~option:"--spec" f));
    match Spec.parse_files p files with
    | Error ds -> Errors.fail "the spec has %d problem%s:\n%s" (List.length ds) (if List.length ds = 1 then "" else "s") (Diag.list_to_string ds)
    | Ok spec ->
      let has_secret = List.exists spec.sections ~f:(fun s -> Spec.has_secret s.body) in
      (match secret, has_secret with
       | None, true -> Errors.fail "the spec uses the secret (?): give its value with --secret."
       | None, false -> spec
       | Some value, _ ->
         (match Spec.expand_secret p spec ~value with
          | Ok s -> s
          | Error d -> Errors.fail "cannot use %S as the secret: %s" value (Diag.to_string d)))

  let check_variant variant =
    Option.iter variant ~f:(fun v ->
        let vs = List.map (manifest ()).variants ~f:fst in
        if not (List.mem vs v ~equal:String.equal) then
          match vs with
          | [] -> Errors.fail "--variant %s: plugin %s has no variants." v (manifest ()).name
          | _ -> Errors.fail "--variant %s: plugin %s has the variants %s." v (manifest ()).name (Diag.enumerate vs))

  let make_backend ~config ~variant = check_variant variant; N.make ~config ~variant

  (* The generator's state after a history of the learner *)
  module Item = struct
    type t = In of I.t | Out of Value.t list [@@deriving hash, compare, sexp_of]
  end

  module Cache = G.Cache (Item)

  let gen_step gen (st : G.state) : Item.t -> G.state = function
    | Out o -> G.observe gen st o
    | In i ->
      (match st.status with
       | Finished | Invalid -> st
       | Running ->
         let section = G.current st in
         (match Codec.atom_of_input i with
          | Some (cls, atom) when Option.equal String.equal (class_of section) (Some cls) -> G.input gen st { section; atom }
          | _ -> { st with status = Invalid }))

  let input_of_core = Codec.input_of_core

  let options cache (il : I.t list) (ol : O.t list) =
    let rec items il ol acc = match il, ol with
      | i :: il, o :: ol -> items il ol (Item.Out (Codec.observations o) :: Item.In i :: acc)
      | i :: il, [] -> items il [] (Item.In i :: acc)
      | [], _ -> List.rev acc in
    Cache.options cache (Cache.state_of cache (items il ol []))

  let alphabet = Codec.alphabet

  (* Models *)

  let header () = let m = manifest () in Interop.header ~plugin:m.name ~plugin_version:m.version ~core:m.core

  (* A learned model without what the spec does not allow: the transitions that the codec does not keep (the
     illegal inputs: the learner asks for every input in every state), and the states that no transition kept has *)
  let legal_part (m : IO.IIOMealy.t) : IO.IIOMealy.t =
    let transition = Map.filteri m.transition ~f:(fun ~key:(_, i) ~data:(o, _) -> Codec.keep i o) in
    let states = Set.filter m.states ~f:(fun s -> Map.existsi transition ~f:(fun ~key:(s', _) ~data:(_, s'') -> s' = s || s'' = s)) in
    { m with transition; states }

  let write_model file (m : IO.IIOMealy.t) = IO.write_model ~header:(header ()) file (IO.dot_of_t m)

  (* A model of this plugin: the header names it (a model without a header, or of another plugin, is refused) *)
  let read_model ~what file : IO.IIOMealy.t =
    let file = Errors.require_file ~option:what file in
    (match Interop.plugin_of_file file with
     | Some _ -> (try Interop.check_plugin ~plugin:(manifest ()).name file with Interop.Unsupported_format m -> Errors.fail "%s: %s" what m)
     | None when Codec.legacy_models -> () (* a model of an earlier version (format 0) *)
     | None -> Errors.fail "%s (%s) is not a model of ALVIE: its first line is not \"// alvie-model format ...\"." what file);
    try IO.t_of_dot_file IO.IIOMealy.ISet.empty file with
    | Interop.Unsupported_format _ as e -> raise e
    | e -> Errors.fail "cannot read %s (%s): %s" what file (Exn.to_string e)

  (* The models of the comparison, with the hooks derived from the plugin files *)
  module Models (P : sig val secret_values : string list end) = struct
    module H = Ltscompare.Plugin_hooks.Make (struct let plugin = plugin () let secret_values = P.secret_values end)
    module Properties = Ltscompare.Properties.Make (H)
    module C = Properties.C

    let view = Ltscompare.View.make (plugin ())

    let low_classes =
      List.filter_map (plugin ()).sections.sections ~f:(fun s -> match s.role with Attacker -> s.atoms | Victim -> None)

    let input_of (i : I.t) : H.Input.t =
      match Codec.atom_of_input i with
      | Some (cls, atom) -> Atom { cls; low = List.mem low_classes cls ~equal:String.equal; atom }
      | None -> No_input

    (* Each observation of a step is split into its parts (view.yaml), one transition each *)
    let of_mealy (m : IO.IIOMealy.t) : C.IIOMealy.t =
      let states, transition, _ = Map.fold m.transition
          ~init:(m.states, C.IIOMealy.TransitionMap.empty, Set.max_elt_exn m.states)
          ~f:(fun ~key:(s, i) ~data:(o, s') (states, tr, last) ->
              let parts = List.concat_map (Codec.observations o) ~f:(Ltscompare.View.parts view) in
              let n = List.length parts in
              List.foldi parts ~init:(states, tr, last) ~f:(fun idx (states, tr, last) (part, interrupt) ->
                  let start = if idx = 0 then s else last in
                  let stop = if idx = n - 1 then s' else last + 1 in
                  let states = if stop > last then Set.add states stop else states in
                  let input = if interrupt then H.Input.Interrupt else input_of i in
                  (states, Map.add_exn tr ~key:(start, input) ~data:(part, stop), Int.max last stop))) in
      { s0 = 0; states; transition; pred_map = C.IIOMealy.PredMap.empty; input_alphabet = C.IIOMealy.ISet.empty }

    let load ~what file = C.i_lts_of_mealy (of_mealy (read_model ~what file))
  end

  (* Learning *)

  type oracle =
    | Pac of { epsilon : float; delta : float; round_limit : int option }
    | Random_walk of { test_count : int; reset_probability : float }
    | Exhaustive
    | W_method of { extra_states : int; max_tests : int option }

  (* The statistics of the learner: output queries, equivalence queries, resets, steps, dry steps, and the average and
     variance of the length of the equivalence queries *)
  type stats = { queries : int; equivalence_queries : int; resets : int; steps : int; dry_steps : int; avg_length : float; var_length : float }

  type learned = { model : IO.IIOMealy.t; seconds : float; nanoseconds : Int63.t; stats : stats }

  (*
    Learns a model of the backend under the spec. With ~bad_probability p, the oracle offers an input of the whole
    alphabet instead of one that the spec allows with probability p, which it draws before each input (as
    ALVIE/Sancus always did). ~dry skips the learning (a model with one state). The random choices depend only on
    ~seed: learning is deterministic.
  *)
  let learn ?bad_probability ?(dry = false) ~config ~variant ~(spec : Spec.t) ~oracle ~seed () : learned =
    Random.init seed;
    let gen = G.make (plugin ()) spec in
    let cache = Cache.create gen ~step:gen_step in
    let sul = Sul.make ~backend:(make_backend ~config ~variant) ~gen in
    let alphabet = alphabet spec in
    if List.is_empty alphabet then Errors.fail "the spec has no atoms: there is nothing to learn.";
    let pick il ol =
      let bad = match bad_probability with
        | Some p -> Float.(Random.float_range 0.0 1.0 <= p)
        | None -> false in
      if bad then `Next (List.random_element_exn alphabet)
      else match options cache il ol with
        | [] -> `Stop
        | os -> (match List.random_element_exn os with `Stop -> `Stop | `Next i -> `Next (input_of_core i)) in
    let trivial () = IO.IIOMealy.make ~states:(IO.IIOMealy.SSet.singleton 0) ~s0:0 ~input_alphabet:IO.IIOMealy.ISet.empty ~transition:IO.IIOMealy.TransitionMap.empty in
    let start = Time_now.nanoseconds_since_unix_epoch () in
    let model, (queries, equivalence_queries, resets, steps, dry_steps, avg_length, var_length) = match oracle with
      | Pac { epsilon; delta; round_limit } ->
        let o = Pac.make ?round_limit ~epsilon ~delta ~next_input:(fun _ il ol -> pick il ol) () in
        let m = if dry then trivial () else L_pac.lsharp_run o sul alphabet in
        (m, Pac.get_stats o)
      | Random_walk { test_count; reset_probability } ->
        let o = Rw.make ~step_limit:test_count ~reset_prob:reset_probability
            ~next_input:(fun _ il ol -> match pick il ol with `Stop -> Codec.no_input | `Next i -> i) () in
        let m = if dry then trivial () else L_rw.lsharp_run o sul alphabet in
        (m, Rw.get_stats o)
      | Exhaustive ->
        (* every input of the alphabet, until no input, an illegal output, or nothing left *)
        let o = Exh.make ~next_options:(fun _ _ -> List.map alphabet ~f:(fun i -> `Next i))
            ~stop_cond:(fun available is os ->
                List.is_empty available || List.mem is Codec.no_input ~equal:I.equal || List.exists os ~f:Codec.contains_illegal) () in
        let m = if dry then trivial () else L_exh.lsharp_run o sul alphabet in
        (m, Exh.get_stats o)
      | W_method { extra_states; max_tests } ->
        (* the tests of the W-method on the whole alphabet: a test stops at the first illegal output *)
        let o = Wm.make ~extra_states ?max_tests () in
        let m = if dry then trivial () else L_wm.lsharp_run o sul alphabet in
        (m, Wm.get_stats o) in
    let nanoseconds = Int63.(Time_now.nanoseconds_since_unix_epoch () - start) in
    { model = legal_part model; seconds = Int63.to_float nanoseconds /. 1e9; nanoseconds;
      stats = { queries; equivalence_queries; resets; steps; dry_steps; avg_length; var_length } }

  (* Command-line pieces *)

  let spec_flag = Command.Param.(flag "--spec" (one_or_more_as_list string) ~doc:"file the spec (in several files: --spec a --spec b)")
  let secret_flag = Command.Param.(flag "--secret" (optional string) ~doc:"value the value of the secret (?) in the spec")
  let debug_flag = Command.Param.(flag "--debug" no_arg ~doc:" debug-level logging")

  let variant_flag () =
    let vs = (manifest ()).variants in
    Command.Param.(flag "--variant" (optional string)
                     ~doc:(sprintf "name the variant of the system to run (%s)" (match vs with [] -> "this plugin has none" | _ -> String.concat ~sep:", " (List.map vs ~f:fst))))

  let oracle_param =
    let module D = Learninglib.Defaults in
    let oracles = [ ("pac", `Pac); ("randomwalk", `Rw); ("exhaustive", `Exh); ("wmethod", `Wm) ] in
    let%map_open.Command name = flag "--oracle" (optional_with_default (List.Assoc.find_exn oracles ~equal:String.equal D.oracle) (Arg_type.of_alist_exn oracles))
        ~doc:(sprintf "pac|randomwalk|exhaustive|wmethod the equivalence oracle (default: %s)" D.oracle)
    and epsilon = flag "--epsilon" (optional_with_default D.pac_epsilon float) ~doc:(sprintf "e PAC: the error bound (default: %g)" D.pac_epsilon)
    and delta = flag "--delta" (optional_with_default D.pac_delta float) ~doc:(sprintf "d PAC: the confidence bound (default: %g)" D.pac_delta)
    and round_limit = flag "--round-limit" (optional int) ~doc:"n PAC: at most n rounds of equivalence queries"
    and test_count = flag "--test-count" (optional_with_default D.random_walk_steps int)
        ~doc:(sprintf "n random walk: the number of steps of each equivalence query (default: %d)" D.random_walk_steps)
    and reset_probability = flag "--reset-probability" (optional_with_default D.random_walk_reset_probability float)
        ~doc:(sprintf "p random walk: the probability of a reset after each step (default: %g)" D.random_walk_reset_probability)
    and extra_states = flag "--extra-states" (optional_with_default D.wmethod_extra_states int)
        ~doc:(sprintf "k W-method: the system may have up to k more states than the model, which is then exact (default: %d)" D.wmethod_extra_states)
    and max_tests = flag "--max-tests" (optional int) ~doc:"n W-method: stop each equivalence query after n tests, giving up the guarantee (default: no limit)" in
    let check_prob option p = if Float.(p <= 0. || p >= 1.) then Errors.fail "%s must be between 0 and 1 (exclusive), not %g." option p in
    fun () ->
      match name with
      | `Pac -> check_prob "--epsilon" epsilon; check_prob "--delta" delta;
        Option.iter round_limit ~f:(fun n -> if n <= 0 then Errors.fail "--round-limit must be greater than zero.");
        Pac { epsilon; delta; round_limit }
      | `Exh -> Exhaustive
      | `Wm -> if extra_states < 0 then Errors.fail "--extra-states must not be negative.";
        Option.iter max_tests ~f:(fun n -> if n <= 0 then Errors.fail "--max-tests must be greater than zero.");
        W_method { extra_states; max_tests }
      | `Rw -> if test_count <= 0 then Errors.fail "--test-count must be greater than zero.";
        check_prob "--reset-probability" reset_probability;
        Random_walk { test_count; reset_probability }

  let learn_command () =
    Command.basic ~summary:(sprintf "Learn a model of %s under a spec" (manifest ()).name)
      (let%map_open.Command files = spec_flag and secret = secret_flag and variant = variant_flag ()
       and res = flag "--res" (required string) ~doc:"file where to write the model (.dot)"
       and seed = flag "--seed" (optional_with_default Learninglib.Defaults.seed int)
           ~doc:(sprintf "n the seed of the random choices (default: %d; learning is deterministic for a seed)" Learninglib.Defaults.seed)
       and bad_probability = flag "--bad-probability" (optional float)
           ~doc:(sprintf "p the probability that the oracle offers an input of the whole alphabet, not one the spec allows, which tells apart states where the spec allows different inputs (default: %s)"
                   (match Codec.default_bad_probability with Some p -> Float.to_string p | None -> "0, never"))
       and oracle = oracle_param and config = Config.param (manifest ()) and debug = debug_flag in
       fun () ->
         Errors.protect ~debug (fun () ->
             Errors.setup_logs ~debug;
             let oracle = oracle () in
             let bad_probability = match bad_probability with
               | Some p when Float.(p < 0.0 || p > 1.0) -> Errors.fail "--bad-probability must be between 0 and 1 (not %g)." p
               | Some p when Float.(p = 0.0) -> None
               | Some p -> Some p
               | None -> Codec.default_bad_probability in
             let spec = load_spec ~files ~secret in
             ignore (Errors.prepare_directory ~option:"the directory of --res" (Filename.dirname res));
             let l = learn ?bad_probability ~config ~variant ~spec ~oracle ~seed () in
             write_model res l.model;
             printf "Learned a model of %d states and %d transitions in %.1fs (%d queries, %d steps): %s\n"
               (Set.length l.model.states) (Map.length l.model.transition) l.seconds l.stats.queries l.stats.steps res;
             match oracle with
             | W_method { extra_states; max_tests = None } ->
               printf "The model is exact if the system has at most %d more state%s than it, for the inputs of the spec.\n"
                 extra_states (if extra_states = 1 then "" else "s")
             | W_method { max_tests = Some n; _ } ->
               printf "Each equivalence query stopped after %d tests: the model is not guaranteed to be exact.\n" n
             | Pac _ | Random_walk _ | Exhaustive -> ()))

  (* Noninterference *)

  (* what: the options that name the models, for messages *)
  let noninterference ?(what = ("--m1", "--m2", "--m1-baseline", "--m2-baseline")) ~secrets ~tmpdir ~limit ~m1 ~m2 ~baseline () =
    let w1, w2, wb1, wb2 = what in
    let module M = Models (struct let secret_values = secrets end) in
    let a = M.load ~what:w1 m1 and b = M.load ~what:w2 m2 in
    let baseline = Option.map baseline ~f:(fun (b1, b2) -> (M.load ~what:wb1 b1, M.load ~what:wb2 b2)) in
    let name f = String.chop_suffix_if_exists (Filename.basename f) ~suffix:".dot" in
    let count, graph, _ = M.Properties.noninterference ?limit ?baseline ~tmpdir ~names:(name m1, name m2) a b in
    (count, fun file -> Out_channel.with_file file ~f:(fun oc -> M.C.ILTS.Dot.output_graph oc (M.C.ILTS.to_dot graph)))

  let secrets_arg s =
    match String.split s ~on:',' with
    | [ a; b ] when not (String.is_empty a || String.is_empty b) -> [ a; b ]
    | _ -> Errors.fail "--secrets takes the two values of the secret, as s1,s2 (not %S)." s

  let compare_command () =
    Command.basic ~summary:"Find the witnesses that tell apart two models that differ only in the secret (noninterference)"
      ~readme:(fun () -> "Exit status: 0 when there is no witness, 4 when there are, 2 for a mistake in the command or the files.")
      (let%map_open.Command m1 = flag "--m1" (required string) ~doc:"file the model for the first secret"
       and m2 = flag "--m2" (required string) ~doc:"file the model for the second secret"
       and b1 = flag "--m1-baseline" (optional string) ~doc:"file the first model of the baseline (e.g. --variant no-interrupts): its witnesses do not count"
       and b2 = flag "--m2-baseline" (optional string) ~doc:"file the second model of the baseline"
       and secrets = flag "--secrets" (required string) ~doc:"s1,s2 the values of the secret in the two models"
       and witnesses = flag "--witnesses" (required string) ~doc:"file where to write the witness graph (.dot)"
       and tmpdir = flag "--tmpdir" (optional_with_default "/tmp/alvie" string) ~doc:"dir directory for the files of mCRL2 (default: /tmp/alvie)"
       and limit = flag "--cex-limit" (optional int) ~doc:"n stop after n witnesses"
       and debug = debug_flag in
       fun () ->
         let count = Errors.protect ~debug (fun () ->
             Errors.setup_logs ~debug;
             let secrets = secrets_arg secrets in
             let baseline = match b1, b2 with
               | None, None -> None
               | Some a, Some b -> Some (a, b)
               | _ -> Errors.fail "--m1-baseline and --m2-baseline go together." in
             Option.iter limit ~f:(fun n -> if n <= 0 then Errors.fail "--cex-limit must be greater than zero.");
             let tmpdir = Errors.prepare_directory ~option:"--tmpdir" tmpdir in
             ignore (Errors.prepare_directory ~option:"the directory of --witnesses" (Filename.dirname witnesses));
             let count, write = noninterference ~secrets ~tmpdir ~limit ~m1 ~m2 ~baseline () in
             write witnesses;
             printf "%s: %d witness%s (see %s)\n" (if count = 0 then "noninterference holds" else "noninterference does not hold")
               count (if count = 1 then "" else "es") witnesses;
             count) in
         if count > 0 then Stdlib.exit Errors.does_not_hold)

  let property_command () =
    Property_cmd.command ~models:(fun () ->
        let module M = Models (struct let secret_values = [] end) in
        Models { load = M.load; inclusion = M.Properties.inclusion; equivalence = M.Properties.equivalence; formula = M.Properties.formula }) ()

  (* exec *)

  let print_atom (i : G.input) = match class_of i.section with
    | Some cls -> Grammar.print_atom (plugin ()).grammar ~cls i.atom
    | None -> Value.to_string i.atom

  (* Runs the atoms of the file (one per line, as a spec writes them; a line that starts with # is a comment: # can
     be part of an atom, as in the immediates of Sancus, mov #1, r4) from a fresh test *)
  let exec ~config ~variant ~(spec : Spec.t) ~inputs_file =
    let p = plugin () in
    let gen = G.make p spec in
    let backend = make_backend ~config ~variant in
    let sul = Sul.make ~backend ~gen in
    Sul.pre sul;
    let lines = String.split_lines (Errors.read_file ~option:"--inputs" inputs_file) in
    List.iteri lines ~f:(fun n line ->
        let text = String.strip line in
        let text = if String.is_prefix text ~prefix:"#" then "" else text in
        if not (String.is_empty text) then begin
          let st = Sul.generator_state sul in
          let section = G.current st in
          (match st.status with
           | Finished -> Errors.fail "%s:%d: the test has finished (nothing can run after it)." inputs_file (n + 1)
           | Invalid -> Errors.fail "%s:%d: the test is invalid (nothing can run after it)." inputs_file (n + 1)
           | Running -> ());
          let cls = match class_of section with Some c -> c | None -> Errors.fail "%s:%d: section %s takes no atoms." inputs_file (n + 1) section in
          let atom = match Grammar.parse_value p.grammar ~file:inputs_file ~ty:cls text with
            | Ok a -> a
            | Error d ->
              (* The position in the line, on the line of the file *)
              let d = { d with pos = Option.map d.pos ~f:(fun pos -> { pos with line = n + 1 }) } in
              Errors.fail "%s (in %s, which runs atoms of %s)" (Diag.to_string d) section cls in
          let i = { G.section; atom } in
          if not (G.legal gen st i) then
            Errors.fail "%s:%d: the spec does not allow %s here (in %s); it allows: %s." inputs_file (n + 1) text section
              (match G.options gen st with
               | [] -> "nothing (the test has finished)"
               | os -> String.concat ~sep:", " (List.map os ~f:(function `Stop -> "(stop)" | `Next i -> print_atom i)));
          let o = Sul.step sul (input_of_core i) in
          let st' = Sul.generator_state sul in
          printf "%-8s %-16s %s%s\n" section text (String.concat ~sep:"; " (List.map (Codec.observations o) ~f:Value.to_string))
            (match st'.status with
             | Finished -> "  (finished)"
             | Invalid -> "  (invalid)"
             | Running -> if String.equal (G.current st') section then "" else "  -> " ^ G.current st')
        end);
    Sul.post sul

  let exec_command () =
    Command.basic ~summary:"Run a sequence of atoms on the backend and print what it observes"
      ~readme:(fun () -> "The file has one atom per line, as a spec writes them; a line that starts with # is a comment. Each atom runs in the current section, which the observations change as phases.yaml says; the spec must allow it.")
      (let%map_open.Command files = spec_flag and secret = secret_flag and variant = variant_flag ()
       and inputs_file = flag "--inputs" (required string) ~doc:"file the atoms to run"
       and config = Config.param (manifest ()) and debug = debug_flag in
       fun () ->
         Errors.protect ~debug (fun () ->
             Errors.setup_logs ~debug;
             let spec = load_spec ~files ~secret in
             exec ~config ~variant ~spec ~inputs_file))

  (* Fixtures *)

  let fixtures_dir dir =
    match dir with
    | Some d -> Errors.require_directory ~option:"--dir" d
    | None ->
      let m = manifest () in
      (match m.fixtures with
       | None -> Errors.fail "plugin %s declares no fixtures (fixtures: in alvie-plugin.yaml); give a directory with --dir." m.name
       | Some f ->
         (* relative to the plugin's directory (plugins/<name> for a plugin built into a program) *)
         let d = Filename.concat (plugin ()).dir f in
         if Sys_unix.is_directory_exn d then d
         else Errors.fail "the fixtures of plugin %s are in %s, which is not a directory here: run from the directory alvie/code, or give --dir." m.name d)

  type verdict = { fixture : string; passed : bool; summary : string }

  (* Learns the models of the fixture into out, compares them, and checks the verdict *)
  let run_fixture ~base ~out ~tmpdir ~oracle file : verdict =
    let name = String.chop_suffix_if_exists (Filename.basename file) ~suffix:".yaml" in
    let fx = match Fixture_file.load ~file with
      | Ok fx -> fx
      | Error ds -> Errors.fail "the fixture %s has problems:\n%s" file (Diag.list_to_string ds) in
    (* the fixture's values, over those of the command line *)
    let given = fx.config @ List.filter base ~f:(fun (k, _) -> not (List.Assoc.mem fx.config ~equal:String.equal k)) in
    let config = match Config.of_assoc (manifest ()) given with Ok c -> c | Error m -> Errors.fail "%s: config: %s" file m in
    Option.iter fx.baseline ~f:(fun v -> try check_variant (Some v) with Errors.User_error m -> Errors.fail "%s: baseline: %s" file m);
    let files = List.map fx.spec ~f:(Filename.concat (Filename.dirname file)) in
    let model ~secret ~variant =
      let path = Filename.concat out (sprintf "%s-%s%s.dot" name secret (match variant with Some v -> "-" ^ v | None -> "")) in
      let spec = load_spec ~files ~secret:(Some secret) in
      (* as learn does by default: the plugin's inputs outside the spec, and the default seed *)
      write_model path (learn ?bad_probability:Codec.default_bad_probability ~config ~variant ~spec ~oracle ~seed:Learninglib.Defaults.seed ()).model;
      path in
    let s1, s2 = fx.secrets in
    let m1 = model ~secret:s1 ~variant:None and m2 = model ~secret:s2 ~variant:None in
    let baseline = Option.map fx.baseline ~f:(fun v -> (model ~secret:s1 ~variant:(Some v), model ~secret:s2 ~variant:(Some v))) in
    let witnesses = Filename.concat out (name ^ "-witnesses.dot") in
    let count, write = noninterference ~secrets:[ s1; s2 ] ~tmpdir ~limit:None ~m1 ~m2 ~baseline () in
    write witnesses;
    let found = match count with 0 -> "no leak" | 1 -> "a leak (1 witness)" | n -> sprintf "a leak (%d witnesses)" n in
    let passed = match fx.expect with Leak -> count > 0 | No_leak -> count = 0 in
    let expected = match fx.expect with Leak -> "a leak" | No_leak -> "no leak" in
    { fixture = name; passed;
      summary = if passed then found else sprintf "expected %s, found %s: see %s" expected found witnesses }

  let fixtures_command () =
    Command.basic ~summary:"Learn and compare the fixtures of the plugin, and check their verdicts"
      ~readme:(fun () -> "A fixture is a spec with the verdict of noninterference it must give (see the Plugin Files Reference). The options of the backend apply to every fixture, and a fixture's config: overrides them. Exit status: 0 when every fixture gives its verdict, 4 when one does not, 2 for a mistake in the command or the files.")
      (let%map_open.Command names = anon (sequence ("NAME" %: string))
       and dir = flag "--dir" (optional string) ~doc:"dir the directory of the fixtures (default: the plugin's)"
       and out = flag "--out" (optional_with_default "/tmp/alvie/fixtures" string) ~doc:"dir where to write the models, the witnesses and the files of mCRL2 (default: /tmp/alvie/fixtures)"
       and oracle = oracle_param and base = Config.param (manifest ()) and debug = debug_flag in
       fun () ->
         let ok = Errors.protect ~debug (fun () ->
             Errors.setup_logs ~debug;
             let oracle = oracle () in
             let dir = fixtures_dir dir in
             let all = Sys_unix.ls_dir dir |> List.filter ~f:(String.is_suffix ~suffix:".yaml") |> List.sort ~compare:String.compare in
             let chosen = match names with
               | [] -> all
               | _ -> List.map names ~f:(fun n ->
                   let f = if String.is_suffix n ~suffix:".yaml" then n else n ^ ".yaml" in
                   if List.mem all f ~equal:String.equal then f
                   else Errors.fail "there is no fixture %s in %s (fixtures: %s)." n dir
                       (String.concat ~sep:", " (List.map all ~f:(String.chop_suffix_if_exists ~suffix:".yaml")))) in
             if List.is_empty chosen then Errors.fail "there are no fixtures (*.yaml) in %s." dir;
             let out = Errors.prepare_directory ~option:"--out" out in
             let tmpdir = Errors.prepare_directory ~option:"--out" (Filename.concat out "mcrl2") in
             let verdicts = List.map chosen ~f:(fun f ->
                 let v = run_fixture ~base ~out ~tmpdir ~oracle (Filename.concat dir f) in
                 printf "%s %-24s %s\n%!" (if v.passed then "PASS" else "FAIL") v.fixture v.summary;
                 v) in
             let failed = List.count verdicts ~f:(fun v -> not v.passed) in
             printf "%d fixture%s, %d failed (models and witnesses in %s)\n" (List.length verdicts) (if List.length verdicts = 1 then "" else "s") failed out;
             failed = 0) in
         if not ok then Stdlib.exit Errors.does_not_hold)

  (* Conformance: whether the backend keeps the contract of Core (Alvie_backend.Backend), on random tests of a spec *)

  module Backend = Alvie_backend.Backend

  type record = { input : G.input; observations : Value.t list; bookkeeping : N.B.bookkeeping }

  let backend_step gen st (i : G.input) =
    let position = G.position st i.section in
    let st' = G.input gen st i in
    let step = { Backend.programs = G.programs gen st'; section = i.section; position; atom = i.atom; key = lazy (G.key st'); silent = true } in
    (st', step)

  (* Runs a test from pre: the given inputs, then (with choose) more, up to length; returns its steps, and the
     input that the spec no longer allowed, if any *)
  let run_test b gen ?(given = []) ?(choose = fun _ -> None) ~length () =
    N.B.pre b;
    let rec go st given acc n =
      if n >= length then (List.rev acc, None)
      else match st.G.status with
        | Finished | Invalid -> (List.rev acc, None)
        | Running ->
          let opts = List.filter_map (G.options gen st) ~f:(function `Next i -> Some i | `Stop -> None) in
          let next, rest = match given with i :: rest -> (Some i, rest) | [] -> (choose opts, []) in
          match next with
          | None -> (List.rev acc, None)
          | Some i when not (List.mem opts i ~equal:G.equal_input) -> (List.rev acc, Some i)
          | Some i ->
            let st', step = backend_step gen st i in
            let observations, bookkeeping = N.B.step b step in
            go (G.observe gen st' observations) rest ({ input = i; observations; bookkeeping } :: acc) (n + 1) in
    let r = go (G.initial gen) given [] 0 in
    N.B.post b;
    r

  let show_input (i : G.input) = sprintf "%s: %s" i.section (print_atom i)
  let show_obs os = "[" ^ String.concat ~sep:"; " (List.map os ~f:Value.to_string) ^ "]"
  let show_test (t : record list) = String.concat ~sep:"; " (List.map t ~f:(fun r -> show_input r.input))

  (* The first step where two runs of the same inputs observe differently *)
  let first_difference (a : record list) (b : record list) =
    List.zip_with_remainder a b |> fst
    |> List.find_mapi ~f:(fun k (x, y) ->
        if List.equal Value.equal x.observations y.observations then None
        else Some (sprintf "step %d (%s): %s, then %s" (k + 1) (show_input x.input) (show_obs x.observations) (show_obs y.observations)))

  type check = { name : string; doc : string; mutable runs : int; mutable failure : string option; applies : bool }

  let conformance ~config ~variant ~(spec : Spec.t) ~tests ~length ~seed =
    let p = plugin () in
    let gen = G.make p spec in
    let caps = N.B.capabilities in
    let check name doc ?(applies = true) () = { name; doc; runs = 0; failure = None; applies } in
    let c_obs = check "observations" "every step returns observations of observations.yaml, each matched by a phase rule" ()
    and c_phases = check "phases" "the backend's observations never make a legal test invalid" ()
    and c_det = check "determinism" "the same inputs on a new backend observe the same" ()
    and c_reset = check "reset" "after pre, a backend that ran other tests observes as a new one" ()
    and c_branch = check "prefixes" "a test that begins as an earlier one observes the same on that beginning, whatever it does next" ()
    and c_restore = check "restore" "restoring steps (dry steps) and then stepping observes as stepping all along" ~applies:(List.mem caps Backend.Restore ~equal:Backend.equal_capability) ()
    and c_clone = check "clone" "a clone continues as the original would, and does not change it" ~applies:(List.mem caps Backend.Clone ~equal:Backend.equal_capability) () in
    let checks = [ c_obs; c_phases; c_det; c_reset; c_branch; c_restore; c_clone ] in
    let fail c ~test msg = c.runs <- c.runs + 1; if Option.is_none c.failure then c.failure <- Some (sprintf "%s\n      test: %s" msg (show_test test)) in
    let pass c = c.runs <- c.runs + 1 in
    let compare c ~test a b = match first_difference a b with None -> pass c | Some d -> fail c ~test d in
    Random.init seed;
    let choose opts = List.random_element opts in
    let shared = make_backend ~config ~variant in
    let start = Time_now.nanoseconds_since_unix_epoch () in
    let steps = ref 0 in
    let corpus = List.init tests ~f:(fun _ ->
        let t, _ = run_test shared gen ~choose ~length () in
        steps := !steps + List.length t;
        (* observations and phases *)
        let st = ref (G.initial gen) in
        List.iter t ~f:(fun r ->
            let st' = G.input gen !st r.input in
            (match r.observations with
             | [] -> fail c_obs ~test:t (sprintf "%s returned no observation" (show_input r.input))
             | os -> List.iter os ~f:(fun o ->
                 match Observations_file.check p.observations o with
                 | Error m -> fail c_obs ~test:t (sprintf "%s observed %s, which is not a value of observations.yaml: %s" (show_input r.input) (Value.to_string o) m)
                 | Ok () ->
                   let current = G.current st' in
                   if not (List.exists gen.phases ~f:(fun rule -> G.matches rule ~current o)) then
                     fail c_obs ~test:t (sprintf "%s observed %s in %s, and no phase rule matches it (add one with do: [] if it changes nothing)" (show_input r.input) (Value.to_string o) current)
                   else pass c_obs));
            let st'' = G.observe gen st' r.observations in
            (match !st.status, st''.status with
             | Running, Invalid -> fail c_phases ~test:t (sprintf "%s observed %s, which made the test invalid although the spec allowed it" (show_input r.input) (show_obs r.observations))
             | _ -> pass c_phases);
            st := st'');
        t) in
    let seconds = Int63.(to_float (Time_now.nanoseconds_since_unix_epoch () - start)) /. 1e9 in
    let inputs t = List.map t ~f:(fun r -> r.input) in
    List.iter corpus ~f:(fun t ->
        if not (List.is_empty t) then begin
          (* determinism: on two new backends *)
          let fresh1, _ = run_test (make_backend ~config ~variant) gen ~given:(inputs t) ~length () in
          let fresh2, _ = run_test (make_backend ~config ~variant) gen ~given:(inputs t) ~length () in
          compare c_det ~test:t fresh1 fresh2;
          (* reset: the shared backend ran other tests before this one (and since) *)
          compare c_reset ~test:t fresh1 t;
          let again, _ = run_test shared gen ~given:(inputs t) ~length () in
          compare c_reset ~test:t fresh1 again;
          let k = Random.int (List.length t) in
          let prefix = List.take t k in
          (* prefixes: the same beginning, then other choices *)
          let b, _ = run_test shared gen ~given:(inputs prefix) ~choose ~length () in
          compare c_branch ~test:t prefix (List.take b k);
          (* restore: dry steps for the prefix, then real ones *)
          if c_restore.applies then begin
            N.B.pre shared;
            let st = List.fold prefix ~init:(G.initial gen) ~f:(fun st r ->
                let st', step = backend_step gen st r.input in
                N.B.restore shared step ~observations:r.observations r.bookkeeping;
                G.observe gen st' r.observations) in
            let _, rest = List.fold (List.drop t k) ~init:(st, []) ~f:(fun (st, acc) r ->
                let st', step = backend_step gen st r.input in
                let observations, bookkeeping = N.B.step shared step in
                (G.observe gen st' observations, { r with observations; bookkeeping } :: acc)) in
            N.B.post shared;
            compare c_restore ~test:t (List.drop t k) (List.rev rest)
          end;
          (* clone: at the end of the prefix; the clone then the original run the rest *)
          if c_clone.applies then begin
            N.B.pre shared;
            let st = List.fold prefix ~init:(G.initial gen) ~f:(fun st r ->
                let st', step = backend_step gen st r.input in
                ignore (N.B.step shared step);
                G.observe gen st' r.observations) in
            let c = N.B.clone shared in
            let continue b = snd (List.fold (List.drop t k) ~init:(st, []) ~f:(fun (st, acc) r ->
                let st', step = backend_step gen st r.input in
                let observations, bookkeeping = N.B.step b step in
                (G.observe gen st' observations, { r with observations; bookkeeping } :: acc))) |> List.rev in
            let on_clone = continue c in
            let on_original = continue shared in
            N.B.post shared;
            (match first_difference (List.drop t k) on_clone, first_difference (List.drop t k) on_original with
             | Some d, _ -> fail c_clone ~test:t ("the clone: " ^ d)
             | None, Some d -> fail c_clone ~test:t ("the original, after the clone ran: " ^ d)
             | None, None -> pass c_clone)
          end
        end);
    (checks, !steps, seconds)

  let conformance_command () =
    Command.basic ~summary:"Check that the backend keeps the contract of Core, on random tests of a spec"
      ~readme:(fun () -> "Runs random legal tests of the spec, and checks: observations, phases, determinism, reset, prefixes, restore and clone (the last two if the manifest declares the capability). Exit status: 0 when every check passes, 4 when one fails, 2 for a mistake in the command or the files.")
      (let%map_open.Command files = spec_flag and secret = secret_flag and variant = variant_flag ()
       and tests = flag "--tests" (optional_with_default 50 int) ~doc:"n the number of random tests (default: 50)"
       and length = flag "--length" (optional_with_default 30 int) ~doc:"n the most steps of a test (default: 30)"
       and seed = flag "--seed" (optional_with_default 0 int) ~doc:"n the seed of the random tests (default: 0)"
       and config = Config.param (manifest ()) and debug = debug_flag in
       fun () ->
         let ok = Errors.protect ~debug (fun () ->
             Errors.setup_logs ~debug;
             if tests <= 0 then Errors.fail "--tests must be greater than zero.";
             if length <= 0 then Errors.fail "--length must be greater than zero.";
             let spec = load_spec ~files ~secret in
             let m = manifest () in
             let checks, steps, seconds = conformance ~config ~variant ~spec ~tests ~length ~seed in
             printf "Conformance of plugin %s %s: %d random tests, %d steps (%.2f ms a step), seed %d\n" m.name m.version tests steps
               (if steps = 0 then 0. else seconds *. 1000. /. Float.of_int steps) seed;
             List.iter checks ~f:(fun c ->
                 match c.applies, c.failure with
                 | false, _ -> printf "SKIP %-13s %s (the manifest does not declare the capability)\n" c.name c.doc
                 | true, None -> printf "PASS %-13s %s (%d checks)\n" c.name c.doc c.runs
                 | true, Some f -> printf "FAIL %-13s %s\n      %s\n" c.name c.doc f);
             List.for_all checks ~f:(fun c -> Option.is_none c.failure)) in
         if not ok then Stdlib.exit Errors.does_not_hold)

  (*
    A backend that replays a learned model of this plugin, as a native plugin with the same files: e.g. to test the
    learner and its oracles, which should learn the model again. An input that the model has no transition for
    (the spec did not allow it) observes Illegal, and so does everything after it.
  *)
  module Model_native (M : sig val model : IO.IIOMealy.t end) : Native.S = struct
    let plugin = N.plugin

    module B = struct
      type t = { mutable state : int option }
      type bookkeeping = N.B.bookkeeping [@@deriving sexp]

      let capabilities = Backend.[ Restore; Clone ]
      let illegal = [ Value.Node ("Illegal", []) ]
      let pre t = t.state <- Some M.model.s0
      let post _ = ()
      let clone t = { state = t.state }

      let step t (s : Backend.step) =
        match t.state with
        | Some q ->
          (match Map.find M.model.transition (q, input_of_core { G.section = s.section; atom = s.atom }) with
           | Some (o, q') -> t.state <- Some q'; Codec.output_to_core o
           | None -> t.state <- None; (illegal, N.none))
        | None -> (illegal, N.none)

      let restore t s ~observations:_ _ = ignore (step t s)
    end

    let none = N.none
    let make ~config:_ ~variant:_ = { B.state = Some M.model.s0 }
  end
end

(* The commands of most plugins, with Atoms_codec *)
module Make (N : Native.S) = Make_codec (N) (Atoms_codec (N))

(* The commands of the plugin, as a group: alvie <plugin> learn|compare|property|exec|conformance|fixtures, or the
   ones of only *)
module type COMMANDS = sig
  val manifest : unit -> Manifest_file.t
  val learn_command : unit -> Command.t
  val compare_command : unit -> Command.t
  val property_command : unit -> Command.t
  val exec_command : unit -> Command.t
  val conformance_command : unit -> Command.t
  val fixtures_command : unit -> Command.t
end

(* The commands of a runner (Make or Make_codec), or the ones of only *)
let group ?only ?summary (module R : COMMANDS) =
  let m = R.manifest () in
  let all = [ ("learn", R.learn_command); ("compare", R.compare_command); ("property", R.property_command);
              ("exec", R.exec_command); ("conformance", R.conformance_command); ("fixtures", R.fixtures_command) ] in
  let chosen = match only with None -> all | Some names -> List.filter all ~f:(fun (n, _) -> List.mem names n ~equal:String.equal) in
  Command.group ~summary:(Option.value summary ~default:(sprintf "Learn and compare models of %s (plugin %s %s)" m.name m.name m.version))
    (List.map chosen ~f:(fun (n, c) -> (n, c ())))

let commands ?only ?summary (module N : Native.S) = group ?only ?summary (module Make (N))
