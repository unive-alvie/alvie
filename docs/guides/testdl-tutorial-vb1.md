---
title: 'TestDL Tutorial: V-B1 Example'
description: A one-hour introduction to the TestDL languages through a worked V-B1 example.
---

This tutorial is a first practical session with the two small languages used
by ALVIE. In about one hour, we illustrate the TestDL languages through a
worked example: the specification used to reproduce the V-B1 vulnerability
from the [*Mind the Gap* paper](https://mici.hu/papers/bognar22gap.pdf), using
the corresponding [Sancus implementation](https://github.com/martonbognar/sancus-core-gap).
The language walkthrough uses a reduced fast profile. The attack reproduction
uses the complete, checked-in V-B1 models, so it remains a real result rather
than a made-up teaching example.

The complete syntax and semantics are in the
[TestDL Action Reference](/alvie/reference/testdl-action-reference/). Use that page
when you need details; this tutorial focuses on where to start and what each
part is doing.

For the quickest setup, use the published Docker image described in
[Getting Started](/alvie/getting-started/). Mount a host directory so the
witness PDF produced later survives after the container exits:

```bash
mkdir -p "$PWD/alvie-output"
docker pull matteobusi/alvie
docker run --rm -it \
  -v "$PWD/alvie-output:/output" \
  matteobusi/alvie
```

The image already contains ALVIE, its dependencies, and `sancus-core-gap`; it
starts in the repository root, so the paths below work unchanged. The Docker
Hub image is [matteobusi/alvie](https://hub.docker.com/r/matteobusi/alvie).
Inside the container, use `/output` for files you want to keep; on the host,
they appear in `./alvie-output`. The repository Dockerfile installs Graphviz
for the rendering command below. Rebuild the image locally if the published
image predates that update.
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
suitable for learning the language, but it is not a replacement for the full
paper experiment.

### A short security vocabulary

You do not need prior Sancus or side-channel experience for this tutorial.
Here, a **secret** is a value held by the enclave that the attacker should not
be able to distinguish. The attacker cannot read protected memory directly,
but can choose allowed actions, request timer interrupts, and observe public
effects such as execution time, control-flow boundaries, and unprotected
memory. A **side channel** exists when those public observations differ for
secret `0` and secret `1`.

V-B1 is a timing/interrupt example. The vulnerable Sancus implementation takes
one extra CPU cycle for the first instruction after `reti` (return from
interrupt), while its security model expects that instruction to take the
normal time. ALVIE learns models for both secret values and searches them for
an attacker-visible consequence of that one-cycle mismatch. This is the
workflow described in the [ALVIE paper](https://arxiv.org/abs/2404.09518).

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

## 4. Learn one small model directly

Before comparing V-B1, run ALVIE directly on the repository's small running
example. This is a real simulator execution and produces one learned model in
about half a minute on a typical development machine. It teaches the learner
interface without presenting a short, bounded run as a V-B1 security verdict.

```bash
mkdir -p "$ALVIE_OUTPUT/example-learn"
dune exec bin/learn.exe -- \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --res "$ALVIE_OUTPUT/example-learn/secret-0.dot" \
  --tmpdir "$ALVIE_OUTPUT/example-learn/tmp" \
  --commit bf89c0b \
  --sancus ../../sancus-core-gap \
  --secret 0 \
  --oracle randomwalk \
  --step-limit 5000 \
  --reset-probability 0.09 \
  > "$ALVIE_OUTPUT/example-learn/learn.log" 2>&1
```

The two `--*-spec` arguments select the attacker and victim languages. `--res`
chooses the learned-model file, and `--tmpdir` holds generated programs and
simulator traces. `--sancus` points to the Sancus checkout. This command fixes
the secret to `0` and uses final Sancus revision `bf89c0b`; it does not compare
secrets and therefore cannot establish or rule out a vulnerability.

`randomwalk` is a bounded equivalence oracle. `--step-limit 5000` caps its
exploration work, while `--reset-probability 0.09` makes it restart some paths.
The output model is `$ALVIE_OUTPUT/example-learn/secret-0.dot`; the complete
learner output is in `learn.log`. The current example produces a small
21-line DOT file. The full command-line reference is in the
[Executables Reference](/alvie/reference/executables-reference/).

## 5. Reproduce the checked-in V-B1 witness

Learning V-B1 from scratch can take a long time, even with a bounded oracle.
For this first session, use the four complete V-B1 models already tracked in
the repository. They were learned for vulnerable Sancus revision `ef753b6`:

- one model for each secret value (`0` and `1`);
- one interrupt-enabled and one no-interrupt model for each secret.

Run the same four-model comparison that ALVIE uses for an attack assessment:

```bash
cd alvie/code
# Docker container:
export ALVIE_OUTPUT=/output
# Native host: export ALVIE_OUTPUT=/tmp/alvie-output
mkdir -p "$ALVIE_OUTPUT/vb1-fa"
dune exec bin/fa.exe -- \
  --m1-int ../../results/ef753b6-b1-enclave-complete-0-0.01-0.01-int.dot \
  --m2-int ../../results/ef753b6-b1-enclave-complete-1-0-0.01-0.01-int.dot \
  --m1-nint ../../results/ef753b6-b1-enclave-complete-0-0.01-0.01-nint.dot \
  --m2-nint ../../results/ef753b6-b1-enclave-complete-1-0.01-0.01-nint.dot \
  --tmpdir "$ALVIE_OUTPUT/vb1-fa" \
  --witness-file-basename "$ALVIE_OUTPUT/vb1-fa/witness" \
  --cex-limit 1
```

The arguments deliberately name all four models:

- `--m1-int` and `--m2-int` are the interrupt-enabled models for secret `0`
  and secret `1`.
- `--m1-nint` and `--m2-nint` are their no-interrupt counterparts. ALVIE
  subtracts differences already present without interrupts, leaving behavior
  attributable to the interrupt-enabled threat model.
- `ALVIE_OUTPUT=/output` selects the Docker bind mount. Native users can set
  it to `/tmp/alvie-output` instead. `--tmpdir` is a disposable work directory
  for mCRL2 intermediate files.
- `--witness-file-basename` chooses the output prefix; ALVIE writes
  `$ALVIE_OUTPUT/vb1-fa/witness_int.dot`.
- `--cex-limit 1` asks for one witness, which keeps this introductory result
  focused and fast.

For the complete comparison interface, see [Executables Reference](/alvie/reference/executables-reference/#2-faexe--find-flow-analysis-ni-violations-between-two-models).

## 6. Render and inspect the witness

Render the resulting Graphviz file:

```bash
dot -Tpdf "$ALVIE_OUTPUT/vb1-fa/witness_int.dot" \
  -o "$ALVIE_OUTPUT/vb1-fa/witness_int.pdf"
```

`dot -Tpdf` turns the witness graph into a PDF; `-o` gives that PDF its name.
Open it with a local PDF viewer. In the Docker workflow, the PDF is now on the
host under `./alvie-output/vb1-fa/`. If you are using an older published image
without Graphviz, copy the checked-in rendering instead:

```bash
cp ../../counterexamples/b1/pdf/ef753b6-b1_int.pdf \
  "$ALVIE_OUTPUT/vb1-fa/reference-witness.pdf"
```

To locate the important labels directly in the generated graph, run:

```bash
grep -nE 'add #1, &data_s|timer_enable 1|timerA_counter = [01]' \
  "$ALVIE_OUTPUT/vb1-fa/witness_int.dot"
```

The graph starts with the common setup: `timer_enable 3`, `create`, and
`jin enc_s`. It then shows two executions side by side. The black dashed path
is the model for secret `0`; the red dotted path is the model for secret `1`.
The attacker is not choosing `cmp #0, r4` or `cmp #1, r4`: those are the two
secret-specific enclave programs being compared.

Follow the branch labelled `ifz [ add #1, &data_s; nop], [ nop; add #1,
&data_s;]`. The attacker first uses `timer_enable 3` so an interrupt arrives
during the first instruction of that action. In the handler, it executes
`timer_enable 1` and then `reti`, scheduling another interrupt for the first
cycle after the handler returns.

Timer A counts from `0` to the requested value, so the decisive public value
is either `0` or `1`:

- With secret `0`, the first cycle after `reti` is Sancus padding intended to
  mitigate the Nemesis attack. The second interrupt therefore runs immediately
  after that padding, and the attacker observes `timerA_counter = 0`.
- With secret `1`, control first returns to the enclave to execute the
  remaining `nop`. Because of V-B1, that `nop` takes two cycles rather than
  one, so the originally balanced `ifz` branches are no longer balanced. When
  the attacker regains control, it observes `timerA_counter = 1`.

That single public timer value distinguishes the secret-dependent executions.
It is the V-B1 attack: a one-cycle implementation/model mismatch after `reti`
becomes a secret-dependent timing observation.

The witness is evidence for this threat model and these learned models. It is
not a claim that every Sancus program leaks, nor does it automatically provide
a code repair. The [Log and Output Reference](/alvie/reference/log-output-reference/)
explains fields such as `k`, `gie`, `timerA_counter`, `PM`, and `UM`.

## 7. Optional: learn the models yourself

The comparison above is complete and immediately reproducible. Run learning
yourself only when you have time to let it finish and want to regenerate the
models. The repository wrapper runs the full V-B1 experiment:

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
`logs/fast/`, and `tmp/fast/`. This can take many hours; it is not a required
step in the one-hour tutorial. See
[Reproducing the Simulation Experiments](/alvie/guides/walkthrough-repro/) for
wrapper behavior and [Executables Reference](/alvie/reference/executables-reference/)
for the underlying commands.

For the full paper profile, replace `fast` with a separate namespace and use
the complete specifications. Expect it to take substantially longer.

## 8. Make a small change

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
