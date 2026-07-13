# AGENTS.md

Keep this file up to date whenever you learn something useful about this repo,
the local machine, the FPGA setup, or a debugging session. The goal is to let a
future session resume work without rereading old transcripts.

## Project

ALVIE learns and checks Sancus/openMSP430 models.

Important paths:

- `alvie/code`: OCaml implementation; build from here with `dune build`.
- `alvie/code/lib/sancus/sul/fpga.ml`: FPGA-backed SUL.
- `alvie/scripts/fpga_daemon.py`: legacy long-lived serial daemon used by old
  FPGA mode; the current FPGA SUL opens the tty directly from OCaml and keeps
  it open for the whole learning session.
- `alvie/scripts/run_fpga.py`: one-shot ELF uploader/trace dumper.
- `alvie/scripts/setup_fpga.sh`: once-per-tempdir FPGA build setup.
- `alvie/scripts/build_pmem_fpga`: per-query assembler/linker for FPGA mode.
- `spec-lib/<name>`: experiment specs used by the wrapper scripts.
- `logs/<name>` and `results/<name>`: simulator runs.
- `logs/<name>-fpga`, `results/<name>-fpga`, and `tmp/<name>-fpga`: FPGA runs.

## Common Commands

Build:

```bash
cd alvie/code
dune build
```

Run one learning batch in simulation:

```bash
./learn_one.sh <special_commit> <att_spec> <subdirectory>
```

Run one learning batch on FPGA:

```bash
./learn_one.sh <special_commit> <att_spec> <subdirectory> --fpga
```

Example for B1:

```bash
./learn_one.sh e8cf011 b1 b1
./learn_one.sh e8cf011 b1 b1 --fpga
```

`learn_one.sh`, `learn_all.sh`, and `learn_one_nospecial.sh` require an
explicit `<subdirectory>`. If it is omitted, they now fail with usage instead
of writing into `logs/-fpga`, `results/-fpga`, and `tmp/-fpga`.

The `<subdirectory>` argument is also the output namespace. If
`spec-lib/<subdirectory>` exists, specs are loaded from there; otherwise the
scripts fall back to root `spec-lib`. This supports names such as `b1` for
`logs/b1-fpga` while still reading `spec-lib/b1.atdl`.

For each attack/backend, a complete ALVIE run means four learned models:

- secret 0 with interrupts enabled: `*-0-*-int.dot`
- secret 1 with interrupts enabled: `*-1-*-int.dot`
- secret 0 with `--ignore-interrupts`: `*-0-*-nint.dot`
- secret 1 with `--ignore-interrupts`: `*-1-*-nint.dot`

The final comparison must use all four models. `fa.exe` compares the two
interrupt-enabled models while subtracting witnesses already present in the
two no-interrupt models via `--m1-nint` and `--m2-nint`. `check_one.sh`
implements this convention.

## FPGA Notes

The board programming scripts are outside this checkout:

```bash
cd /home/matteo/projects/alvie/arty_s7_openmsp430_sancus/scripts
vivado -mode batch -source S.tcl
```

Replace `S.tcl` with the Vivado script to run. As of 2026-07-06, the user
reported that the board was programmed with this flow.

The Vivado programming Tcl scripts in that directory verify the bitstream
SHA-256 before `program_hw_devices`. The expected hash currently used for the
`inst_number_50_ef753b6` image is:

```text
8270dd57894434a9a05e58c2ee84791f47ec830f4904f3d2cc6b3b7fe5272eb3
```

Vivado script suffixes:

- `_inst_number`: execution checkpoints at a given instruction number.
- `_inst_pc`: execution checkpoints at a given program counter.
- `_inst_number_50`: execution checkpoints at a given instruction number, with
  an observation window of 50 cycles instead of 10.
- `_ef753b6`: image built from Sancus git commit `ef753b6`.

If the script name does not indicate a commit, it uses Sancus commit `bf89c0b`,
the final Sancus commit with all known bugs fixed except paper bugs V-B8 and
V-B9.

The current ALVIE FPGA software path expects a 50-entry trace window:
`alvie/scripts/run_fpga.py` reads 50 trace entries, and the OCaml FPGA SUL now
parses the same 50-entry raw trace directly from the serial port. Historical
debug logs from the old daemon path show `FPGA daemon response (50 lines)`.

The FPGA backend defaults to `/dev/ttyUSB1`. Override with:

```bash
FPGA_PORT=/dev/ttyUSB1 ./learn_one.sh <special_commit> <att_spec> <subdirectory> --fpga
```

If serial I/O is slow or flaky, the board may need the FTDI latency timer set:

```bash
echo 1 | sudo tee /sys/bus/usb-serial/devices/ttyUSB1/latency_timer
```

Known bitstreams in this checkout:

- `sancus-core-gap/fpga/xilinx_digilent_s3board/synthesis/xilinx/bitstreams/openMSP430_fpga.bit`
- `sancus-core-gap/fpga/xilinx_digilent_s3board/synthesis/xilinx/bitstreams/openMSP430_fpga.mcs`

This environment did not show `/dev/ttyUSB*` or `/dev/ttyACM*` devices during
the 2026-07-06 session, and common programming tools (`impact`,
`openFPGALoader`, `djtgcfg`, `xc3sprog`) were not on `PATH`.

## Current Debug Context

On 2026-07-06, the paper running example was reproduced into
`/tmp/alvie-example-20260706-154415` with fresh simulator and FPGA outputs.
The FPGA run needed execution outside the filesystem sandbox because the
sandboxed process could not open `/dev/ttyUSB1`.
The user manually validated on 2026-07-06 that this reproduces the paper's
running-example attack.

Results:

- Simulator learning, both secrets in parallel: 30.84s wall time.
- FPGA learning, secrets sequentially: 12.74s wall time.
- Both backends produced two 21-line DOT models.
- Secret-0-vs-secret-1 comparison produced a 45-line witness for both
  backends.
- Simulator and FPGA DOTs are not byte-identical: FPGA timing payloads differ
  (`create` reports `k = 50` instead of simulator `k = 600`, and some
  `timerA_counter` values differ). The counterexample structure is preserved.

The interrupted FPGA run was invoked as:

```bash
./learn.sh ef753b6 b1 --fpga
```

