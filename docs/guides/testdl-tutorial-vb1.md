---
title: 'TestDL Tutorial: V-B1 Example'
description: A one-hour introduction to the TestDL languages through a worked V-B1 example.
---

This tutorial is a first practical session with the two small languages used
by ALVIE. In about one hour, we illustrate the TestDL languages through a
worked example: the specification used to reproduce the V-B1 vulnerability
from the [*Mind the Gap* paper](https://mici.hu/papers/bognar22gap.pdf), using
the corresponding [Sancus implementation](https://github.com/martonbognar/sancus-core-gap).
The example uses a reduced fast profile so the first model can be learned more
quickly.

The complete syntax and semantics are in the
[TestDL Action Reference](/alvie/reference/testdl-action-reference/). Use that page
when you need details; this tutorial focuses on where to start and what each
part is doing.

For the quickest setup, use the published Docker image described in
[Getting Started](/alvie/getting-started/):

```bash
docker pull matteobusi/alvie
docker run --rm -it matteobusi/alvie
```

The image already contains ALVIE, its dependencies, and `sancus-core-gap`; it
starts in the repository root, so the paths below work unchanged. The Docker
Hub image is [matteobusi/alvie](https://hub.docker.com/r/matteobusi/alvie).
Use the native setup instructions in [Getting Started](/alvie/getting-started/)
only when you need a local development environment.

## What you will build

An ALVIE experiment combines two files:

- an attacker specification (`.atdl`) describes allowed attacker actions,
  including interrupt behavior;
- an enclave specification (`.etdl`) describes the victim program.

The worked example uses:

```text
spec-lib/fast/b1.atdl
spec-lib/fast/enclave-complete.etdl
```

The fast profile is intentionally smaller than the complete profile. It is
suitable for learning the language and workflow, but it is not a replacement
for the full paper experiment.

## 1. Prepare the checkout

If you are using a native checkout rather than the Docker image, check that
the required Sancus repository is present and build the OCaml project:

```bash
test -d sancus-core-gap
cd alvie/code
dune build
cd ../..
```

`test -d sancus-core-gap` succeeds only when the simulator checkout is at the
repository root. `dune build` compiles the executables used later in this
tutorial; the `cd` commands enter and leave ALVIE's OCaml project directory.
See [Getting Started](/alvie/getting-started/) for the full environment setup.

If the build fails, follow [Getting Started](/alvie/getting-started/) first.

## 2. Read the enclave specification

Open `spec-lib/fast/enclave-complete.etdl`. Its outer `enclave` section is the
set of victim-program behaviours ALVIE may instantiate. Each expression
describes a possible protected program fragment, not an instruction the
attacker chooses directly. Its outer form is:

```text
enclave {
    ...
};
```

Actions separated by `; ` run in sequence. The `?` placeholder is replaced by
the value passed to `learn.exe --secret`:

```text
cmp ?, r4;
jmp #enc_e
```

The large parenthesized expression in the file contains alternatives joined
by `|`. Parentheses group an expression, `eps` means an empty action, and a
choice lets the learner explore different allowed victim behaviors.

One representative branch is:

```text
ifz (mov #42, &unprot_mem; nop)
    (nop; mov #42, &unprot_mem)
```

The full meaning of `ifz`, operands, memory labels, and instruction atoms is
covered by the [TestDL Action Reference](/alvie/reference/testdl-action-reference/).

## 3. Read the attacker specification

Open `spec-lib/fast/b1.atdl`. Attacker files have three sections:

```text
isr { ... };
prepare { ... };
cleanup { ... };
```

The example attacker specification contains:

```text
isr {
    timer_enable 1;
    reti
};

prepare {
    timer_enable 3;
    create <enc_s, enc_e, data_s, data_e>;
    jin enc_s
};

cleanup { nop };
```

`prepare` is the attacker-controlled setup executed before the interaction
being learned: here it configures a timer, enables the enclave with its memory
boundaries, and transfers control to the enclave entry point. `isr` describes
the code run when the timer interrupts execution. In this example it schedules
the next interrupt at one tick and returns with `reti`, making closely spaced
interrupts part of the threat model. `cleanup` is the attacker-controlled
suffix after an interaction; it is where a specification can model teardown,
reset, or follow-up actions. This example uses `nop`, so cleanup has no extra
effect.

These bodies use the same `; `, `|`, `eps`, repetition, and grouping operators
as enclave expressions. The [TestDL Language Reference](/alvie/reference/spec-tutorial/)
describes their grammar, and the [TestDL Action Reference](/alvie/reference/testdl-action-reference/)
defines the actions.

## 4. Learn one model first

Run one secret value directly. This keeps the first experiment understandable:

```bash
cd alvie/code
dune exec bin/learn.exe -- \
  --att-spec ../../spec-lib/fast/b1.atdl \
  --encl-spec ../../spec-lib/fast/enclave-complete.etdl \
  --oracle randomwalk \
  --step-limit 500 \
  --reset-probability 0.05 \
  --res /tmp/alvie-b1-fast-s0.dot \
  --tmpdir /tmp/alvie-b1-fast-s0 \
  --sancus ../../sancus-core-gap \
  --commit ef753b6 \
  --secret 0
```

This command learns one model for secret `0` only:

- `--att-spec` and `--encl-spec` select the fast V-B1 attacker and victim
  languages.
- `--oracle randomwalk` selects random-walk equivalence queries;
  `--step-limit 500` bounds each walk and `--reset-probability 0.05` gives the
  probability of restarting a walk.
- `--res` is the learned-model output file, while `--tmpdir` holds generated
  assembly, binaries, simulator files, and VCD traces.
- `--sancus` locates the Sancus checkout; `--commit ef753b6` selects the
  vulnerable revision used by the V-B1 case study; `--secret 0` substitutes
  `0` for the enclave's `?` placeholder.

The command writes a learned Mealy machine to `/tmp/alvie-b1-fast-s0.dot`.
For the complete option reference, see [Executables Reference](/alvie/reference/executables-reference/#1-learnexe--learn-a-mealy-machine-model).

Inspect it with:

```bash
head -20 /tmp/alvie-b1-fast-s0.dot
dot -Tpdf /tmp/alvie-b1-fast-s0.dot -o /tmp/alvie-b1-fast-s0.pdf
```

`head` shows the beginning of the Graphviz model as text. `dot -Tpdf` renders
the same file to a PDF; `-o` names that PDF. These commands inspect the learned
model and do not rerun learning.

The `.dot` file is an observed model, not the generated victim program. Its
edges contain attacker inputs and the outputs returned by the simulator.

## 5. Use the wrapper after the first run

Once the direct command is clear, use the repository wrapper for the example's
fast profile:

```bash
cd ../..
./learn_one.sh e8cf011 b1 fast
./check_one.sh b1 fast
```

`cd ../..` returns from `alvie/code` to the repository root. In
`learn_one.sh e8cf011 b1 fast`, `e8cf011` is V-B1's special fixing commit,
`b1` selects the attacker spec, and `fast` is both the specification directory
and output namespace. The wrapper learns secret 0/1 models with and without
interrupts for the vulnerable, special-fix, and final commits. `check_one.sh
b1 fast` compares the secret pairs and subtracts no-interrupt witnesses.

Results, logs, and temporary files are placed under `results/fast/`,
`logs/fast/`, and `tmp/fast/`. See [Reproducing the Simulation Experiments](/alvie/guides/walkthrough-repro/)
for wrapper behavior and [Executables Reference](/alvie/reference/executables-reference/)
for the underlying commands.

For the full paper profile, replace `fast` with a separate namespace and use
the complete specifications. Expect it to take substantially longer.

## 6. Make a small change

Copy a specification before experimenting so generated output stays separate:

```bash
cp spec-lib/fast/b1.atdl /tmp/my-b1.atdl
```

This copies the original fast attacker specification to a disposable path.
Keep the original under `spec-lib/` unchanged, then pass `/tmp/my-b1.atdl` as
`--att-spec` and choose new `--res` and `--tmpdir` paths when rerunning the
direct learner command.

Change one timer, choice, or action and rerun the direct command with a new
`--res` and `--tmpdir`. Parser errors usually come from a missing semicolon,
unmatched parenthesis, unknown action, or invalid register. Consult the
[action reference](/alvie/reference/testdl-action-reference/) for exact syntax and
[Extending TestDL Actions](/alvie/guides/spec-extending-actions/) when adding a new
language construct.

## Related files

- Complete V-B1 attacker profile: `spec-lib/b1.atdl`
- Complete enclave profile: `spec-lib/enclave-complete.etdl`
- Full experiment workflow: [Reproducing the Simulation Experiments](/alvie/guides/walkthrough-repro/)
