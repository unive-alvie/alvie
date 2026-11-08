(*
  The input generator of ALVIE/Core (Alvie_inputgen.Generator) on the Sancus types: learn.exe gives it histories of
  Input.t and Output_internal.t, as it gave them to Inputgen, and gets the options as Input.t.

  The plugin files of plugins/sancus are embedded in the executables (sancus_plugin_files.ml), so that learning does
  not depend on where it runs. An attacker input belongs to the current section (isr, prepare or cleanup), as in
  Inputgen; an input of the other class than the current section's makes the test invalid, as there.

  Until the backend works on values (M4), this module translates; the translations and the states of the prefixes
  of histories are cached, so a step costs about the same as with Inputgen.
*)

open Core
module V = Alvie_plugin.Value
module G = Alvie_inputgen.Generator

let plugin =
  lazy (match Alvie_plugin.Plugin.load_embedded ~dir:"plugins/sancus" Sancus_plugin_files.files with
      | Ok p -> p
      | Error es -> failwith ("the embedded Sancus plugin files do not load (a bug):\n" ^ Alvie_plugin.Diag.list_to_string es))

(* Observations *)

let payload_fields (p : Output_internal.payload_t) =
  [ ("k", V.Int p.k); ("gie", V.Bool p.gie); ("umem_val", V.Int p.umem_val); ("reg_val", V.Int p.reg_val);
    ("timerA_counter", V.Int p.timerA_counter); ("mode", V.Sym (Output_internal.show_mode_t p.mode)) ]

let payload p = V.Node ("payload", payload_fields p)

let observation (e : Output_internal.element_t) : V.t =
  match e with
  | OMaybeDiverge -> V.Node ("Diverge", [])
  | OIllegal -> V.Node ("Illegal", [])
  | OUnsupported -> V.Node ("Unsupported", [])
  | OReset -> V.Node ("Reset", [])
  | OSilent -> V.Node ("Silent", [])
  | OJmpIn p -> V.Node ("JmpIn", payload_fields p)
  | OJmpOut p -> V.Node ("JmpOut", payload_fields p)
  | OReti p -> V.Node ("Reti", payload_fields p)
  | OTime p -> V.Node ("Time", payload_fields p)
  | OJmpOut_Handle (p, p') -> V.Node ("JmpOut_Handle", [ ("time", payload p); ("handle", payload p') ])
  | OTime_Handle (p, p') -> V.Node ("Time_Handle", [ ("time", payload p); ("handle", payload p') ])

let payload_of_fields fields : Output_internal.payload_t =
  let get name = List.Assoc.find_exn fields ~equal:String.equal name in
  let int name = match get name with V.Int i -> i | v -> failwithf "Generic_inputgen: %s is not an integer: %s" name (V.to_string v) () in
  { k = int "k"; gie = (match get "gie" with V.Bool b -> b | _ -> failwith "Generic_inputgen: gie");
    umem_val = int "umem_val"; reg_val = int "reg_val"; timerA_counter = int "timerA_counter";
    mode = (match get "mode" with V.Sym "PM" -> PM | V.Sym "UM" -> UM | _ -> failwith "Generic_inputgen: mode") }

(* The inverse of observation *)
let element_of_observation (v : V.t) : Output_internal.element_t =
  let payload = function V.Node ("payload", fields) -> payload_of_fields fields | v -> failwithf "Generic_inputgen: not a payload: %s" (V.to_string v) () in
  match v with
  | V.Node ("Diverge", []) -> OMaybeDiverge
  | V.Node ("Illegal", []) -> OIllegal
  | V.Node ("Unsupported", []) -> OUnsupported
  | V.Node ("Reset", []) -> OReset
  | V.Node ("Silent", []) -> OSilent
  | V.Node ("JmpIn", fields) -> OJmpIn (payload_of_fields fields)
  | V.Node ("JmpOut", fields) -> OJmpOut (payload_of_fields fields)
  | V.Node ("Reti", fields) -> OReti (payload_of_fields fields)
  | V.Node ("Time", fields) -> OTime (payload_of_fields fields)
  | V.Node ("JmpOut_Handle", [ ("time", t); ("handle", h) ]) -> OJmpOut_Handle (payload t, payload h)
  | V.Node ("Time_Handle", [ ("time", t); ("handle", h) ]) -> OTime_Handle (payload t, payload h)
  | v -> failwithf "Generic_inputgen: not a Sancus observation: %s" (V.to_string v) ()

