---
title: Code Architecture
description: The modules of ALVIE/Core, of the plugins Tiny and ALVIE/Sancus, and of the command line.
sidebar:
  order: 2
  badge:
    text: A
    variant: caution
---

This document describes the implementation: ALVIE/Core, its plugins Tiny and ALVIE/Sancus, and the command line.

## Packages

The code in `alvie/code` is split into three opam packages, defined in `dune-project`:

| Package | Directory | Libraries | Contents |
| --- | --- | --- | --- |
| `alvie-core` | `lib/core/`, `plugins/tiny/`, `sdk/` | `learninglib`, `prof`, `interop`, `ltscompare`, `alvie_plugin`, `alvie_inputgen`, `alvie_backend`, `alvie_cli`, `alvie_rpc`, `alvie_tiny` | The L# learner and its oracles, the profiler, reading and writing `.dot` models, the comparison engine, the plugin files and spec language, the input generator, the backend contract and its protocol, the commands of Core, external plugins, and Tiny, the reference platform. It has no Sancus code. |
| `alvie-rtl-util` | `lib/rtl-util/` | `vcd` | Helpers for backends that simulate RTL designs: the VCD parser. It is not part of Core. |
| `alvie-sancus` | `lib/sancus/`, `plugins/sancus/`, `bin/`, `test/` | `sancus` | The Sancus backend, its plugin files, the executables and the test suites. |

`alvie-core` does not depend on the other two packages: CI builds it on its own with `dune build -p alvie-core`, which fails if a library of `alvie-core` uses one of `alvie-sancus` or `alvie-rtl-util`.
`dune build` builds all three, and the executables keep their paths (`_build/default/bin/learn.exe` and so on).

The comparison engine (`Ltscompare.Cexfinder.Make`) does not know what the inputs and outputs of a model mean.
A backend tells it through the `Ltscompare.Hooks.S` signature: which inputs the attacker chooses, which outputs the attacker cannot see, which outputs end a run, when two outputs look the same to the attacker, which outputs come from the victim, and which victim code a run executes.
`Ltscompare.Plugin_hooks` derives all of them from the files of a plugin: hidden outputs and public equality from the attacker view (`view.yaml`, applied before mCRL2, so the comparison sees only what the attacker sees), the end of a run from the phase rules that stop or restart the test, the low inputs and the victim code from the roles of the sections, and the victim code up to the secret from the expansions of the secret's values.
The view also splits observations that stand for several events into parts (`parts:` rules), each one a transition of the compared model, with the interrupt as the input of the parts that are one.
`fa.exe` uses this engine with the Sancus plugin; nothing in the comparison is written for Sancus.

`Ltscompare.Properties` is the catalogue of properties (version 1): noninterference with an optional baseline, inclusion and equivalence of models, and mCRL2 modal mu-calculus formulas on one model.

### Plugin files and values

`alvie_plugin` reads the files that declare a plugin (see the [Plugin Files Reference](/alvie/plugin-authors/plugin-files/)) and parses specs with them:

| Module | Responsibility |
| --- | --- |
| `Value` | The values of atoms and observations, their JSON form, and interning |
| `Yaml_tree`, `Shape` | YAML with positions, and the decoders that check each file and generate its JSON Schema |
| `Manifest_file`, `Sections_file`, `Atoms_file`, `Observations_file`, `Rules_file` | One file format each |
| `Grammar` | The atom grammar: parsing and printing from the syntax templates, type checks, secret expansion |
| `Plugin` | Loading a plugin directory and the checks across its files |
| `Spec` | The spec language over values |

The parser is not generated as code: `Grammar` interprets the syntax templates.
It finds every way a type matches at a position, keeps the first declared alternative for each end position, and memoises on (type, position), so it runs in polynomial time even when templates are ambiguous.
In a spec body, an atom must be followed by an operator or by the end of its parenthesis or section; of the ways to read an atom, the parser takes the longest one that is.

Interned values (`Value.Interned`) hash and compare equal by their id.
They keep the structural order, which learning depends on, and compare by id when both were preloaded together (as the atoms of a spec will be before learning).
On the atoms of `spec-lib/`, interned values sort, hash and compare faster than today's derived functions on `Input.t` (see `test/value_bench.ml`); plain values are slower, mostly because their tags are strings.

## End-to-end pipeline

`learn.exe` performs one active-learning experiment:

1. `Alvie_plugin.Spec` parses the enclave and the attacker specification with the grammar of `plugins/sancus/` (embedded in the executables), and `Atom_value` gives the result in the form of `testdl.ml` for the simulator.
2. `Enclave` and `Attacker` compile the TestDL syntax into instruction/action templates.
   The secret placeholder is expanded before learning.