There is no `learn.sh` in the checkout; the intended wrapper is probably
`learn_one.sh`. The missing third positional argument caused an empty
subdirectory name, so the run wrote to:

- `logs/-fpga`
- `results/-fpga`
- `tmp/-fpga`

Logs in `logs/-fpga` show long PAC exploration output. The final traceback is
from killing the process: `fpga_daemon.py` gets `KeyboardInterrupt`, then OCaml
raises `Sys_error "Broken pipe"` in `Sancus__Fpga.run_fpga_script.query`.

Do not treat that traceback as the root cause; it is the expected result of
interrupting the daemon while learning is still issuing FPGA queries.

The B1 attacker spec is expensive because its ISR runs `timer_enable 1; reti`,
so runs that interrupt inside enclave control flow can produce dense repeated
interrupt behavior. FPGA mode is sequential and much slower than simulation.

For B6, the user expects `spec-lib/fast` to be significantly faster than the
full specs. The 2026-07-06 FPGA board was already flashed with the vulnerable
`ef753b6` image. The recommended learner settings for bounded experiments are:

```bash
--oracle randomwalk --step-limit 5000 --reset-probability 0.09
```

Direct `attack_fpga` B6 regression tests pass, but that is not enough for
ALVIE simulator/FPGA parity. The goal is to learn the full four-model B6
matrix and then run the four-model comparison.

2026-07-06 B6 fast FPGA result:

- Specs: `spec-lib/fast/b6.atdl` and `spec-lib/fast/enclave-complete.etdl`.
- Commit label: `ef753b6`; board already flashed with the vulnerable image.
- Learner settings: `--fpga --oracle randomwalk --step-limit 5000
  --reset-probability 0.09`.
- Output namespace: `fast-b6-rw5000-fpga`.
- Four learned models were written to `results/fast-b6-rw5000-fpga/`.
- Logs were written to `logs/fast-b6-rw5000-fpga/`.
- Witness comparison output was written to
  `counterexamples/fast-b6-rw5000-fpga/ef753b6-b6_int.dot`.
- Learning time for all four FPGA models was 3075s (about 51m15s).
- `fa.exe` comparison time was 0.27s and reported 72 FA violations.
- Model sizes: 101 lines for secret 0 int, 106 lines for secret 1 int, and
  130 lines for each no-interrupt model.

2026-07-07 matching B6 fast simulator comparison:

- Same specs and learner settings as the FPGA run:
  `spec-lib/fast/b6.atdl`, `spec-lib/fast/enclave-complete.etdl`,
  `--oracle randomwalk --step-limit 5000 --reset-probability 0.09`.
- Output namespace: `fast-b6-rw5000-sim`.
- Four learned models were written to `results/fast-b6-rw5000-sim/`.
- Witness comparison output was written to
  `counterexamples/fast-b6-rw5000-sim/ef753b6-b6_int.dot`.
- Simulator learning time for four parallel jobs was 2057s (about 34m17s).
- `fa.exe` comparison time was 0.31s and reported 27 FA violations.
- Simulator model sizes: 124 lines for secret 0 int, 121 lines for secret 1
  int, and 117 lines for each no-interrupt model.
- FPGA model sizes for the same settings were 101/106 lines for int and
  130/130 lines for no-interrupt.
- The witness counts differ: simulator fast/randomwalk found 27 FA violations;
  FPGA fast/randomwalk found 72.
- The simulator models observe `umem_val = 42` on the
  `mov #42, &unprot_mem` transitions. The FPGA models contain the same
  `mov #42, &unprot_mem` input branch but report `umem_val = 0` on the
  corresponding observed outputs. This should be investigated before claiming
  model equivalence between simulator and FPGA for B6.

2026-07-07 B6 fast comparison after latest FPGA reset fix:

- Same specs and learner settings:
  `spec-lib/fast/b6.atdl`, `spec-lib/fast/enclave-complete.etdl`,
  `--oracle randomwalk --step-limit 5000 --reset-probability 0.09`.
- Simulator namespace: `fast-b6-rw5000-resetfix-sim`.
- FPGA namespace: `fast-b6-rw5000-resetfix-fpga`.
- Simulator learning time for four parallel jobs: 3359s (about 55m59s).
- FPGA active learning time was about 4473s (about 1h14m33s): the first model
  took about 2117s before a shell-driver crash while recording timing, and a
  successful restart learned the remaining three models in 2356s. The crash was
  from using zsh's read-only `status` variable in an ad hoc shell driver, not a
  learner or FPGA failure.
- Model sizes:
  - Simulator: 124 lines for secret 0 int, 121 for secret 1 int, and 117/117
    for no-interrupt models.
  - FPGA: 129 lines for secret 0 int, 126 for secret 1 int, and 122/122 for
    no-interrupt models.
- `fa.exe` reported 27 FA violations for both simulator and FPGA.
- Both witness DOTs are 154 lines. They are not byte-identical, but after
  normalizing timing fields (`k` and `timerA_counter`) the simulator and FPGA
  witness DOTs are identical.
- The complete learned models are still not identical even after normalizing
  obvious timing fields. With randomwalk equivalence this can be sampling
  variance; the security-level comparison result is now aligned.

2026-07-07 B6 FPGA/simulator parity diagnosis:

- The user expectation is that simulator and FPGA models should be equivalent
  up to timing payload differences.
- `alvie/code/lib/sancus/sul/verilog.ml` now samples payload signals
  (`r4`, `gie`, `umem`, `timerA`) at `<= ref_time_end`, so values committed at
  the next instruction boundary are visible. Its `e_status` window must remain
  half-open (`ref_time_begin <= t < ref_time_end`); including
  `ref_time_end` pulls in the next instruction's Sancus state and can raise
  `output_of_signals: found PM, PM, OTHER` on B6 interrupt boundaries.
- `alvie/code/lib/sancus/sul/fpga.ml` now mirrors that payload convention by
  sampling the first trace row for `inst_number + 1` when available, falling
  back to the last current-instruction row only at reset/end of trace.
  `dune build` passed after this change.
- Re-running `dune exec test/attack_fpga.exe -- test b6 --show-errors
  --color=never` then failed old expected values, but still showed
  `umem_val = #0` for the `mov #42, &unprot_mem` step.
