---
title: Extending TestDL Actions
description: Add a new attacker or enclave action to ALVIE/Sancus.
---

In this tutorial, we add a TestDL action called `trace_marker` and verify that ALVIE/Sancus accepts, compiles, and displays it.
Together, we follow it from the TestDL token we write in a specification, through the instruction generated for it, to the simulator trace and learned model we inspect at the end.
The completed exercise lives on the [`feat/testdl-trace-marker-implementation`](https://github.com/unive-alvie/alvie/tree/feat/testdl-trace-marker-implementation) branch, which we use only as a reference while we work from `main`.
For TestDL syntax outside this exercise, we use the [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/).

## What We Change

`trace_marker` is an attacker action that compiles to one `nop`.
The simulator prints `🚨` when we submit it.
The marker helps us read a long trace, but it does not create a new observation for learning or comparison.

For this action, we change three files:

- [`attacker.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/attacker.ml) defines and compiles the action.
- [`testdl.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/testdl.ml) accepts the `trace_marker` token in an attacker specification.
- [`verilog.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/sul/verilog.ml) prints the `🚨` marker.

## Step 1: Start from main

From the repository root, switch to an up-to-date `main` branch:

```bash
git switch main
git pull --ff-only
```

We make the changes in this tutorial ourselves.
The implementation branch is available only when we want to compare a completed file with our work.

## Step 2: Add the action and its instruction

Our first change will be to extend `type atom_t` with our constructor.
For that, open [`attacker.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/attacker.ml) (the linked file shows the completed version for comparison) and add the new action to `atom_t`:

```ocaml
| CTraceMarker
```

Then implement its lowering in `atom_compile`.

For `trace_marker`, the compiler emits:

```ocaml
| CTraceMarker ->
    [
      "nop";
    ]
```

The constructor records the new TestDL action.
The compiler case gives it the one-instruction implementation used in this exercise.

## Step 3: Accept the TestDL token

Open [`testdl.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/testdl.ml) and use the linked completed version for comparison.

1. Add a parser for the action (for attacker):

```ocaml
let atrace_marker =
  (string "trace_marker" *> return (Attacker.Atom CTraceMarker)) <?> "atrace_marker"
```

2. Include it in all three attacker alternatives:
   - `single_atom`
   - `all_atoms`
   - `atom body`

This makes `trace_marker` valid wherever an attacker action is valid.

## Step 4: Display the marker in the trace

In [`verilog.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/sul/verilog.ml), update the input rendering in `step` so the temporary action gets a short symbol.

For `CTraceMarker`, render a conspicuous `🚨` marker.

This changes only the printed trace.

## When We Need a New Observation

For `trace_marker`, existing observations are enough, so we do not change output handling.

When a new action needs a genuinely new observation, we also:

1. Add a new output variant in `alvie/code/lib/sancus/output_internal.ml`.
2. Emit that variant in `alvie/code/lib/sancus/sul/verilog.ml` (`output_of_signals` / `analyse_dump`).
3. Teach DFA progression how to consume it in `alvie/code/lib/sancus/inputgen.ml` (`transition_nomemo`).

Without these three changes, the action may parse but cannot be learned correctly.

## Step 5: Run the exercise

Assuming ALVIE is set up correctly (see [Getting Started](/alvie/getting-started/)), we can now experiment with the new action.
We write a minimal attacker specification in a dedicated folder:

```bash
mkdir -p /tmp/trace-marker-run
cat > /tmp/trace-marker-run/trace-marker.atdl <<'EOF'
isr { reti };

prepare {
  trace_marker;
  create <enc_s, enc_e, data_s, data_e>;
  jin enc_s
};

cleanup { nop };
EOF
```
We then run a small learning test and save the generated artifacts under `/tmp/trace-marker-run`:
```bash
cd alvie/code
dune build
dune exec bin/learn.exe -- \
  --att-spec /tmp/trace-marker-run/trace-marker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --secret 0 \
  --commit bf89c0b \
  --sancus ../../sancus-core-gap \
  --tmpdir /tmp/trace-marker-run/tmp \
  --res /tmp/trace-marker-run/trace-marker.dot \
  --oracle randomwalk \
  --step-limit 5 \
  --reset-probability 0.09 \
  2>&1 | tee /tmp/trace-marker-run/learning.log
```
The command uses our attacker file and the checked-in example enclave specification.
It writes the learned model, generated files, and terminal output under `/tmp/trace-marker-run`.
The small step limit keeps this exercise short.

## Step 6: Inspect the generated files

The temporary directory we created in the last step contains one randomly named directory for the execution.
List it first:

```bash
ls /tmp/trace-marker-run/tmp
```

Then inspect the generated assembly.
The `*` stands for the one temporary directory that the command created.

```bash
less /tmp/trace-marker-run/tmp/.tmp.*/pmem.s43
```

The relevant output looks like this:

```text
S_0:
        ; CTraceMarker
E_0:
S_1:
        nop
E_1:
```

`S_0` and `E_0` delimit the abstract action.
`S_1` and `E_1` delimit the generated processor instruction.
This confirms that `trace_marker` becomes one `nop` instruction.

The learner prints a compact trace to the terminal and saves the same output in `learning.log`.
Open the saved log and look for the `🚨` marker between square brackets:

```bash
less /tmp/trace-marker-run/learning.log
```

It looks like this:

```text
.[_†].[C†].[🚨t].[R†].[=†].[I†].[U†]
```

The action marker proves that the new input reached the trace printer.
It does not prove that the SUL returned a new observation.
We inspect the learned model next to confirm that the marker did not add a new observation.

## Step 7: Inspect the DOT model

The `--res` file is a Graphviz representation of the learned Mealy machine.
Open it directly:

```bash
less /tmp/trace-marker-run/trace-marker.dot
```

A representative model contains an edge such as:

```text
0 -> 3 [label="((IAttacker CTraceMarker)...)"];
```

The input label contains `CTraceMarker` because the model records the abstract action.
The output label remains an existing output such as `OTime` because `trace_marker` has no semantic effect.

Render the model as a PNG or PDF:

```bash
dot -Tpng /tmp/trace-marker-run/trace-marker.dot \
  -o /tmp/trace-marker-run/trace-marker.png
dot -Tpdf /tmp/trace-marker-run/trace-marker.dot \
  -o /tmp/trace-marker-run/trace-marker.pdf
```

The repository includes a small [sample DOT model](/alvie/assets/trace-marker-model.dot) and its [rendered graph](/alvie/assets/trace-marker-model.png).

![A small learned model containing a trace_marker edge](/alvie/assets/trace-marker-model.png)

Follow the arrows from state `0` to see the input/output sequence.
The model is intentionally small because the command uses only five random-walk steps.

## Enclave actions: same idea, different files

For an enclave action, we use the same process in:

- [`alvie/code/lib/sancus/enclave.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/enclave.ml) (atom type + compile)
- enclave parser branch in [`alvie/code/lib/sancus/testdl.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/testdl.ml)
- optional glyph update in [`alvie/code/lib/sancus/sul/verilog.ml`](https://github.com/unive-alvie/alvie/blob/feat/testdl-trace-marker-implementation/alvie/code/lib/sancus/sul/verilog.ml)

We change outputs and DFA handling only when the action needs a new observation.
