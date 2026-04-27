open Core
open Sancus

(* open Attacker
open Enclave *)

let spec_parse_or_fail spec =
  match Testdl.Parser.parse_spec spec with
  | Result.Ok r -> r
  | Result.Error e -> failwith e

let command () =
  let dbg = true in
  (* let commit = "ef753b6" in *)
  let tmpdir = "/home/ubuntu/sancus-learn/tmpfast" in
  let sancus_core_gap_dir = "/home/ubuntu/sancus-learn/sancus-core-gap" in
  (* let limit = 100000 in *)
  let enclave_spec_fn = "/home/ubuntu/sancus-learn/spec-lib/enclave-complete.etdl" in
  let attacker_spec_fn = "/home/ubuntu/sancus-learn/spec-lib/passive.atdl" in
  Random.init 0;
  Logs.set_reporter (Logs_fmt.reporter ());
  (if dbg then Logs.set_level (Some Logs.Debug)
  else Logs.set_level (Some Logs.App));
  let cwd = Sys_unix.getcwd () in
  Logs.debug (fun m -> m "Current directory: %s" cwd);
  (* Create tmpdir if not present *)
  (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
  let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
  (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
  (* Basic sanity checks on the repo *)
  assert (Sys_unix.file_exists_exn sancus_core_gap_dir);
  assert (Sys_unix.is_directory_exn sancus_core_gap_dir);
  (* We are now ready to
      load the spec
  *)
  let enclave_spec_str = In_channel.read_all enclave_spec_fn in
  let attacker_spec_str = In_channel.read_all attacker_spec_fn in
  Logs.debug (fun m -> m "Enclave spec: %s" enclave_spec_str);
  Logs.debug (fun m -> m "Attacker spec: %s" attacker_spec_str);
  let complete_spec = spec_parse_or_fail (enclave_spec_str ^ " " ^ attacker_spec_str) in
  let (enclave_spec, _, _, _) = complete_spec in
  Logs.debug (fun p -> p "Enclave S-Exp:\n%s" (Sexp.to_string_hum ~indent:2 (Testdl.sexp_of_enclave_t enclave_spec)));
  let spec_dfa = Inputgen.build_spec_dfa complete_spec in
  (* initialize the interface with the processor's implementation *)
  (* let sul =
    Sancus.Verilog.make
      ~workingdir:cwd
      ~tmpdir:tmpdir
      ~basename:"generic"
      ~verilog_compile: (cwd ^ "/../scripts/verilog_compile")
      ~get_symbolpos: (cwd ^ "/../scripts/get_symbolpos.sh")
      ~pmem_elf:"pmem.elf"
      ~pmem_script:(cwd ^ "/../scripts/build_pmem")
      ~simulate_script:(cwd ^ "/../scripts/simulate")
      ~submitfile:(cwd ^ "/../src/submit.f")
      ~sancus_repo:sancus_core_gap_dir
      ~sancus_master_key:"cafe"
      ~commit:commit
      ~templatefile:(cwd ^ "/../src/generic_template.s43")
      ~filledfile:"generic.s43"
      ~dumpfile:"tb_openMSP430.vcd"
      ~initial_spec:spec_dfa
      () in *)
      let in_sexp = "((IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))(IAttacker(CJmpIn enc_s))(IEnclave(CInst I_NOP))(IEnclave(CInst(I_ADD(S_IMM 1)(D_R(R 4)))))(IEnclave(CInst(I_ADD(S_IMM 1)(D_R(R 4)))))(IEnclave(CInst(I_MOV(S_IMM 42)(D_R(R 5)))))(IEnclave(CInst(I_MOV(S_IMM 1)(D_AMP_MEM unprot_mem))))(IEnclave(CInst(I_MOV(S_IMM 42)(D_R(R 5)))))(IEnclave(CInst(I_MOV(S_IMM 1)(D_AMP_MEM unprot_mem))))(IEnclave(CInst(I_MOV(S_IMM 1)(D_AMP_MEM unprot_mem))))(IEnclave(CInst(I_ADD(S_IMM 1)(D_R(R 4)))))(IEnclave(CInst(I_MOV(S_IMM 1)(D_AMP_MEM unprot_mem))))(IEnclave(CInst(I_MOV(S_IMM 42)(D_R(R 5)))))(IEnclave(CInst I_DINT)))" in
      let out_sexp = "(OSilent OJmpIn(OTime 1)(OTime 1)(OTime 1)(OTime 2)(OTime 4)(OTime 2)(OTime 4)(OTime 4)(OTime 1)(OTime 4)(OTime 2)(OTime 1))" in
      let il = List.t_of_sexp Input.t_of_sexp (Sexp.of_string in_sexp) in
      let ol = List.t_of_sexp Output_internal.t_of_sexp (Sexp.of_string out_sexp) in
        let st = Time_float.now () in
          let i = match Inputgen.generate_next spec_dfa il ol with `Next i -> i | _ -> failwith "Should never happen!" in
          let et = Time_float.now () in
          Logs.debug (fun p -> p "Inputgen.generate_next: %s" (Time_float.Span.to_string (Time_float.diff et st)));
        let st = Time_float.now () in
          ignore (Inputgen.matchable spec_dfa i il ol);
          let et = Time_float.now () in
          Logs.debug (fun p -> p "Inputgen.matchable: %s" (Time_float.Span.to_string (Time_float.diff et st)))


let () = ignore (command ())


