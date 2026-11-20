(*
  ALVIE/Sancus on the simulator compiled to WebAssembly (alvie/web/sim), for a browser build of ALVIE: the target
  of Step that builds the program of a step with Msp430_asm, runs it on the testbench in WebAssembly, and analyses
  its VCD trace as the simulator's (Step.analyse_dump).

  The program does not know how to reach the simulator: the host does (see host), e.g. the JavaScript of the page or
  of Node that loaded the simulator of the commit. It also gives the files that the programs of the commit need
  (pmem_defs.asm, sancus_macros.asm, pmem.x, pmem.sh and the template), which the native ALVIE makes with the
  toolchain on its first step; this target writes them into the temporary directory and never runs the toolchain.
*)

open Core

type host = {
  (* The files of the programs of the commit, as (name, text) *)
  files : commit:string -> (string * string) list;
  (* Runs the program in the file mem (a memory file, Msp430_asm.mem_file) on the simulator of the commit and writes
     its VCD trace in the file vcd: the status of scripts/simulate (0 success, 1 the stimulus did not complete,
     2 timeout, 3 another failure). The files are in the file system of the program (Node's, or the page's), so that
     the program and the trace do not go through strings. *)
  run : commit:string -> mem:string -> vcd:string -> int;
}

(* The host of this program: set it before making a backend *)
let host : host option ref = ref None

let the_host () =
  match !host with
  | Some h -> h
  | None -> failwith "Sancus: this build runs the simulator in WebAssembly, and its host has not given it"

let run_step ~commit (cfg : Step.cfg_t) =
  Step.invalidate_symtab ();
  match Step.assemble_native cfg with
  | None -> failwith "Sancus: the assembler of ALVIE does not accept the program of the step, and this build has no toolchain"
  | Some img ->
    let mem = cfg.tmpdir ^ "/pmem.mem" in
    Prof.time "sul.ihex2mem" (fun () -> Out_channel.write_all mem ~data:(Msp430_asm.mem_file ~mem_size:(Step.pmem_size cfg) img));
    let status = Prof.time "sul.simulate" (fun () -> (the_host ()).run ~commit ~mem ~vcd:cfg.dumpfile) in
    if status = 1 then failwith "Simulator: Stimulus did not complete!";
    if status = 3 then failwith "Simulator: Unexpected error :(";
    let dump = Prof.time "sul.vcd_parse" (fun () -> Vcd.vcd ~signals:Step.analysed_signals cfg.dumpfile) in
    (* As on the simulator: status 2 is a timeout, i.e., the step may diverge *)
    fun labels -> Step.analyse_dump (status = 2) cfg labels dump

(* The backend of Step on the simulator in WebAssembly of commit, with its files in tmpdir *)
let make_step ~commit ~tmpdir ~ignore_interrupts ~collapse_reentries : Step.t =
  Step.mkdir_p tmpdir;
  List.iter ((the_host ()).files ~commit) ~f:(fun (name, text) -> Out_channel.write_all (tmpdir ^ "/" ^ name) ~data:text);
  (* The files are those of the setup of build_pmem: Step.assemble_native needs its marker *)
  Out_channel.write_all (tmpdir ^ "/.build_pmem_setup_done") ~data:"";
  ref (Step.make_cfg_t
         ~workingdir:tmpdir ~tmpdir ~basename:"generic" ~get_symbolpos:"" ~pmem_script:"" ~simulate_script:""
         ~templatefile:(tmpdir ^ "/generic_template.s43") ~pmem_elf:(tmpdir ^ "/pmem.elf")
         ~filledfile:(tmpdir ^ "/generic.s43") ~dumpfile:(tmpdir ^ "/tb_openMSP430.vcd")
         ~sim_cycle_ratio:500 ~input_history:[] ~output_history:[] ~left_labels:[] ~last_inst_number:0
         ~ignore_interrupts ~collapse_reentries ~reentries:[] ~spec_key:""
         ~target:(Other { name = "wasm"; boot = []; run = run_step ~commit })
         ())

(* ALVIE/Sancus for the commands of Core (as Native), on the simulator in WebAssembly. The parameters are those of
   plugins/sancus/alvie-plugin.yaml; sancus (the checkout of sancus-core-gap) is not used: the host has the
   simulators. *)
module Native = struct
  include Native_codec

  let make ~config ~variant =
    let get k = match List.Assoc.find config ~equal:String.equal k with Some v -> v | None -> failwithf "Sancus: no value for %s" k () in
    let ignore_interrupts = match variant with
      | None -> false
      | Some "no-interrupts" -> true
      | Some v -> failwithf "Sancus: unknown variant %S (expected no-interrupts)" v () in
    if not (String.equal (get "sancus-master-key") "cafe") then
      failwith "Sancus: the simulators in WebAssembly are built with the key cafe";
    let tmpdir = String.rstrip (get "tmpdir") ~drop:(Char.equal '/') ^ "/wasm-" ^ get "commit" in
    make_step ~commit:(get "commit") ~tmpdir ~ignore_interrupts
      ~collapse_reentries:(not (String.equal (get "keep-repeated-reentries") "true"))
end
