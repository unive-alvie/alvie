# Extending TestDL: Add a New Action End-to-End

This guide is for contributors who want to introduce a new action in TestDL and make it usable in ALVIE.

## Scope

When you add an action, decide which kind of change it is:

- **Kind A: syntax/generation only**
  - New action parses from `.atdl`/`.etdl`
  - New action compiles to low-level instruction sequence
  - Observability semantics stay expressible with existing output kinds
- **Kind B: new observation semantics**
  - New action also requires ALVIE to emit or track a new semantic event
  - You must touch output classification and DFA transitions

Most new instructions start as **Kind A**.

## Example target action

In this tutorial we add a simple attacker action:

```text
start_counting <n>
```

The same workflow applies to any new attacker action (or enclave action with the enclave-specific files).

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
| CStartCounting of ti_t
```

Then implement its lowering in `atom_compile`.

For `start_counting`, the current code emits:

```ocaml
| CStartCounting ti ->
    let ti_correct = ti - 2 in
    [
      sprintf "mov #%d, &TACCR0" ti_correct;
      "mov #0x214, &tactl_val";
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
let atstart_counting =
  (string "start_counting" *> whitespace *> integer >>= (fun v ->
    let v = int_of_string v in
    if v >= 0 && v < 65536 then return (Attacker.Atom (CStartCounting v))
    else fail "start_counting: delay is too long"))
```

2. Include it in all attacker alternatives:
   - `single_atom`
   - `all_atoms`
   - `atom body`

Without all three, parsing may work in some syntactic contexts and fail in others.

## Step 3: Keep trace rendering readable (optional but recommended)

In `alvie/code/lib/sancus/sul/verilog.ml`, update the input rendering in `step` so your action gets a short symbol.

For `CStartCounting`, current rendering is `SC`.

This does not change semantics; it only improves debugging output.

## Step 4: Decide whether outputs and DFA transitions must change

If your new action can be understood via existing outputs (`OTime`, `OJmpIn`, `OReti`, `OJmpOut`, `OReset`, ...), stop here.

If not, do this:

1. Add a new output variant in `alvie/code/lib/sancus/output_internal.ml`.
2. Emit that variant in `alvie/code/lib/sancus/sul/verilog.ml` (`output_of_signals` / `analyse_dump`).
3. Teach DFA progression how to consume it in `alvie/code/lib/sancus/inputgen.ml` (`transition_nomemo`).

Failing to update all three can make a spec syntactically valid but semantically unusable.

## Step 5: Add a tiny spec to exercise the action

Create a local attacker file (example):

```text
isr { reti };

prepare {
  start_counting 8;
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
- Trace rendering shows your new action symbol (if added).

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
