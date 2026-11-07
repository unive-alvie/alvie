# Changelog

## Unreleased

ALVIE becomes a framework: ALVIE/Core learns and compares models for any
platform that a plugin describes, and ALVIE/Sancus is its plugin for Sancus.
Experiments on Sancus run as before, with the same specs, commands and model
files; some results change, because 2026.10 got them wrong (see the Fixes,
Input generation, Backends and Comparison sections). New: Tiny, the reference
platform; the commands of Core for any plugin; conformance checks and
fixtures; external plugins and the Python SDK. "Migrating from 2026.10" in
the documentation lists what users must do.

### One learning path

- `learn.exe` and `fa.exe` (`alvie learn` and `alvie compare`) learn and
  compare with the commands of ALVIE/Core (`Alvie_cli.Runner`), as every other
  plugin does, through the codec of Sancus (`Sancus.Native.Codec`): their
  options and output, and the models they learn, do not change (regression:
  no differences). The runner gains what Sancus needed: a codec of the
  plugin's own (`Runner.Make_codec`), random inputs outside the spec
  (`--bad-probability`), the exhaustive oracle, `--dry` and the statistics of
  `--report`. `alvie sancus fixtures` writes models in the format of Sancus.
- A file that is not a model, given to `fa.exe` or `alvie compare`, is a
  mistake in the command (exit 2, `cannot read --m1-int ...`), no longer an
  unexpected failure.

### Documentation

- The documentation is grouped by reader: ALVIE/Core, ALVIE/Sancus, Writing
  Plugins, Reference, and Developing ALVIE. The addresses of the pages that
  moved lead to their new ones.
- New pages: Migrating from 2026.10, Tutorial: Find a Leak on Tiny, Plugin
  Author Guide, External Plugin Protocol, Making a Release; How ALVIE Works
  explains ALVIE/Core and its plugins.
- The version of ALVIE is set in one place (`dune-project`); `alvie
  --version` gives it.


### Fixes

- The simulator deletes its clone of Sancus (in `--tmpdir`) when the program
  ends: each backend left one behind, and runs that make many backends filled
  the disk (conformance: about 10 GB for 50 tests). The VCD dumps and the
  programs stay in `--tmpdir`.
- The simulator backend no longer fails with `Could not clone Sancus
  repository` when the temporary directory is on another file system than the
  `sancus-core-gap` checkout (for example `--tmpdir /tmp`, as in the direct
  commands of the documentation, or a Docker bind mount): a local clone
  hard-links the objects, so the backend now copies them when hard links are
  not possible. The message, when the clone does fail, says what to check.
- `Could not check out Sancus commit` now says that a shallow checkout of
  `sancus-core-gap` lacks the older commits, and how to fetch them.
- `fa.exe` looked for witnesses in one direction only: mCRL2 checks that the
  traces of the first model are traces of the second one, so a behavior that
  only the second model (secret 1) has was found only by chance. It now
  searches both directions and reports the union. It also counted the same
  witness again each time a later round of the search found it: each witness
  is now counted once. The witness counts change accordingly (for example B3
  on `ef753b6` goes from 3619 to 351, and `bf89c0b` gives 3 or 9 instead of
  6); the witness graphs gain the witnesses of the reverse direction, e.g. the
  B8/B9 witnesses for the timer values 1 and 2. `--debug` logs the numbers of
  each direction, and every witness with the directions that found it.
  `counterexamples/` and the attack catalogue are regenerated.
- `equal_public_payload_t` in `cexfinder.ml` compared the mode of the first
  payload twice (the known issue of 2026.10): two payloads were equal
  whenever the first one was in PM. It now requires both to be in PM, and so
  does the public equality of `tt_attack`, which had the same typo. No witness
  count changes; two witness graphs change (B3 on `ef753b6`, and the Getting
  Started example), because a witness now ends at the first output that the
  attacker can tell apart instead of one step later.
