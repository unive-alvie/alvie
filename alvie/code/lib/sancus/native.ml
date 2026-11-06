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

let make ~config ~variant =
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
    ()
