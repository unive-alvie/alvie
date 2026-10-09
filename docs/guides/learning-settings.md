---
title: Choosing Learner Settings
description: How to choose the equivalence oracle and its limits, and how to balance run time against confidence in the learned model.
---

The learner settings decide how hard ALVIE looks for behavior that the model does not yet describe.
Weak settings finish fast and can give an incomplete model.
Strong settings give more confidence and take longer.
This guide helps you to choose.

Read [How ALVIE Works](/alvie/guides/concepts/) first.
The commands run from `alvie/code`.

## The three oracles

The `--oracle` option selects how ALVIE searches for a difference between the model and the system.

| Oracle | How it searches | Guarantee | Cost |
| --- | --- | --- | --- |
| `randomwalk` | Follows random paths that the specification allows. Stops after `--step-limit` steps. | None. | Low. You control it. |
| `pac` | Samples many random paths. The number grows with each round. | A probability bound from `--epsilon` and `--delta`. | Medium to high. |
| `exhaustive` | Tries every input sequence from the full alphabet, level by level. | It checks every sequence up to its stop condition. | Very high. |

Use `randomwalk` to develop and test a specification.
Use `pac` for a result that you report.
Use `exhaustive` only for very small specifications.

The wrapper scripts (`learn_one.sh`, `learn_all.sh`) use `pac` with `--epsilon 0.01 --delta 0.01`.

## Random walk

The random-walk oracle starts at the initial state of the model.
It chooses the next input at random from the inputs that the specification allows.
It sends the input to the system and compares the output with the model.
If the outputs differ, the oracle has found a difference.

Three options control it:

| Option | Default | Meaning |
| --- | --- | --- |
| `--step-limit` | 500 | The number of steps for each equivalence query. A reset also counts as one step. |
| `--reset-probability` | 0.05 | The probability that the walk restarts from the initial state after each step. |
| `--bad-probability` | 0.20 | The probability that the next input ignores the specification. `pac` uses this option too. |

A larger step limit means a longer search and a lower chance to miss a behavior.
A higher reset probability gives shorter paths and tests more early behavior.
A lower reset probability gives longer paths.
Use a lower value when the behavior you need appears only after many steps.

If the oracle finds no difference within the step limit, the learner accepts the model.
The oracle gives no probability for the error.

## PAC

The PAC oracle (Probably Approximately Correct) samples random paths in rounds.
Round *r* samples this many paths:

```text
ceil( (1 / ε) × ( ln(1 / δ) + (r + 1) × ln 2 ) )
```

The first round samples these numbers of paths:

| `--epsilon` and `--delta` | Paths in round 1 | Paths in round 2 |
| --- | --- | --- |
| 0.01 | 530 | 600 |
| 0.001 (default) | 7601 | 8295 |

- `--epsilon` is the error bound.
  A smaller value means that the model can disagree with the system on fewer paths.
- `--delta` is the confidence bound.
  A smaller value means that the guarantee fails with a lower probability.
- `--round-limit` limits the number of rounds.
  Without it, the oracle runs until a round finds no difference.

The guarantee is for one model.
An ALVIE experiment uses four models, so the combined bounds are weaker.
The paper gives (1 − δ)⁴ for the confidence and (1 − ε)⁴ for the accuracy.

`--pac-bound` has no effect on the oracle.
It appears only in the `--report` output.

## Exhaustive

The exhaustive oracle tries every input from the complete alphabet.
It does this level by level.
It does not use the specification to reduce the search.
A path ends when the system gives an illegal output.

The number of input sequences grows quickly with the length and the alphabet size.
Use this oracle only for a small alphabet, for example in a test of a new action.

## Measured examples

The table below shows real runs of the Getting Started example (secret 0, commit `bf89c0b`) on one workstation.
Five runs shared the machine, so the times are rough.
The complete model has 6 states and 5 transitions.

| Settings | SUL steps | Time | Result |
| --- | --- | --- | --- |
| `randomwalk --step-limit 20` | 141 | 33 s | 5 states. **Incomplete.** |
| `randomwalk --step-limit 100` | 146 | 31 s | 5 states. **Incomplete.** |
| `randomwalk --step-limit 500` | 228 | 34 s | 6 states. Complete. |
| `pac --epsilon 0.01 --delta 0.01` | 278 | 40 s | 6 states. Complete. |
| `pac` (default 0.001) | 1119 | 83 s | 6 states. Complete. |

The two short random walks accepted a model that had merged two states.
ALVIE did not report an error.
This is the main risk of a weak oracle.

Part of the time in each run is fixed.
ALVIE needs 20 to 25 seconds to prepare the simulator before it asks the first query.

## How to choose

1. **Develop with the fast specifications.**
   The directory `spec-lib/fast/` has faster attacker specifications.
   They use one timer value instead of four, so the learner has fewer cases to explore.
   The enclave specification is the same.
   Use `randomwalk --step-limit 5000 --reset-probability 0.09` with them.
   In development measurements on one workstation, learning the four B6 models took between 35 and 55 minutes.
2. **Test that the model is stable.**
   Learn the model again with a larger step limit.
   If the model does not change, you have more confidence in it.
   If it changes, the first limit was too low.
3. **Report with PAC.**
   Use `--oracle pac --epsilon 0.01 --delta 0.01` for the final run.
   Use the complete specifications for a result that you publish.
4. **State your settings.**
   Write the oracle, the limits, and the specification names next to every result.

The complete specifications can need many hours for each model.
Start the run on a machine that you can leave running.

## Repeatable runs

`learn.exe` starts its random generator with a fixed seed.
If you run the same command twice, you get the same search and the same model.
To try a different search, change a limit (for example `--step-limit`).
Do not run the same command again and expect a different result.

## Read the statistics

Add `--report` to print one line of statistics on the error output.
The fields, in order, are:

```text
oracle, pac-bound, epsilon, delta, step-limit, reset-probability,
resets, steps, dry-steps, output-queries, equivalence-queries,
average-path-length, path-length-variance, time-in-milliseconds
```

Example (the `randomwalk --step-limit 500` run above):

```text
randomwalk, 1, 0.001000, 0.001000, 500, 0.050000, 324, 228, 1011, 184, 6, 3.962687, 4.409055, 6242
```

- `steps` is the number of inputs that ran on the simulator.
- `dry-steps` is the number of inputs that ALVIE answered from data it already had.
- `equivalence-queries` is the number of rounds of model checking.
- The last field is the time that the learner took, without the simulator preparation.

## Interrupts

The option `--ignore-interrupts` changes `timer_enable`.
The action no longer enables the timer interrupt, so the timer cannot interrupt the enclave.
Use it to learn the baseline models for a four-model comparison.
Always give the baseline run the same oracle and limits as the main run.
The [Reading and Checking a Witness](/alvie/guides/interpreting-results/) guide explains how the comparison uses them.

## Related pages

- [Executables Reference](/alvie/reference/executables-reference/) lists every option.
- [Troubleshooting](/alvie/reference/troubleshooting/) helps when a run is too slow or gives an unexpected model.
- [Glossary](/alvie/reference/glossary/) defines ε, δ, and the other terms.
