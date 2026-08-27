---
title: Getting Started
description: A first-session tutorial for building ALVIE/Sancus and learning a Sancus model.
---

This one-hour tutorial is a first guided session with ALVIE/Sancus.
Together, we build the project, run the included Sancus example, inspect the learned models, and produce a counterexample graph.

## A quick introduction to ALVIE

ALVIE is a security-analysis tool that combines **active automata learning** with model checking.
It is designed to find timing side-channel attacks on processor implementations, which ALVIE treats as **systems under learning** (SULs).
A typical ALVIE run, called an *experiment* in this tutorial, starts with a threat model and a family of relevant victim programs.
ALVIE then uses the L# active automata learning algorithm to query the SUL with sequences of attacker and victim actions, records the resulting observations, and constructs finite-state Mealy-machine models.
Finally, the [mCRL2 model checker](https://www.mcrl2.org/) checks those learned models for security-relevant behavioral differences.

ALVIE was initially designed for [Sancus](https://github.com/sancus-tee), a lightweight trusted execution environment for secure IoT devices, and this tutorial focuses on that target.
As part of the [CCAT project](https://ccat.fi.muni.cz/), ALVIE is being extended to other architectures.
**ALVIE/Sancus** denotes the Sancus-specific backend and workflow, while **ALVIE** refers to the general framework.

ALVIE/Sancus experiments assess whether families of Sancus enclaves, which are hardware-protected memory regions for code and data, protect their secrets from timing and interrupt-capable attackers.
A standard experiment uses the same attacker and victim specifications to learn four models: secret 0 and secret 1, each with interrupts enabled and ignored.
`fa.exe` compares the two interrupt-enabled models and filters out differences that are also present in the no-interrupt models.
The remaining differences are written as Graphviz witness graphs.

The important distinction is:

- a learned `.dot` file is a Mealy machine obtained from the observations collected during one run;
- a witness graph is a distinguishing behavior found by comparing models;
- a nonzero witness count is evidence of a possible attack under the selected specifications and threat model, not a universal proof about Sancus;
- a zero witness count means that no distinguishing behavior was found under the selected specifications and threat model.
  When the PAC oracle is used, its confidence is controlled by `--epsilon` and `--delta`, but the result is not a universal proof that Sancus is immune.

## 1. Prepare the environment

The fastest first setup uses the published Docker image, which includes the reference ALVIE environment and the required Sancus checkout.
We first create a host directory, then mount it into the container so PDFs, witness graphs, custom specifications, and other outputs remain available after the container exits:

```bash
mkdir -p "$PWD/alvie-output"
docker pull matteobusi/alvie
docker run --rm -it \
  -v "$PWD/alvie-output:/output" \
  matteobusi/alvie
```

The container starts in its repository root.
The image is published at [Docker Hub](https://hub.docker.com/r/matteobusi/alvie), and `--rm` removes the container when it exits.
The bind mount exposes `/output` as `./alvie-output` on the host.
The ALVIE/Sancus wrapper scripts write to repository directories inside the container, so we explicitly copy selected results into `/output` before the container exits.
We keep custom specifications under `/output` as well when we want to edit or reuse them on the host.
We do not mount a host directory over `/home/alvie`, because that would hide the ALVIE/Sancus installation bundled in the image.

To build the same environment locally instead, use the repository Dockerfile:

```bash
docker build -t alvie .
docker run --rm -it alvie
```

The Dockerfile builds for the host architecture by default.

For a native setup, we install OCaml 4.13.1 with opam, Dune, the MSP430 toolchain, Verilator, Python 3 with the `Verilog_VCD` package, mCRL2, and the tools required by the Sancus simulator.
The Sancus checkout must be available as `sancus-core-gap/` at the repository root.

## 2. Compile ALVIE/Sancus

After the environment is set up, build ALVIE/Sancus from its OCaml project directory:

```bash
cd alvie/code
dune build
cd ../..
```

If this command fails, fix the build before starting an experiment.
Most setup problems are an incomplete opam switch, a missing simulator dependency, or a Sancus checkout in the wrong location.
If the build continues to fail, open a [GitHub issue](https://github.com/unive-alvie/alvie/issues) with the setup details and completed steps.

## 3. Run the included example

The paper example is the shortest complete workflow.
It learns one interrupt-enabled model for each secret and compares the two; unlike the full attack workflow, it does not learn no-interrupt baselines.

```bash
rm -rf results/example counterexamples/example logs/example tmp/example
./learn_example.sh
./check_example.sh
```

The first command removes only existing results, counterexamples, logs, and temporary files in the `example` namespace.
Run it only when an earlier example run is no longer needed.
The learning wrapper creates output under:

```text
results/example/             learned Mealy machines
logs/example/                captured learning output
tmp/example/                 generated programs and VCD files
counterexamples/example/    comparison witnesses
```

When using Docker, copy the durable artifacts to the bind mount before exiting the container:

```bash
mkdir -p /output/results /output/counterexamples /output/logs
cp -a results/example /output/results/
cp -a counterexamples/example /output/counterexamples/
cp -a logs/example /output/logs/
```

On the host, they then appear under `alvie-output/results`, `alvie-output/counterexamples`, and `alvie-output/logs`.
The temporary simulator files under `tmp/example` are intentionally not copied.

The exact filenames depend on the commit and learner parameters.
List the files after the run:

```bash
find results/example counterexamples/example -name '*.dot' -print
```

The comparison wrapper reports its flow-analysis result and creates a witness graph when the example has a distinguishing behavior.
A successful command means the workflow completed; it does not mean that no attack exists.

## 4. Read the result

Graphviz can render a learned model or witness graph as a PDF:

```bash
dot -Tpdf \
  counterexamples/example/bf89c0b-attacker_int.dot \
  -o example-witness.pdf
```

The filename may differ, so use the `find` command above if this exact path is not present.
When using Docker, run `cp example-witness.pdf /output/` to make the PDF available as `alvie-output/example-witness.pdf` on the host.
Open the PDF with a local viewer, or inspect the source directly:

```bash
head -30 counterexamples/example/*.dot
```

In a witness graph, follow the input labels from the initial state.
An input is an attacker action; the output on the edge is the observation returned by the SUL.
The graph records a distinguishing trace, so it is usually more useful to read a short path than to inspect every state.

For the meaning of output tokens and timing payloads, see [`Logs and outputs`](/alvie/reference/log-output-reference/).
For the four-model comparison and its command-line arguments, see [`Executables reference`](/alvie/reference/executables-reference/).

## When a run does not finish

Before interpreting an experiment, distinguish a completed result from an incomplete one:

- A completed comparison with a witness is a **finding** under the learned models and selected threat model.
- A completed comparison without a witness is **no finding under that configuration**.
  It does not establish that every Sancus program is secure.
- A timeout, an interrupted command, or a wrapper that stops before learning all required models is **incomplete**.
  It provides no result to interpret, so keep its logs and rerun it in a fresh namespace when ready.
- A build, setup, or command-line error is also **incomplete**.
  Read the error and corresponding log first, then open a [GitHub issue](https://github.com/unive-alvie/alvie/issues) when the documented setup cannot proceed.

For any long run, the matching `logs/<namespace>/` directory records the command output, while `results/<namespace>/` and `counterexamples/<namespace>/` show which artifacts were actually produced.

## 5. Understand the specifications

Experiments are driven by two TestDL files:

- an attacker specification (`.atdl`) describes the inputs the attacker may issue;
- an enclave specification (`.etdl`) describes the victim program and its actions.

The included example specifications are under `spec-lib/example/`.
Start with the [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/) to understand their syntax.
Then use the [action reference](/alvie/reference/testdl-action-reference/) when reading an existing specification.

The attack-focused specifications intentionally restrict the attacker to keep learning tractable.
They are not a complete model of every possible attacker capability.

## 6. Try one attack

Once the example works, we run one attack in its own namespace.
B6 is a useful first experiment because it is smaller than some of the other complete attacks:

```bash
./learn_one.sh d54f031 b6 b6-sim
./check_one.sh b6 b6-sim
```

The namespace `b6-sim` keeps its results separate from `example`.
A standard attack run learns four models for each relevant Sancus commit: secret 0 and secret 1, both with interrupts enabled and ignored.
The final comparison needs all four models.
When using Docker, preserve this namespace with `cp -a results/b6-sim /output/results/`, `cp -a counterexamples/b6-sim /output/counterexamples/`, and `cp -a logs/b6-sim /output/logs/` before exiting.

For a quicker development run, use the smaller specifications in `spec-lib/fast/`:

```bash
./learn_one.sh d54f031 b6 fast
```

Fast specifications are useful for checking code changes and timing, but they are not equivalent to the complete attacker profiles.

Learning time depends strongly on the machine, oracle settings, and selected specification.
Use a separate namespace for every run and keep the generated logs when diagnosing a slow or failed experiment.

## Where to go next

- [`Reproducing the Simulation Experiments`](/alvie/guides/walkthrough-repro/) has the full simulator experiment commands and attack mapping.
- [`Executables Reference`](/alvie/reference/executables-reference/) documents the direct `learn.exe`, `fa.exe`, `exec.exe`, and `pbt.exe` interfaces.
- [`Code Architecture`](/alvie/reference/code-architecture/) explains the parser, input generator, SUL, learner, and comparison pipeline.
- [`Extending TestDL`](/alvie/guides/spec-extending-actions/) is the starting point for adding a specification action.

The project README contains the repository layout, complete attack list, and Graphviz rendering examples.
