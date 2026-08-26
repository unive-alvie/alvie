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

In `alvie/code/lib/sancus/attacker.ml`, extend `type atom_t` with your constructor (if not already present):

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

## Step 3: Keep trace rendering readable (optional but recommended)

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

## Step 6: Quick validation checklist

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
