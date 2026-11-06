---
title: "Tutorial: Find a Leak on Tiny"
description: Learn and compare models of Tiny, the reference platform of ALVIE/Core, and find two planted timing leaks in a few seconds, without a simulator.
sidebar:
  order: 2
isNew: true
---

This tutorial runs a whole ALVIE experiment on **Tiny**, the reference platform of ALVIE/Core.
Tiny is a small processor written in OCaml, so learning a model takes a fraction of a second, and you need no simulator and no Sancus checkout.
It has two planted timing leaks: one that any attacker sees, and one that only an attacker with interrupts sees.
The steps are those of an experiment on Sancus (see [Getting Started](/alvie/getting-started/)), and [How ALVIE Works](/alvie/guides/concepts/) explains the ideas behind them.

You need the OCaml build of ALVIE (`dune build` in `alvie/code`, for example in the Docker image) and, to compare models, mCRL2.
Run every command from `alvie/code`.

## 1. The platform

Tiny runs the attacker's code or the code of one enclave.
The attacker arms a timer with `timer n` and calls the enclave with `call`.
Each instruction of the enclave takes one or two cycles, and the timer counts them.
When the timer expires during an instruction, the instruction completes and then the interrupt is handled: the attacker sees the interrupt and its *latency*, the cycles the instruction still ran after the timer expired.
The attacker's ISR runs, and `reti` resumes the enclave.
When the enclave returns (`ret`), the attacker sees how many cycles it ran since it was called or last resumed.

The enclave's instructions:

| Instruction | Cycles |
| --- | --- |
| `nop`, `mov r, v`, `ret` | 1 |
| `bz r` (branch on zero) | 2 if `r` is 0, 1 otherwise |
| `pad r` (pads a branch on zero) | 1 if `r` is 0, 2 otherwise |

The plugin files are in `plugins/tiny/`, and the backend is `lib/core/tiny/tiny.ml`.

## 2. The spec

A spec says which tests to run, one body per section, as for Sancus.
`plugins/tiny/fixtures/leak-time.spec`:

```
// The enclave branches on the secret with bz: it takes two cycles if the secret is 0, one otherwise, so the time it
// takes tells the secret, with or without interrupts.
prepare { (timer 1 | timer 2 | timer 3 | eps); call };
enclave { mov r0, ?; bz r0; ret };
isr { reti };
cleanup { halt };
```

The attacker may arm the timer, then calls the enclave.
The enclave puts the secret (`?`) in `r0` and branches on it.
The ISR resumes the enclave, and after the enclave has returned the attacker ends the test.

## 3. Run one test by hand

`alvie tiny exec` runs atoms one at a time and prints what each observes, with the section the test moves to.
Write the atoms in a file, one per line:

```
timer 2
call
mov r0, 0
bz r0
reti
ret
halt
```

```bash
_build/default/bin/alvie.exe tiny exec --spec plugins/tiny/fixtures/leak-time.spec --secret 0 --inputs inputs.txt
```

```text
prepare  timer 2          Ok
prepare  call             Enter  -> enclave
enclave  mov r0, 0        Run
enclave  bz r0            Irq(latency = 1)  -> isr
isr      reti             Resume  -> enclave
enclave  ret              Exit(time = 1)  -> cleanup
cleanup  halt             Done  (finished)
```

`mov` took one cycle; the timer expired after the first cycle of `bz`, which takes two on 0, so the latency is 1.
An atom that the spec does not allow at that point is refused, with the atoms it allows.

## 4. Learn two models

Learn a model for each value of the secret:

```bash
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-time.spec --secret 0 --res /tmp/tiny/time-0.dot
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-time.spec --secret 1 --res /tmp/tiny/time-1.dot
```

```text
Learned a model of 19 states and 21 transitions in 0.1s (1078 queries, 1640 steps): /tmp/tiny/time-0.dot
Learned a model of 17 states and 19 transitions in 0.1s (961 queries, 1541 steps): /tmp/tiny/time-1.dot
```

Learning is deterministic: the same spec and options give the same model (`--seed` changes the random choices).
The options of the learner are those of [Choosing Learner Settings](/alvie/guides/learning-settings/): `--oracle pac` (the default) with `--epsilon` and `--delta`, or `--oracle randomwalk`.

## 5. Compare them

`alvie tiny compare` looks for runs that the attacker tells apart: the same attacker inputs, the same enclave code up to the secret, and different outputs.

```bash
_build/default/bin/alvie.exe tiny compare --m1 /tmp/tiny/time-0.dot --m2 /tmp/tiny/time-1.dot --secrets 0,1 --witnesses /tmp/tiny/time-witnesses.dot
```

```text
noninterference does not hold: 3 witnesses (see /tmp/tiny/time-witnesses.dot)
```

The exit status is 4 when there are witnesses, so scripts can test it.
Render the witness graph with Graphviz (`dot -Tsvg /tmp/tiny/time-witnesses.dot -o witnesses.svg`) and read it as [Reading and Checking a Witness](/alvie/guides/interpreting-results/) explains: one witness is the run without a timer, where the enclave returns after `Exit(time = 4)` for secret 0 and `Exit(time = 3)` for secret 1.

