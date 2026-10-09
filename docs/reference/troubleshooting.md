---
title: Troubleshooting
description: Symptoms, causes, and fixes for the problems that users meet when they build ALVIE, run experiments, and read results.
---

Find your symptom in the tables below.
Each entry gives the likely cause and the action to take.

If none of the entries helps, open a [bug report](https://github.com/unive-alvie/alvie/issues/new?template=bug-report.yml).
Include the full command, the output, and the files that you used.

## Exit codes

ALVIE tools use these exit codes:

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | The tool finished. | Check the result. A finished run is not always a finding. |
| 1 | An unexpected failure. | Run again with `--debug`. Open a bug report. |
| 2 | An input error that you can fix. | Read the message. It names the option or the file. |
| 3 | The simulator did not finish (`ALVIE incomplete`). | Do not use the output. Run again with `--debug`. |

## Build and setup

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `dune: command not found` in a Docker command | The opam environment is not active. | Run `eval "$(opam env)"` first. An interactive shell does this for you. |
| `Library "core" not found` | The active opam switch is not the one with the ALVIE dependencies. | Run `eval "$(opam env --switch=<name>)"` with the correct switch. Then run `dune build` again. |
| `dune build` fails on a missing library | The dependencies are not installed. | Run `opam install . --deps-only --with-test` in `alvie/code`. |
| A simulator run fails, and `which msp430-gcc` prints nothing. | The MSP430 toolchain is not installed or not on the `PATH`. ALVIE also needs `msp430-as` and `msp430-ld`. | Install the toolchain from [Getting Started](/alvie/getting-started/). |
| A simulator run fails, and `verilator --version` fails or shows another version. | Verilator is missing or has another version. | The Docker image uses version 5.002. Use the image, or follow the native installation steps. |
| `fa.exe` fails, and `which ltscompare` prints nothing. | mCRL2 is not installed. `fa.exe` needs `ltscompare` and `tracepp`. | Install mCRL2. |
| `dot: command not found` | Graphviz is not installed. | Install it. The current Docker image has it. Older images do not. |
| The directory `sancus-core-gap` is empty | The git submodule is not downloaded. | Run `git submodule update --init` in the repository root. |

## Input errors (exit code 2)

These messages start with `ALVIE error:`.

| Message | Cause | Action |
| --- | --- | --- |
| `… names a file that does not exist` | A path is wrong. Paths are relative to the current directory. | Run the tool from `alvie/code`, or use absolute paths. |
| `… names a directory that does not exist` | The `--sancus` path is wrong. | Point `--sancus` to the `sancus-core-gap` directory. |
| `Could not parse the TestDL specifications: …` | A specification has a syntax error. The message shows the place. | Check for a missing `;`, a missing section, or a register outside `r0` to `r14`. See the [Specification Reference](/alvie/reference/testdl-specification-reference/). |
| `The enclave specification uses ?. Supply --secret <value>.` | The enclave uses the secret placeholder. | Add `--secret 0` or `--secret 1`. |
| `Unknown --oracle value … Choose randomwalk, pac, or exhaustive.` | The oracle name is wrong. | Use one of the three names. |
| `--epsilon must be greater than 0 and smaller than 1` | A number is out of range. | Use a value in the range that the message shows. |
| `--X requires --Y` | Two options must be used together. | Add the missing option. |

A parse error appears at once, before the simulator starts.
This makes it a fast way to check a specification.
To check a specification and your setup without learning, add `--dry` to `learn.exe`.
The tool prepares the simulator, which takes about 20 seconds, and writes a model with one state.

## While a run is going

| Symptom | Likely cause | Action |
| --- | --- | --- |
| The output shows many `†` symbols. | This is normal. `†` means "input not allowed here". ALVIE sends 20% of its inputs without the guidance of the specification (`--bad-probability`) on purpose. | Do nothing. ALVIE removes these transitions from the final model. |
| Nothing appears for 20 to 30 seconds at the start. | ALVIE prepares the simulator. | Wait. |
| A run takes many hours. | The complete specifications with the `pac` oracle are large. | Use `spec-lib/fast/` and `randomwalk` while you develop. See [Choosing Learner Settings](/alvie/guides/learning-settings/). |
| A wrapper prints `[OK - Done before]` and does nothing. | The result file exists. The wrapper skips finished work. | Use a new namespace, or delete the old result files. |
| `Comparison incomplete: no secret-0 interrupt-enabled models found` | The `results/<namespace>/` directory has no models. | Run the learning wrapper first. Use the same namespace. |
| `Comparison incomplete: missing no-interrupt model` | One of the four models is missing. | Learn the missing model. The comparison needs all four. |
| A wrapper prints `[KO - <logfile>]` | One background job failed. | Read the log file that the message names. |

## Results that look wrong

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `fa.exe` prints nothing. | The count appears only in debug mode. | Add `--debug`. The witness file is written in any case. |
| `check_example.sh` shows no violation count. | The script does not use debug mode. | Run `fa.exe` with `--debug`. See [Reading and Checking a Witness](/alvie/guides/interpreting-results/). |
| The witness file has one state and no transitions. | The comparison found no difference. | This is a result, not an error. See the limits in [How ALVIE Works](/alvie/guides/concepts/#what-a-result-means). |
| The model has fewer states than expected. | The oracle stopped too early. A short random walk can accept a model that has merged two states. | Learn again with a larger `--step-limit`, or use `pac`. |
| Two runs of the same command give the same model. | `learn.exe` uses a fixed random seed. This is by design. | To try a different search, change a limit. |
| The numbers differ from a checked-in model. | The state numbers are arbitrary. Timing values can differ between ALVIE versions and toolchains. | Compare the structure first. A fresh example run can show `k = 648` for `create` where the checked-in model shows `k = 600`. |
| The violation count differs from the [Attack Catalogue](/alvie/reference/attack-catalogue/). | New models can differ when the oracle or the limits differ. | Run the comparison on the checked-in models first. If that count is wrong, check the build and mCRL2. |
| `exec.exe` shows `†` for an input that you copied from a model. | The secret in the input does not match `--secret`. | Use the same secret in the input and in the option. |
| The last commit `bf89c0b` still gives witnesses. | The known problems B8 and B9 have no fix in any commit. | This is the expected result. See the [Attack Catalogue](/alvie/reference/attack-catalogue/). |

## Docker

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Files disappear after the container stops. | The `--rm` option removes the container. | Mount a host directory, and copy the results to it. See [Getting Started](/alvie/getting-started/). |
| The ALVIE installation disappears when you mount a directory. | The mount hides `/home/alvie`. | Mount a different path, for example `/output`. |
