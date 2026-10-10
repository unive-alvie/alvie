---
title: Attack Catalogue
description: The known Sancus vulnerabilities that ALVIE reproduces, with their commits, specification files, and expected results.
sidebar:
  order: 3
isNew: true
---

This page lists the Sancus problems that ALVIE can reproduce.
Use it to choose an experiment and to check that your result is the expected one.

The names B1 to B9 come from the papers.
B1 to B7 are from [*Mind the Gap*](https://mici.hu/papers/bognar22gap.pdf) (Bognar, Van Bulck, Piessens).
B8 and B9 are new findings from the [ALVIE paper](https://arxiv.org/abs/2404.09518).
The papers call them V-B1 to V-B9.

## The three commits

Each experiment uses up to three versions of the Sancus processor (`--commit`).
All three are in the `sancus-core-gap` repository.

| Commit | Meaning |
| --- | --- |
| `ef753b6` | The original version. It has all the known problems. |
| A fixing commit | The version that fixes one problem. See the table below. |
| `bf89c0b` | The last version. It has all the fixes of the *Mind the Gap* paper. |

## Mismatches between model and implementation

Each row is one problem in the Sancus implementation.
The "Attacker spec" column names the specification in `spec-lib/`.

| ID | Problem | Fixing commit | Attacker spec | Fast spec |
| --- | --- | --- | --- | --- |
| B1 | The first instruction after `reti` takes one extra cycle. | `e8cf011` | `b1.atdl` | yes |
| B2 | One instruction takes more than 6 cycles (the maximum in the model). | `3170d5d` | `b2.atdl` | yes |
| B3 | An enclave can be resumed more than once with `reti`. | `6475709` | `b3.atdl` | yes |
| B4 | An interrupted enclave can be restarted from the interrupt service routine. | `3636536` | `b4.atdl` | yes |
| B5 | More than one enclave can exist. | `b17b013` | none | no |
| B6 | An enclave can access unprotected memory. | `d54f031` | `b6.atdl` | yes |
| B7 | An enclave can change interrupt behavior (for example the `GIE` bit). | `264f135` | `b7.atdl` | yes |
| B8 | A read or write violation resets the CPU. | none | `b8.atdl` | no |
| B9 | The enclave can reset the CPU with `rst`. | none | `b9.atdl` | yes |

Notes:

- **B5 is not supported.**
  ALVIE has no action that creates more than one enclave.
- **B8 and B9 have no fix.**
  Even the last commit `bf89c0b` has them.
  The paper explains that a CPU reset inside an enclave is an observable event, and an attacker with interrupts can use it.
- **Problems outside the scope.**
  The *Mind the Gap* paper also describes two problems that need new attacker capabilities (V-C1, DMA, and V-C2, the watchdog timer).
  ALVIE does not analyze them.

## Other specification files

| File | Content |
| --- | --- |
| `spec-lib/enclave-complete.etdl` | The enclave family for all attacks. |
| `spec-lib/complete.atdl` | One attacker with four timer values in `prepare`. The interrupt service routine can set a timer, then run `reti` or `jin enc_s`. `cleanup` runs `nop` or `reti`. |
| `spec-lib/a.atdl` | One attacker with a fixed timer (`timer_enable 4`) and `reti` in the interrupt service routine. |
| `spec-lib/example/` | The running example of the paper. Its enclave is insecure on purpose. |
| `spec-lib/fast/` | Faster versions of the attacker specifications. They use one timer value (`timer_enable 3`, or 4 for B7) instead of four. The enclave family is the same. |

The attacker specifications differ mainly in the interrupt service routine (`isr`) section.
For example, `b1.atdl` runs `timer_enable 1; reti` in the routine, and `b4.atdl` runs `jin enc_s`.
Open the file to see exactly what the attacker can do.

## Commands

The wrapper scripts learn all models for one attack and compare them.
The third argument is the output namespace.
See [Reproducing the Simulation Experiments](/alvie/guides/walkthrough-repro/) for details.

For B1, B2, B3, B4, B6, and B7, give the fixing commit:

```bash
./learn_one.sh d54f031 b6 b6-sim
./check_one.sh b6 b6-sim
```

For B8 and B9, there is no fixing commit:

```bash
./learn_one_nospecial.sh b8 b8-sim
./check_one.sh b8 b8-sim
```

Each run learns four models for each commit.
See [How ALVIE Works](/alvie/guides/concepts/) for the reason.

## Expected results

The repository contains learned models for every row above.
The table shows the number of violations that `fa.exe` reports for the checked-in four-model sets.
A result that matches these numbers shows that your setup works.
A different number is not always an error.
New models learned with a different oracle or different limits can give a different number.

| Attack | `ef753b6` | Fixing commit | `bf89c0b` |
| --- | --- | --- | --- |
| B1 | 237 | 62 (`e8cf011`) | 33 |
| B2 | 18 | 11 (`3170d5d`) | 6 |
| B3 | 768 | 8 (`6475709`) | 6 |
| B4 | 32 | 16 (`3636536`) | 6 |
| B6 | 15 | 10 (`d54f031`) | 6 |
| B7 | 15 | 6 (`264f135`) | 6 |
| B8 | 15 | — | 6 |
| B9 | 15 | — | 6 |
| `a.atdl` | 13 | — | 0 |

Two points help you to read this table:

- **The counts do not fall to zero.**
  The enclave family includes `rst` and a read from unprotected memory.
  They trigger B8 and B9 on every commit, including `bf89c0b`.
  A count of 6 on `bf89c0b` is the expected "fixed" result.
- **`a.atdl` reports nothing on `bf89c0b`.**
  It uses one timer value only.
  It is the attacker used to observe the behavior of Section IV.D of the paper: when the enclave jumps to its data section, the CPU loops instead of resetting.
  The learned models show this behavior, but it is visible without interrupts too, so the comparison removes it.
  The paper reports it as not exploitable.
- **A count is not a number of vulnerabilities.**
  It is the number of witness traces.
  Compare the counts of one attack across commits, not across attacks.

To check one fix, compare the original commit with the fixing commit.
The witnesses that disappear are the effect of the fix.
The [Reading and Checking a Witness](/alvie/guides/interpreting-results/) guide shows how to read them.

## A worked example

The [TestDL Tutorial: V-B1 Example](/alvie/guides/testdl-tutorial-vb1/) explains the B1 specification and its witness line by line.
It is the best first example of an attack.