- A raw one-shot trace with `python3 alvie/scripts/run_fpga.py
  /home/matteo/projects/alvie/alvie-wip/tmp/.tmp.ngOWPj/pmem.elf
  --inst-number 25 --port /dev/ttyUSB1` confirmed the FPGA serial stream
  itself reports `umem = 0` through later instructions even though the ELF
  disassembly contains `mov #42, &0x0250`.
- A targeted one-cycle-delay check on the same ELF maps `mov #42, &0x0250`
  to CPU `inst=26`, `pc=0x5c5e`; the immediately following instruction is
  `inst=27`, `pc=0x5c64` (`nop`). The FPGA trace still reports `umem=0` for
  all cycles of `inst=26`, for `inst=27`, and for `inst=28`, so the observed
  mismatch is not explained by a simple one-cycle memory-write visibility
  delay.
- A simulator check of the same B6 sequence on vulnerable commit `ef753b6`
  does not raise `OIllegal` or reset at the `mov #42, &unprot_mem` step. The
  generated ELF contains `mov #42, &0x0250`; the VCD changes `mem250` from
  `0x0` to `0x2a` at the following instruction (`pc=0x5c64`), with
  `sm_violation=0` and `puc_rst=0` in that window. `Verilog.analyse_dump`
  reports `OTime_Handle` with the UM/interrupt payload `umem_val = #0x2a`.
- Running the same sequence on fixed commit `bf89c0b` produces `OReset` later
  in the simulator path. That is the expected fixed-commit behavior, but it is
  not what the vulnerable `ef753b6` simulator does.
- Register-write sanity checks on 2026-07-07:
  - A controlled `mov #42, r4` enclave instruction updates raw simulator VCD
    `r4` to `0x2a` at the following instruction. The raw FPGA trace also
    reports `r4=42` starting at the following instruction (`inst=20`,
    `pc=0x5c4a`) even though the current instruction's own trace rows still
    show `r4=0`.
  - A controlled `mov #42, r8; mov r8, r4` sequence updates raw simulator VCD
    `r8` to `0x2a` after the first instruction and `r4` to `0x2a` after the
    second. The raw FPGA trace cannot export `r8`, but it reports `r4=42`
    starting at the instruction after `mov r8, r4`, proving the exported `r4`
    path and normal register writes work.
  - After the analyser sampling fix, ALVIE's public payload reports
    `reg_val=#0x2` for `mov #42, r4`, which is correct because public
    `reg_val` is intentionally reduced modulo 8.
- This does not look like a low-level VCD parsing bug. Raw VCD extraction sees
  `r4`/`r8` changes at the expected timestamps. The earlier simulator
  off-by-one was in the payload sampling convention, and it is now fixed for
  payload values while keeping `e_status` half-open.
- After the sampling fix, a one-shot B6 simulator execution of
  `/tmp/alvie-b6-mov-unprot.sexp` reports:

  ```text
  OTime_Handle(
    { k = 7; gie = true; umem_val = #0x2a; reg_val = #0; timerA_counter = #0x4; mode = PM },
    { k = 5; gie = false; umem_val = #0x2a; reg_val = #0; timerA_counter = #0x3; mode = UM })
  ```

  The same one-shot on FPGA, using the currently programmed `ef753b6`
  bitstream, still reports `umem_val = #0` in both payloads for the same
  `mov #42, &unprot_mem` step. Therefore the remaining B6 mismatch is not
  explained by the ALVIE simulator sampling bug.
- On 2026-07-07, after the FPGA-side memory-export fix was applied, the same
  B6 one-shot showed that the memory signal is now exported: the first focused
  FPGA run reported `umem_val = #0x2a` in the interrupt/handle payload after
  `mov #42, &unprot_mem`. However, the preceding PM `OTime` payload still
  reported `umem_val = #0`, while the simulator reports `#0x2a` for both PM
  and handle payloads. A raw follow-up trace showed `umem=42` around
  instructions 25-28, so there may still be a one-cycle/order difference in
  FPGA trace sampling.
- Important: after that FPGA write, rerunning the same one-shot without
  reprogramming/resetting the board showed `umem_val = #0x2a` from the very
  first step (`timer_enable`). This indicates `unprot_mem`/DMEM is not being
  cleared between FPGA SUL queries by the current upload/reset path. Full FPGA
  learning can be polluted by retained data memory unless the loader clears
  DMEM or the generated setup explicitly initializes observed unprotected
  memory such as `unprot_mem`.
- Reset test on 2026-07-07: after dirtying `unprot_mem` to 42, a fresh
  `run_fpga.py ... --inst-number 1` query restarted execution at
  `inst=1, pc=0x5c00`, confirming the CPU/program reset path runs for each
  query. The same first-instruction trace still reported `umem=42`, confirming
  that this reset does not clear data BRAM. The simulator testbench does clear
  DMEM explicitly in `src/sim/stimulus.v`, while the FPGA `dmem_0` instance in
  `src/rtl/openMSP430_fpga.v` has no reset/clear port wired.
- Repeating the same FPGA SUL request for
  `mov &unprot_mem, r4; add #1, r4; mov r4, &unprot_mem` produced different
  observations across consecutive requests. The first run started with
  `umem_val = #0x2a`; the second run reported `umem_val = #0xcea9` from the
  first prepare/create step, before the enclave body. This reinforces that
  FPGA-side DMEM state persists or is otherwise stale across requests; it is
  not just a clean deterministic `42 -> 43` increment.
- After the user updated the FPGA on 2026-07-07, the first repeated
  `mov &unprot_mem, r4; add #1, r4; mov r4, &unprot_mem` SUL execution
  started clean with `umem_val = #0`. However, the next two fresh SUL
  executions still started dirty before the enclave body, with
  `umem_val = #0x93df` and then `umem_val = #0x19f4`. The update improved the
  immediately-after-programming state but did not make per-query DMEM reset
  deterministic.
- After a later FPGA update on 2026-07-07, the same repeated SUL request was
  clean for two consecutive fresh executions. Both runs started with
  `umem_val = #0`, and the sequence behaved consistently (`reg_val` moved from
  `0` to `1` while `umem_val` stayed `0` at the sampled points). The previous
  stale-DMEM symptom is not reproducing on the currently programmed image.
- Re-run the focused B6 simulator/FPGA comparison before drawing conclusions
  from the older `fast-b6-rw5000-*` model-size/witness mismatch, because those
  models were learned before the latest FPGA reset fix.
