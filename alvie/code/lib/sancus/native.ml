(*
  ALVIE/Sancus as a native plugin of ALVIE/Core (Alvie_backend.Native.S): the files of plugins/sancus and the
  simulator, for Core's generic commands (alvie sancus conformance and fixtures).

  The backend is built as learn.exe builds it, from the configuration parameters of the manifest; like learn.exe,
  it runs from alvie/code (the scripts and the template are in ../scripts and ../src). The variant no-interrupts
  ignores the interrupts of the timer.

  learn.exe and fa.exe keep the Sancus types (Input, Output_internal) and the format of the checked-in models;
  the generic commands work on values, and their models are of the generic format.
*)

open Core

let plugin = Generic_inputgen.plugin

module B = Verilog.Backend

let none = ([], 0)

(* The backend for the configuration and the variant, on the simulator or on target (another plugin's, see
   Simulator.target): config has the parameters of plugins/sancus/alvie-plugin.yaml *)
let make_with ?target ~config ~variant () =
  let get k = match List.Assoc.find config ~equal:String.equal k with Some v -> v | None -> failwithf "Sancus: no value for %s" k () in
  let ignore_interrupts = match variant with
    | None -> false
    | Some "no-interrupts" -> true
    | Some v -> failwithf "Sancus: unknown variant %S (expected no-interrupts)" v () in
  let cwd = Sys_unix.getcwd () in
  let tmpdir = String.rstrip (get "tmpdir") ~drop:(Char.equal '/') in
  Core_unix.mkdir_p tmpdir;
  Simulator.make
    ~workingdir:cwd ~tmpdir ~basename:"generic"
    ~verilog_compile:(cwd ^ "/../scripts/verilog_compile")
    ~get_symbolpos:(cwd ^ "/../scripts/get_symbolpos.sh")
    ~pmem_elf:"pmem.elf"
    ~pmem_script:(cwd ^ "/../scripts/build_pmem")
    ~simulate_script:(cwd ^ "/../scripts/simulate")
    ~submitfile:(cwd ^ "/../src/submit.f")
    ~sancus_repo:(get "sancus") ~sancus_master_key:(get "sancus-master-key") ~commit:(get "commit")
    ~templatefile:(cwd ^ "/../src/generic_template.s43")
    ~filledfile:"generic.s43" ~dumpfile:"tb_openMSP430.vcd"
    ~ignore_interrupts
    ~collapse_reentries:(not (String.equal (get "keep-repeated-reentries") "true"))
    ?target
    ()

let make ~config ~variant = make_with ~config ~variant ()

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

  let input_to_core = Verilog.Codec.input_to_core
  let output_of_core = Verilog.Codec.output_of_core
  let output_to_core = Verilog.Codec.output_to_core
  let illegal = Verilog.Codec.illegal

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
end
