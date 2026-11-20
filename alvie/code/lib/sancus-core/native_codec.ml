(*
  ALVIE/Sancus for the commands of ALVIE/Core: its plugin files and its codec, whatever runs the programs. Native
  adds the backend on the simulator, Wasm_target the backend on the simulator in WebAssembly.
*)

open Core

let plugin = Generic_inputgen.plugin

module B = Step_sul.Backend

let none = ([], 0)

(*
  The codec of ALVIE/Sancus for the commands of Core (Alvie_cli.Runner.Make_codec): the learner works on the types
  of Sancus (Input.t, Output_internal.t), as learn.exe always did, so that models keep their format and learn the
  same. The alphabet is that of learn.exe: no input, then the atoms of isr, prepare and cleanup (each section's in
  order, without merging them), then those of the enclave.
*)
module Codec = struct
  type bookkeeping = B.bookkeeping

  module Input = Input
  module Output = Output_internal

  type input = Input.t
  type output = Output.t

  let input_to_core = Step_sul.Codec.input_to_core
  let output_of_core = Step_sul.Codec.output_of_core
  let output_to_core = Step_sul.Codec.output_to_core
  let illegal = Step_sul.Codec.illegal

  let input_of_core (i : Alvie_inputgen.Generator.input) : Input.t =
    match Alvie_plugin.Plugin.atoms_of (Lazy.force plugin) i.section with
    | Some cls -> Generic_inputgen.input_of_atom ~cls i.atom
    | None -> INoInput

  let no_input = Input.INoInput

  let alphabet (spec : Alvie_plugin.Spec.t) : Input.t list =
    match Atom_value.to_test_spec spec with
    | Error m -> failwithf "Sancus: the spec cannot be simulated: %s" m ()
    | Ok (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) ->
      let attacker = List.fold [ isr; prepare; cleanup ] ~init:[] ~f:(fun acc b -> acc @ Set.to_list (Attacker.Attacker.get_atoms b)) in
      Input.INoInput :: List.map attacker ~f:(fun a -> Input.IAttacker a) @ List.map (Set.to_list (Enclave.Enclave.get_atoms enclave)) ~f:(fun i -> Input.IEnclave i)

  let observations ((ol, _, _) : Output.t) = List.map ol ~f:Generic_inputgen.observation

  (* as learn.exe's model: no INoInput, and no output that is only OIllegal *)
  let keep (i : Input.t) ((ol, _, _) : Output.t) =
    match i, ol with
    | INoInput, _ | _, [ Output_internal.OIllegal ] -> false
    | _ -> true

  let contains_illegal ((ol, _, _) : Output.t) = List.mem ol Output_internal.OIllegal ~equal:Output_internal.equal_element_t

  let atom_of_input (i : Input.t) =
    match Generic_inputgen.class_of_input i, Generic_inputgen.atom_of_input i with
    | Some cls, Some atom -> Some (cls, atom)
    | _ -> None

  let legacy_models = true

  (* as learn.exe (--bad-probability 0.20): for Sancus, learning needs these inputs to finish (B3 on ef753b6: 3
     minutes with them, more than 30 without) *)
  let default_bad_probability = Some 0.20
end