- A `cleanup` section that runs more than once now replays its earlier run,
  as the enclave and the ISR already did. `cleanup` runs again when it
  re-enters the enclave (with `reti` or `jin`) and the enclave jumps out
  again. Before, the second run could choose different actions, e.g. `nop`
  instead of `reti` with `spec-lib/complete.atdl`; the generated program then
  no longer matched the earlier steps, and the simulator reported
  `OUnsupported`. The specifications of the attack catalogue have a single
  choice in `cleanup`, so their models and witnesses do not change.

### Tests and CI

- Adds `regression.sh`, which checks that a change leaves the checked-in
  results unchanged: `witnesses` compares the checked-in models again and
  checks every witness graph and count; `learning` learns every model again
  and checks that it is identical to the checked-in one (learning is
  deterministic), then checks its witnesses. It also records the learning
  time of each model.
- Adds `tt_inputgen_golden`, which checks the input generator against a
  corpus of histories taken from the learned models
  (`alvie/code/test/golden/inputgen.sexp`). It needs no external tool.
- CI runs the corpus check with the fast checks, and runs `regression.sh all`
  and `tt_attack` in the published Docker image.

### Command line and files

- One command, `alvie`, with the subcommands `learn`, `compare`, `exec`,
  `pbt`, `property` and `plugin` (`check` and `schemas`, for plugin
  authors). `alvie property` checks inclusion, equivalence or an mCRL2
  formula on learned models, with exit status 4 when the property does not
  hold. The
  options of the backend are generated from the configuration parameters of
  the plugin's manifest. `learn.exe`, `fa.exe`, `exec.exe` and `pbt.exe`
  remain, as the same commands, for one release; their options and output
  do not change, so alvie-ui, which runs `bin/learn.exe` and parses its
  output, works as before.
- Model files start with a line that gives their format, the plugin and the
  version of Core (`// alvie-model format 1; plugin sancus 2026.10; core 1`).
  Models without it read as before; a model of a later format is refused
  with a message. The checked-in models get the line, and nothing else
  changes in them.

### External plugins

- **The protocol of Core with external plugins**, version 1: JSON-RPC 2.0,
  one message per line on the plugin's standard input and output, with a
  handshake that checks versions and capabilities (see the External Plugin
  Protocol reference, and `protocol.schema.json`).
- `alvie external DIR ...` runs the commands of Core (`learn`, `compare`,
  `property`, `exec`, `conformance`, `fixtures`) on the external plugin in
  `DIR`. A plugin that crashes, hangs (`ALVIE_RPC_TIMEOUT`), writes on its
  standard output or fails stops the command with a message and the end of
  its log. `ALVIE_RPC_RECORD` and `ALVIE_RPC_REPLAY` record a run and replay
  it without the plugin.
- **The Python SDK** (`sdk/python/alvie_plugin.py`, standard library only),
  `alvie plugin types` for the constructors of a plugin's observations, and
  `alvie plugin new NAME --external`.
- **Tiny in Python** (`plugins/tiny-py`) passes conformance and learns the
  same models as Tiny. A call costs about 0.1 ms.

### Plugins: the reference platform, conformance and fixtures

- **Tiny** (`plugins/tiny`, `lib/core/tiny`): the reference platform of
  ALVIE/Core, a small processor in pure OCaml with a timer that interrupts
  its enclave and two planted timing leaks. Learning a model takes a
  fraction of a second; the new tutorial "Find a Leak on Tiny" uses it.
- **The commands of Core for any native plugin** (`Alvie_cli.Runner`):
  `learn`, `compare` (noninterference, with a baseline variant),
  `property`, `exec`, `conformance` and `fixtures`, with the options of the
  manifest. `alvie tiny ...` runs them on Tiny; `alvie sancus conformance`,
  `fixtures` and `exec` on Sancus. `compare`, `property`, `conformance` and
  `fixtures` exit with 4 when the check does not pass.
- **Conformance** checks that a backend keeps the contract of Core on
  random tests of a spec: observations, phases, determinism, reset,
  prefixes, restore and clone. Tiny and the Sancus simulator pass.
