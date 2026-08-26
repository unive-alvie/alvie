---
title: TestDL Specification Reference
description: Syntax, semantics, and constraints for existing TestDL specifications.
---

This reference explains how to read, create, and modify ALVIE/Sancus specifications using the existing TestDL language.
For a guided example, start with the [V-B1 TestDL tutorial](/alvie/guides/testdl-tutorial-vb1/).
For the precise meaning of individual actions, use the [TestDL Action Reference](/alvie/reference/testdl-action-reference/).
To add a language construct or a new observable behavior, use [Extending TestDL Actions](/alvie/guides/spec-extending-actions/) instead.

A full ALVIE/Sancus run is built by combining:

- one enclave (victim) spec file (`.etdl`)
- one attacker spec file (`.atdl`)

The CLI merges both files and parses them as a single TestDL specification.

## Where specs live

- Main library of ready-to-use specs: `spec-lib/`
- Running example: `spec-lib/example/`
  - attacker: `spec-lib/example/attacker.atdl`
  - enclave: `spec-lib/example/enclave.etdl`

Commands in this reference run from `alvie/code/`.
Pass specifications with:

```bash
dune exec bin/learn.exe -- \
  --att-spec path/to/attacker.atdl \
  --encl-spec path/to/enclave.etdl \
  ...
```

## Enclave specifications

An enclave file defines the `enclave { ... };` section.

Minimal shape:

```text
enclave {
  <body>
};
```

### Supported enclave atoms

- `nop`, `dint`, `mov ...`, `add ...`, `cmp ...`, `jmp ...`, `push ...`
- `rst`
- `ubr`
- `ifz (<atom-list>) (<atom-list>)`
- `balanced_ifz (<instruction-list>)`

### TestDL combinators

Attacker and enclave sections share these combinators:

- sequencing: `a; b`
- choice: `a | b`
- repetition: `a*`
- epsilon (empty action): `eps`
- grouping: `( ... )`

`ifz` takes two non-empty, semicolon-separated branch lists.
Executable enclave branches currently support instruction atoms and `rst`; nested `ifz`, `ubr`, and `balanced_ifz` inside an `ifz` branch are not supported.
`balanced_ifz` accepts a non-empty instruction list, rather than an arbitrary TestDL expression.

### Secret placeholder

Inside enclave instructions, `?` means "secret immediate value".
Example:

```text
cmp ?, r4;
```

At runtime, `?` is replaced by the value passed through `--secret`.

## Attacker specifications

An attacker file defines three sections:

```text
isr { ... };
prepare { ... };
cleanup { ... };
```

The sections must appear in this order.

- `isr`: what the interrupt handler can do
- `prepare`: setup before interaction
- `cleanup`: teardown/reset actions

### Supported attacker atoms

- `rst` / `rst_nz`
- `jin <label>`
- `create <ts, te, ds, de>`
- `timer_enable <n>`
- `start_counting <n>`
- `reti`
- instruction atoms: `nop`, `dint`, `mov ...`, `add ...`, `cmp ...`, `jmp ...`, `push ...`
- conditional macro: `ifz (<atom-list>) (<atom-list>)`

Attacker sections support the same combinators (`;`, `|`, `*`, `eps`, parentheses).

Both branches of attacker `ifz` must be non-empty lists of atoms.
Nested `ifz` is not supported.

## How specifications guide learning

TestDL expressions describe languages of permitted action sequences; they are not templates that ALVIE/Sancus emits all at once.
During learning, ALVIE/Sancus replays the current input/output history and offers only actions that can still extend a sequence accepted by the active expression:

- `a; b` requires `a` before `b`;
- `a | b` permits either branch;
- `a*` permits zero or more repetitions;
- `eps` permits an empty body or choice branch;
- parentheses control grouping.

The observed Sancus behavior selects which section is active:

| Active section | Inputs ALVIE/Sancus may generate | Typical transition |
| --- | --- | --- |
| `prepare` | attacker actions from `prepare` | `jin`/jump-in enters `enclave` |
| `enclave` | victim actions from `enclave` | an interrupt enters `isr`; jump-out/reset enters `cleanup` |
| `isr` | attacker actions from `isr` | `reti` resumes `enclave` or enters `cleanup`, depending on the return mode |
| `cleanup` | attacker actions from `cleanup` | reset starts a new `prepare` phase |

