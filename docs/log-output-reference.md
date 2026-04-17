# ALVIE Log & Output Reference

This document explains how to read the live progress output and log files produced by ALVIE's learning (`learn.exe`) and comparison (`fa.exe`) phases.

## Learning Phase Output (`learn.exe`)

### Live Progress Stream

During learning, ALVIE prints a compact progress stream to stdout. Each character or bracketed token represents one interaction with the Sancus simulator. The stream is structured as repeated units of the form:

```
.[INPUT][OUTPUT].[INPUT][OUTPUT]...
```

A newline is printed each time the current hypothesis is promoted to the oracle for an equivalence check.

#### Separator

| Symbol | Meaning |
|--------|---------|
| `.` (yellow) | SUL reset — the simulator was reset and a new run begins |

---

### Input Symbols (inside `[...]`, before the output)

Inputs are colour-coded by actor:

**Yellow — no meaningful input**

| Symbol | Source | Meaning |
|--------|--------|---------|
| `_` | — | `INoInput` — empty/null input step |

**Blue — attacker actions**

| Symbol | Source | Meaning |
|--------|--------|---------|
| `I` | Attacker | `CJmpIn` — attacker jumps into the enclave |
| `C` | Attacker | `CCreateEncl` — attacker creates/enables an enclave |
| `T` | Attacker | `CTimerEnable` — attacker enables the hardware timer |
| `SC` | Attacker | `CStartCounting` — attacker starts the timer counter |
| `N` | Attacker | `CInst NOP` — attacker issues a no-op instruction |
| `D` | Attacker | `CInst DINT` — attacker disables interrupts |
| `M` | Attacker | `CInst MOV` — attacker issues a move instruction |
| `A` | Attacker | `CInst ADD` — attacker issues an add instruction |
| `=` | Attacker | `CInst CMP` — attacker issues a compare instruction |
| `JMP` | Attacker | `CInst JMP` — attacker issues an unconditional branch |
| `JNZ` | Attacker | `CInst JNZ` — attacker issues a jump-if-not-zero |
| `JZ` | Attacker | `CInst JZ` — attacker issues a jump-if-zero |
| `P` | Attacker | `CInst PUSH` — attacker pushes onto the stack |
| `IfZ` | Attacker | `CIfZ` — attacker issues a conditional (if-zero) block |
| `•` (red) | Attacker | `CRst` — attacker triggers a reset unconditionally |
| `Z` (red) | Attacker | `CRstNZ` — attacker triggers a reset if not zero |

**Magenta — reti**

| Symbol | Source | Meaning |
|--------|--------|---------|
| `R` (magenta) | Attacker | `CReti` — attacker returns from interrupt |

**Green — enclave actions**

| Symbol | Source | Meaning |
|--------|--------|---------|
| `N` | Enclave | `CInst NOP` |
| `D` | Enclave | `CInst DINT` |
| `U` | Enclave | `CUbr` — unconditional branch (exit the enclave) |
| `M` | Enclave | `CInst MOV` |
| `A` | Enclave | `CInst ADD` |
| `=` | Enclave | `CInst CMP` |
| `JMP` | Enclave | `CInst JMP` |
| `JNZ` | Enclave | `CInst JNZ` |
| `JZ` | Enclave | `CInst JZ` |
| `P` | Enclave | `CInst PUSH` |
| `BIfZ` | Enclave | `CBalancedIfZ` — balanced conditional branch |
| `IfZ` | Enclave | `CIfZ` — conditional block |
| `•` (green) | Enclave | `CRst` — enclave triggers a reset |

> **Note:** The same letter can appear in both blue (attacker) and green (enclave). Colour distinguishes the actor.

---

### Output Symbols (inside `[...]`, after the input)

Output symbols follow the input within the same bracket and describe what the simulator observed. They are colour-coded by category:

**Yellow — anomalous/illegal**

| Symbol | Meaning |
|--------|---------|
| `†` (yellow) | `OIllegal` — input not permitted at this point; the step is ignored |
| `?` (yellow) | `OUnsupported` — action is not representable (e.g. unsupported mode transition) |

**Red — fatal/irrecoverable**

| Symbol | Meaning |
|--------|---------|
| `•` (bold red) | `OReset` — the processor reset; the run is terminated and re-initialised |
| `∞` (bold red) | `OMaybeDiverge` — simulation diverged (infinite loop detected) |

**Blue — attacker-driven transitions**

| Symbol | Meaning |
|--------|---------|
| `i` (bold blue) | `OJmpIn` — the processor entered the enclave (PM mode) |
| `s` (bold blue) | `OSilent` — action completed silently (no observable effect on the enclave boundary) |

**Green — enclave-driven transitions**