- In `/home/matteo/projects/alvie/arty_s7_openmsp430_sancus`, the visible
  top-level source has a `dmem_40` BRAM port meant to observe `0x250`
  (`mem250`), but the program scripts are untracked wrappers that load prebuilt
  bitstreams from `build/`. The checked-in source also appears incomplete for
  the currently programmed custom UART stream, so the bitstream/source
  provenance needs checking before patching RTL expectations.

2026-07-07 FPGA timing/caching instrumentation:

- `alvie/code/lib/sancus/sul/fpga.ml` now prints an exit summary on stderr:

  ```text
  [FPGA_STATS] build_calls=... build_ms=... query_calls=... query_ms=... avg_build_ms=... avg_query_ms=...
  ```

- `fpga.ml` also logs per-step `[PERF] build_pmem_fpga...` and
  `[PERF] run_fpga...` lines at info level. Use `--info` or `--debug` on
  learner/exec commands when detailed timing logs are needed.
- `fpga.ml` intentionally does not cache build outputs or raw FPGA traces. A
  short-lived build/trace cache experiment saw zero hits on fast-B6 L# learning
  because L# avoids repeating exact exploration queries; keeping it would add
  complexity without measured benefit. If cache keys are reintroduced later,
  use SHA-256, not MD4/MD5.
- `alvie/scripts/fpga_daemon.py` now prints an exit summary on stderr:

  ```text
  [FPGA_DAEMON_STATS] queries=... elf_cache_hits=... elf_parse_ms=... payload_ms=... serial_ms=...
  ```

- The daemon cache is keyed by SHA-256 of the ELF bytes and stores the
  ready-to-upload payload prefix for that program (`0xff`, PMEM length/data,
  vector length/data). Each query appends only the breakpoint instruction
  number. This avoids repeated ELF parsing and byte swapping when the same
  program is queried again.
- The FPGA SUL now opens `/dev/ttyUSB1` once from OCaml, keeps the fd alive
  for the whole learning session, and writes queries directly to the board.
  The old Python daemon is still available for reference, but it is no longer
  on the hot path. Do not reopen the tty per query; that would recreate the
  process/startup overhead we are trying to avoid.
- Quick smoke test on 2026-07-08 used
  `dune exec tt_attack_fpga -- test --color=never b6 0`. The direct-serial
  transport worked: the run reached FPGA queries and produced trace data.
  The test failed because its expected b6 no-interrupt value is stale relative
  to the current direct-serial path; the run observed
  `OJmpOut { umem_val = #0x2a; timerA_counter = #0x3 }` where the test still
  expected `umem_val = #0`. Treat this as a test fixture update issue, not a
  transport regression.
- The first timing target is to determine whether `build_pmem_fpga`,
  daemon-side ELF/payload preparation, or serial round trips dominate B6
  learning time before attempting larger FPGA protocol changes.
- A single post-cache fast-B6 FPGA run was measured on 2026-07-07:
  `secret=0`, interrupts enabled, `--oracle randomwalk --step-limit 5000
  --reset-probability 0.09`, namespace `fast-b6-rw5000-cache-fpga`.
  It finished in 927.15s (about 15m27s) and produced a 129-line DOT model.
  The DOT was byte-identical to the older
  `results/fast-b6-rw5000-resetfix-fpga/ef753b6-b6-enclave-complete-0-0.01-0.01-int.dot`.
  Final counters were:

  ```text
  [FPGA_STATS] build_calls=58 build_cache_hits=0 build_ms=582.1 trace_cache_hits=0 query_calls=60 query_ms=4229.3 avg_build_ms=10.0 avg_query_ms=70.5
  [FPGA_DAEMON_STATS] queries=60 elf_cache_hits=2 elf_parse_ms=49.9 payload_ms=0.0 serial_ms=4167.7
  ```

  The old reset-fix FPGA run's first model was approximately 2117s, but that
  number was reconstructed from wrapper timestamps and included first-run noise.
  The now-removed `fpga.ml` build/trace caches saw no hits, so the shorter wall
  time should not be attributed to cache effectiveness. During the run,
  `learn.exe` spent most of the wall time CPU-bound after only 52-60 hardware
  queries, while measured build plus serial time was under 5s total. The next
  timing instrumentation should measure L#/oracle phases and dry/internal SUL
  steps.
- A later no-`--info` rerun for the same fast-B6 FPGA configuration was started
  with stdout/stderr redirected to `logs/fast-b6-wall-fpga/`, but it did not
  finish in the session window and had to be killed. `run.time` stayed empty,
  so there is no new wall-time datapoint from that attempt.
- The same no-`--info` fast-B6 FPGA rerun was completed on 2026-07-08:
  `secret=0`, interrupts enabled, `--oracle randomwalk --step-limit 5000
  --reset-probability 0.09`, namespace `fast-b6-wall-fpga`.
  Wall time was 604.79s (about 10m05s). The produced DOT model was
  byte-identical to `results/fast-b6-rw5000-cache-fpga/ef753b6-b6-enclave-complete-0-rw5000-0.09-int.dot`
  and had 129 lines.
  Final counters were:

  ```text
  [FPGA_STATS] build_calls=58 build_ms=480.9 query_calls=60 query_ms=4225.7 avg_build_ms=8.3 avg_query_ms=70.4
  [FPGA_DAEMON_STATS] queries=60 elf_cache_hits=2 elf_parse_ms=49.4 payload_ms=0.0 serial_ms=4163.5
  ```

  Compared with the earlier 927.15s cached FPGA run, this is faster on the
  same model shape and still dominated by the same 60 hardware queries. The
  result is consistent with the earlier pre-cache behavior: the witness/model
  structure did not change, only the wall time did.
- Current L# hotspot from inspection of `lib/lsharp/lsharp.ml` and
  `lib/lsharp/observationtree.ml`: rule 3 rebuilds `frontier` and `f2b`
  from scratch on every pass, then calls `apart_with_witness` repeatedly on
  candidate basis pairs. `check_hypothesis` also recomputes `frontier`
  separately. The likely next optimization is to cache frontier/f2b within a
  stable `(ot, basis)` iteration and/or memoize apartness queries inside the
  observation tree.
