# TestDL Action Reference (Intuition and Semantics)

This reference explains what each existing TestDL action means conceptually and where it is typically used.

It complements `docs/spec-tutorial.md` (how to write specs) and `docs/spec-extending-actions.md` (how to extend the language).

## Reading notes

- TestDL has attacker and enclave actions.
- The same instruction syntax (`mov`, `add`, `cmp`, `jmp`, `push`, `nop`, `dint`) can appear as an attacker atom or enclave atom depending on section.
- Section context matters for semantics:
  - attacker sections: `isr`, `prepare`, `cleanup`
  - enclave section: `enclave`

## Structural combinators

- `a; b` - sequence: do `a` then `b`.
- `a | b` - choice: allow either branch.
- `a*` - repetition: allow zero or more repetitions.
- `eps` - empty action.
- `( ... )` - grouping.

These do not emit instructions by themselves; they shape the language of accepted traces.

## Attacker actions

### `rst`

- Intuition: force watchdog-triggered reset.
- Typical use: reset system state before/after experiments.
- Common section: `prepare` or `cleanup`.

### `rst_nz`

- Intuition: conditional reset based on zero flag (`jz` guard before reset code).
- Typical use: branch-dependent restart behavior.
- Caveat: side effects depend on machine state/flags at that point.

### `create <ts, te, ds, de>`

- Intuition: create/enable enclave with text/data boundaries.
- Typical use: setup in `prepare` before jumping in.
- Common pattern: `create ...; jin enc_s`.

### `jin <label>`

- Intuition: jump into enclave entry label.
- Typical use: transition from setup to enclave execution.
- Usually appears once per run path in `prepare`.

### `timer_enable <n>`

- Intuition: configure timer interrupt after `n` ticks.
- Typical use: model interrupt scheduling during enclave execution.
- Effect: helps generate handle/reti flows in traces.

### `start_counting <n>`

- Intuition: start timer counting without the interrupt-enabled mode used by `timer_enable`.
- Typical use: finer control of timing behavior.

### `reti`

- Intuition: return from interrupt handler.
- Typical use: terminate `isr` path and resume interrupted control flow.

### `ifz (<atom-list>) (<atom-list>)`

- Intuition: attacker-side branch macro based on zero flag.
- Typical use: conditional attack behavior encoded compactly.
- Caveat: currently intended for non-nested `ifz` atoms.

### Instruction atoms (`nop`, `dint`, `mov`, `add`, `cmp`, `jmp`, `push`)

- Intuition: raw low-level attacker instructions.
- Typical use: handcrafted attack steps when high-level atoms are insufficient.

## Enclave actions

### Instruction atoms (`nop`, `dint`, `mov`, `add`, `cmp`, `jmp`, `push`)

- Intuition: victim-side behavior fragments.
- Typical use: encode instruction-level variability to test non-interference and distinguishability.

### `rst`

- Intuition: enclave-side reset behavior.
- Typical use: model abrupt resets as part of victim program family.

### `ubr`

- Intuition: model a branch-like divergence pattern that exits through `enc_e` with side effects.
- Typical use: compactly represent observable divergence in enclave logic.

### `ifz (<atom-list>) (<atom-list>)`

- Intuition: enclave-side conditional based on zero flag.
- Typical use: represent data/control-dependent behavior with explicit branch alternatives.

### `balanced_ifz (<instruction-list>)`

- Intuition: compare a "zero" branch with a cycle-balanced non-zero branch (using inserted NOPs).
- Typical use: model timing-aware conditional behavior where branch lengths are controlled.

## Operand intuition

- `rX` - register operand (`X` in `0..14`).
- `@rX` - register-indirect source.
- `&label` - memory label/address form.
- `#imm` - immediate value.
- `?` - secret placeholder (typically in enclave spec), replaced by `--secret`.

## Section intent quick map

- `prepare` - establish preconditions and enter enclave (`create`, timers, `jin`).
- `enclave` - victim behavior language under analysis.
- `isr` - interrupt handler behavior available to attacker.
- `cleanup` - post-run attacker actions/reset paths.

## Observable-effect intuition (high level)

ALVIE classifies execution into output categories such as jump-in/jump-out, timing observations, reset, illegal, and interrupt-handle/reti events.

You usually do not need to reason at this level while authoring specs, but if you add new actions that create genuinely new event classes, see `docs/spec-extending-actions.md` for output/DFA updates.