- **Fixtures** (`fixtures/*.yaml` of a plugin): specs with the verdict of
  noninterference the plugin must give. Tiny has five, Sancus four (the
  Getting Started example, a safe variant of it, and attack A on ef753b6
  and bf89c0b).
- `alvie plugin new NAME` makes a native plugin from a template that works
  from the start, with its own `alvie-NAME`; the Plugin Author Guide starts
  from it.
- Variants of the manifest (`--variant no-interrupts`) are now applied: the
  backend gets the variant it runs.
- Specs can have comments, from `//` to the end of the line.
- The input generator simplifies the derivatives of spec bodies: a star in a
  section no longer makes a test exponentially slower with every repetition.
  The options it offers do not change (the corpus check has no difference).
- A model of another plugin is refused with a message, by `alvie compare`
  and `alvie property` too.

### Comparison

- Comparisons see what the attacker view declares (`plugins/sancus/view.yaml`),
  and nothing in them is written for Sancus any more: the hooks of the
  comparison engine are derived from the plugin files (hidden outputs and
  public equality from the view, the end of a run from the phase rules, low
  inputs and the victim's code from the roles of the sections, the victim's
  code up to the secret from the expansions of the secret). The temporary
  Sancus hooks (`lib/sancus-compare`) are removed.
- The view can split an observation into parts (`parts:`): an interrupt
  handled is the instruction then the handling, whose input is the
  interrupt, as `fa.exe` did by hand.
- mCRL2 compares what the attacker sees, not whole outputs: the cycle count
  `k` no longer takes part. **B1 on `ef753b6` gives 31 witnesses instead of
  29**; no other count changes. Witness graphs label the outputs that the
  attacker does not see with `(hidden)`; their labels have a new form
  (`ubr/Time(k = 2, ...)`), so all the graphs are generated again.
- The catalogue of properties (`Ltscompare.Properties`, version 1):
  noninterference with an optional baseline, inclusion and equivalence of
  models with a distinguishing trace, and mCRL2 modal mu-calculus formulas
  on one model. New suite `tt_properties` (needs mCRL2; run in CI).

### Backends

- ALVIE/Core defines the contract with a backend (`Alvie_backend.Backend.S`):
  `step` gets the programs of all the sections from Core and returns
  observations (values) and bookkeeping; `restore` replays a step whose
  observations Core already knows. An adapter turns any backend into the
  SUL of the learner, so L# and the oracles are unchanged. `tt_plugin` learns
  a small backend written for the tests, with nothing of Sancus.
- The Sancus simulator is a backend of this contract (`Sancus.Simulator`). It
  no longer reconstructs the code of the sections from the history
  (`relevant_enclave`, `relevant_isr`, `relevant_cleanup` and `update_cfg`
  are gone), and Core checks that inputs are legal, with the same rules as
  the input generator: the former generator (`Inputgen`) is used only to
  compare with, and `learn.exe --inputgen` is removed.
- **Results change for 8 models, and for two witness counts on `ef753b6`**
  (B1: 29 instead of 26; B3: 11 instead of 124). The former reconstruction of
  the enclave code was wrong in three cases, where the code it simulated was
  not the code the test had run:
  - after two or more interrupts, it left out the instructions executed
    between the first and the last resume (B1, B4: e.g. a write to
    unprotected memory before the interrupt was lost after a re-entry by
    `jin`, so the attacker read 0 instead of 42);
  - after a re-entry by `reti`, the learner could still try other enclave
    instructions than those the enclave had run there (B3; the input
    generator stopped choosing them in the previous change, but the learner
    also tries every input of its alphabet).
  B3 is still found: the witness graph of `ef753b6` has 12 jumps out of the
  enclave and 12 `reti` edges that resume it in protected mode, and the
  graphs of `6475709` and `bf89c0b` have none. The counts on the fixing commits and on
  `bf89c0b` do not change. 48 other models are learned with other state
  numbers only (isomorphic, with the same bookkeeping).
- A reset of Sancus restarts the test: the phase rule `restart` starts it
  afresh from `prepare`, with new code, as the simulator always did. Before,
  the input generator continued in `cleanup` after a reset in the enclave,
  where the simulator then answered every input as illegal.