3. The input generator of ALVIE/Core (`Alvie_inputgen.Generator`, through `Generic_inputgen`) tracks which specification actions are legal after an observed input/output history and proposes the next input symbols.
   It follows the test through its sections with `plugins/sancus/phases.yaml`, applies the prefix rule, and checks the constraints of the spec.
4. `Sancus.Verilog` implements the SUL (system under learning): the Sancus backend (`Sancus.Simulator`) behind the adapter of ALVIE/Core.
   It generates a program from the programs of the sections that Core gives, runs it on a target (the Sancus Verilog testbench, or an FPGA board with `--target fpga`), finds the input's instructions in the trace, and turns them into `Output_internal` observations.
   Compiled simulators are cached across runs, and only the top level of the testbench is traced.
5. `Lsharp.LSharp` learns a Mealy machine using output queries and an equivalence oracle.
6. `Interop` serializes the learned machine as a Graphviz `.dot` file.
7. `fa.exe` converts learned machines to LTSs and uses mCRL2 to enumerate distinguishing traces.

The learner is parameterized by the SUL and oracle interfaces.
It keeps caches of apartness, frontier and frontier-to-basis candidates across the run, updated incrementally as the observation tree grows; they rely on the oracles numbering new tree nodes increasingly.
The production configuration in `learn.exe` uses `Sancus.Verilog` with one of the oracle implementations in `lib/core/lsharp/oracles/`.

## Main modules

| Module | Responsibility |
| --- | --- |
| `lib/sancus/testdl.ml` | TestDL parser and specification types |
| `lib/sancus/attacker.ml` | Attacker actions, compilation, derivatives, and action sets |
| `lib/sancus/enclave.ml` | Enclave actions, compilation, derivatives, and action sets |
| `lib/core/inputgen/generator.ml` | Input generation: phase rules, the prefix rule, interrupts, constraints |
| `lib/core/inputgen/deriv.ml` | Derivatives of spec bodies |
| `lib/sancus/generic_inputgen.ml` | The Core generator on Sancus inputs and outputs, with the embedded plugin files |
| `lib/sancus/inputgen.ml` | The former input generator, kept to compare with (`tt_inputgen_golden check --engine legacy`) |
| `lib/sancus/sul/simulator.ml` | The Sancus backend: code generation, the targets, simulation, the instructions of a step in the VCD dump |
| `lib/sancus/sul/fpga.ml` | The FPGA target: the serial port, the queries to the board, the instructions of a step in its trace |
| `lib/sancus/sul/step_analysis.ml` | From the instructions of a step to its observations, for both targets |
| `lib/sancus/serial_stubs.c` | Opens the serial port of the board at 5 Mbaud (Linux `termios2`) |
| `lib/sancus/sul/verilog.ml` | The Sancus SUL: the backend behind Core's adapter |
| `lib/core/backend/` | The backend contract and its adapter to the learner |
| `lib/sancus/output_internal.ml` | Observable output and timing payload types |
| `lib/core/lsharp/lsharp.ml` | L# learning loop |
| `lib/core/lsharp/observationtree.ml` | Observation tree and basis/frontier operations |
| `lib/core/lsharp/oracles/` | PAC, random-walk, exhaustive, and incremental oracles |
| `lib/core/interop/interop.ml` | Reading and writing learned machines as `.dot` files |
| `lib/core/compare/cexfinder.ml` | Model conversion, mCRL2 comparison and witness extraction, generic in the hooks |
| `lib/core/compare/hooks.ml` | What the comparison engine needs to know about a backend's inputs and outputs |
| `lib/rtl-util/vcd/vcd.ml` | VCD parser |
| `lib/core/prof/prof.ml` | Optional profiler (`ALVIE_PROFILE=1`) |
| `lib/core/compare/view.ml` | The attacker view: parts and what the attacker sees of each |
| `lib/core/compare/plugin_hooks.ml` | The hooks of the engine, derived from the plugin files |
| `lib/core/compare/properties.ml` | The catalogue of properties |
| `bin/alvie.ml` | The `alvie` command: the subcommands below and `plugin` |
| `bin/learn_cmd.ml` | `alvie learn` (`learn.exe`): its options, their checks and `--report`; the learning is the runner's (`Sancus_runner`) |
| `bin/fa_cmd.ml` | `alvie compare` (`fa.exe`): its options and output; the comparison is the runner's |
| `bin/sancus_runner.ml` | The commands of Core on Sancus, with the codec of Sancus (`Sancus.Native.Codec`) |
| `lib/core/cli/config.ml` | Options generated from a manifest (`Alvie_cli.Config`) |
| `lib/core/cli/runner.ml` | The commands of Core for any native plugin: learn, compare, property, exec, conformance, fixtures |
| `lib/core/cli/errors.ml` | How every command reports its errors, and its exit statuses |
| `lib/core/cli/plugin_cmd.ml`, `plugin_template.ml` | `alvie plugin check`, `schemas` and `new` (the template) |
| `lib/core/backend/native.ml` | What a native plugin gives Core: its files, its backend, and how to make one |
| `lib/core/tiny/tiny.ml` | Tiny, the reference platform (`plugins/tiny`) |
| `lib/sancus/native.ml` | ALVIE/Sancus as a native plugin, for `alvie sancus conformance` and `fixtures` |
| `lib/core/plugin/fixture_file.ml` | The fixtures of a plugin |
| `lib/core/backend/protocol.ml` | The protocol with external plugins: its messages and its JSON Schema |
| `lib/core/rpc/rpc_backend.ml`, `proc.ml` | An external plugin as a native one: the process, the calls, timeouts, recording and replay |
| `lib/core/cli/python_types.ml` | `alvie plugin types`: the Python constructors of a plugin's observations |
| `sdk/python/alvie_plugin.py` | The Python SDK |
| `lib/core/interop/interop.ml` | Model files: reading, writing, and their format line |

