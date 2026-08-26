---
title: Executables Reference
description: Command-line reference for ALVIE/Sancus tools.
---

All executables are built with `dune build` from inside `alvie/code/`.
Run them through Dune or from the build directory:

```
dune exec bin/<name>.exe -- [flags]
_build/default/bin/<name>.exe [flags]
```

from the **`alvie/code/` directory** unless a `--tmpdir` or `--sancus` path says otherwise.
For direct simulator commands, pass `--sancus` as an absolute path such as `"$PWD/../../sancus-core-gap"`.
The simulator creates a temporary working directory before cloning that checkout.

---

## 1. `learn.exe` — Learn a Mealy machine model

**Purpose:** Runs the L# active automata learning algorithm against a Sancus Verilog simulation.
Produces a `.dot` file representing the learned Mealy machine: the attacker's observable behavior of the enclave.
This is the main experiment driver.

### Required flags

| Flag | Description |
|------|-------------|
| `--att-spec <file>` | Path to attacker specification (`.atdl` file) |
| `--encl-spec <file>` | Path to enclave specification (`.etdl` file) |
| `--res <file>` | Output `.dot` file path for the learned model |
| `--tmpdir <dir>` | Directory for temporary Verilog simulation files |
| `--sancus <dir>` | Path to the Sancus simulator root |
| `--oracle <mode>` | Query oracle mode: `randomwalk`, `pac`, or `exhaustive` |

### Other flags

| Flag | Default | Description |
|------|---------|-------------|
| `--commit <sha>` | `ef753b6` | Label or git commit of the Sancus version to check |
| `--secret <value>` | absent | Secret substituted into the enclave specification; required when the spec contains `?` |
| `--epsilon <float>` | `0.001` | PAC epsilon parameter |
| `--delta <float>` | `0.001` | PAC delta parameter |
| `--pac-bound <int>` | `1` | PAC reset bound |
| `--step-limit <int>` | `500` | Max steps for a random-walk equivalence query |
| `--round-limit <int>` | unlimited | Max rounds for a PAC equivalence query |
| `--reset-probability <float>` | `0.05` | Random-walk probability of restarting the current path |
| `--bad-probability <float>` | `0.20` | Probability of generating an input not driven by the specification |
| `--ignore-interrupts` | false | Treat interrupts as invisible (collapse interrupt outputs) |
| `--sancus-master-key <hex>` | _(default key)_ | Master key passed to the Sancus simulator |
| `--dry` | false | Dry run: set up the simulator but do not learn |
| `--report` | false | Print the learning statistics table |
| `--debug` | false | Enable debug-level logging |
| `--info` | false | Enable info-level logging |

### Output

A Mealy machine in `.dot` format is written to `--res`.
Each edge is labelled `input / output`, where inputs and outputs use the symbolic alphabet defined in the specifications.
See the [Log and Output Reference](../log-output-reference/) for output token meanings.

### Quick example

```bash
cd alvie/code
_build/default/bin/learn.exe \
  --att-spec  ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --oracle    randomwalk \
  --secret    0 \
  --step-limit 100 \
  --res       /tmp/example-s0.dot \
  --tmpdir    /tmp/alvie-example-s0 \
  --sancus    "$PWD/../../sancus-core-gap" \
  --info
```

This learns a model for the `example` attack with secret=0 using random-walk equivalence queries, writing the result to `/tmp/example-s0.dot`.

---

## 2. `fa.exe` — Find flow-analysis (NI) violations between two models

**Purpose:** Takes two interrupt-enabled `.dot` Mealy machines and optionally their two no-interrupt counterparts.
It uses mCRL2 model checking to find distinguishing traces.
Supplying the no-interrupt models removes witnesses that already exist without interrupt scheduling.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--m1-int <file>` | _(required)_ | secret=0 model, interrupt variant (`.dot`) |
| `--m2-int <file>` | _(required)_ | secret=1 model, interrupt variant (`.dot`) |
| `--m1-nint <file>` | optional | secret=0 no-interrupt model (`.dot`) |
| `--m2-nint <file>` | optional | secret=1 no-interrupt model (`.dot`) |
| `--witness-file-basename <base>` | _(required)_ | Output path prefix; produces `<base>_int.dot` |
| `--tmpdir <dir>` | _(required)_ | Directory for intermediate mCRL2 files |
| `--cex-limit <int>` | unlimited | Maximum number of counterexamples to enumerate |
| `--debug` | false | Enable debug-level logging |

### Output

`<witness-file-basename>_int.dot` — a `.dot` graph whose paths are distinguishing traces (attack witnesses).
If no counterexample exists (the models are equivalent), the file is empty.

### Quick example

```bash
cd alvie/code
_build/default/bin/fa.exe \
  --m1-int    /tmp/example-orig-s0-int.dot \
  --m2-int    /tmp/example-orig-s1-int.dot \
  --m1-nint   /tmp/example-orig-s0-nint.dot \
  --m2-nint   /tmp/example-orig-s1-nint.dot \
  --tmpdir /tmp/alvie-fa \
  --witness-file-basename /tmp/example-orig-witness \
  --cex-limit 3