- New tool `alvie-model-compare A.dot B.dot` (alvie-core): whether two models
  are the same machine up to the numbering of their states, and otherwise the
  shortest inputs on which they answer differently (`--observations-only`
  ignores the bookkeeping of Sancus outputs).

### ALVIE/Sancus-FPGA

- New native plugin `sancus-fpga`: Sancus on an openMSP430/Sancus board (an
  Arty S7 with an `inst_number_50` image), over its serial port. Its commands
  are `alvie sancus-fpga learn|compare|property|exec|conformance|fixtures`,
  with the options of `plugins/sancus-fpga/alvie-plugin.yaml`: `--commit`
  (required: the commit of the image on the board), `--fpga-port` (default
  `/dev/ttyUSB1`), `--sancus`, `--tmpdir`. A step takes 15 to 30 ms on the
  board. New page: Running on an FPGA.
- It shares the specs, inputs and observations of ALVIE/Sancus (its manifest
  names the files of `plugins/sancus`), and its models have the inputs and
  outputs of the simulator's: `alvie-model-compare` compares them.
- It reuses the Sancus backend as a library, with the board as its target
  (`Simulator.target`): the program of a step, its build, the bookkeeping,
  re-entries and the observations of the instructions found
  (`Sancus.Step_analysis`) are the simulator's. Only how a step runs and how
  its instructions are found in the board's trace are its own
  (`lib/sancus-fpga`). ALVIE/Sancus does not change (regression: no
  differences).
- This ports the FPGA backend of the branch `feat/alvie-fpga` and its later
  fixes. Differences from the branch: the serial port is `--fpga-port` (not
  the variable `FPGA_PORT`); ALVIE does not program the board (`FPGA_TCL` is
  removed); `learn.exe --fpga`, the `--fpga` option of the wrapper scripts
  and the serial daemon (`fpga_daemon.py`, `run_fpga.py`) are removed; the
  programs use the headers of `--commit`, not of the current checkout.
  Copies of a backend, and several processes, can share a board: each query
  locks the serial port.
- It needs no clone of Sancus: building the programs reads the memory sizes
  and the linker script of `--commit` from the checkout (`git show`).
- New script `alvie/scripts/program_fpga.tcl`: programs the board with a
  bitstream, after checking that its SHA-256 is that of a known image, and
  prints the commit of the image.
- Fixtures: those of ALVIE/Sancus, each for the image of its commit.
- New suite `tt_attack_fpga`: the attack traces of `tt_attack` on the board
  (image `ef753b6`), with the simulator's expected observations except where
  the hardware differs, each with its reason. It needs the board, so CI does
  not run it.

### Input generation

- Learning uses the input generator of ALVIE/Core, driven by the plugin files
  of `plugins/sancus/` (embedded in the executables). It follows a test
  through its sections with `phases.yaml` and applies one rule to every
  section: a section is code, so all its runs in a test are prefixes of its
  longest run, and new actions are chosen only beyond its end.
  `learn.exe --inputgen legacy` uses the former generator.
- **Results change for B3 on `ef753b6`**: 124 witnesses instead of 351, and
  its two models with interrupts are about half as large. The former
  generator let an enclave that the attacker re-enters with `reti` choose
  new actions where the timer had interrupted it, although it was running the
  same code again: the simulator then ran code that did not match the
  earlier steps of the test. The enclave now runs the code it ran from that
  point the first time. B3 is still found: its witness graph on `ef753b6`
  has 66 `reti` edges (2 on the fixing commit), and the counts on `6475709`
  and `bf89c0b` do not change. The former generator also let `prepare`
  choose new actions after a reset. Three other models (B1 on `ef753b6`, B3
  on `bf89c0b` with secret 1) are learned again with other state numbers
  only: they are isomorphic to the earlier ones.
- Specs can state constraints between sections, e.g.
  `constraint { disjoint(writes(isr), reads(enclave)) };`: the generator
  offers only actions that keep them, and never leads a section into a dead
  end. The Sancus atoms have the attributes `reads` and `writes` (the
  registers of the source and destination operands).
