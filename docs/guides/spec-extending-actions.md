---
title: Extending TestDL Actions
description: Add a new attacker or enclave action to ALVIE/Sancus.
---

This guide is for contributors who want to introduce a new action in TestDL and make it usable in ALVIE/Sancus.
For existing TestDL syntax and constraints, see the [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/).
This guide begins when the existing language is insufficient.

## Scope

When you add an action, decide which kind of change it is:

- **Kind A: syntax/generation only**
  - New action parses from `.atdl`/`.etdl`
  - New action compiles to low-level instruction sequence
  - Observability semantics stay expressible with existing output kinds
- **Kind B: new observation semantics**
  - New action also requires ALVIE/Sancus to emit or track a new semantic event
  - You must touch output classification and DFA transitions

Most new instructions start as **Kind A**.

## Example target action

In this tutorial we add a simple attacker action:

```text
trace_marker
```

The action compiles to one `nop` and has no security-observable effect.
The simulator prints `🚨` when the action is submitted, making it easy to identify in a long trace.
The marker is a debugging aid, not a new ALVIE observation used by learning or comparison.
The same workflow applies to any new Kind A attacker action or enclave action.

## Files involved

- Attacker action model and code generation: `alvie/code/lib/sancus/attacker.ml`
- TestDL parser: `alvie/code/lib/sancus/testdl.ml`
- Optional input/output glyph rendering (CLI trace readability): `alvie/code/lib/sancus/sul/verilog.ml`
- Only if semantic outputs change:
  - output type definitions: `alvie/code/lib/sancus/output_internal.ml`
  - signal classification: `alvie/code/lib/sancus/sul/verilog.ml`
  - mode transitions: `alvie/code/lib/sancus/inputgen.ml`

## Step 1: Add a constructor in attacker atoms

In `alvie/code/lib/sancus/attacker.ml`, extend `type atom_t` with your constructor:

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

Guidelines:

- Keep emitted assembly deterministic and side effects explicit.
- If you rely on labels, follow existing naming conventions.
- Ensure the emitted sequence still makes sense under `ignore_interrupts` where applicable.

## Step 2: Parse the new token in TestDL

In `alvie/code/lib/sancus/testdl.ml`:

1. Add a parser for the action (for attacker):

```ocaml
let atrace_marker =
  (string "trace_marker" *> return (Attacker.Atom CTraceMarker)) <?> "atrace_marker"
```

2. Include it in all attacker alternatives:
   - `single_atom`
   - `all_atoms`
   - `atom body`

Without all three, parsing may work in some syntactic contexts and fail in others.

## Step 3: Extend the trace rendering (usually optional)

In `alvie/code/lib/sancus/sul/verilog.ml`, update the input rendering in `step` so your action gets a short symbol.

For `CTraceMarker`, render a conspicuous `🚨` marker.

This does not change semantics; it only improves debugging output.

## Step 4: Decide whether outputs and DFA transitions must change

If your new action can be understood via existing outputs (`OTime`, `OJmpIn`, `OReti`, `OJmpOut`, `OReset`, ...), stop here.

If not, do this:

1. Add a new output variant in `alvie/code/lib/sancus/output_internal.ml`.
2. Emit that variant in `alvie/code/lib/sancus/sul/verilog.ml` (`output_of_signals` / `analyse_dump`).
3. Teach DFA progression how to consume it in `alvie/code/lib/sancus/inputgen.ml` (`transition_nomemo`).

Failing to update all three can make a spec syntactically valid but semantically unusable.
The output classifier should consume the execution trace and its surrounding state, not raw VCD data owned by an individual action.

## Step 5: Add a tiny spec to exercise the action

Create a local attacker file (example):

```text
isr { reti };

prepare {
  trace_marker;
  create <enc_s, enc_e, data_s, data_e>;
  jin enc_s
};

cleanup { nop };
```

Pair it with a minimal enclave spec (e.g. from `spec-lib/example/enclave.etdl` or a reduced one), then run:

```bash
_build/default/bin/learn.exe \
  --att-spec /path/to/attacker.atdl \
  --encl-spec /path/to/enclave.etdl \
  --secret 0 \
  --commit bf89c0b \
  --sancus ./sancus-core-gap \
  --res /tmp/new-action.dot
```

