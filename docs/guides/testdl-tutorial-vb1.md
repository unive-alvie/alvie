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

From the repository root, check the simulator checkout and build ALVIE:

```bash
test -d sancus-core-gap
cd alvie/code
dune build
cd ../..
```

If the build fails, follow [Getting Started](/alvie/getting-started/) first.

## 2. Read the enclave specification

Open `spec-lib/fast/enclave-complete.etdl`. Its outer form is:

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

`prepare` sets up the timer, creates the enclave, and jumps into it. `isr`
describes the interrupt handler, which enables the timer again and returns.
`cleanup` describes the final teardown. These bodies use the same `; `, `|`,
`eps`, repetition, and grouping operators as enclave expressions.

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

The main flags select the two specifications, secret, Sancus revision, oracle,
model output, and temporary directory. The command writes a learned Mealy
machine to `/tmp/alvie-b1-fast-s0.dot`.

Inspect it with:

```bash
head -20 /tmp/alvie-b1-fast-s0.dot
dot -Tpdf /tmp/alvie-b1-fast-s0.dot -o /tmp/alvie-b1-fast-s0.pdf
```

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

The wrapper learns the models needed for the selected attack and Sancus
revisions. Results, logs, and temporary files are placed under `results/fast/`,
`logs/fast/`, and `tmp/fast/`. The comparison requires secret 0/1 models with
interrupts enabled and disabled.

For the full paper profile, replace `fast` with a separate namespace and use
the complete specifications. Expect it to take substantially longer.

## 6. Make a small change

Copy a specification before experimenting so generated output stays separate:

```bash
cp spec-lib/fast/b1.atdl /tmp/my-b1.atdl
```

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
