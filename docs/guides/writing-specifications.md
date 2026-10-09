---
title: Designing Your Own Specifications
description: How to plan, write, check, and refine attacker and enclave specifications for a new ALVIE experiment.
sidebar:
  badge:
    text: Advanced
    variant: caution
---

This guide shows how to design the specifications for an experiment that is not in `spec-lib/`.
It explains the decisions that come before the syntax.
It then gives a method to check that a specification works.

The [TestDL Specification Reference](/alvie/reference/testdl-specification-reference/) and the [TestDL Action Reference](/alvie/reference/testdl-action-reference/) define the syntax.
The [V-B1 tutorial](/alvie/guides/testdl-tutorial-vb1/) reads a complete specification line by line.
Read [How ALVIE Works](/alvie/guides/concepts/) before this guide.

## 1. Define the question

Write one sentence that states what you want to test.
Examples:

- "Can an interrupt change the execution time of an enclave branch that is balanced in time?"
- "Does a write to unprotected memory inside an enclave reach the attacker?"

The sentence tells you which attacker capabilities and which enclave behavior you need.
If you cannot write the sentence, you are not ready to write the specification.

## 2. Choose the attacker capabilities

The attacker specification has three sections.

| Section | What it describes |
| --- | --- |
| `prepare` | What the attacker does before the enclave runs: set a timer, create the enclave, jump in. |
| `isr` | What the attacker does when an interrupt stops the enclave. |
| `cleanup` | What the attacker does after the enclave stops. |

The ALVIE paper uses two attackers as a pattern.

- **The basic attacker** creates the enclave, starts it, and observes the result.
  It does not use interrupts.
  The file `spec-lib/example/attacker.atdl` is a basic attacker.
- **The interrupt attacker** also schedules timer interrupts and handles them.
  It adds `timer_enable` in `prepare`, and `reti` in `isr`.
  Most of the files `spec-lib/b*.atdl` are interrupt attackers.

Add capabilities one at a time.
Each new action makes the alphabet larger, so learning takes longer.

| You want to test | Add |
| --- | --- |
| Timing of interrupts | `timer_enable` with several values in `prepare`. |
| Behavior in the handler | Actions in `isr`, then `reti`. |
| Abuse of entry points | `jin enc_s` in `isr`, or `reti` in `cleanup`. |

A timer value selects the moment of the interrupt.
Use several values in a choice, for example `(timer_enable 1 | timer_enable 2 | timer_enable 3 | timer_enable 4)`.
Then the learner can interrupt the enclave at different instructions.

## 3. Choose the enclave behavior

The enclave specification describes a family of victim programs.
The programs must be such that a correct processor keeps the secret.
A leak in the program itself does not help you.

The ALVIE paper uses this pattern:

```text
enclave {
    cmp ?, r4;
    ( ifz (c; nop) (nop; c) | … );
    jmp #enc_e
};
```

- `cmp ?, r4` compares the secret with a value.
  The `?` is the secret placeholder.
- `ifz (c; nop) (nop; c)` runs the command `c` in one of two branches.
  The branches take the same time, because each has `c` and a `nop`.
- Each choice in the list is one command `c` to test, for example a write to memory.

If the branches have the same length, a correct processor must hide the secret.
A difference between the secrets then shows a problem in the processor.
Use `ifz` with balanced branches for every command you test.
Do not write an unbalanced branch, because it adds program flaws to the result.

Use two secret values (0 and 1).
The enclave compares the secret with 0, so these two values cover both branches.

## 4. Start small

Do not begin with the complete specification.
Take the smallest specification that can show your question.

1. Copy `spec-lib/example/` to a new directory.
2. Change one thing.
3. Learn, compare, and read the witness.
4. Change the next thing.

The number of actions that appear in your specification is the size of the alphabet.
Every action multiplies the work of the learner.
These changes make learning much more expensive:

- Many alternatives in one choice.
- A repetition (`*`) that allows sequences of unlimited length.
- Several timer values.

Use a repetition only when the behavior needs an unlimited number of steps.
Use a single timer value first.
The `spec-lib/fast/` files do this, and they learn much faster.

## 5. Check the specification before a long run

Use these checks in this order.
Each takes less time than the next one.