The `--att-spec` and `--encl-spec` options select the two TestDL files.
The `--secret 0` option supplies the value used for `?` in the enclave specification.
The `--commit bf89c0b` option selects the Sancus implementation revision.
The `--sancus` option points to the local `sancus-core-gap` checkout.
The `--tmpdir` option stores generated assembly, ELF, memory images, and VCD files.
The `--res` option names the learned Graphviz model.

For a short contributor smoke test, use a small random-walk limit and preserve the terminal output:

```bash
cd alvie/code
mkdir -p /tmp/trace-marker-run
dune exec bin/learn.exe -- \
  --att-spec /path/to/attacker.atdl \
  --encl-spec /path/to/enclave.etdl \
  --secret 0 \
  --commit bf89c0b \
  --sancus /path/to/sancus-core-gap \
  --tmpdir /tmp/trace-marker-run/tmp \
  --res /tmp/trace-marker-run/trace-marker.dot \
  --oracle randomwalk \
  --step-limit 5 \
  --reset-probability 0.09 \
  2>&1 | tee /tmp/trace-marker-run/learning.log
```

The short limit is for validating the extension path, not for making a statistically strong security claim.
The command still parses the specifications, generates a program, runs the simulator, analyses its trace, and writes a DOT model.

## Step 6: Inspect the generated files

The temporary directory contains one randomly named directory for the execution.
List the useful files with:

```bash
find /tmp/trace-marker-run/tmp -maxdepth 2 -type f \
  \( -name 'pmem.s43' -o -name 'pmem.elf' -o -name '*.vcd' \) -print
```

Inspect the generated assembly and confirm that the action is represented by a comment followed by one `nop`:

```bash
rg -n -C2 'CTraceMarker|nop' /tmp/trace-marker-run/tmp/.tmp.*/pmem.s43
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
The comment is useful when reading generated assembly, but it is not executed by the processor.

The learner prints a compact trace to the terminal and to `learning.log`.
The marker is visible between the square brackets, for example:

```text
.[_†].[C†].[🚨t].[R†].[=†].[I†].[U†]
```

The colored symbols identify the submitted inputs and the symbols with `†` identify returned observations.
The exact sequence depends on the specification and random-walk seed.
To remove ANSI color codes before searching a saved log, use:

```bash
sed -E 's/\x1B\[[0-9;]*m//g' /tmp/trace-marker-run/learning.log | rg '🚨|CTraceMarker|Results'
```

The action marker proves that the new input reached the trace printer.
It does not prove that the SUL returned a new observation.
For that distinction, inspect the edge labels in the learned model.

## Step 7: Inspect the DOT model

The `--res` file is a Graphviz representation of the learned Mealy machine.
Print its first lines:

```bash
sed -n '1,30p' /tmp/trace-marker-run/trace-marker.dot
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

The repository includes a small [sample DOT model](/alvie/assets/trace-marker-model.dot) and its [rendered graph](/alvie/assets/trace-marker-model.png):

![A small learned model containing a trace_marker edge](/alvie/assets/trace-marker-model.png)

Follow the arrows from state `0` to see the input/output sequence.
The model is intentionally small because the command uses only five random-walk steps.
It is a smoke-test artifact, not a complete security assessment.

## Step 8: Run the focused tests

Run the fast parser tests after making the code change:

```bash
cd alvie/code
dune build
dune exec test/attack.exe -- test --color=never testdl
```

- Parsing passes (`.atdl`/`.etdl` accepted).
- Learning command starts and produces output graph.
- No unexpected `OIllegal` caused by grammar/transition mismatches.
- Trace rendering shows the `🚨` marker.
- Existing learned models are unchanged when the new action is not used.

## Common pitfalls

- Updating only `single_atom` but not `atom body` in parser.
- Adding code generation but forgetting to include atom in parser alternatives.
- Introducing a truly new semantic event but not updating `output_internal` + `verilog` + `inputgen` consistently.
- Assuming all new actions need new output kinds (often false).

## Enclave actions: same idea, different files

For enclave-side extensions, mirror the process in:

- `alvie/code/lib/sancus/enclave.ml` (atom type + compile)
- enclave parser branch in `alvie/code/lib/sancus/testdl.ml`
- optional glyph update in `alvie/code/lib/sancus/sul/verilog.ml`

Only touch outputs/DFA if the extension changes semantic observables.
