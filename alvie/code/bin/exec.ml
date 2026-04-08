open Core
open Sancus

open Enclave

let spec_parse_or_fail spec =
  match Testdl.Parser.parse_spec spec with
  | Result.Ok r -> r
  | Result.Error e -> failwith e

let command =
  Command.basic
    ~summary:"Runs the given raw input on the specified version of Sancus with the given SUL configuration"
    (let%map_open.Command
     dbg =
      flag
         "--debug"
         no_arg
         ~doc:"Enables debug-level logging"
      and sexp_fn =
      flag
      "--sexp-input"
      (required string)
      ~doc:"filename S-exp representing the raw input for the simulator"
      and enclave_spec_fn =
      flag
         "--encl-spec"
         (required string)
         ~doc:"filename Enclave specification file, using the TestDL language"
     and attacker_spec_fn =
      flag
        "--att-spec"
        (required string)
        ~doc:"filename Attacker specification file, using the TestDL language"
     and tmpdir =
      flag
        "--tmpdir"
        (required string)
        ~doc:"directory Temporary directory where intermediate results will be stored"
     and sancus_core_gap_dir =
      flag
        "--sancus"
        (required string)
        ~doc:"directory Directory where the sancus-core-gap repository was cloned"
     and sancus_master_key =
      flag
        "--sancus-master-key"
        (optional_with_default "cafe" string)
        ~doc:"key A hex number to be used as the master key when building the processor (default: cafe)"
     and commit =
      flag
        "--commit"
        (optional_with_default "ef753b6" string)
        ~doc:"checksum/label Checksum/label of the commit for which we want to learn the Mealy model (default: ef753b6, i.e., the version w/o the Mind the Gap mitigations)"
    and secret =
      flag
        "--secret"
        (optional string)
        ~doc:"value This is the value of the secret. It will be substituted inside the enclave."
    and ignore_interrupts =
      flag
        "--ignore-interrupts"
        no_arg
        ~doc:"Ignores *any* interrupt-scheduling actions from the attacker (i.e., timer_enable)."
      in
     fun () ->
        Random.init 0;
        Logs.set_reporter (Logs_fmt.reporter ());
        (if dbg then Logs.set_level (Some Logs.Debug)
        else Logs.set_level (Some Logs.App));
        let cwd = Sys_unix.getcwd () in
        Logs.info (fun m -> m "Current directory: %s" cwd);
        (* Create tmpdir if not present *)
        (* If the last char of tmpdir is /, remove it. It causes problems to the Verilog compiler :( *)
        let tmpdir = if Char.equal tmpdir.[String.length tmpdir - 1] '/' then String.drop_suffix tmpdir 1 else tmpdir in
        (match Sys_unix.file_exists tmpdir with | `No -> Core_unix.mkdir_p tmpdir | _ -> ());
        (* Basic sanity checks on the repo *)
        assert (Sys_unix.file_exists_exn sancus_core_gap_dir);
        assert (Sys_unix.is_directory_exn sancus_core_gap_dir);
        (* We are now ready to load the spec *)
        let enclave_spec_str = In_channel.read_all enclave_spec_fn in
        let attacker_spec_str = In_channel.read_all attacker_spec_fn in
        Logs.info (fun m -> m "Enclave spec: %s" enclave_spec_str);
        Logs.info (fun m -> m "Attacker spec: %s" attacker_spec_str);
        let spec_w_secret = spec_parse_or_fail (enclave_spec_str ^ " " ^ attacker_spec_str) in
        let (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) = spec_w_secret in
        (* Secret must be expanded *)
        let enclave = match secret with | None -> assert (not (Enclave.has_secret enclave)); enclave | Some secret -> Enclave.expand_secret secret enclave in
        let complete_spec = let open Testdl in (Enclave enclave, ISR isr, Prepare prepare, Cleanup cleanup) in
        let spec_dfa = Inputgen.build_spec_dfa complete_spec in
        let tmp = Input.IEnclave (Enclave.CIfZ ([CRst; CInst (I_NOP)], [CInst (I_NOP); CRst])) in
        (* let tmp = Input.IEnclave (Enclave.CInst (I_MOV (S_AMP "data_s", D_R (R 4)))) in *)
        Logs.debug (fun p -> p "tmp: %s" (Sexp.to_string (Sancus.Input.sexp_of_t tmp)));
        (* let input_str = "(
          (IAttacker(CInst(I_MOV(S_IMM 8)(D_R(R 2)))))
          (IAttacker(CInst(I_MOV(S_IMM 4)(D_AMP_MEM TACTL))))
          (IAttacker(CInst(I_MOV(S_IMM 100)(D_AMP_MEM TACCR0))))
          (IAttacker(CInst(I_MOV(S_IMM 530)(D_AMP_MEM TACTL))))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
        )" in *)
        (* let input_str = "(
          (IAttacker(CTimerEnable 0))
          (IAttacker(CInst(I_MOV(S_IMM 1)(D_R(R 4)))))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))(IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_MOV(S_IMM 0)(D_AMP_MEM data_s))))
          (IAttacker(CTimerEnable 0))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_MOV(S_IMM 0)(D_AMP_MEM data_s))))
          (IAttacker(CTimerEnable 0))
        )" in *)
        (* Run with --secret 0*)
        (* let input_str = "(
          (IAttacker(CTimerEnable 3))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_CMP(S_IMM 0)(D_R (R 4)))))
          (IEnclave(CIfZ(((CInst I_NOP)(CInst(I_MOV(S_IMM 42)(D_AMP_MEM unprot_mem))))((CInst(I_MOV(S_IMM 42)(D_AMP_MEM unprot_mem)))(CInst I_NOP)))))
        )" in *)
        (* Run with --secret 1*)
        (* let input_str = "(
          (IAttacker(CTimerEnable 3))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_CMP(S_IMM 1)(D_R (R 4)))))
          (IEnclave(CIfZ(((CInst I_NOP)(CInst(I_MOV(S_IMM 42)(D_AMP_MEM unprot_mem))))((CInst(I_MOV(S_IMM 42)(D_AMP_MEM unprot_mem)))(CInst I_NOP)))))
        )" in
        let input_str = "(
          (IAttacker(CTimerEnable 3))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_CMP(S_IMM 1)(D_R(R 4)))))
          (IEnclave(CIfZ(((CInst(I_MOV(S_IMM 42)(D_R(R 5)))))((CInst I_NOP)(CInst I_NOP)))))
          (IEnclave(CInst(I_JMP(S_IMM enc_e))))
        )" in *)
        (* let input_str = "(
          (IAttacker(CTimerEnable 4))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_CMP (S_IMM 0) (D_R(R 4)))))
          (IEnclave(CIfZ(((CInst I_DINT)(CInst I_NOP))((CInst I_NOP)(CInst I_DINT)))))
          (IEnclave(CInst(I_JMP(S_IMM enc_e))))
        )" in *)
        (* let input_str = "(
          (IAttacker(CInst(I_MOV(S_IMM -1)(D_AMP_MEM TACCR0))))
          (IAttacker(CInst(I_MOV(S_IMM 532)(D_AMP_MEM tactl_val))))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CInst(I_MOV(S_IMM 0)(D_R(R 5)))))
          (IAttacker(CJmpIn enc_s))
          (IEnclave CUbr)
          (IAttacker(CInst(I_CMP(S_IMM 0)(D_AMP_MEM TAR))))
          (IAttacker CRstNZ)
        )" in *)
        (* let input_str = "(
          (IAttacker(CTimerEnable 0))
          (IAttacker(CInst(I_MOV(S_IMM 0)(D_AMP_MEM irq_cnt))))
          (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
          (IAttacker(CJmpIn enc_s))
          (IEnclave(CInst(I_MOV(S_IMM 0)(D_AMP_MEM data_s))))
          (IAttacker CReti)
          (IEnclave(CInst(I_ADD(S_IMM 1)(D_AMP_MEM data_s))))
          (IEnclave(CInst(I_MOV(S_AMP data_s)(D_R(R 4)))))
          (IEnclave(CInst(I_JMP(S_IMM enc_e))))
          (IAttacker(CInst(I_CMP(S_IMM 0)(D_AMP_MEM irq_cnt))))
          (IAttacker(CInst(I_MOV(S_IMM 1)(D_AMP_MEM irq_cnt))))
          (IAttacker(CIfZ CReti(CInst I_NOP)))
          (IAttacker(CInst(I_CMP(S_IMM 2)(D_R(R 4)))))
          (IAttacker CRstNZ)
        )" in *)
        let input_sequence = List.t_of_sexp Sancus.Input.t_of_sexp (Sexp.load_sexp sexp_fn) in
        (* initialize the interface with the processor's implementation *)
        let sul =
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
            ~sancus_master_key:sancus_master_key
            ~commit:commit
            ~templatefile:(cwd ^ "/../src/generic_template.s43")
            ~filledfile:"generic.s43"
            ~dumpfile:"tb_openMSP430.vcd"
            ~initial_spec:spec_dfa
            ~ignore_interrupts:ignore_interrupts
            () in
            (* let input_sequence = [
              Sancus.Input.IAttacker (Sancus.Attacker.CTimerEnable 3); (* Choose among 2 or 3 *)
              Sancus.Input.IAttacker (Sancus.Attacker.CInst (Common.I_MOV (Common.S_IMM "0", Common.D_R (R 14))));
              Sancus.Input.IAttacker (Sancus.Attacker.CInst (Common.I_MOV (Common.S_IMM "enc_e", Common.D_R (R 4))));
              Sancus.Input.IAttacker (Sancus.Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e"));
              Sancus.Input.IAttacker (Sancus.Attacker.CJmpIn "enc_s");
              Sancus.Input.IEnclave (Sancus.Common.I_CMP (Common.S_IMM "0", Common.D_R (R 14)));  (* Assume r14==0 *)
              Sancus.Input.IEnclave (Sancus.Common.I_ADD (Common.S_IMM "1", Common.D_R (R 5)));
              Sancus.Input.IEnclave (Sancus.Common.I_JMP (Common.S_R (R 4)));
              Sancus.Input.IAttacker (Sancus.Attacker.CReti);
            ] in *)
            (* let rec body_seq_to_list s =
              match s with
              | Enclave.Epsilon -> []
              | Enclave.Seq (Atom i, s') -> (Sancus.Input.IEnclave i)::(body_seq_to_list s')
              | _ -> failwith "Not supported" in *)
            (* let input_sequence = [
              Sancus.Input.IAttacker (Attacker.CTimerEnable 3);
              Sancus.Input.IAttacker (Attacker.CCreateEncl ("enc_s", "enc_e", "data_s", "data_e"));
              Sancus.Input.IAttacker (Attacker.CJmpIn "enc_s");
              Sancus.Input.IEnclave (Enclave.CInst (Common.I_CMP (Common.S_IMM "0", Common.D_R (R 4))));
              Sancus.Input.IEnclave (Enclave.CZeroOrNop (Common.I_MOV (Common.S_IMM "42", Common.D_R (R 5)), 2));
              Sancus.Input.IAttacker (Attacker.CReti) ] in *)
              ignore (Sys_unix.command (sprintf "rm -f %s/tb_openMSP430.vcd" tmpdir));
              let cmd = sprintf "ln -sr %s %s/tb_openMSP430.vcd" !sul.dumpfile tmpdir in
              ignore (Sys_unix.command cmd);
              List.iter input_sequence ~f:(fun i -> let o = Sancus.Verilog.step sul i in
              Logs.debug (fun m -> m "exec result: %s" (Output_internal.show o)));
  )

let () = Command_unix.run command


