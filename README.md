# ALVIE

ALVIE is the source code accompanying *Bridging the Gap: Automated Analysis of
Sancus* by M. Busi, R. Focardi, and F. Luccio. It learns models of Sancus
enclave behavior and compares models for different secrets to find observable
attacks.

This branch documents the stable Verilog-simulator workflow. FPGA execution is
maintained separately.

## Repository layout

- `alvie/code/`: OCaml implementation and executables.
- `spec-lib/`: attacker (`.atdl`) and enclave (`.etdl`) specifications.
- `alvie/src/`: simulator templates and generated-program support files.
- `results/`: learned Graphviz models.
- `counterexamples/`: witness graphs produced by `fa.exe`.
- `logs/`: learning and comparison logs.
- `tmp/`: generated simulator programs and VCD files.
- `docs/`: specification, executable, output, reproduction, and architecture
  documentation.
- `sancus-core-gap/`: checkout of the Sancus simulator repository.

Start with [`docs/walkthrough-repro.md`](docs/walkthrough-repro.md) for a
working experiment and [`docs/code-architecture.md`](docs/code-architecture.md)
for the implementation overview.

The project landing page is published at
`https://unive-alvie.github.io/alvie/` once GitHub Pages is enabled for the
repository. The repository documentation is canonical and is linked from the
site; the Wiki is reserved for informal notes and discussion rather than being
a second copy of the technical reference.

## Prerequisites

The native workflow requires a Linux environment with OCaml/opam, Dune, the
MSP430 toolchain, Icarus Verilog, Python 3 with the `Verilog_VCD` package,
mCRL2, and the tools used by `sancus-core-gap`. The Dockerfile provides the
intended Ubuntu 22.04 dependency environment and installs OCaml 4.13.1.

Build the image on platforms where mCRL2 is available:

```bash
docker build --platform linux/amd64 -t alvie .
docker run --rm -it alvie
```

The published image name is historical and may not be available; building the
image locally is the reproducible option.

For a native checkout, make sure `sancus-core-gap` is present at the repository
root and build from `alvie/code`:

```bash
cd alvie/code
dune build
```

## Running the paper example

The example wrapper learns two models, one for each secret, then the comparison
wrapper produces witness graphs:

```bash
rm -rf results/example counterexamples/example logs/example tmp/example
./learn_example.sh
./check_example.sh
```

Models are written to `results/example/`, and witnesses to
`counterexamples/example/`. The exact runtime depends on the machine.

The test suite for the published attack examples is:

```bash
cd alvie/code
dune exec tt_attack
```

## Running one attack

The wrappers use an explicit output namespace. For a root `spec-lib/` attack,
use any namespace whose directory does not exist under `spec-lib`; the wrapper
then falls back to the root specifications. For example:

```bash
./learn_one.sh d54f031 b6 sim
./check_one.sh b6 sim
```

This learns the four models needed for B6 against the original, fixing, and
final Sancus commits, then compares them. B8 and B9 have no special fixing
commit:

```bash
./learn_one_nospecial.sh b8 sim
./check_one.sh b8 sim
```

The standard attack-to-fixing-commit mapping is:

| Attack | Fixing commit |
| --- | --- |
| B1 | `e8cf011` |
| B2 | `3170d5d` |
| B3 | `6475709` |
| B4 | `3636536` |
| B6 | `d54f031` |
| B7 | `264f135` |
| B8, B9 | no fix |

`bf89c0b` is the final known-good commit for the fixed attacks. Learning can
take from hours to days; `spec-lib/fast/` contains smaller, less complete
specifications for exploratory runs.

## Running all attacks

The all-attacks wrapper takes an output namespace and runs the simulator jobs
in parallel:

```bash
./learn_all.sh sim
./check_all.sh sim
```

Use a separate namespace for each experiment so results and logs do not mix.

## Direct executables

The main executables are:

- `learn.exe`: L# learning against the Verilog SUL.
- `fa.exe`: four-model flow-analysis comparison using mCRL2.
- `exec.exe`: developer utility for replaying its hardcoded input sequence.
- `pbt.exe`: property-based non-interference testing without model learning.

See [`docs/executables-reference.md`](docs/executables-reference.md) for the
actual flags and [`docs/log-output-reference.md`](docs/log-output-reference.md)
for the progress stream and output payloads.

## Specifications

The attacker and enclave languages are documented in:

- [`docs/spec-tutorial.md`](docs/spec-tutorial.md)
- [`docs/testdl-action-reference.md`](docs/testdl-action-reference.md)
- [`docs/spec-extending-actions.md`](docs/spec-extending-actions.md)

The attack-focused specifications intentionally use restricted attacker
capabilities to keep learning tractable. They are not a complete model of the
maximal attacker from the paper.

## Graphviz output

Convert a learned model or witness graph to PDF with Graphviz:

```bash
dot -Tpdf results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot \
  -o model.pdf
dot -Tpdf counterexamples/example/bf89c0b-attacker_int.dot \
  -o witness.pdf
```

The exact filenames depend on the experiment namespace and model naming
parameters. Existing `.dot` files are the authoritative generated output;
PDFs are only renderings.
