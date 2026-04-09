# ALVIE Spec Tutorial: Attacker and Victim Modeling

This guide explains how to write ALVIE specifications without digging into the OCaml internals. A full ALVIE run is built by combining:

- one enclave (victim) spec file (`.etdl`)
- one attacker spec file (`.atdl`)

The CLI merges both files and parses them as a single TestDL specification.

## Where specs live

- Main library of ready-to-use specs: `spec-lib/`
- Running example: `spec-lib/example/`
  - attacker: `spec-lib/example/attacker.atdl`
  - enclave: `spec-lib/example/enclave.etdl`

You can pass your own files with:

```bash
_build/default/bin/learn.exe --att-spec path/to/attacker.atdl --encl-spec path/to/enclave.etdl ...
```

## 1) Victim (enclave) modeling

An enclave file defines the `enclave { ... };` section.

Minimal shape:

```text
enclave {
  <body>
};
```

### Enclave atoms

- `nop`, `dint`, `mov ...`, `add ...`, `cmp ...`, `jmp ...`, `push ...`
- `rst`
- `ubr`
- `ifz (<atom-list>) (<atom-list>)`
- `balanced_ifz (<instruction-list>)`

### Enclave combinators

- sequencing: `a; b`
- choice: `a | b`
- repetition: `a*`
- epsilon (empty action): `eps`
- grouping: `( ... )`

### Secret placeholder

Inside enclave instructions, `?` means "secret immediate value". Example:

```text
cmp ?, r4;
```

At runtime, `?` is replaced by the value passed through `--secret`.

## 2) Attacker modeling

An attacker file defines three sections:

```text
isr { ... };
prepare { ... };
cleanup { ... };
```

- `isr`: what the interrupt handler can do
- `prepare`: setup before interaction
- `cleanup`: teardown/reset actions

### Attacker atoms

- `rst` / `rst_nz`
- `jin <label>`
- `create <ts, te, ds, de>`
- `timer_enable <n>`
- `start_counting <n>`
- `reti`
- instruction atoms: `nop`, `dint`, `mov ...`, `add ...`, `cmp ...`, `jmp ...`, `push ...`
- conditional macro: `ifz (<atom-list>) (<atom-list>)`

Attacker sections support the same combinators (`;`, `|`, `*`, `eps`, parentheses).

## 2b) Attacker modeling (2/2): extending observable actions in OCaml

If you add a new attacker action, there are two different concerns:

- syntax + generation (the action can be written in `.atdl` and compiled to code), and
- observation semantics (ALVIE can classify resulting behavior and keep DFA mode transitions consistent).

Use this checklist.

### A. Add the new action to attacker syntax and code generation

1. Add a constructor in `alvie/code/lib/sancus/attacker.ml` (`type atom_t`).
2. Extend `atom_compile` in `alvie/code/lib/sancus/attacker.ml` to emit assembly for that constructor.
3. Add parser support in `alvie/code/lib/sancus/testdl.ml`:
   - define parser for the new token,
   - include it in `single_atom` and `all_atoms`,
   - include it in `atom` parser alternatives.
4. (Recommended) add a short glyph in `alvie/code/lib/sancus/sul/verilog.ml` (`step` pretty-print input branch), so interactive traces stay readable.

### B. If the new action introduces a new kind of observed behavior

If the action changes what ALVIE should observe (not just how code is generated), also update:

1. `alvie/code/lib/sancus/output_internal.ml`
   - add a new `element_t` variant if needed.
2. `alvie/code/lib/sancus/sul/verilog.ml`
   - update `output_of_signals` / `analyse_dump` to emit the new output element,
   - update output rendering in `step`.
3. `alvie/code/lib/sancus/inputgen.ml`
   - update `transition_nomemo` if the new output changes mode transitions (`Prepare`, `Enclave`, `ISR_toPM`, `ISR_toUM`, `Cleanup`).

Rule of thumb: if your new action is only a different instruction sequence but maps to existing outcomes (`OTime`, `OJmpIn`, `OReti`, `OJmpOut`, ...), you usually do not need a new output type. If it creates a new semantic event, you do.

## 3) Operands and registers

The parser accepts:

- registers: `r0` to `r14`
- source operands: `rX`, `@rX`, `&label`, `#imm`, `?`
- destination operands: `rX`, `&rX`, `&label`

Examples:

- `mov #42, &data_s`
- `cmp ?, r4`
- `jmp #enc_e`

## 4) Practical workflow for a new assessment

1. Start from `spec-lib/example/attacker.atdl` and `spec-lib/example/enclave.etdl`.
2. Encode victim behavior in `enclave { ... };` using choices and sequences.
3. Encode attacker setup in `prepare`, interrupt behavior in `isr`, cleanup in `cleanup`.
4. If enclave uses `?`, run with `--secret <value>`.
5. Learn and verify with existing scripts (`learn_one.sh`, `check_one.sh`) or direct CLI commands.

### Concrete example (minimal)

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

Run:

```bash
_build/default/bin/learn.exe \
  --att-spec attacker.atdl \
  --encl-spec enclave.etdl \
  --secret 0 \
  --commit bf89c0b \
  --sancus ./sancus-core-gap \
  --res /tmp/tutorial.dot
```

## 5) Extending the DSL (for contributors)

If you need a new attacker/enclave action not expressible with current atoms:

1. Add the atom constructor in:
   - attacker: `alvie/code/lib/sancus/attacker.ml`
   - enclave: `alvie/code/lib/sancus/enclave.ml`
2. Add parser support in `alvie/code/lib/sancus/testdl.ml`.
3. Map the new atom to emitted low-level instructions in `atom_compile`.
4. Rebuild and test with a small spec in `spec-lib/`.

This keeps the language extension aligned across syntax, semantics, and code generation.

## 6) Reference specs in this repository

- Complete attacker profile: `spec-lib/complete.atdl`
- Attack-focused profiles: `spec-lib/b1.atdl`, `spec-lib/b2.atdl`, `spec-lib/b3.atdl`, `spec-lib/b4.atdl`, `spec-lib/b6.atdl`, `spec-lib/b7.atdl`, `spec-lib/b8.atdl`, `spec-lib/b9.atdl`
- Enclave baseline: `spec-lib/enclave-complete.etdl`
- Example pair: `spec-lib/example/attacker.atdl`, `spec-lib/example/enclave.etdl`

## Troubleshooting quick notes

- Parser errors usually come from missing `;`, missing section headers, or out-of-range registers.
- `?` is valid in enclave instructions; ensure a secret is provided when needed.
- If `timer_enable`/interrupt scheduling is not desired, use the CLI option to ignore interrupts.