(* Inputs *)

let class_of_input (i : Input.t) = match i with IAttacker _ -> Some "attacker" | IEnclave _ -> Some "enclave" | INoInput -> None

let atom_of_input = Memo.general ~hashable:Hashtbl.Poly.hashable (fun (i : Input.t) ->
    match i with
    | IAttacker a -> Some (Atom_value.of_attacker a)
    | IEnclave a -> Some (Atom_value.of_enclave a)
    | INoInput -> None)

let input_of_atom ~cls (v : V.t) : Input.t =
  match cls with
  | "attacker" -> IAttacker (Result.ok_or_failwith (Atom_value.to_attacker v))
  | "enclave" -> IEnclave (Result.ok_or_failwith (Atom_value.to_enclave v))
  | c -> failwithf "Generic_inputgen: unknown atom class %s" c ()

module Item = struct
  type t = In of Input.t | Out of Output_internal.t [@@deriving hash, ord, sexp_of]
end

module C = G.Cache (Item)

type t = { gen : G.t; cache : C.cache }

let step (gen : G.t) (st : G.state) (item : Item.t) : G.state =
  match item with
  | Out (ol, _, _) -> G.observe gen st (List.map ol ~f:observation)
  | In i ->
    (match st.status with
     | Finished | Invalid -> st
     | Running ->
       let section = G.current st in
       let cls = Map.find gen.classes section in
       (match class_of_input i, atom_of_input i with
        | Some c, Some atom when Option.equal String.equal (Some c) cls -> G.input gen st { section; atom }
        | _ -> { st with status = Invalid }))

(* The generator of a spec parsed with plugins/sancus (with its constraints), whose secret is already expanded *)
let make_of_spec (spec : Alvie_plugin.Spec.t) : t =
  let gen = G.make (Lazy.force plugin) spec in
  { gen; cache = C.create gen ~step }

(* A spec of testdl.ml as a spec of plugins/sancus (without constraints) *)
let spec_of_test_spec (spec : Testdl.test_spec_t) : Alvie_plugin.Spec.t =
  let sections = List.map (Atom_value.of_test_spec spec) ~f:(fun (name, body) ->
      { Alvie_plugin.Spec.name; body; pos = { file = "<spec>"; line = 1; col = 1 } }) in
  { sections; constraints = [] }

(* The generator of a spec of testdl.ml whose secret is already expanded *)
let make (spec : Testdl.test_spec_t) : t = make_of_spec (spec_of_test_spec spec)

let intersperse (il : Input.t list) (ol : Output_internal.t list) =
  let rec go il ol acc =
    match il, ol with
    | [], [] -> List.rev acc
    | i :: il, [] -> go il [] (Item.In i :: acc)
    | [], o :: ol -> go [] ol (Item.Out o :: acc)
    | i :: il, o :: ol -> go il ol (Item.Out o :: Item.In i :: acc) in
  go il ol []

(* As Inputgen.get_options: the options after the history (il, ol), which have the same length *)
let get_options t (il : Input.t list) (ol : Output_internal.t list) : [ `Stop | `Next of Input.t ] list =
  let e = C.state_of t.cache (intersperse il ol) in
  List.map (C.options t.cache e) ~f:(function
      | `Stop -> `Stop
      | `Next (i : G.input) -> `Next (input_of_atom ~cls:(Map.find_exn t.gen.classes i.section) i.atom))

(* As Inputgen.generate_next *)
let generate_next
    ?(choose = fun _ _ options -> if List.is_empty options then `Stop else List.random_element_exn options)
    t il ol : [ `Stop | `Next of Input.t ] =
  choose il ol (get_options t il ol)

(* The section of the test after the history, for messages *)
let current_section t il ol = G.current (C.state_of t.cache (intersperse il ol)).st
