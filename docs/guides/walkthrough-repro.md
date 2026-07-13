---
title: Reproducing the Simulation Experiments
description: Build ALVIE and reproduce the paper experiments.
---

This walkthrough covers the stable Verilog-simulator workflow. It assumes the
repository root is the current directory and that `sancus-core-gap` is checked
out there.

## Prerequisites

The Dockerfile is the reference environment. Build and run it with:

```bash
docker build --platform linux/amd64 -t alvie .
docker run --rm -it alvie
```

The `linux/amd64` platform is needed on ARM hosts because the mCRL2 package
used by this project is not available for every ARM platform. Native users
need OCaml 4.13.1, Dune, the MSP430 toolchain, Verilator, Python 3 with
`Verilog_VCD`, mCRL2, and the Sancus simulator checkout.

Verify the OCaml build:

```bash
cd alvie/code
dune build
cd ../..
```

## Running example

The example wrapper learns secret 0 and secret 1 models for the final Sancus
commit, both with and without interrupt handling:

```bash
rm -rf results/example counterexamples/example logs/example tmp/example
./learn_example.sh
./check_example.sh
```

The learned models are in `results/example/`; the witness graph is in
`counterexamples/example/`. The exact output filenames are visible with:

```bash
find results/example counterexamples/example -name '*.dot' -print
```

Render a graph with Graphviz:

```bash
dot -Tpdf counterexamples/example/bf89c0b-attacker_int.dot -o example.pdf
```

The example test suite can be run independently:

```bash
cd alvie/code
dune exec tt_attack
```

## One attack

Use a namespace for each run. The third argument selects the output namespace;
when no matching directory exists under `spec-lib/`, the wrapper uses the root
specifications. B6 is a practical first experiment:

```bash
./learn_one.sh d54f031 b6 b6-sim
./check_one.sh b6 b6-sim
```

The standard fixing commits are:

| Attack | Fixing commit |
| --- | --- |
| B1 | `e8cf011` |
| B2 | `3170d5d` |
| B3 | `6475709` |
| B4 | `3636536` |
| B6 | `d54f031` |
| B7 | `264f135` |
| B8, B9 | no special fixing commit |

For B8 and B9:

```bash
./learn_one_nospecial.sh b8 b8-sim
./check_one.sh b8 b8-sim
```

Each standard attack run learns four models per relevant commit: secret 0 and
secret 1, with interrupts enabled and disabled. The comparison uses all four
models and writes a witness graph under `counterexamples/<namespace>/<attack>/`.
Learning time varies substantially with the machine and specification.

## All attacks

```bash
./learn_all.sh all-sim
./check_all.sh all-sim
```

The learning wrapper launches simulator jobs in parallel. Use a machine with
enough memory and disk space for the temporary VCD/program files.

## Fast specifications

`spec-lib/fast/` contains deliberately smaller attacker/enclave specifications.
Pass `fast` as the namespace to select them:

```bash
./learn_one.sh d54f031 b6 fast
```

Fast specifications are useful for development and timing experiments; they
are not equivalent to the complete attacker profiles.

## Direct commands

From `alvie/code`, a single model can be learned directly:

```bash
dune exec bin/learn.exe -- \
  --att-spec ../../spec-lib/b6.atdl \
  --encl-spec ../../spec-lib/enclave-complete.etdl \
  --res /tmp/alvie-b6-s0.dot \
  --tmpdir /tmp/alvie-b6 \
  --sancus ../../sancus-core-gap \
  --commit ef753b6 \
  --secret 0 \
  --oracle pac
```

Compare four models with:

```bash
dune exec bin/fa.exe -- \
  --m1-int /tmp/model-0-int.dot \
  --m2-int /tmp/model-1-int.dot \
  --m1-nint /tmp/model-0-nint.dot \
  --m2-nint /tmp/model-1-nint.dot \
  --tmpdir /tmp/alvie-fa \
  --witness-file-basename /tmp/alvie-witness
```

This writes `/tmp/alvie-witness_int.dot`. A nonzero violation count means the
comparison found distinguishing traces; it is evidence of an attack under the
learned models and selected threat model, not a universal proof about Sancus.

## Output layout

- `results/<namespace>/`: learned `.dot` Mealy machines.
- `counterexamples/<namespace>/`: comparison witness graphs.
- `logs/<namespace>/`: stdout/stderr captured by the wrappers.
- `tmp/<namespace>/`: generated assembly, binaries, simulator files, and VCDs.

The model filename contains the Sancus commit, attacker and enclave names,
secret, PAC parameters, and either `int` or `nint`.

## Troubleshooting

If the build fails, check the active OCaml switch and run `dune build` from
`alvie/code`. If the simulator cannot find a Sancus file, verify that the
`sancus-core-gap` checkout exists at the repository root and that the requested
commit is available in it. For slow or memory-heavy runs, start with B6 or a
smaller specification and inspect the corresponding log under `logs/`.

To remove generated artifacts for a namespace, use the project cleanup script
only after checking that it does not contain results you want to keep:

```bash
./clean.sh
```