- Errors in specs give the file, line and column, and what was expected there.
- The input generation corpus (`tt_inputgen_golden`) now records the
  generator of ALVIE/Core (703 walks); `check --engine legacy` checks the
  former one, `--show-history` prints the history before a difference.

### Plugin files (preview)

- ALVIE/Core reads the YAML files that declare a plugin: the manifest, the
  sections, the atoms with their syntax templates, the observations, the
  phase rules and the attacker view. It checks each file and the files
  against each other, and reports every error with its file, line and
  column, with a suggestion after a typo. Unquoted YAML 1.1 booleans (`on`,
  `yes`, ...) are rejected. See the new Plugin Files Reference.
- `plugins/sancus/` declares ALVIE/Sancus in these files. Every spec in
  `spec-lib/` parses with its grammar to the same values as with
  `testdl.ml`. Learning and comparison do not use the files yet.
- The spec language is generic: named sections, the regular operators of
  TestDL, and the secret as a typed hole. `constraint`, `threads` and `step`
  blocks are reserved and rejected with an explanation.
- `alvie/code/schemas/` has a JSON Schema for each plugin file, for editors.
- New suite `tt_plugin` (fast, run in CI) and benchmark `test/value_bench.exe`.
- New dependencies: `yaml` and `yojson` (alvie-core), `qcheck-core`
  (alvie-sancus tests). The Dockerfile and the native installation
  instructions install them; CI adds them to the published image until it is
  rebuilt.

### Code structure

- The OCaml project is split into three opam packages: `alvie-core` (the L#
  learner and its oracles, the profiler, reading and writing `.dot` models,
  and the comparison engine; no backend), `alvie-rtl-util` (the VCD parser)
  and `alvie-sancus` (the Sancus backend, the executables and the test
  suites). The libraries move to `lib/core/`, `lib/rtl-util/` and
  `lib/sancus-compare/`; `Interop` moves from `bin/` to a library. The
  executables, their options and their outputs do not change, and
  `regression.sh all` finds the same models, witness graphs and counts.
- The comparison engine of `fa.exe` is generic: what it needs to know about
  the Sancus inputs and outputs (attacker inputs, public equality, hidden
  outputs, victim code) comes from a hooks module
  (`lib/sancus-compare/obs.ml`). The hooks are temporary, until the
  declarative attacker view replaces them.
- CI checks that `alvie-core` and `alvie-rtl-util` build on their own.
- `opam install . --deps-only --with-test` installs the dependencies of all
  three packages; `alvie.opam` is replaced by `alvie-core.opam`,
  `alvie-rtl-util.opam` and `alvie-sancus.opam`.

### Scripts

- `learn_all.sh` also learns the attacker `a`, so that it learns every model
  of `results/` ("All attacks" in the reproduction guide).

### Documentation

- The testing guide gives the current time of `tt_attack` (about 2 minutes
  with cached simulators).
- The testing guide documents the new suites, what to run after each kind of
  change, and what CI runs.

## 2026.10

### Performance

Learning is much faster; for example, `spec-lib/fast/b4` (`ef753b6`, interrupts,
secret 0) went from 2235s to about 11s of learning, and all the models of
`learn_all.sh` are learned in about 6 minutes on 16 cores.

- L#: apartness is cached across the run (it is monotone in the observation
  tree), frontier-to-basis candidates are tracked incrementally node by node,
  and the frontier, rule 2 and rule 3 no longer rescan the whole tree after
  every output query. Learned models and queries are unchanged;
  `ALVIE_CHECK_APART=1` cross-checks all of this against the original
  computations.
- Observation trees are updated incrementally.
- Verilog SUL: native VCD parser (no more Python), only the analysed signals
  are traced, the toolchain and the simulator are run without shell scripts,
  symbols are read from the ELF file, the program image is built with a
  one-time setup, and a no-op shell command run at every step is gone.
