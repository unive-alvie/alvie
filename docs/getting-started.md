---
title: Getting Started
description: A first-session tutorial for building ALVIE and learning a Sancus model.
---

This tutorial is a guided first session with ALVIE. In about one hour, you
will build the project, run the included Sancus example, inspect the learned
models, and produce a counterexample graph.

The stable workflow described here uses the Verilog Sancus simulator. FPGA
execution is maintained separately from this documentation branch.

## What ALVIE does

ALVIE treats the Sancus implementation as a **system under learning** (SUL).
It sends the SUL sequences of attacker actions and records the outputs visible
to the attacker. The L# active-learning algorithm uses those observations to
construct a finite-state Mealy machine.

An experiment normally has two secrets and two interrupt settings. The four
learned models are compared by `fa.exe`; witnesses that only appear when
interrupts are enabled are written as Graphviz graphs.

The important distinction is:

- a learned `.dot` file is a model of the observations collected during one
  run;
- a witness graph is a distinguishing behavior found by comparing models;
- a nonzero witness count is evidence of an attack under the selected
  specifications and threat model, not a universal proof about Sancus.

## 1. Prepare the environment

The Dockerfile is the reference environment. From the repository root, build
and start it with:

```bash
docker build --platform linux/amd64 -t alvie .
docker run --rm -it alvie
```

The `linux/amd64` option is useful on ARM hosts because the mCRL2 package used
by this project is not available for every ARM platform.

For a native setup, install OCaml 4.13.1 with opam, Dune, the MSP430
toolchain, Icarus Verilog, Python 3 with the `Verilog_VCD` package, mCRL2, and
the tools required by the Sancus simulator. The Sancus checkout must be
available as `sancus-core-gap/` at the repository root.

Build ALVIE from its OCaml project directory:

```bash
cd alvie/code
dune build
cd ../..
```

If this command fails, fix the build before starting an experiment. Most
setup problems are an incomplete opam switch, a missing simulator dependency,
or a Sancus checkout in the wrong location.

## 2. Run the included example

The paper example is the shortest complete workflow. It learns the two
secret-dependent models and then compares them:

```bash
rm -rf results/example counterexamples/example logs/example tmp/example
./learn_example.sh
./check_example.sh
```

The first command removes only the example namespace, so it does not delete
results from other experiments. The learning wrapper creates output under:

```text
results/example/             learned Mealy machines
logs/example/                captured learning output
tmp/example/                 generated programs and VCD files
counterexamples/example/    comparison witnesses
```

The exact filenames depend on the commit and learner parameters. List the
files after the run:

```bash
find results/example counterexamples/example -name '*.dot' -print
```

The comparison wrapper should report its flow-analysis result and create a
witness graph when the example has a distinguishing behavior. A successful
command means the workflow completed; it does not mean that no attack exists.

## 3. Read the result

Graphviz can render a learned model or witness graph as a PDF:

```bash
dot -Tpdf \
  counterexamples/example/bf89c0b-attacker_int.dot \
  -o example-witness.pdf
```

The filename may differ, so use the `find` command above if this exact path is
not present. Open the PDF with a local viewer, or inspect the source directly:

```bash
head -30 counterexamples/example/*.dot
```

In a witness graph, follow the input labels from the initial state. An input
is an attacker action; the output on the edge is the observation returned by
the SUL. The graph records a distinguishing trace, so it is usually more
useful to read a short path than to inspect every state.

For the meaning of output tokens and timing payloads, see
[`Logs and outputs`](/alvie/reference/log-output-reference/). For the four-model
comparison and its command-line arguments, see
[`Executables reference`](/alvie/reference/executables-reference/).

## 4. Understand the specifications

Experiments are driven by two TestDL files:

- an attacker specification (`.atdl`) describes the inputs the attacker may
  issue;
- an enclave specification (`.etdl`) describes the victim program and its
  actions.

The included example specifications are under `spec-lib/example/`. Start with
the [TestDL tutorial](/alvie/reference/spec-tutorial/) to understand their syntax, then
use the [action reference](/alvie/reference/testdl-action-reference/) when reading an
existing specification.

The attack-focused specifications intentionally restrict the attacker to keep
learning tractable. They are not a complete model of every possible attacker
capability.

## 5. Try one attack

Once the example works, run one attack in its own namespace. B6 is a useful
first experiment because it is smaller than some of the other complete
attacks:

```bash
./learn_one.sh d54f031 b6 b6-sim
./check_one.sh b6 b6-sim
```

The namespace `b6-sim` keeps its results separate from `example`. A standard
attack run learns four models for each relevant Sancus commit: secret 0 and
secret 1, both with interrupts enabled and disabled. The final comparison
needs all four models.

For a quicker development run, use the smaller specifications in
`spec-lib/fast/`:

```bash
./learn_one.sh d54f031 b6 fast
```

Fast specifications are useful for checking code changes and timing. They are
not equivalent to the complete attacker profiles and should not replace the
complete paper experiment.

Learning time depends strongly on the machine, oracle settings, and selected
specification. Use a separate namespace for every run and keep the generated
logs when diagnosing a slow or failed experiment.

## Where to go next

- [`Reproducing the Simulation Experiments`](/alvie/guides/walkthrough-repro/) has
  the full simulator experiment commands and attack mapping.
- [`Executables Reference`](/alvie/reference/executables-reference/) documents the
  direct `learn.exe`, `fa.exe`, `exec.exe`, and `pbt.exe` interfaces.
- [`Code Architecture`](/alvie/reference/code-architecture/) explains the parser,
  input generator, SUL, learner, and comparison pipeline.
- [`Extending TestDL`](/alvie/guides/spec-extending-actions/) is the starting point
  for adding a specification action.

The project README contains the repository layout, complete attack list, and
Graphviz rendering examples.
