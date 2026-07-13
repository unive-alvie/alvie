# ALVIE Code Architecture

This document describes the stable, simulator-based implementation in this
branch. FPGA support is maintained separately and is intentionally outside
this guide.

## End-to-end pipeline

`learn.exe` performs one active-learning experiment:

1. `Testdl.Parser` parses an enclave specification and an attacker
   specification.
2. `Enclave` and `Attacker` compile the TestDL syntax into instruction/action
   templates. The secret placeholder is expanded before learning.
3. `Inputgen` tracks which specification actions are legal after an observed
   input/output history and proposes the next input symbols.
4. `Sancus.Verilog` implements the SUL (system under learning). It generates a
   program, runs the Sancus Verilog testbench, parses the VCD dump, and turns
   the trace into `Output_internal` observations.
5. `Lsharp.LSharp` learns a Mealy machine using output queries and an
   equivalence oracle.
6. `Interop` serializes the learned machine as a Graphviz `.dot` file.
7. `fa.exe` converts learned machines to LTSs and uses mCRL2 to enumerate
   distinguishing traces.

The learner is parameterized by the SUL and oracle interfaces. The production
configuration in `learn.exe` uses `Sancus.Verilog` with one of the oracle
implementations in `lib/lsharp/oracles/`.

## Main modules

| Module | Responsibility |
| --- | --- |
| `lib/sancus/testdl.ml` | TestDL parser and specification types |
| `lib/sancus/attacker.ml` | Attacker actions, compilation, derivatives, and action sets |
| `lib/sancus/enclave.ml` | Enclave actions, compilation, derivatives, and action sets |
| `lib/sancus/inputgen.ml` | Specification-guided input generation and matchability |
| `lib/sancus/sul/verilog.ml` | Simulator-backed SUL and VCD-to-observation conversion |
| `lib/sancus/output_internal.ml` | Observable output and timing payload types |
| `lib/lsharp/lsharp.ml` | L# learning loop |
| `lib/lsharp/observationtree.ml` | Observation tree and basis/frontier operations |
| `lib/lsharp/oracles/` | PAC, random-walk, exhaustive, and incremental oracles |
| `lib/ltscomparator/cexfinder.ml` | Model conversion and witness extraction |
| `bin/learn.ml` | Experiment orchestration and model writing |
| `bin/fa.ml` | Four-model flow-analysis comparison |

## The SUL contract

`lib/lsharp/sul.mli` defines the backend contract:

- `clone` creates an independent learning state;
- `pre` initializes a fresh experiment;
- `step` applies one input and returns one output;
- `post` releases backend resources.

`step` also supports `silent` and `dry_output` arguments. L# uses these to
separate observable steps from internal bookkeeping and to avoid rerunning a
known output when exploring the observation tree.

The simulator backend keeps a configuration record containing the generated
program, the current specification state, labels, and the last instruction
number. `pre` resets that configuration. A step updates the specification
state, generates the corresponding MSP430 program, runs the simulator, parses
the VCD, and analyzes the trace at the instruction boundaries relevant to the
input.

## Outputs and observability

The backend returns a list of `Output_internal.element_t` values plus labels and
an execution-time summary. Outputs distinguish normal, interrupt, reset,
illegal, unsupported, and divergent behavior. Timed payloads contain the
cycle count `k`, interrupt-enable state, the public `r4` value, the observed
unprotected memory value, the timer counter, and the processor mode.

The payload is deliberately smaller than the simulator state: it represents
what the attacker can observe. See
`docs/log-output-reference.md` for the rendered symbols and payload fields.

## Learning and comparison boundaries

The learner does not compare secrets directly. Run it separately for secret 0
and secret 1, with and without interrupt actions, producing four models. The
comparison tool receives the two interrupt-enabled models and the two
no-interrupt models. It removes witnesses already present without interrupts,
then reports the remaining flow-analysis violations in
`<basename>_int.dot`.

This is why a single successful learning run is not a complete attack result:
the four-model matrix and the comparison phase are both required.

## Extension points

### Add a TestDL action

Update the syntax and parser, the attacker or enclave atom type, compilation,
derivative/action-set logic, and tests. Follow
`docs/spec-extending-actions.md`.

### Add a learning backend

Implement the `SUL` signature, keep input and output types comparable and
serializable, and instantiate `LSharp` with the new backend in an executable.
The backend must preserve the observable-output contract; changing payload
semantics changes learned models and their comparability.

### Add an oracle

Implement the `Oracle` functor signature in
`lib/lsharp/oracles/oracle.mli`. The oracle supplies output queries and
equivalence queries; it may use `Inputgen` to stay within the selected TestDL
specification.

## Build and test

From `alvie/code`:

```bash
dune build
dune exec tt_attack
dune exec tt_derive
dune exec tt_genall
```

The shell wrappers at repository root build first and place models, logs, and
temporary simulator files under `results/`, `logs/`, and `tmp/`. The Sancus
submodule/repository must be available at `sancus-core-gap` for simulator
experiments.

## Generated files

Source and specifications live in `alvie/`, `spec-lib/`, and `src/`. Learned
models, comparison witnesses, logs, and temporary simulator programs are
generated artifacts. Do not use generated `.dot`, VCD, or temporary files as
the source of truth for backend behavior; inspect the OCaml SUL and the
simulator/testbench when changing semantics.