| Symbol | Meaning |
|--------|---------|
| `o` (bold green) | `OJmpOut` — the enclave exited normally (returned to UM) |
| `t` (bold green) | `OTime` — a timed observation (records cycle count `k`, register `r4`, memory, timer) |

**Magenta — interrupt-related**

| Symbol | Meaning |
|--------|---------|
| `r` (bold magenta) | `OReti` — processor returned from interrupt routine |
| `th` (bold magenta) | `OTime_Handle` — timed observation followed by an interrupt being handled |
| `oh` (bold magenta) | `OJmpOut_Handle` — enclave exit followed by an interrupt being handled |

---

### Reading a Log Line

Each line of the learning log is one round of exploration. Example (colours stripped):

```
.[SC t][C t]
```

Decoded:
- `.` — reset
- `[SC` — input: attacker `CStartCounting`; `t]` — output: `OTime` (timed observation, success)
- `[C` — input: attacker `CCreateEncl`; `t]` — output: `OTime`

A line ending with a newline (no more tokens) means the hypothesis was submitted to the equivalence oracle. If a counterexample is found, exploration resumes on the next line.

---

### Output Payload

The `t`, `i`, `o`, `r`, `th`, `oh` outputs carry an internal payload (not shown in the stream but recorded in the model) consisting of:

| Field | Description |
|-------|-------------|
| `k` | Cycle count for this step (instruction timing) |
| `gie` | Global interrupt enable flag (`true`/`false`) |
| `reg_val` | Value of register `r4` (lower 3 bits) |
| `umem_val` | Value of unprotected memory cell |
| `timerA_counter` | Hardware timer counter value |
| `mode` | CPU mode at end of step: `PM` (protected) or `UM` (unprotected) |

These values are what distinguish states in the learned Mealy machine and ultimately reveal whether the attacker can extract the secret.

---

### Learning Completion

When the PAC oracle declares the hypothesis equivalent to the SUL, the learning terminates and ALVIE writes the model to the `.dot` result file. No explicit "done" message appears in the stream; the process exits cleanly.

---

## Comparison Phase Output (`fa.exe`)

The `fa.exe` binary compares pairs of learned models (secret=0 vs secret=1) and reports how many distinguishing traces (FA violations) it found.

### Terminal Output

```
=== Results: found N FA violations. See <path>_int.dot for details.
```

| Part | Meaning |
|------|---------|
| `N` | Number of distinct witness traces found where the two models behave differently |
| `_int.dot` | The counterexample graph for the interrupt-enabled models |

- **`N = 0`**: The two models are indistinguishable — the attacker cannot tell secret=0 from secret=1. The system is **secure** under the given threat model (up to the PAC guarantees).
- **`N > 0`**: Distinguishing traces exist — the attacker **can** observe a difference. An attack exists.

### Counterexample Dot Files

`counterexamples/<attack>/<commit>-<attack>_int.dot` is a Graphviz LTS (Labelled Transition System) graph where:

- Each **node** represents a step in the distinguishing scenario.
- Each **edge** is labelled with the input taken at that step.
- Two branches diverge at the point where the two models produce different outputs, making them distinguishable.

Convert to PDF for inspection:
```bash
dot -Tpdf counterexamples/b6/d54f031-b6_int.dot -o attack_b6.pdf
```

---

## Log Files (`logs/`)

Log files mirror the terminal stream and are written per experiment.

### Learning logs

`logs/<attack>/learn-<name>.log` — full learning progress for one model.

- Contains the same symbol stream as the terminal output.
- Use `cat` or a terminal that handles ANSI escape codes to read with colours; use `sed 's/\x1B\[[0-9;]*m//g'` to strip them.

### Comparison logs

`logs/<attack>/compare-<commit>-<attack>.log` — output of `fa.exe` for one model pair.

- Contains the final `=== Results: found N FA violations` line and any debug info if `--debug` was passed.

---

## Quick Symbol Cheat Sheet

```
RESETS / SEPARATORS
  .   yellow   SUL reset (new run starts)

INPUTS (before output in [...])
  _   yellow   No input
  I   blue     JmpIn (attacker jumps into enclave)
  C   blue     CreateEncl
  SC  blue     StartCounting
  T   blue     TimerEnable
  =   blue/green  CMP instruction
  U   green    Ubr (enclave unconditional branch / exit)
  R   magenta  Reti

OUTPUTS (after input in [...])
  †   yellow   Illegal (step rejected)
  ?   yellow   Unsupported
  •   red      Reset
  ∞   red      Diverge (infinite loop)
  i   blue     JmpIn observed
  s   blue     Silent
  t   green    Timed observation (normal step)
  o   green    JmpOut (enclave exited)
  r   magenta  Reti observed
  th  magenta  Timed + interrupt handled
  oh  magenta  JmpOut + interrupt handled
```
