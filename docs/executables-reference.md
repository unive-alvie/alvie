# ALVIE Executables Reference

All executables are built with `dune build` from inside `alvie/code/` and run as:

```
_build/default/bin/<name>.exe [flags]
```

from the **`alvie/code/` directory** unless a `--tmpdir` or `--sancus` path says otherwise.

---

## 1. `learn.exe` — Learn a Mealy machine model

**Purpose:** Runs the L# active automata learning algorithm against a Sancus Verilog simulation. Produces a `.dot` file representing the learned Mealy machine (the attacker's observable behaviour of the enclave). This is the main experiment driver.

### Required flags

| Flag | Description |
|------|-------------|
| `--att-spec <file>` | Path to attacker specification (`.atdl` file) |
| `--encl-spec <file>` | Path to enclave specification (`.etdl` file) |
| `--oracle <mode>` | Query oracle mode: `randomwalk`, `pac`, or `exhaustive` |

### Optional flags

| Flag | Default | Description |
|------|---------|-------------|
| `--res <file>` | _(none)_ | Output `.dot` file path for the learned model |
| `--tmpdir <dir>` | `/tmp` | Directory for temporary Verilog simulation files |
| `--sancus <dir>` | `../..` (repo root) | Path to the Sancus simulator root |
| `--commit <sha>` | _(HEAD)_ | Git commit of the Sancus simulator to check out before running |
| `--secret <0\|1>` | `0` | Secret value loaded into the enclave (controls which branch is executed) |
| `--epsilon <float>` | `0.005` | PAC epsilon parameter (accuracy bound) |
| `--delta <float>` | `0.005` | PAC delta parameter (confidence bound) |
| `--step-limit <int>` | `200` | Max steps per random walk / PAC sample |
| `--round-limit <int>` | _(none)_ | Max total learning rounds before stopping |
| `--reset-probability <float>` | `0.1` | Probability of reset in random-walk oracle |
| `--bad-probability <float>` | `0.05` | Probability of injecting a "bad" (non-standard) input |
| `--pac-bound <int>` | _(computed)_ | Override the number of PAC samples |
| `--ignore-interrupts` | false | Treat interrupts as invisible (collapse interrupt outputs) |
| `--sancus-master-key <hex>` | _(default key)_ | Master key passed to the Sancus simulator |
| `--dry` | false | Dry run: set up the simulator but do not learn |
| `--report <file>` | _(none)_ | Write a JSON learning report to this file |
| `--debug` | false | Enable debug-level logging |
| `--info` | false | Enable info-level logging |

### Output

A Mealy machine in `.dot` format written to `--res`. Each edge is labelled `input / output` where inputs and outputs use the symbolic alphabet defined in the specs. See `docs/log-output-reference.md` for output token meanings.

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
  --info
```

This learns a model for the `example` attack with secret=0 using random-walk equivalence queries, writing the result to `/tmp/example-s0.dot`.

---

## 2. `fa.exe` — Find flow-analysis (NI) violations between two models

**Purpose:** Takes four `.dot` Mealy machines — the secret=0 and secret=1 models in both the interrupt (`--int`) and no-interrupt (`--nint`) variants — and uses mCRL2 model checking to find distinguishing traces (counterexamples to non-interference). Outputs a witness graph in `.dot` format.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--m1-int <file>` | _(required)_ | secret=0 model, interrupt variant (`.dot`) |
| `--m2-int <file>` | _(required)_ | secret=1 model, interrupt variant (`.dot`) |
| `--m1-nint <file>` | _(required)_ | secret=0 model, no-interrupt variant (`.dot`) |
| `--m2-nint <file>` | _(required)_ | secret=1 model, no-interrupt variant (`.dot`) |
| `--witness-file-basename <base>` | _(required)_ | Output path prefix; produces `<base>_int.dot` |
| `--tmpdir <dir>` | `/tmp` | Directory for intermediate mCRL2 files |
| `--cex-limit <int>` | `1` | Number of counterexamples to enumerate |
| `--debug` | false | Enable debug-level logging |

### Output

`<witness-file-basename>_int.dot` — a `.dot` graph whose paths are distinguishing traces (attack witnesses). If no counterexample exists (the models are equivalent), the file is empty.