- Implemented the first part of that optimization in `lib/lsharp/lsharp.ml`:
  the rule loop now threads a `loop_state_t` record containing `ot`, `basis`,
  cached `frontier`, and lazy cached `f2b`. `frontier` is rebuilt only when
  `ot` or `basis` changes, and `f2b` is computed on demand once for that loop
  state. `dune build` passed after the change. A simulator paper-example smoke
  run for `bf89c0b`, `secret=0`, PAC oracle produced a 21-line model in
  26.24s; it differs from the old checked artifact only in timer payload values
  on the same three transitions. A second current-code rerun produced a
  byte-identical model, so the difference is from the old June artifact being
  stale relative to the current Verilog timing/payload sampling convention
  (`<= ref_time_end` for payloads and `+1` in `k`), not from the loop-state
  refactor.
  - Full fast-B6 FPGA comparison after the `loop_state_t` frontier/f2b cache
    change used the same configuration as `fast-b6-wall-fpga`: `secret=0`,
    interrupts enabled, `--oracle randomwalk --step-limit 5000
    --reset-probability 0.09`. Namespace: `fast-b6-lsharp-frontier-fpga`.
  The produced 129-line DOT was byte-identical to the pre-change
  `fast-b6-wall-fpga` model, but the run was slower:

  ```text
  pre-change fast-b6-wall-fpga: real 604.79s, learn_oracle_ms=604522.9, r1_ms=134475.2, r3_ms=455946.4
  post-change fast-b6-lsharp-frontier-fpga: real 928.79s, learn_oracle_ms=928533.0, r1_ms=196432.1, r3_ms=718157.4
  ```

  Hardware-side work stayed effectively identical (`query_calls=60`,
  `query_ms ~= 4.23s`). Treat the loop-state threading as
  behavior-preserving but not a proven performance win; measure simulator-only
  or revert before layering more optimizations on top.
  - A fresh FPGA A/B on 2026-07-08 compared the current loop-state version
    with a temporary pre-loop-state variant that recomputes `frontier` and
    `f2b` on each pass. The configuration was the same B6 randomwalk case:
    `spec-lib/fast/b6.atdl`, `spec-lib/fast/enclave-complete.etdl`,
    `--secret 0 --oracle randomwalk --step-limit 5000 --reset-probability
    0.09`.

    Loop-state FPGA sample:

    ```text
    namespace: fast-b6-lsharp-frontier-fpga-ab
    real 944.07s
    [LEARN_PHASES] total_ms=943921.8 learn_oracle_ms=943781.4 sul_make_ms=135.7
    [LSHARP_PROFILE] r1_calls=5678 r1_ms=203738.6 r2_calls=5646 r2_ms=8775.6 r3_calls=5263 r3_ms=724025.5 r4_calls=10 r4_ms=7230.9
    [FPGA_STATS] build_calls=58 build_ms=604.8 query_calls=60 query_ms=4239.6
    [FPGA_DAEMON_STATS] queries=60 elf_cache_hits=2 elf_parse_ms=58.4 payload_ms=0.0 serial_ms=4166.7
    ```

    Pre-loop-state FPGA sample:

    ```text
    namespace: fast-b6-pre-loopstate-fpga-ab3
    real 951.71s
    [LEARN_PHASES] total_ms=951538.2 learn_oracle_ms=951427.3 sul_make_ms=100.0
    [LSHARP_PROFILE] r1_calls=5678 r1_ms=187908.4 r2_calls=5646 r2_ms=6438.8 r3_calls=5263 r3_ms=654767.8 r4_calls=10 r4_ms=102302.4
    [FPGA_STATS] build_calls=58 build_ms=1386.3 query_calls=60 query_ms=4336.8
    [FPGA_DAEMON_STATS] queries=60 elf_cache_hits=2 elf_parse_ms=136.2 payload_ms=0.1 serial_ms=4169.1
    ```

    The two FPGA DOTs are byte-identical (`cmp` exit 0) and both 129 lines.
    The pre-cache wrapper is not a model change; on this sample it is slightly
    slower and shifts time from `sul_make`/`FPGA_STATS` into learner-side
    `r4_ms`, but the result is the same. Keep the loop-state version as the
    current baseline.
  - A finer FPGA breakdown run on 2026-07-08 used the loop-state baseline and
    the same B6 randomwalk configuration to split `query_ms` into transmit,
    receive, and Python decode time. The result was:

    ```text
    namespace: fast-b6-breakdown-fpga
    real 881.49s
    [FPGA_STATS] query_calls=60 query_ms=4230.7 query_send_ms=1.0 query_recv_ms=4229.7
    [FPGA_DAEMON_STATS] queries=60 elf_cache_hits=2 elf_parse_ms=50.2 payload_ms=0.0 serial_write_ms=1.6 serial_read_ms=4166.4 decode_ms=5.7
    ```

    This confirms the FPGA query cost is almost entirely the serial read of
    the 800-byte trace, not payload prep, decode/print, or the OCaml-side
    transmit path. The model stayed byte-identical to the
    earlier loop-state FPGA result (`cmp` exit 0, 129 lines).
  - The FPGA SUL now refuses to start learning unless the active USB serial
    device reports `latency_timer = 1` under
    `/sys/bus/usb-serial/devices/<port>/latency_timer`. This check runs in
    `Sancus.Fpga.make` before the serial port is opened, so bad latency settings
    fail fast instead of producing misleading timing runs. If the port is
    `ttyUSB1`, the expected file is
    `/sys/bus/usb-serial/devices/ttyUSB1/latency_timer`.
  - After the user explicitly set `ttyUSB1` latency timer to `1`, a fresh
    FPGA rerun of the same B6 sample (`fast-b6-latency1-fpga`) completed in
    947.90s, with:

    ```text
    [FPGA_STATS] query_calls=60 query_ms=4226.6 query_send_ms=1.0 query_recv_ms=4225.6
    [FPGA_DAEMON_STATS] serial_write_ms=1.8 serial_read_ms=4162.9 decode_ms=5.5
    ```

    The result is byte-identical to the earlier loop-state FPGA sample
    (`cmp` exit 0, 129 lines). The latency setting did not materially change
    the hardware/query cost on this workload.
  - A fixed-ELF transport benchmark on 2026-07-08 used
    `tmp/fast-b6-latency1-fpga/.tmp.25eL9a/pmem.elf` with breakpoint 25. The
    one-shot direct uploader (`run_fpga.py`) executed 20 runs in 1.75s. The
    persistent serial path processed the same 20 queries in 0.14s and
    reported:

    ```text
    [FPGA_DAEMON_STATS] queries=20 elf_cache_hits=19 elf_parse_ms=2.4 payload_ms=0.0 serial_write_ms=1.3 serial_read_ms=55.0 decode_ms=3.8
    ```

    This is not a full learner benchmark, but it shows the serial/board path
    itself can be very fast when the ELF is fixed and the cache is hot.
    The repeated in-process direct loop without resets diverged, so use fresh
    one-shot uploads or a proper reset path when benchmarking the direct path.
