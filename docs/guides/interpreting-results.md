---
title: Reading and Checking a Witness
description: How to read a comparison result, understand a witness graph, and check that a witness is a real difference.
---

This guide shows how to read the result of a comparison and how to check a witness.
It uses the Getting Started example, so run that example first.
The [How ALVIE Works](/alvie/guides/concepts/) page explains the terms.

The commands run from the repository root.
In the Docker image, the repository root is the start directory.

## 1. Find the violation count

The comparison tool prints the number of distinguishing traces.
It prints this number only in debug mode.

- `check_one.sh` and `check_all.sh` use debug mode.
  They save the count in `logs/<namespace>/compare-<commit>-<attack>.log`.
- `check_example.sh` does not use debug mode.
  Its log is empty.

For an attack run, read the count from the log:

```bash
grep "Results" logs/<namespace>/compare-*.log
```

The line looks like this:

```text
=== Results: found 15 FA violations. See …/ef753b6-b6_int.dot for details.
```

For the example, run the comparison again with `--debug`.
Run this command from `alvie/code`:

```bash
R=../../results/example
_build/default/bin/fa.exe \
  --m1-int $R/bf89c0b-attacker-enclave-0-0.01-0.01.dot \
  --m2-int $R/bf89c0b-attacker-enclave-1-0.01-0.01.dot \
  --witness-file-basename /tmp/example-witness \
  --tmpdir /tmp/alvie-fa \
  --debug
```

The example reports `found 1 FA violations`.
Without `--debug`, the tool writes the witness file and prints nothing.
You can also look at the witness file.
A witness with at least one transition contains lines with `->`:

```bash
grep -c -- '->' counterexamples/example/bf89c0b-attacker_int.dot
```

| Count | Meaning |
| --- | --- |
| 0 | No difference found. The witness file contains one state and no transitions. |
| 1 or more | The tool found differences. Open the witness file. |

The count is the number of traces, not the number of vulnerabilities.
The option `--cex-limit` caps it.

## 2. Draw the witness

Convert the witness to a PDF:

```bash
dot -Tpdf counterexamples/example/bf89c0b-attacker_int.dot -o example-witness.pdf
```

Open the PDF.
If you cannot open it, read the file as text.
Each transition is one line that starts with two state numbers.

## 3. Read the colors

A witness graph shows the paths of both models in one drawing.

| Style | Meaning |
| --- | --- |
| Black, dashed | A path of the secret 0 model. Paths that both models share are also black. |
| Red, dotted | A path of the secret 1 model. |

Start at the initial state.
Follow the black path.
The red path leaves the black path at the point where the two models first give different outputs.

## 4. Read one transition

Each transition has a label in this form:

```text
input / output (k = …, gie = …, umem_val = …, reg_val = …, timerA_counter = …, mode = …)
```

Example:

```text
ubr/Time (k = 7, gie = false, umem_val = 0, reg_val = 0, timerA_counter = 9, mode = PM)
```

| Part | Meaning |
| --- | --- |
| `ubr` | The input that ALVIE sent. |
| `Time` | The kind of output. See the [Log and Output Reference](/alvie/reference/log-output-reference/). |
| `k` | The number of clock cycles of this step. |
| `gie` | The global interrupt enable bit. |
| `umem_val` | The value of the observed unprotected memory cell. |
| `reg_val` | The value of register `r4`, reduced to 3 bits. |
| `timerA_counter` | The value of the hardware timer that the attacker can read. |
| `mode` | `PM` if the CPU runs protected code. `UM` if it runs unprotected code. |

The secret appears in some inputs.
For example, `cmp #0, r4` is the enclave instruction `cmp ?, r4` with secret 0.

## 5. Find the first difference

Compare the black and red paths step by step.
Stop at the first step where the output is different.

In the Getting Started example, the two paths separate at the secret comparison:

```text
black: cmp #0, r4 / Time (k = 1, …, timerA_counter = 2, mode = PM)
red:   cmp #1, r4 / Time (k = 1, …, timerA_counter = 2, mode = PM)
```

The outputs are equal here, so this step is not the difference.
The inputs differ only because the secret is in the input.

The next steps show the difference:

```text
black: ubr / Time (k = 7, …, timerA_counter = 9, mode = PM)
red:   ubr / Time (k = 2, …, timerA_counter = 4, mode = UM)
```

For secret 0, the enclave runs 7 cycles.
For secret 1, it runs 2 cycles.
The attacker reads the timer and learns the secret.

The exact cycle numbers can change with the toolchain and the ALVIE version.
The difference between the two paths is the important part.

## 6. Decide what kind of difference you have

Use this table to classify the first different output.

