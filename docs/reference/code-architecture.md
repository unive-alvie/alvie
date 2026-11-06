---
title: Code Architecture
description: The ALVIE/Sancus implementation.
sidebar:
  order: 8
  badge:
    text: A
    variant: caution
---

This document describes the ALVIE/Sancus implementation.

## Packages

The code in `alvie/code` is split into three opam packages, defined in `dune-project`:

| Package | Directory | Libraries | Contents |
| --- | --- | --- | --- |
| `alvie-core` | `lib/core/` | `learninglib`, `prof`, `interop`, `ltscompare`, `alvie_plugin` | The L# learner and its oracles, the profiler, reading and writing `.dot` models, the comparison engine, and the plugin files and spec language. It has no backend. |
| `alvie-rtl-util` | `lib/rtl-util/` | `vcd` | Helpers for backends that simulate RTL designs: the VCD parser. It is not part of Core. |
| `alvie-sancus` | `lib/sancus/`, `lib/sancus-compare/`, `plugins/sancus/`, `bin/`, `test/` | `sancus`, `ltscomparator` | The Sancus backend, its plugin files and comparison hooks, the executables and the test suites. |

`alvie-core` does not depend on the other two packages: CI builds it on its own with `dune build -p alvie-core`, which fails if a library of `alvie-core` uses one of `alvie-sancus` or `alvie-rtl-util`.
`dune build` builds all three, and the executables keep their paths (`_build/default/bin/learn.exe` and so on).

The comparison engine (`Ltscompare.Cexfinder.Make`) does not know what the inputs and outputs of a model mean.
A backend tells it through the `Ltscompare.Hooks.S` signature: which inputs the attacker chooses, which outputs the attacker cannot see, which outputs end a run, when two outputs look the same to the attacker, which outputs come from the victim, and which victim code a run executes.
`lib/sancus-compare/obs.ml` gives the Sancus answers, and `fa.exe` uses the resulting instance.
These hooks are temporary: they become the declarative attacker view of the plugin files in a later release of ALVIE/Core.

### Plugin files and values

`alvie_plugin` reads the files that declare a plugin (see the [Plugin Files Reference](../plugin-files/)) and parses specs with them:

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
   `--inputgen legacy` uses the former generator, `Inputgen`, instead.
4. `Sancus.Verilog` implements the SUL (system under learning).
   It generates a program, runs the Sancus Verilog testbench, parses the VCD dump, and turns the trace into `Output_internal` observations.
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
| `lib/sancus/inputgen.ml` | The former input generator (`--inputgen legacy`); the simulator still uses its phase tracking |
| `lib/sancus/sul/verilog.ml` | Sancus SUL and VCD-to-observation conversion |
| `lib/sancus/output_internal.ml` | Observable output and timing payload types |
| `lib/core/lsharp/lsharp.ml` | L# learning loop |
| `lib/core/lsharp/observationtree.ml` | Observation tree and basis/frontier operations |
| `lib/core/lsharp/oracles/` | PAC, random-walk, exhaustive, and incremental oracles |
| `lib/core/interop/interop.ml` | Reading and writing learned machines as `.dot` files |
| `lib/core/compare/cexfinder.ml` | Model conversion, mCRL2 comparison and witness extraction, generic in the hooks |
| `lib/core/compare/hooks.ml` | What the comparison engine needs to know about a backend's inputs and outputs |
| `lib/rtl-util/vcd/vcd.ml` | VCD parser |
| `lib/core/prof/prof.ml` | Optional profiler (`ALVIE_PROFILE=1`) |
| `lib/sancus-compare/obs.ml` | The inputs and outputs that `fa.exe` compares, and the Sancus hooks |
| `bin/learn.ml` | Experiment orchestration and model writing |
| `bin/fa.ml` | Four-model flow-analysis comparison |

## The SUL contract

`lib/core/lsharp/sul.mli` defines the backend contract:

- `clone` creates an independent learning state;
- `pre` initializes a fresh experiment;
- `step` applies one input and returns one output;
- `post` releases backend resources.

`step` also supports `silent` and `dry_output` arguments.
L# uses these to separate observable steps from internal bookkeeping and to avoid rerunning a known output when exploring the observation tree.

The simulator backend keeps a configuration record containing the generated program, the current specification state, labels, and the last instruction number. `pre` resets that configuration.
The pending labels and the last instruction number are part of the returned output so that dry steps can restore them, but they are bookkeeping: output equality ignores them, so that states are told apart only by what is observed.
When an enclave is resumed with `reti`, the backend also identifies a segment of execution between two re-entries with an identical segment immediately before it, so that an enclave that can be resumed repeatedly still has a finite model (see `--keep-repeated-reentries`).
A step updates the specification state, generates the corresponding MSP430 program, runs the simulator, parses the VCD, and analyzes the trace at the instruction boundaries relevant to the input.

## Outputs and observability

The backend returns a list of `Output_internal.element_t` values plus labels and an execution-time summary.
Outputs distinguish normal, interrupt, reset, illegal, unsupported, and divergent behavior.
Timed payloads contain the cycle count `k`, interrupt-enable state, the public `r4` value, the observed unprotected memory value, the timer counter, and the processor mode.

The payload is deliberately smaller than the simulator state: it represents what the attacker can observe.
See the [Log and Output Reference](../log-output-reference/) for the rendered symbols and payload fields.

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
Follow the [Extending TestDL Actions](../../guides/spec-extending-actions/) guide.

### Add a learning backend

Implement the `SUL` signature, keep input and output types comparable and serializable, and instantiate `LSharp` with the new backend in an executable.
To compare its models, implement `Ltscompare.Hooks.S` for its inputs and outputs and instantiate `Ltscompare.Cexfinder.Make`, as `lib/sancus-compare/` does.
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

The [Testing ALVIE](/alvie/guides/testing-alvie/) guide explains each suite, what it needs, and when to run it.

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