## The backend contract

`lib/core/backend/backend.ml` (`Alvie_backend.Backend.S`) is the contract between ALVIE/Core and a backend:

- `pre` starts a test from the initial state of the platform;
- `step` runs one input. Core gives the programs of all the sections, with the input included, and where the input is: its section, its position in the section's current run, and its atom. The backend generates the code, runs it to the end of the input, and returns the observations of the step (values of `observations.yaml`) and its bookkeeping;
- `restore` is a dry step: Core already knows the observations (from an earlier test with the same prefix) and gives them back with the bookkeeping the backend returned then; the backend updates its state as if it had run the step;
- `clone` makes an independent copy, for learning in parallel;
- `post` ends a test.

Bookkeeping is what the backend needs to continue a test but is not observed.
Core stores it and gives it back, but never compares it: two steps are equal when their observations are.

`lib/core/backend/sul.ml` adapts a backend to the SUL of the learner (`lib/core/lsharp/sul.mli`), so that L# and the oracles do not change.
The adapter follows the test with the input generator: it checks that each input is legal, computes the programs for the backend, turns dry steps into `restore`, and feeds the observations to the phase rules.
An input that the spec does not allow, and any input after the test has stopped, gets the illegal output without running the backend.
A codec translates between the learner's input and output types and Core's values: `Sul.Values` for a learner that works on values, as the toy backend of `tt_plugin` does; `Sul.Atoms`, whose inputs are atoms of a class (the same input in every section of that class), for the commands of Core (`Alvie_cli.Runner`); ALVIE/Sancus keeps its own types (`Input.t`, `Output_internal.t`), so that its model files keep their format: its codec (`Sancus.Native.Codec`) is that of the runner too.

## Native plugins and the commands of Core

A native plugin is a module of signature `Alvie_backend.Native.S`: its plugin files (embedded in the program), its backend, and `make`, which builds a backend from the values of the manifest's parameters and a variant.
`Alvie_cli.Runner.Make` turns it into the commands of Core, with the codec `Atoms_codec`; `Runner.Make_codec` takes another codec (`Runner.MODEL_CODEC`), which says what the learner's inputs and outputs are, its alphabet, and what model files keep. The commands are: `learn` (L# with the PAC or random-walk oracle, inputs chosen by the generator from the spec), `compare` (noninterference with `Plugin_hooks`), `property`, `exec`, `conformance` (random tests of the spec, checked against the contract) and `fixtures`.
`alvie tiny` and `alvie sancus` are these commands for Tiny and Sancus, and `alvie plugin new` makes a plugin with its own `alvie-NAME`.
Every plugin learns and compares through these functions, ALVIE/Sancus included: `learn.exe` and `fa.exe` are front ends that keep their options and output, and learn and compare with the runner and the codec of Sancus (`bin/sancus_runner.ml`), with the random inputs outside the spec (`--bad-probability`) and the exhaustive oracle that the runner offers as options.
`Runner.Make(N).Model_native` replays a learned model as a native plugin, to test the learner.
`Alvie_rpc.Rpc_backend.native ~dir` makes the module of an external plugin at run time, from its directory: `alvie external DIR` gives it the same commands.