| What differs | Likely cause |
| --- | --- |
| `k` or `timerA_counter` | A timing leak. The secret changes the execution time. |
| `umem_val` | A value written to unprotected memory depends on the secret. |
| `reg_val` | A register value that depends on the secret reaches the attacker. |
| The kind of output (for example `Reset` against `Time`) | The secret changes the control flow or causes a reset. |
| `gie` or `mode` | The secret changes the interrupt state or the CPU mode. |

Next, decide whether the leak is a program flaw or an architecture problem.

- **Four-model comparison.**
  The tool has already removed the differences that exist without interrupts.
  What remains needs interrupts.
  It is more likely an architecture problem.
- **Two-model comparison.**
  The Getting Started example uses only two models.
  A difference can be a program flaw.
  The enclave in that example is unbalanced on purpose (`ubr`), so its witness is a program flaw.

Then check whether the witness is expected.
Some processor commits still have known problems.
The [Attack Catalogue](/alvie/reference/attack-catalogue/) lists them.
For example, the last Sancus commit `bf89c0b` still reports violations because of the known issues V-B8 and V-B9.

## 7. Replay the witness

Replay a witness to confirm it on the simulator.
You need the exact inputs.
The learned model files contain them in S-expression form.

1. Open the learned model for secret 0, for example `results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot`.
   Find the transitions along the witness path.
   Each label starts with the input:

   ```text
   0 -> 6 [label="((IAttacker(CStartCounting 256))(((OTime(…)))()5))", …
   ```

2. Write the inputs into a file, one after the other, inside one pair of parentheses:

   ```text
   ((IAttacker(CStartCounting 256))
    (IAttacker(CCreateEncl(enc_s enc_e data_s data_e)))
    (IAttacker(CJmpIn enc_s))
    (IEnclave(CInst(I_CMP(S_IMM 0)(D_R(R 4)))))
    (IEnclave CUbr))
   ```

3. Run `exec.exe` from `alvie/code` with secret 0:

   ```bash
   _build/default/bin/exec.exe \
     --sexp-input /tmp/trace0.sexp \
     --att-spec ../../spec-lib/example/attacker.atdl \
     --encl-spec ../../spec-lib/example/enclave.etdl \
     --secret 0 \
     --commit bf89c0b \
     --tmpdir /tmp/alvie-exec0 \
     --sancus "$PWD/../../sancus-core-gap"
   ```

4. Change `S_IMM 0` to `S_IMM 1` in the file.
   Run the command again with `--secret 1`.

The input must match the secret.
If the file has `S_IMM 0` and you pass `--secret 1`, the specification does not allow the input.
The tool shows a `†` output.

The tool prints one bracket group for each input.
For this trace, the last group is different:

```text
secret 0:  [SCt][Ct][Iti][=t][Uto]
secret 1:  [SCt][Ct][Iti][=t][Uo]
```

The two runs give different outputs for the same inputs, except for the secret.
This confirms the witness.
Add `--debug` to see the full payload of each step.

See the [Log and Output Reference](/alvie/reference/log-output-reference/) for the meaning of the symbols.

## 8. Run a known-answer check

A known-answer check shows that your setup produces correct results.
The repository contains learned models for the known attacks.
The comparison of these models is fast, because it does not run the simulator.

Run `fa.exe` from `alvie/code` on the checked-in B6 models:

```bash
R=../../results
mkdir -p /tmp/alvie-kat
_build/default/bin/fa.exe \
  --m1-int  $R/ef753b6-b6-enclave-complete-0-0.01-0.01-int.dot \
  --m2-int  $R/ef753b6-b6-enclave-complete-1-0.01-0.01-int.dot \
  --m1-nint $R/ef753b6-b6-enclave-complete-0-0.01-0.01-nint.dot \
  --m2-nint $R/ef753b6-b6-enclave-complete-1-0.01-0.01-nint.dot \
  --witness-file-basename /tmp/alvie-kat/b6 \
  --tmpdir /tmp/alvie-kat/tmp \
  --debug
```

The expected counts for the checked-in models are:

| Attack | Original commit `ef753b6` | Last commit `bf89c0b` |
| --- | --- | --- |
| B1 | 81 | 25 |
| B3 | 701 | 6 |
| B6 | 15 | 6 |

If your counts are different, check the build and the mCRL2 installation first.
See [Troubleshooting](/alvie/reference/troubleshooting/).

## 9. Report what you found

A finding is more useful when another person can reproduce it.
Keep these items:

- The commit label and the specification files.
- The `learn.exe` options, mainly the oracle and its limits.
- The four learned models and the witness file.
- The replay file and the output of both replays.

ALVIE shows that a difference exists.
It does not say how to fix it.
Use the witness and the replay to find the cause in the design.

If you think ALVIE gives a wrong result, open a [bug report](https://github.com/unive-alvie/alvie/issues/new?template=bug-report.yml) and attach these items.
