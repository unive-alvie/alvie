(* alvie exec (exec.exe) on the simulator: see Sancus_cmd.Exec_cmd *)
open Core

include Sancus_cmd.Exec_cmd.Make (struct
    let native = true

    let make_sul ~spec ~sancus ~sancus_master_key ~commit ~tmpdir ~ignore_interrupts =
      let cwd = Sys_unix.getcwd () in
      Sancus.Verilog.make ~workingdir:cwd ~tmpdir ~basename:"generic" ~verilog_compile:(cwd ^ "/../scripts/verilog_compile")
        ~get_symbolpos:(cwd ^ "/../scripts/get_symbolpos.sh") ~pmem_elf:"pmem.elf" ~pmem_script:(cwd ^ "/../scripts/build_pmem")
        ~simulate_script:(cwd ^ "/../scripts/simulate") ~submitfile:(cwd ^ "/../src/submit.f") ~sancus_repo:sancus
        ~sancus_master_key ~commit ~templatefile:(cwd ^ "/../src/generic_template.s43") ~filledfile:"generic.s43"
        ~dumpfile:"tb_openMSP430.vcd" ~spec ~ignore_interrupts ()

    let link_dump sul ~tmpdir =
      ignore (Sys_unix.command (sprintf "rm -f %s/tb_openMSP430.vcd" tmpdir));
      ignore (Sys_unix.command (sprintf "ln -sr %s %s/tb_openMSP430.vcd" (Sancus.Verilog.dumpfile sul) tmpdir))
  end)