An action written in another section is therefore not available merely because it occurs somewhere in the combined specification.
Within the active section, ALVIE/Sancus uses the derivative of the expression after the existing prefix and discards actions whose derivative has an empty language.
Re-entered enclave and ISR executions may also replay a previously observed action path so that the same generated program remains consistent across repeated execution.

Illegal or unsupported observations invalidate the current generated path; reset, jump-in, jump-out, interrupt-handle, and `reti` observations update the active section as described above.
This is how `.atdl` and `.etdl` files limit both the learner's alphabet and the order in which inputs can be queried.

## Operands and registers

The parser accepts:

- registers: `r0` to `r14`
- source operands: `rX`, `@rX`, `&label`, `#imm`, `?`
- destination operands: `rX`, `&rX`, `&label`

Labels and symbolic immediates use letters, digits, `_`, and `-`.
Decimal timer arguments must be in `0..65535`.
The `?` source operand is supported in enclave instructions, where `--secret` expands it before code generation; do not use an unexpanded `?` in attacker actions.

Examples:

- `mov #42, &data_s`
- `cmp ?, r4`
- `jmp #enc_e`

## Creating or modifying a specification

1. Start from `spec-lib/example/attacker.atdl` and `spec-lib/example/enclave.etdl`.
2. Encode victim behavior in `enclave { ... };` using choices and sequences.
3. Encode attacker setup in `prepare`, interrupt behavior in `isr`, cleanup in `cleanup`.
4. If enclave uses `?`, run with `--secret <value>`.
5. Learn and verify with existing scripts (`learn_one.sh`, `check_one.sh`) or direct CLI commands.

### Concrete syntax example

`enclave.etdl`:

```text
enclave {
  cmp ?, r4;
  ifz (mov #42, &data_s; nop) (nop; mov #1, &data_s);
  jmp #enc_e
};
```

`attacker.atdl`:

```text
isr {
  reti
};

prepare {
  timer_enable 4;
  create <enc_s, enc_e, data_s, data_e>;
  jin enc_s
};

cleanup {
  nop
};
```

To run a small checked-in example using the same syntax, start in `alvie/code/` and execute:

```bash
dune exec bin/learn.exe -- \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --res /tmp/alvie-testdl-example.dot \
  --tmpdir /tmp/alvie-testdl-example \
  --secret 0 \
  --commit bf89c0b \
  --sancus ../../sancus-core-gap \
  --oracle randomwalk \
  --step-limit 500 \
  --reset-probability 0.09
```

`--att-spec` and `--encl-spec` select the two TestDL files.
`--secret 0` expands their victim-side `?` operands, while `--oracle randomwalk` selects a bounded equivalence oracle.
`--step-limit` bounds each equivalence search, and `--reset-probability` controls how often it abandons the current exploration path.
`--tmpdir` contains generated programs and simulator artifacts, and `--res` receives the learned DOT model.
See the [Executables Reference](/alvie/reference/executables-reference/) for every learner option.

## Reference specifications in this repository

- Complete attacker profile: `spec-lib/complete.atdl`
- Attack-focused profiles: `spec-lib/b1.atdl`, `spec-lib/b2.atdl`, `spec-lib/b3.atdl`, `spec-lib/b4.atdl`, `spec-lib/b6.atdl`, `spec-lib/b7.atdl`, `spec-lib/b8.atdl`, `spec-lib/b9.atdl`
- Enclave baseline: `spec-lib/enclave-complete.etdl`
- Example pair: `spec-lib/example/attacker.atdl`, `spec-lib/example/enclave.etdl`

## Troubleshooting

- Parser errors usually come from missing `;`, missing section headers, or out-of-range registers.
- `?` is valid in enclave instructions; ensure a secret is provided when needed.
- If `timer_enable`/interrupt scheduling is not desired, use the CLI option to ignore interrupts.