- Compiled simulators are cached across runs (`ALVIE_SIM_CACHE`).
- The GC is tuned for learning (`OCAMLRUNPARAM` overrides it).
- Experiment wrappers run at most `ALVIE_JOBS` experiments at a time
  (default: number of cores) instead of all of them at once.

### Fixes

- B3 on unpatched Sancus (`ef753b6`, interrupts) did not terminate: the
  instruction counter used by the SUL was compared as part of the
  observations, and repeated enclave re-entries kept producing new states.
  The counter is no longer compared, and the SUL identifies a re-entry
  segment with an identical one immediately preceding it
  (`--keep-repeated-reentries` disables this).

### Tooling

- `ALVIE_PROFILE=1` prints a wall-clock profile (also on `SIGUSR1`);
  `--info` logs PAC rounds and counterexamples.
- Learning logs end with a statistics line (`--report`), including the
  learning time.
- Drops the obsolete `tt_genall` and `tt_derive` programs and the `py` and
  `Verilog_VCD` dependencies.

### Known issues

- `equal_public_payload_t` in `alvie/code/lib/ltscomparator/cexfinder.ml` tests
  `p.mode` twice and never `p'.mode`, so the comparison of public payloads is
  asymmetric and too permissive: when the first payload is in PM it returns
  true whatever the second one is. It can suppress genuine violations in the
  analysis run by `fa.exe`. It is present in 2026.09 as well and is not fixed
  here, because fixing it changes the recorded witness counts.

### Documentation

- Documents the new options and environment variables (`--keep-repeated-reentries`,
  `ALVIE_SIM_CACHE`, `ALVIE_JOBS`, `ALVIE_PROFILE`, `ALVIE_CHECK_APART`,
  `ALVIE_FULL_TRACE`) and the `--info` output, and updates the measured
  times and the expected results.

### Results

- Regenerates `results/` and `counterexamples/`. Models differ from the
  CSF'24 ones because of the current toolchain (today's `main` produces the
  same models) and of the fixes above; witnesses report the same attacks.
  The models for the attack `a` are now learned from `spec-lib/a.atdl`
  (the previous ones were copies of those of `b6`/`b7`).

## 2026.09

This is the first release since the CSF'24 artifact (`csf24.v1`).

### ALVIE UI

ALVIE now has an easy-to-use graphical interface,
[alvie-ui](https://github.com/unive-alvie/alvie-ui): a user interface for the
ALVIE research tool from Ca’ Foscari University of Venice, developed by Marco
Ballarin and Giovanni Quacchia during their thesis work at Ca’ Foscari
University of Venice.

### Build and distribution

- Ports ALVIE to OCaml 4.14 and updates library calls.
- Merges the Dockerfiles into a single multi-platform image for amd64 and arm64,
  published as `matteobusi/alvie`, and adds `docker-build.sh`.
- Tracks `sancus-core-gap` as a git submodule.
- Trims unused simulator dependencies from the Docker image.
- Adds the MIT License.

### Features and fixes

- Adds a new TestDL action and human-readable trace markers (#20).
- Adds actionable CLI diagnostics (#23).
- Aligns executable behavior, `--help`, and the reference docs (#34).
  `pbt.exe --step-limit` is renamed to `--test-count`, and the old name
  remains as a deprecated alias.
- Fixes VCD signal lookup and macOS script compatibility.
- Fixes `mm_exec` to load its input from a file.

### Documentation

- Adds a documentation website, published from `main`, with getting-started,
  V-B1 tutorial, reproduction, and native-installation guides
  (#18, #19, #24, #25, #26, #30, #31, #33).
- Completes the TestDL specification reference and extension guide.

### Tests and CI

- Adds the isolated `tt_features` Alcotest suite (#22).
- Covers malformed specs and incomplete simulations (#29).
- Verifies the documentation in CI, and caches OCaml dependencies (#36).

### Removed

- Removes the archived L# prototypes. They remain on the
  `archive/minimal-lsharp-prototypes` branch (#35).

## csf24.v1

The artifact accompanying the CSF'24 paper.