### Quick example

```bash
cd alvie/code
_build/default/bin/fa.exe \
  --m1-int    /tmp/example-orig-s0-int.dot \
  --m2-int    /tmp/example-orig-s1-int.dot \
  --m1-nint   /tmp/example-orig-s0-nint.dot \
  --m2-nint   /tmp/example-orig-s1-nint.dot \
  --witness-file-basename /tmp/example-orig-witness \
  --cex-limit 3
```

Produces `/tmp/example-orig-witness_int.dot` containing up to 3 distinguishing attack traces.

---

## 3. `exec.exe` — Replay a fixed input sequence (debugging tool)

**Purpose:** Developer/debugging utility. Sets up the Sancus simulator exactly like `learn.exe` but instead of learning, it replays a **hardcoded** input sequence and prints the observed outputs. Useful for manually inspecting the simulator's response to a specific trace without writing a full spec or running the full learner.

> **Note:** The input sequence to replay is currently hardcoded in `alvie/code/bin/exec.ml` (lines 137–144). To test a different trace, edit that file and rebuild.

### Flags

Same setup flags as `learn.exe` (minus oracle/learning flags):

| Flag | Description |
|------|-------------|
| `--att-spec <file>` | Attacker specification (`.atdl`) |
| `--encl-spec <file>` | Enclave specification (`.etdl`) |
| `--tmpdir <dir>` | Temp directory for simulation files |
| `--sancus <dir>` | Path to Sancus simulator root |
| `--commit <sha>` | Simulator git commit to use |
| `--secret <0\|1>` | Secret value |
| `--ignore-interrupts` | Collapse interrupt outputs |
| `--sancus-master-key <hex>` | Master key |
| `--debug` | Debug logging |
| `--info` | Info logging |

### Output

Prints one line per step to stdout: the input sent and the output received from the simulator.

### Quick example

```bash
cd alvie/code
# Edit bin/exec.ml lines 137-144 to set the desired trace, then rebuild:
dune build

_build/default/bin/exec.exe \
  --att-spec  ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --secret    1 \
  --info
```

---

## 4. `pbt.exe` — Property-based testing (no model learning)

**Purpose:** Tests non-interference (NI) directly on the Sancus simulator using QCheck random input generation, **without** learning a Mealy machine. For each randomly generated input sequence, it runs the simulator twice (with secret=0 and secret=1) and checks that the low-level outputs are indistinguishable to the attacker. Reports any counterexample found.

This is faster than `learn.exe` for a quick sanity-check but less thorough (it cannot prove absence of violations).

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--att-spec1 <file>` | _(required)_ | Attacker spec for the first run (`.atdl`) |
| `--att-spec2 <file>` | _(required)_ | Attacker spec for the second run (`.atdl`) |
| `--encl-spec <file>` | _(required)_ | Enclave specification (`.etdl`) |
| `--step-limit <int>` | `200` | Max steps per generated test case |
| `--tmpdir <dir>` | `/tmp` | Temp directory |
| `--sancus <dir>` | `../..` | Sancus simulator root |
| `--commit <sha>` | _(HEAD)_ | Simulator git commit |
| `--secret <0\|1>` | `0` | Secret value (the two runs differ only in this) |
| `--ignore-interrupts` | false | Collapse interrupt outputs |
| `--sancus-master-key <hex>` | _(default)_ | Master key |
| `--debug` | false | Debug logging |
| `--info` | false | Info logging |

### Output

QCheck test results printed to stdout. On failure, prints the shortest counterexample trace found (a sequence of inputs that produces distinguishable outputs for secret=0 vs secret=1).

### Quick example

```bash
cd alvie/code
_build/default/bin/pbt.exe \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --step-limit 50 \
  --info
```

---

## Summary table

| Executable | Purpose | Needs simulator | Needs mCRL2 | Output |
|------------|---------|-----------------|-------------|--------|
| `learn.exe` | Learn Mealy machine via L# | Yes | No | `.dot` model |
| `fa.exe` | Find NI violations between two models | No | Yes | `.dot` witness graph |
| `exec.exe` | Replay hardcoded trace (debug) | Yes | No | stdout trace |
| `pbt.exe` | Random NI testing (no model) | Yes | No | QCheck report |