## 6. Is the leak caused by interrupts?

Learn the same spec on the variant `no-interrupts`, whose timer never expires, and give it to `compare` as the baseline: witnesses that the baseline has too do not count.

```bash
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-time.spec --secret 0 --variant no-interrupts --res /tmp/tiny/time-0-nint.dot
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-time.spec --secret 1 --variant no-interrupts --res /tmp/tiny/time-1-nint.dot
_build/default/bin/alvie.exe tiny compare --m1 /tmp/tiny/time-0.dot --m2 /tmp/tiny/time-1.dot \
  --m1-baseline /tmp/tiny/time-0-nint.dot --m2-baseline /tmp/tiny/time-1-nint.dot \
  --secrets 0,1 --witnesses /tmp/tiny/time-witnesses-baseline.dot
```

```text
noninterference holds: 0 witnesses (see /tmp/tiny/time-witnesses-baseline.dot)
```

Every witness is already there without interrupts: the leak of `bz` is the time the enclave takes, which any attacker sees.

## 7. A leak that only interrupts reveal

`plugins/tiny/fixtures/leak-interrupt.spec` pads the branch:

```
enclave { mov r0, ?; bz r0; pad r0; ret };
```

`bz r0; pad r0` takes three cycles whatever the secret, so without interrupts nothing leaks.
Learn the four models and compare, first the baseline on its own, then with interrupts against it:

```bash
for s in 0 1; do
  _build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-interrupt.spec --secret $s --res /tmp/tiny/irq-$s.dot
  _build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-interrupt.spec --secret $s --variant no-interrupts --res /tmp/tiny/irq-$s-nint.dot
done
_build/default/bin/alvie.exe tiny compare --m1 /tmp/tiny/irq-0-nint.dot --m2 /tmp/tiny/irq-1-nint.dot --secrets 0,1 --witnesses /tmp/tiny/irq-nint.dot
_build/default/bin/alvie.exe tiny compare --m1 /tmp/tiny/irq-0.dot --m2 /tmp/tiny/irq-1.dot \
  --m1-baseline /tmp/tiny/irq-0-nint.dot --m2-baseline /tmp/tiny/irq-1-nint.dot --secrets 0,1 --witnesses /tmp/tiny/irq.dot
```

```text
noninterference holds: 0 witnesses (see /tmp/tiny/irq-nint.dot)
noninterference does not hold: 2 witnesses (see /tmp/tiny/irq.dot)
```

The witnesses arm the timer with `timer 2` or `timer 3`.
With `timer 2`, the timer expires in the first cycle of `bz` for secret 0, a latency of 1, and at the end of `bz` for secret 1, a latency of 0: the interrupt tells the secret, as the attack of Nemesis does on Sancus.

## 8. Check a mitigation

The parameter `mitigation` of the manifest is an option of every command.
`--mitigation constant-time` makes `bz` and `pad` take two cycles whatever the register:

```bash
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-interrupt.spec --secret 0 --mitigation constant-time --res /tmp/tiny/ct-0.dot
_build/default/bin/alvie.exe tiny learn --spec plugins/tiny/fixtures/leak-interrupt.spec --secret 1 --mitigation constant-time --res /tmp/tiny/ct-1.dot
_build/default/bin/alvie.exe tiny compare --m1 /tmp/tiny/ct-0.dot --m2 /tmp/tiny/ct-1.dot --secrets 0,1 --witnesses /tmp/tiny/ct.dot
```

```text
noninterference holds: 0 witnesses (see /tmp/tiny/ct.dot)
```

## 9. Other properties

`alvie tiny property` checks the other properties of the catalogue: inclusion and equivalence of two models, with a trace that shows the difference, and mCRL2 formulas (see the [Executables Reference](/alvie/reference/executables-reference/#properties-alvie-property)).
For example, the two models without interrupts of step 6 are not equivalent:

```bash
_build/default/bin/alvie.exe tiny property equivalence /tmp/tiny/time-0-nint.dot /tmp/tiny/time-1-nint.dot
```

```text
does not hold: a trace of /tmp/tiny/time-0-nint.dot only:
  call/Enter
  mov r0; 0/τ
  bz r0/τ
  ret/Exit[time = 4]
```

Hidden outputs are `τ`.

## 10. All at once: the fixtures

Steps 4 to 8 are the *fixtures* of Tiny, in `plugins/tiny/fixtures`: each is a spec with the verdict it must give.
`alvie tiny fixtures` learns and compares them all, and checks the verdicts:

```bash
_build/default/bin/alvie.exe tiny fixtures --out /tmp/tiny/fixtures
```

```text
PASS leak-interrupt           a leak (2 witnesses)
PASS leak-time-baseline       no leak
PASS leak-time                a leak (3 witnesses)
PASS safe-constant-time       no leak
PASS safe-no-branch           no leak
5 fixtures, 0 failed (models and witnesses in /tmp/tiny/fixtures)
```

## Next

- Change the enclave of a spec and predict the verdict before you check it.
- [Plugin Author Guide](/alvie/guides/plugin-author-guide/): Tiny is also the smallest complete plugin; the guide shows how to make your own.
- [Getting Started](/alvie/getting-started/): the same experiment on Sancus, with its simulator.