The Sancus backend is `lib/sancus/sul/simulator.ml`, and `Sancus.Verilog` is its adapter.
It compiles the programs that Core gives into the testbench template: the input's occurrence is labelled, so that the analysis finds its instructions, and the other atoms run but are not analysed.
Its bookkeeping is the code still to analyse and the number of the last instruction analysed.
When an enclave is resumed with `reti`, the backend also identifies a segment of execution between two re-entries with an identical segment immediately before it, so that an enclave that can be resumed repeatedly still has a finite model (see `--keep-repeated-reentries`); it compares the places in the spec with the key that Core gives (`Generator.key`).
A step generates the MSP430 program, runs it on the target, and analyzes the trace at the instruction boundaries relevant to the input.
The target (`Simulator.target`) is only how a step runs and how its instructions are found in the trace: the simulator parses its VCD dump (`analyse_dump`); the FPGA target (`Sancus.Fpga`) sends the program to the board and reads back a window of 50 clock cycles.
Both give the signals of each instruction to `Sancus.Step_analysis`, which turns them into observations; everything else is the same for both.

## Outputs and observability

The backend returns a list of `Output_internal.element_t` values plus labels and an execution-time summary.
Outputs distinguish normal, interrupt, reset, illegal, unsupported, and divergent behavior.
Timed payloads contain the cycle count `k`, interrupt-enable state, the public `r4` value, the observed unprotected memory value, the timer counter, and the processor mode.

The payload is deliberately smaller than the simulator state: it represents what the attacker can observe.
See the [Log and Output Reference](/alvie/sancus/log-output-reference/) for the rendered symbols and payload fields.

## Learning and comparison boundaries

The learner does not compare secrets directly.
Run it separately for secret 0 and secret 1, with and without interrupt actions, producing four models.
The comparison tool receives the two interrupt-enabled models and the two no-interrupt models.
It removes witnesses already present without interrupts, then reports the remaining flow-analysis violations in `<basename>_int.dot`.
Each witness pairs two runs, one for each secret, with the same attacker inputs.
mCRL2 checks trace inclusion, which is not symmetric, so `find_all_cex_sym` searches both directions (the secret 0 model against the secret 1 model, and the other way round), for the models with and without interrupts, and keeps each distinct witness once.
The runs are taken from the models as complete paths: a run ends at a reset, a divergence, a state without successors, or a state the same run has already visited, never because another run reached that state first.

This is why a single successful learning run is not a complete attack result: the four-model matrix and the comparison phase are both required.

## Extension points

### Add a TestDL action

Update the syntax and parser, the attacker or enclave atom type, compilation, derivative/action-set logic, and tests.
Follow the [Extending TestDL Actions](/alvie/sancus/spec-extending-actions/) guide.

### Add a learning backend

Implement the `SUL` signature, keep input and output types comparable and serializable, and instantiate `LSharp` with the new backend in an executable.
To compare its models, instantiate `Ltscompare.Plugin_hooks.Make` with its plugin and `Ltscompare.Properties.Make` (or `Cexfinder.Make`) with the result, as `fa.exe` does.
Depend only on the libraries of `alvie-core` (and `alvie-rtl-util` if the backend simulates RTL), not on `alvie-sancus`.
The backend must preserve the observable-output contract; changing payload semantics changes learned models and their comparability.

### Add an oracle

Implement the `Oracle` functor signature in `lib/core/lsharp/oracles/oracle.mli`.
The oracle supplies output queries and equivalence queries; it may use the input generator to stay within the selected TestDL specification.

## Build and test

From `alvie/code`:

```bash
dune build
bash test/cli_diagnostics.sh
```

The [Testing ALVIE](/alvie/development/testing-alvie/) guide explains each suite, what it needs, and when to run it.

`test/cli_diagnostics.sh` runs the ALVIE-only diagnostic suite, including TestDL parsing and command-line validation.
It does not require the Sancus simulator or mCRL2.

The isolated feature suite exercises TestDL parsing and derivatives, code generation, specification-guided input generation, observation-tree algorithms, and serialization without external target tooling:

```bash
dune exec tt_features -- test --color=never
```

`tt_attack` is the simulator-backed regression suite.
It replays the supplied attack traces against expected observations for the relevant Sancus commits, secrets, and interrupt modes.
It requires the external Sancus checkout and its simulator toolchain:

```bash
dune exec tt_attack -- test --color=never
```

The shell wrappers at repository root build first and place models, logs, and temporary simulator files under `results/`, `logs/`, and `tmp/`.
The `sancus-core-gap` checkout must be available at the repository root for simulator experiments.

## Generated files

Source and specifications live in `alvie/`, `spec-lib/`, and `src/`.
Learned models, comparison witnesses, logs, and temporary simulator programs are generated artifacts.
Do not use generated `.dot`, VCD, or temporary files as the source of truth for backend behavior; inspect the OCaml SUL and the simulator/testbench when changing semantics.