1. **Parse check.**
   Run `learn.exe`.
   A syntax error appears at once with exit code 2.
   The message shows the place:

   ```text
   ALVIE error: Could not parse the TestDL specifications: section_enclave > };: string. …
   ```

2. **Dry run.**
   Add `--dry` to `learn.exe`.
   The tool prepares the simulator and then stops without learning.
   This takes about 20 seconds.
   Use it to check your setup and your paths.
3. **Short run.**
   Learn with `--oracle randomwalk --step-limit 500`.
   Look at the model.
   Does it show the actions that you expect?
4. **Full run.**
   Learn with the oracle that you plan to report.
   See [Choosing Learner Settings](/alvie/guides/learning-settings/).

## 6. Use a control experiment

A comparison that finds nothing can mean two things.
The processor is secure, or your specification cannot show the problem.
A control experiment tells you which.

- **A positive control** is a specification and a processor that must show a leak.
  Use the original commit `ef753b6` with a known attack.
  If ALVIE finds no leak, your specification is too weak.
- **A negative control** is a specification that must show no leak.
  Use an enclave that is balanced on purpose.
  If ALVIE finds a leak, look for a flaw in the specification.

### Example: a negative control

The enclave of the Getting Started example is unbalanced on purpose (`ubr`).
The comparison of its two models gives 1 violation.

Write a balanced enclave in the file `/tmp/balanced.etdl`:

```text
enclave {
    cmp ?, r4;
    ifz (mov r5, r5; nop) (nop; mov r5, r5);
    jmp #enc_e
};
```

Learn one model for each secret.
Run this command from `alvie/code`, once with `--secret 0` and once with `--secret 1`.
Change the name of the result file each time.

```bash
_build/default/bin/learn.exe \
  --att-spec  ../../spec-lib/example/attacker.atdl \
  --encl-spec /tmp/balanced.etdl \
  --oracle pac --epsilon 0.01 --delta 0.01 \
  --secret 0 \
  --commit bf89c0b \
  --res /tmp/balanced-0.dot \
  --tmpdir /tmp/alvie-balanced-0 \
  --sancus "$PWD/../../sancus-core-gap"
```

Compare the two models:

```bash
_build/default/bin/fa.exe \
  --m1-int /tmp/balanced-0.dot \
  --m2-int /tmp/balanced-1.dot \
  --witness-file-basename /tmp/balanced-witness \
  --tmpdir /tmp/alvie-fa \
  --debug
```

The result is `found 0 FA violations`.
Both branches take the same time, so the attacker sees no difference.
The control works.
The example enclave gives a witness, and the balanced enclave gives none.

## 7. Refine from the witness

Use each result to decide the next change.

| Result | Next step |
| --- | --- |
| A witness. | Read it, and replay it. See [Reading and Checking a Witness](/alvie/guides/interpreting-results/). Decide if it is a program flaw or a processor problem. |
| A witness that is a program flaw. | Fix the enclave specification so that its branches are balanced. Learn again. |
| No witness, and the controls work. | Add one capability to the attacker, or one command to the enclave. Learn again. |
| No witness, and the positive control fails. | The specification is too weak. Add the missing capability. |

Keep each specification and its results in one namespace.
Write down the settings that you used.
Then you can reproduce the result later.

## Common mistakes

| Mistake | Effect | Fix |
| --- | --- | --- |
| `?` in an attacker action. | ALVIE does not expand `?` in the attacker sections. | Use `?` only in enclave instructions. |
| A nested `ifz`, `ubr`, or `balanced_ifz` in an `ifz` branch. | The specification is not supported. | Put each in the main sequence, not in a branch. |
| Missing `--secret`. | `learn.exe` stops with exit code 2. | Add `--secret 0` or `--secret 1`. |
| Different oracle limits for the `int` and `nint` models. | The comparison can show differences that come from the learner. | Use the same limits for all four models. |
| A repetition without need. | Learning does not finish in a useful time. | Replace `a*` with a fixed number of choices. |

## Related pages

- [Attack Catalogue](/alvie/reference/attack-catalogue/) shows the specifications for the known attacks.
- [Extending TestDL Actions](/alvie/guides/spec-extending-actions/) explains how to add a new kind of action.
- [Troubleshooting](/alvie/reference/troubleshooting/) lists errors and fixes.