- Profiling suspect for the CPU-bound time: `Inputgen.get_options` recomputes
  spec state from the full I/O prefix on every call by interspersing `il`/`ol`
  and folding `transition` from the initial spec. `Inputgen` explicitly uses
  Brzozowski derivatives instead of building DFAs. This makes spec-guided
  generation at least quadratic in path length, before derivative expression
  growth and option filtering. Related hotspots to instrument:
  `Inputgen.get_options`, `Attacker.derive`, `Enclave.derive`,
  `Attacker.is_empty`, `Enclave.is_empty`, and oracle list appends in
  `randomwalkoracle.ml`/`pacoracle.ml` (`is @ [new_i]`, `os @ [o_hyp]`).
  Plausible fixes are incremental spec-state threading in the oracle, compiling
  TestDL regexes to explicit DFA/NFA states, or at minimum simplifying/hash-
  consing derivatives and avoiding repeated list appends.
- 2026-07-07 profiling instrumentation was added:
  - `learn.exe` prints `[LEARN_PHASES]` at exit with coarse end-to-end
    timings for `setup`, `spec`, `sul_make`, `alphabet`, `learn_oracle`,
    `filter_model`, and `dot_write`.
  - `LSharp` prints `[LSHARP_PROFILE]` at exit with per-rule call counts,
    applied counts, finish counts for rule 4, and time spent in rules R1-R4.
  - `Inputgen` prints `[INPUTGEN_STATS]` at exit with `get_options` timing,
    history replay timing, option generation timing, transition counts,
    derivative timing, `is_empty` timing, and `get_atoms` timing.
  - `randomwalkoracle.ml` prints `[RW_ORACLE_PROFILE]` at exit with
    `next_input` timing and list append timing.
  - `pacoracle.ml` prints `[PAC_ORACLE_PROFILE]` at exit with the same
    categories.
  - `Verilog` prints `[VERILOG_STATS]` at exit with aggregate simulator PMEM
    build and simulator execution timing.
  - A tiny `exec.exe` smoke test using `/tmp/alvie-b6-mov-unprot.sexp` exited
    normally and printed:

    ```text
    [INPUTGEN_STATS] get_options_calls=5 get_options_ms=0.7 avg_get_options_ms=0.134 history_len_avg=4.0 history_len_max=8 intersperse_ms=0.0 replay_ms=0.1 option_ms=0.6 transition_calls=20 transition_ms=0.1 attacker_derive_calls=16 attacker_derive_ms=0.1 enclave_derive_calls=24 enclave_derive_ms=0.5 attacker_is_empty_calls=7 attacker_is_empty_ms=0.0 enclave_is_empty_calls=23 enclave_is_empty_ms=0.0 attacker_get_atoms_calls=3 attacker_get_atoms_ms=0.0 enclave_get_atoms_calls=2 enclave_get_atoms_ms=0.1
    ```

    This only validates the counters; it is too small to diagnose learner
    runtime. A short learner/oracle run that exits normally is still needed to
    compare `INPUTGEN_STATS` with `RW_ORACLE_PROFILE` or `PAC_ORACLE_PROFILE`.
