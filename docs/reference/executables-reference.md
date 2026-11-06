---
title: Executables Reference
description: Command-line reference for ALVIE/Sancus tools.
sidebar:
  order: 2
---

All executables are built with `dune build` from inside `alvie/code/` and run from the **`alvie/code/` directory** unless a `--tmpdir` or `--sancus` path says otherwise.

## The `alvie` command

`alvie` gathers the tools of this page under one command:

| Command | Same as | Does |
| --- | --- | --- |
| `alvie learn` | `learn.exe` | Learns a model |
| `alvie compare` | `fa.exe` | Compares the four models of an experiment |
| `alvie exec` | `exec.exe` | Runs a sequence of inputs on the simulator |
| `alvie pbt` | `pbt.exe` | Property-based testing of two attacker specifications |
| `alvie property inclusion M1 M2` | | Checks that every trace of `M1` is one of `M2`, or prints one that is not |
| `alvie property equivalence M1 M2` | | Checks that two models have the same traces, or prints one of a single model |
| `alvie property formula M -f F.mcf` | | Checks that a model satisfies an mCRL2 modal μ-calculus formula |
| `alvie plugin check [DIR]` | | Checks the files of a plugin (by default `plugins/sancus`, which `alvie` is built with) and prints a summary, or every problem with its place |
| `alvie plugin schemas OUT` | | Writes the JSON Schemas of the plugin files and of the plugin's values to `OUT` |
| `alvie plugin new NAME [--external]` | | Makes a plugin from the template: native, or external in Python (see the [Plugin Author Guide](/alvie/plugin-authors/plugin-author-guide/)) |
| `alvie plugin types DIR OUT.py` | | Writes the Python constructors of the observations of the plugin in `DIR` |
| `alvie external DIR ...` | | The commands of ALVIE/Core on the external plugin in `DIR` (see the [protocol](/alvie/plugin-authors/protocol/)) |
| `alvie tiny ...` | | The commands of ALVIE/Core on Tiny, the reference platform (see [below](#the-commands-of-a-plugin)) |
| `alvie sancus conformance`, `fixtures`, `exec` | | The same commands on Sancus: the conformance of the simulator, and the fixtures of `plugins/sancus` |

```bash
_build/default/bin/alvie.exe learn --att-spec ... --encl-spec ... --res model.dot --tmpdir /tmp/alvie --sancus ../../sancus-core-gap --oracle pac
_build/default/bin/alvie.exe plugin check
```

`learn.exe`, `fa.exe`, `exec.exe` and `pbt.exe` are the same commands under their former names.
They remain for one release, for the scripts and tools that call them (alvie-ui runs `bin/learn.exe` and reads its output, which does not change), and the sections below describe them by these names.

The options of the backend (`--sancus`, `--commit`, `--sancus-master-key`, `--tmpdir`, `--keep-repeated-reentries`) come from the configuration parameters of `plugins/sancus/alvie-plugin.yaml`: their names, types, defaults and help are those of the manifest.

## Properties (`alvie property`)

`alvie property` checks the other properties of the catalogue of ALVIE/Core (version 1) on learned models.
Noninterference, the fourth, is `alvie compare`.
Like `alvie compare`, it sees the models as the attacker does: through the view of `plugins/sancus/view.yaml`, with hidden outputs silent (`τ` in traces).
Each needs mCRL2.

```bash
_build/default/bin/alvie.exe property equivalence ../../results/264f135-b7-enclave-complete-0-0.01-0.01-int.dot ../../results/264f135-b7-enclave-complete-1-0.01-0.01-int.dot
_build/default/bin/alvie.exe property formula model.dot --formula my-property.mcf
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--tmpdir` | `/tmp/alvie` | Directory for the files given to mCRL2 |
| `--formula`, `-f` | | The formula (`formula` only) |
| `--debug` | | Debug-level logging, and keep the files of mCRL2; the command prints where they are |

In a formula, the actions are the labels of the model, `input/Output(fields)`, made into mCRL2 identifiers: every character other than a letter or a digit becomes `_`.
With `--debug`, `actions.txt`, next to the model given to mCRL2, lists each action and its label.

The exit status is 0 when the property holds and 4 when it does not; when it does not, the output gives a trace that shows it (except for a formula).
A mistake in the command or the files (a missing model, a model of a newer format, a formula that mCRL2 rejects) exits with 2 and a message.

## The commands of a plugin

ALVIE/Core has the same commands for every plugin: `alvie tiny ...` for Tiny, `alvie-NAME ...` for a native plugin made with `alvie plugin new`, and `alvie external DIR ...` for an external one (`alvie external plugins/tiny-py ...` for Tiny in Python).
Their options include those of the plugin's manifest: `--mitigation` for Tiny.
The [Tiny tutorial](/alvie/core/tiny-tutorial/) uses each of them.

| Command | Does |
| --- | --- |
| `learn --spec F --res M.dot` | Learns a model of the backend under the spec (several `--spec` for a spec in several files) |
| `compare --m1 A --m2 B --secrets s1,s2 --witnesses W.dot` | Noninterference: the witnesses that tell apart two models that differ only in the secret |
| `property inclusion\|equivalence\|formula` | The other properties, as `alvie property` below |
| `exec --spec F --inputs FILE` | Runs the atoms of `FILE` (one per line, as a spec writes them) and prints what each observes |
| `conformance --spec F` | Checks that the backend keeps the contract of Core, on random tests of the spec |
| `fixtures [NAME ...]` | Learns and compares the plugin's fixtures, and checks their verdicts |

Options of `learn` (and of `exec` and `conformance` where they apply):

| Option | Default | Meaning |
| --- | --- | --- |
| `--secret V` | | The value of the secret `?` in the spec; needed when the spec has one |
| `--variant NAME` | | A variant of the system from the manifest, such as `no-interrupts` |
| `--oracle` | `pac` | `pac`, with `--epsilon` and `--delta` (0.01 each) and `--round-limit`, or `randomwalk`, with `--test-count` (10000) and `--reset-probability` (0.09) |
| `--seed N` | 0 | The seed of the random choices: learning is deterministic for a seed |
| `--debug` | | Debug-level logging |

Options of `compare`: `--m1-baseline` and `--m2-baseline` (models of a baseline variant, whose witnesses do not count), `--tmpdir` (for mCRL2, default `/tmp/alvie`) and `--cex-limit`.
Options of `conformance`: `--tests` (50), `--length` (30) and `--seed`; of `fixtures`: `--dir` (another directory of fixtures) and `--out` (the models, witnesses and files of mCRL2, default `/tmp/alvie/fixtures`).

The models of these commands are of the generic form: their inputs are atoms and their outputs observations, as the plugin files declare them; they do not contain the inputs that the spec does not allow.
`compare`, `property` and `fixtures` refuse a model of another plugin.

`compare`, `property`, `conformance` and `fixtures` exit with 0 when the check passes and 4 when it does not.
A mistake in the command or its files exits with 2; errors that the command-line parser finds (an unknown option, a value of the wrong type, a missing option) exit with 1.

On Sancus, `alvie learn` and `alvie compare` stay the commands of experiments, with the Sancus model files; `alvie sancus` has the commands that check the plugin.
The simulator takes a few minutes for each model of a fixture.

## Model files

Learned models are Graphviz `.dot` files whose first line says what made them:

```text
// alvie-model format 1; plugin sancus 2026.10; core 1
```

Models without this line come from earlier versions; they read the same.
A model of a later format is refused with a message: it needs a newer ALVIE, and so is a model of another plugin.

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
| `--oracle <mode>` | Query oracle mode: `randomwalk`, `pac`, or `exhaustive` |
| `--res <file>` | Output `.dot` file path for the learned model |
| `--tmpdir <dir>` | Directory for temporary Verilog simulation files |
| `--sancus <dir>` | Path to the Sancus simulator root |

### Other flags

| Flag | Default | Description |
|------|---------|-------------|
| `--commit <sha>` | `ef753b6` | Label or git commit of the Sancus version to check |
| `--secret <value>` | absent | Secret substituted into the enclave specification; required when the spec contains `?` |
| `--epsilon <float>` | `0.001` | PAC error bound, used only by `pac` |
| `--delta <float>` | `0.001` | PAC confidence parameter, used only by `pac` |
| `--pac-bound <int>` | `1` | Included in `--report` output only; does not limit the current PAC oracle |
| `--step-limit <int>` | `500` | Max steps for a random-walk equivalence query |
| `--round-limit <int>` | unlimited | Max rounds for a PAC equivalence query |
| `--reset-probability <float>` | `0.05` | Random-walk probability of restarting the current path |
| `--bad-probability <float>` | `0.20` | Probability of generating an input not driven by the specification |
| `--ignore-interrupts` | false | Treat interrupts as invisible (collapse interrupt outputs) |
| `--keep-repeated-reentries` | false | Do not identify a segment of execution between two enclave re-entries with an identical one immediately before it (see [Choosing Learner Settings](/alvie/core/learning-settings/#repeated-enclave-re-entries)); learning may not finish when an enclave can be resumed repeatedly |
| `--sancus-master-key <hex>` | _(default key)_ | Master key passed to the Sancus simulator |
| `--dry` | false | Dry run: set up the simulator but do not learn |
| `--report` | false | Print a line of learning statistics on stderr (see the [log output reference](/alvie/sancus/log-output-reference/#learning-statistics)) |
| `--debug` | false | Enable debug-level logging |
| `--info` | false | Enable info-level logging: one line per equivalence-query round and one per counterexample (see the [log output reference](/alvie/sancus/log-output-reference/#info-level-output)) |

### Environment variables

| Variable | Effect |
|----------|--------|
| `ALVIE_SIM_CACHE` | Directory where compiled simulators are kept and reused (default: `simv-cache` inside `--tmpdir`); `0` always compiles. Also used by `exec.exe` and `pbt.exe` |
| `ALVIE_PROFILE` | With `1`, print on stderr, at the end of the run, the time spent in each part of the learner and of the simulator; `SIGUSR1` prints it during the run |
| `ALVIE_CHECK_APART` | With `1`, check every answer of the learner's caches against a computation from scratch, and stop at the first difference. Very slow: for testing changes to the learner |
| `ALVIE_FULL_TRACE` | With `1`, the simulator dumps every signal instead of the top level of the testbench (useful to inspect the VCD files); used when the simulator is compiled |
| `OCAMLRUNPARAM` | Garbage collector settings; when it is set, `learn.exe` does not apply its own |

### Output

A Mealy machine in `.dot` format is written to `--res`.
Each edge is labelled `input / output`, where inputs and outputs use the symbolic alphabet defined in the specifications.
See the [Log and Output Reference](/alvie/sancus/log-output-reference/) for output token meanings.

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

### Failures and diagnostics

`learn.exe`, `fa.exe`, and `pbt.exe` validate their input files and output directories before running a simulator, model comparison, or property-based test.
`learn.exe` also validates the oracle, relevant numeric options, Sancus checkout, and secret placeholder before simulator setup.
It exits with status 2 for those user-correctable errors.
An incomplete simulator run exits with status 3 and must not be interpreted as a learned model or security result.
For an unexpected failure, rerun with `--debug` and file a [bug report](https://github.com/unive-alvie/alvie/issues/new?template=bug-report.yml) with the command and sanitized diagnostics.

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
| `--cex-limit <int>` | unlimited | Stops the search after the round that finds this many witnesses, in each of the two directions. One round can find several witnesses, so the result can have more. |
| `--secrets <s1>,<s2>` | from the model names | The values of the secret in the first and the second model. By default they are read from the names `<commit>-<attacker>-<enclave>-<secret>-<eps>-<delta>[-int\|-nint].dot`. The comparison ignores them in the victim's code, so that the two runs of a witness run "the same code". |
| `--debug` | false | Enable debug-level logging |

### Output

`<witness-file-basename>_int.dot` — a `.dot` graph whose paths are distinguishing traces (attack witnesses).
If no counterexample exists, the file contains one state and no transitions.
The tool prints the number of violations only with `--debug`.
See [Reading and Checking a Witness](/alvie/core/interpreting-results/) for how to read the graph.

### Quick example

```bash
cd alvie/code
_build/default/bin/fa.exe \
  --m1-int    /tmp/example-orig-s0-int.dot \
  --m2-int    /tmp/example-orig-s1-int.dot \
  --m1-nint   /tmp/example-orig-s0-nint.dot \
  --m2-nint   /tmp/example-orig-s1-nint.dot \
  --witness-file-basename /tmp/example-orig-witness \
  --tmpdir /tmp/alvie-fa \
  --cex-limit 3
```

Produces `/tmp/example-orig-witness_int.dot` containing up to 3 distinguishing attack traces.
Add `--debug` to print the number of flow-analysis violations (`=== Results: found N FA violations.`).

---

## 3. `exec.exe` — Replay an input sequence (debugging tool)

**Purpose:** Developer/debugging utility.
Sets up the Sancus simulator exactly like `learn.exe` but, instead of learning, replays the input sequence stored in `--sexp-input` and prints the observed outputs.
It is useful for manually inspecting the simulator's response to a specific trace without running the full learner.

### Flags

Same setup flags as `learn.exe` (minus oracle/learning flags):

| Flag | Description |
|------|-------------|
| `--sexp-input <file>` | Required S-expression file containing the raw input sequence to replay |
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

```bash
cd alvie/code
cat > /tmp/alvie-trace.sexp <<'EOF'
((IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
 (IAttacker(CJmpIn enc_s))
 (IEnclave(CInst I_NOP)))
EOF

_build/default/bin/exec.exe \
  --sexp-input /tmp/alvie-trace.sexp \
  --att-spec  ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --secret    1 \
  --tmpdir    /tmp/alvie-exec \
  --sancus    "$PWD/../../sancus-core-gap" \
  --debug
```

---

## 4. `pbt.exe` — Property-based reset-equivalence testing

**Purpose:** Uses QCheck to generate two input traces without learning a Mealy machine.
The first trace follows `--att-spec1`.
The second follows `--att-spec2` while reusing the first trace's enclave actions.
It runs both traces on the selected simulator configuration and checks whether they agree on the occurrence of a reset.

`pbt.exe` does not substitute secret values or compare the complete attacker-visible output.
It is therefore a focused randomized reset-equivalence smoke test, not a replacement for `learn.exe` followed by `fa.exe`.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--att-spec1 <file>` | _(required)_ | Attacker spec for the first run (`.atdl`) |
| `--att-spec2 <file>` | _(required)_ | Attacker spec for the second run (`.atdl`) |
| `--encl-spec <file>` | _(required)_ | Enclave specification (`.etdl`) |
| `--test-count <int>` | `500` | Number of generated property tests to run |
| `--step-limit <int>` | deprecated | Compatibility alias for `--test-count` |
| `--tmpdir <dir>` | _(required)_ | Temp directory |
| `--sancus <dir>` | _(required)_ | Sancus simulator root |
| `--commit <sha>` | `ef753b6` | Simulator git commit |
| `--sancus-master-key <hex>` | _(default)_ | Master key |
| `--debug` | false | Debug logging |
| `--info` | false | Info logging |

### Output

QCheck test results are printed to stdout.
On failure, the reported pair of traces differs in whether execution resets.

### Quick example

```bash
cd alvie/code
_build/default/bin/pbt.exe \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --tmpdir /tmp/alvie-pbt \
  --sancus "$PWD/../../sancus-core-gap" \
  --test-count 50 \
  --info
```

---

## Summary table

| Executable | Purpose | Needs simulator | Needs mCRL2 | Output |
|------------|---------|-----------------|-------------|--------|
| `learn.exe` | Learn Mealy machine via L# | Yes | No | `.dot` model |
| `fa.exe` | Find NI violations between two models | No | Yes | `.dot` witness graph |
| `exec.exe` | Replay an input trace (debug) | Yes | No | stdout trace |
| `pbt.exe` | Random NI testing (no model) | Yes | No | QCheck report |