```

Produces `/tmp/example-orig-witness_int.dot` containing up to 3 distinguishing attack traces.
The tool also reports the number of flow-analysis violations on stderr.

---

## 3. `exec.exe` — Replay a supplied input sequence (debugging tool)

**Purpose:** Developer/debugging utility.
Sets up the Sancus simulator exactly like `learn.exe` but, instead of learning, replays the input sequence passed through `--sexp-input` and prints the observed outputs.
It is useful for manually inspecting the simulator's response to a specific trace without running the full learner.

### Flags

Same setup flags as `learn.exe` (minus oracle/learning flags):

| Flag | Description |
|------|-------------|
| `--sexp-input <file>` | Required S-expression file containing a list of raw `Sancus.Input` values |
| `--att-spec <file>` | Attacker specification (`.atdl`) |
| `--encl-spec <file>` | Enclave specification (`.etdl`) |
| `--tmpdir <dir>` | Temp directory for simulation files |
| `--sancus <dir>` | Path to Sancus simulator root |
| `--commit <sha>` | Simulator git commit to use |
| `--secret <0\|1>` | Secret value |
| `--ignore-interrupts` | Collapse interrupt outputs |
| `--sancus-master-key <hex>` | Master key |
| `--debug` | Debug logging |

### Output

Prints one line per step to stdout: the input sent and the output received from the simulator.

### Quick example

```text
(
  (IAttacker(CStartCounting 256))
  (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
  (IAttacker(CJmpIn enc_s))
)
```

Save that input sequence as `/tmp/alvie-input.sexp`, then run:

```bash
cd alvie/code
dune exec bin/exec.exe -- \
  --sexp-input /tmp/alvie-input.sexp \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --tmpdir /tmp/alvie-exec \
  --sancus "$PWD/../../sancus-core-gap" \
  --commit bf89c0b \
  --secret 0 \
  --debug
```

The S-expression uses the constructor names defined by `Sancus.Input`.
The supplied sequence must be compatible with the selected TestDL specifications.

---

## 4. `pbt.exe` — Property-based testing (no model learning)

**Purpose:** Tests non-interference (NI) directly on the Sancus simulator using QCheck random input generation, **without** learning a Mealy machine.
For each randomly generated input sequence, it runs the simulator twice (with secret=0 and secret=1) and checks that the low-level outputs are indistinguishable to the attacker.
Reports any counterexample found.

It is useful as a quick randomized sanity check, but it does not construct a learned model or prove absence of violations.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--att-spec1 <file>` | _(required)_ | Attacker spec for the first run (`.atdl`) |
| `--att-spec2 <file>` | _(required)_ | Attacker spec for the second run (`.atdl`) |
| `--encl-spec <file>` | _(required)_ | Enclave specification (`.etdl`) |
| `--step-limit <int>` | `500` | Number of generated test cases |
| `--tmpdir <dir>` | _(required)_ | Temp directory |
| `--sancus <dir>` | _(required)_ | Sancus simulator root |
| `--commit <sha>` | `ef753b6` | Sancus simulator git commit |
| `--sancus-master-key <hex>` | _(default)_ | Master key |
| `--debug` | false | Debug logging |
| `--info` | false | Info logging |

### Output

QCheck test results printed to stdout.
On failure, prints the shortest counterexample trace found (a sequence of inputs that produces distinguishable outputs for secret=0 vs secret=1).

### Quick example

```bash
cd alvie/code
_build/default/bin/pbt.exe \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --tmpdir /tmp/alvie-pbt \
  --sancus "$PWD/../../sancus-core-gap" \
  --step-limit 50 \
  --info
```

---

## Summary table

| Executable | Purpose | Needs simulator | Needs mCRL2 | Output |
|------------|---------|-----------------|-------------|--------|
| `learn.exe` | Learn Mealy machine via L# | Yes | No | `.dot` model |
| `fa.exe` | Find NI violations between two models | No | Yes | `.dot` witness graph |
| `exec.exe` | Replay supplied trace (debug) | Yes | No | stdout trace |
| `pbt.exe` | Random NI testing (no model) | Yes | No | QCheck report |