- Example-profile runs on 2026-07-07:
  - PAC example, secret 0, simulation, output
    `results/example-profile/bf89c0b-attacker-enclave-0-0.01-0.01.dot`:
    26.66s wall time, 21-line model, `PAC_ORACLE_PROFILE`
    `next_input_ms=57.3`, `append_ms=0.7`; `INPUTGEN_STATS`
    `get_options_ms=102.8`, `replay_ms=71.4`, `option_ms=26.8`.
  - Randomwalk example, secret 0, simulation, output
    `results/example-profile-rw/bf89c0b-attacker-enclave-0-rw5000-0.09.dot`:
    27.88s wall time, 21-line model, `RW_ORACLE_PROFILE`
    `next_input_ms=48.0`, `append_ms=0.7`; `INPUTGEN_STATS`
    `get_options_ms=103.5`, `replay_ms=71.2`, `option_ms=27.5`.
  - On the paper example, spec generation and oracle list appends are not the
    runtime bottleneck. The run spends roughly 0.1s in `Inputgen`, about 0.05s
    in oracle `next_input`, and under 1ms in measured append work. The remaining
    time is dominated by simulator/SUL setup and uninstrumented learner work.
    Fast-B6 still needs its own normal-exit profile before optimizing
    derivatives or oracle lists.
  - After adding coarse phase/L# profiling, a PAC example run with output
    `results/example-profile-phases/bf89c0b-attacker-enclave-0-0.01-0.01.dot`
    produced the expected 21-line model in 28.09s wall time. Key counters:

    ```text
    [LEARN_PHASES] total_ms=27937.8 setup_ms=0.1 spec_ms=1.6 sul_make_ms=19212.0 alphabet_ms=0.0 learn_oracle_ms=8723.9 filter_model_ms=0.0 dot_write_ms=0.1
    [LSHARP_PROFILE] total_ms=8723.9 r1_calls=197 r1_applied=5 r1_ms=48.0 r2_calls=192 r2_applied=21 r2_ms=259.0 r3_calls=171 r3_applied=165 r3_ms=1106.7 r4_calls=6 r4_applied=5 r4_finished=1 r4_ms=7309.9
    [VERILOG_STATS] build_calls=5 build_ms=400.9 simulate_calls=5 simulate_ms=84.9 avg_build_ms=80.2 avg_simulate_ms=17.0
    ```

    On this small simulation run, `sul_make` dominates startup at about 19.2s,
    and L# rule 4 dominates the actual learning phase at about 7.3s. Measured
    simulator PMEM build plus Verilog simulation is only about 0.49s total.
  - The same PAC example run on FPGA wrote
    `results/example-profile-phases-fpga/bf89c0b-attacker-enclave-0-0.01-0.01.dot`
    and produced the expected 21-line model in 6.05s wall time. The sandboxed
    run could not open `/dev/ttyUSB1`; the successful run was executed outside
    the filesystem sandbox. Key counters:

    ```text
    [LEARN_PHASES] total_ms=5894.7 setup_ms=0.1 spec_ms=1.7 sul_make_ms=137.6 alphabet_ms=0.0 learn_oracle_ms=5755.1 filter_model_ms=0.0 dot_write_ms=0.1
    [LSHARP_PROFILE] total_ms=5755.1 r1_calls=197 r1_applied=5 r1_ms=41.7 r2_calls=192 r2_applied=21 r2_ms=88.9 r3_calls=171 r3_applied=165 r3_ms=912.1 r4_calls=6 r4_applied=5 r4_finished=1 r4_ms=4712.2
    [FPGA_STATS] build_calls=5 build_ms=40.7 query_calls=5 query_ms=19.8 avg_build_ms=8.1 avg_query_ms=4.0
    [FPGA_DAEMON_STATS] queries=5 elf_cache_hits=0 elf_parse_ms=4.9 payload_ms=0.0 serial_ms=13.8
    ```

    Compared with the simulation-profile model, the FPGA model has the same
    21-line structure. The visible DOT diff is the known timing payload
    difference on `create`: simulator reports `k = 600` and last instruction
    `15`; FPGA reports `k = 50` and last instruction `13`.
  - A longer fast-B6 randomwalk profile was started for simulator and FPGA
    using `spec-lib/fast/b6.atdl`, `spec-lib/fast/enclave-complete.etdl`,
    `--secret 0 --oracle randomwalk --step-limit 5000 --reset-probability
    0.09`, but both runs were interrupted before normal completion. Even so,
    the partial counters were useful:

    ```text
    simulator: [LSHARP_PROFILE] r1_calls=4197 r1_ms=165147.3 r2_calls=4171 r2_ms=26817.9 r3_calls=3848 r3_ms=573103.2 r4_calls=9 r4_ms=6069.8
    simulator: [VERILOG_STATS] build_calls=45 build_ms=8446.9 simulate_calls=45 simulate_ms=2241.9
    simulator: [INPUTGEN_STATS] get_options_calls=28351 get_options_ms=1467.0 replay_ms=964.1 option_ms=462.6 attacker_derive_ms=171.7 enclave_derive_ms=244.8
    FPGA: [LSHARP_PROFILE] r1_calls=4375 r1_ms=173555.6 r2_calls=4348 r2_ms=6015.7 r3_calls=4014 r3_ms=588205.1 r4_calls=9 r4_ms=1088.7
    FPGA: [FPGA_STATS] build_calls=46 build_ms=396.1 query_calls=47 query_ms=4181.4
    FPGA: [INPUTGEN_STATS] get_options_calls=29744 get_options_ms=1561.4 replay_ms=1054.1 option_ms=465.1 attacker_derive_ms=177.4 enclave_derive_ms=258.1
    ```

    The key shape is consistent across both backends: most of the time is in
    L# rule 3 and `Inputgen.get_options`, not in the raw SUL query path. FPGA
    adds a few seconds of query/serial cost and shows occasional ~2s `run_fpga`
    spikes, but that is still small relative to the learner-side work. The
    interrupted runs were not allowed to finish because the profile was already
    clear enough to identify the next bottleneck.
  - After adding a `get_options` cache keyed by `(il, ol, force_encl)`, a
    bounded fast-B6 randomwalk run with `--step-limit 20` completed on both
    backends:

    ```text
    simulator: [LEARN_PHASES] total_ms=159142.5 setup_ms=1.5 spec_ms=85.2 sul_make_ms=153158.2 learn_oracle_ms=5897.2
    simulator: [LSHARP_PROFILE] total_ms=5897.2 r1_calls=283 r1_ms=406.4 r2_calls=280 r2_ms=712.8 r3_calls=214 r3_ms=1921.6 r4_calls=4 r4_ms=2856.0
    simulator: [VERILOG_STATS] build_calls=4 build_ms=513.9 simulate_calls=4 simulate_ms=113.3
    simulator: [INPUTGEN_STATS] get_options_calls=967 get_options_cache_hits=894 get_options_ms=2.9 replay_ms=1.6 option_ms=1.2

    FPGA: [LEARN_PHASES] total_ms=54966.9 setup_ms=1.6 spec_ms=93.1 sul_make_ms=2289.9 learn_oracle_ms=52576.1
    FPGA: [LSHARP_PROFILE] total_ms=52576.0 r1_calls=283 r1_ms=8364.8 r2_calls=280 r2_ms=6395.2 r3_calls=214 r3_ms=35139.5 r4_calls=4 r4_ms=2669.9
    FPGA: [FPGA_STATS] build_calls=4 build_ms=805.1 query_calls=4 query_ms=156.3
    FPGA: [INPUTGEN_STATS] get_options_calls=967 get_options_cache_hits=894 get_options_ms=48.6 replay_ms=23.3 option_ms=24.5
    ```

    The cache is effective in both runs: almost all `get_options` calls hit
    the cache. On FPGA, the learning phase remains the main cost. On the
    simulator, `sul_make` unexpectedly dominates the wall time in this bounded
    case, so the next optimization target should be the simulator setup/build
    path rather than `Inputgen` itself.
  - A full/default fast-B6 single-model randomwalk run was completed on
    2026-07-08 for simulator and FPGA, using `spec-lib/fast/b6.atdl`,
    `spec-lib/fast/enclave-complete.etdl`, `--secret 0 --oracle randomwalk
    --step-limit 5000 --reset-probability 0.09`.

    Current loop-state simulator run:

    ```text
    namespace: fast-b6-lsharp-frontier-sim
    real 626.55s
    [LEARN_PHASES] total_ms=626251.9 sul_make_ms=18376.5 learn_oracle_ms=607864.3
    [LSHARP_PROFILE] r1_calls=5500 r1_ms=122359.6 r2_calls=5469 r2_ms=17039.8 r3_calls=5097 r3_ms=423005.8 r4_calls=10 r4_ms=45449.6
    [VERILOG_STATS] build_calls=57 build_ms=4472.6 simulate_calls=57 simulate_ms=1237.1
    ```

    Temporary pre-loop-state simulator A/B, with the same profiling
    instrumentation and restored afterwards:

    ```text
    namespace: fast-b6-pre-loopstate-sim
    real 1340.07s
    [LEARN_PHASES] total_ms=1337747.0 sul_make_ms=84956.0 learn_oracle_ms=1252736.4
    [LSHARP_PROFILE] r1_calls=5500 r1_ms=258367.7 r2_calls=5469 r2_ms=25794.7 r3_calls=5097 r3_ms=876980.6 r4_calls=10 r4_ms=91581.2
    [VERILOG_STATS] build_calls=57 build_ms=16180.5 simulate_calls=57 simulate_ms=4301.4
    ```

    The pre-loop-state and loop-state simulator DOTs are byte-identical
    (`cmp` exit 0), both with 124 lines. This confirms the loop-state/f2b
    caching change is behavior-preserving on this case and roughly halves
    single-model simulator wall time in this A/B. The previous post-loop-state
    FPGA run in `fast-b6-lsharp-frontier-fpga` took 928.79s even though its
    hardware counters matched the pre-loop FPGA run; treat that as a noisy
    timing sample or random/exploration-path effect until repeated with a
    deterministic seed.

## Worktree Caution

## GitHub Backlog

Fetched from `https://github.com/unive-alvie/alvie` on 2026-07-13 with
`gh issue list --state open`. There are currently 15 open, unlabelled issues:

- #1 [L1] Technical guide for attacker/victim specifications.
- #2 [L1] Real-world security assessment examples.
- #3 [L1] New ALVIE case studies and an extension roadmap.
- #4 [L1] Getting-started guide and troubleshooting for Docker/native setup.
- #5 [L2] Mainstream configuration/API, such as Python and YAML/JSON.
- #6 [L2] FPGA execution architecture design.
- #7 [L1] CLI error reporting and bug-reporting protocol.
- #8 [L1] CI verification for documentation links and code examples.
- #9 [L3] RISC-V analysis feasibility and architecture roadmap.
- #10 [L3] Core modularity and plug-in system.
- #11 [L3] New threat models and attacker capabilities.
- #12 [L1] Syntax documentation for attacker capabilities.
- #13 [L1] Documentation for extending attacker observable actions.
- #14 [L1] Syntax documentation for victim-program families.
- #15 [L1] A worked specification tutorial linked to existing specs.

Issue URLs are stable at `https://github.com/unive-alvie/alvie/issues/<number>`.
For the current codebase, #6 is the most directly related engineering item;
#4, #1, and #12-#15 are practical documentation tasks that can be addressed
incrementally. Before starting a new issue, check this list with:

```bash
gh issue list --repo unive-alvie/alvie --state open --limit 100
```

### Documentation branch audit (2026-07-13)

`origin/documentation` points to `ffe65b6` and adds these documents:

- `docs/spec-tutorial.md`: practical attacker/victim TestDL authoring guide.
- `docs/testdl-action-reference.md`: TestDL action semantics.
- `docs/spec-extending-actions.md`: how to add a TestDL action in OCaml.
- `docs/executables-reference.md`: `learn.exe`, `fa.exe`, `exec.exe`, and
  `pbt.exe` flags and outputs.
- `docs/log-output-reference.md`: learning/comparison log formats.
- `docs/walkthrough-repro.md`: Docker/native setup and paper reproduction.
- `docs/getting-started.md`: first-session tutorial covering setup, the paper
  example, outputs, specifications, and the first attack run.

Issue coverage is currently:

- Strong coverage: #1, #12, #13, #14, and #15 through the four spec documents.
- Partial coverage: #2 through the reproduction walkthrough and checked-in
  examples; #4 through the README and walkthrough; #7 through executable/log
  references.
- Little or no coverage: #3, #5, #6, #8, #9, #10, and #11. In particular,
  there is no FPGA architecture/setup documentation, CI documentation, plugin
  architecture, mainstream-language configuration, RISC-V roadmap, or new
  threat-model guide.

The documentation branch was validated with `dune build`, executable help
commands, shell syntax checks, and the complete simulation example
(`./learn_example.sh && ./check_example.sh`). The example learned both models
and passed comparison. Its README and walkthrough are simulation-only; FPGA
operation is documented in this file and in the FPGA branch.

The branch also contains the Astro Starlight site under `site/`. Canonical
Markdown remains under `docs/`; `.github/workflows/pages.yml` copies those
files into the Starlight content directory, builds, and deploys on every push
to `documentation`. GitHub Pages is enabled with workflow builds at:
`https://unive-alvie.github.io/alvie/`. The workflow was last verified
successfully by run `29244559808`.

The website landing page's `Getting started` button targets
`/alvie/getting-started/`; keep that route stable when reorganizing the docs.

The FPGA implementation is kept on `feat/alvie-fpga` (Git refs cannot contain
the requested `:` character), currently at commit `8bb0765`.

### Code documentation gap

The library has only a few public `.mli` files (`SUL` and `Oracle`), while the
core modules are mostly undocumented implementation files. A useful next
documentation addition is `docs/code-architecture.md`, covering:

- the `learn.exe` pipeline: TestDL parsing, input generation, SUL, L#, oracle,
  and model output;
- the `SUL` contract and the simulator/FPGA implementations;
- observation/output payload semantics, trace windows, reset behavior, and
  timing normalization;
- L# observation trees, frontier/f2b state, and oracle responsibilities;
- the extension points for a new backend, oracle, or TestDL action;
- build/test commands and the boundary between generated artifacts and source.

The code itself should gain concise module/interface comments as public APIs
are documented, especially in `lsharp`, `sancus`, `ltscomparator`, and the two
SUL implementations. Keep comments focused on invariants and contracts rather
than restating individual expressions.

As of 2026-07-06, the worktree had pre-existing local changes not made by this
session:

- Deleted `results/ef753b6-b1-enclave-complete-*-0.01-0.01-*.dot` files.
- Untracked `alvie/code/lib/sancus/sul/serial_stubs.c`.
- Untracked `clean.sh`.
- Untracked `verilator/`.

Do not restore, delete, or overwrite these unless the user explicitly asks.
