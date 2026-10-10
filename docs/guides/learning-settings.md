---
title: Choosing Learner Settings
description: How to choose the equivalence oracle and its limits, and how to balance run time against confidence in the learned model.
sidebar:
  label: Learner Settings
  order: 5
  badge:
    text: A
    variant: caution
isNew: true
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

With `--info`, `learn.exe` logs one line for each round, with the size of the hypothesis and the number of queries so far, and one line for each counterexample that a round finds.
See the [Log and Output Reference](/alvie/reference/log-output-reference/#info-level-output).

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

The table below shows real runs of the Getting Started example (secret 0, commit `bf89c0b`) on one workstation, one run at a time.
The complete model has 6 states and 5 transitions.
The learning time does not include the preparation of the simulator (see below).

| Settings | SUL steps | Learning time | Result |
| --- | --- | --- | --- |
| `randomwalk --step-limit 20` | 136 | 0.2 s | 5 states. **Incomplete.** |
| `randomwalk --step-limit 100` | 200 | 0.2 s | 6 states. Complete. |
| `randomwalk --step-limit 500` | 220 | 0.3 s | 6 states. Complete. |
| `pac --epsilon 0.01 --delta 0.01` | 287 | 0.4 s | 6 states. Complete. |
| `pac` (default 0.001) | 1116 | 0.9 s | 6 states. Complete. |

The shortest random walk accepted a model that had merged two states.
ALVIE did not report an error.
This is the main risk of a weak oracle.

To run the comparison yourself, use a loop from `alvie/code`.
The first run takes about 20 seconds, and the next ones about 1 second each:

```bash
cd alvie/code
for limit in 20 100 500; do
  _build/default/bin/learn.exe \
    --att-spec ../../spec-lib/example/attacker.atdl \
    --encl-spec ../../spec-lib/example/enclave.etdl \
    --oracle randomwalk --step-limit $limit \
    --secret 0 \
    --commit bf89c0b \
    --res /tmp/rw-$limit.dot \
    --tmpdir /tmp/alvie-rw \
    --sancus "$PWD/../../sancus-core-gap" \
    --report
done
wc -l /tmp/rw-*.dot
cd ../..
```

The run with limit 20 writes 20 lines, and the runs with limits 100 and 500 write 21 lines.
The `--report` option prints one line of statistics for each run.

Part of the time in each run is fixed: ALVIE prepares the simulator before it asks the first query.
The first run in a temporary directory compiles the simulator, which takes about 17 seconds.
The compiled simulator is kept in `simv-cache` inside the `--tmpdir` directory, so later runs that use the same `--tmpdir` prepare the simulator in about 1 second.
Set `ALVIE_SIM_CACHE` to use another cache directory, or `ALVIE_SIM_CACHE=0` to always compile.

## How to choose

1. **Develop with the fast specifications.**
   The directory `spec-lib/fast/` has faster attacker specifications.
   They use one timer value instead of four, so the learner has fewer cases to explore.
   The enclave specification is the same.
   Use `randomwalk` with them, and start with `--step-limit 500`.
2. **Test that the model is stable.**
   Learn the model again with a larger step limit.
   If the model does not change, you have more confidence in it.
   If it changes, the first limit was too low.
3. **Report with PAC.**
   Use `--oracle pac --epsilon 0.01 --delta 0.01` for the final run.
   Use the complete specifications for a result that you publish.
4. **State your settings.**
   Write the oracle, the limits, and the specification names next to every result.

With the complete specifications, most models take from a few seconds to about 2 minutes, and the slowest ones (B1 and B3 with interrupts on `ef753b6`) about 5 minutes.
All the models of `learn_all.sh` take about 6 minutes on a machine with 16 cores.

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
randomwalk, 1, 0.001000, 0.001000, 500, 0.050000, 295, 220, 1031, 186, 6, 4.310680, 4.078235, 267
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

## Repeated enclave re-entries

When an attacker can resume an enclave with `reti` more than once (B3 on the unpatched commit `ef753b6`), it can repeat the same piece of enclave execution again and again.
Each repetition makes the trace longer, and the simulation stops only when it reaches its time limit.
Without a special treatment, the learner sees every repetition as a new state and does not finish.

By default, the simulator identifies a segment of execution between two re-entries with an identical segment immediately before it: same inputs, same outputs, and the same state of the input generator.
The first repetition stays in the model, so the vulnerability is still visible.
`--keep-repeated-reentries` turns this off.
Use it only to study the unrolled behavior, together with `--round-limit`, because the learning may not finish.

## Speed

These settings change the speed of a run but not its result:

- `ALVIE_SIM_CACHE` chooses where compiled simulators are kept (see above).
- `ALVIE_JOBS` limits how many experiments the wrapper scripts run at the same time.
  The default is the number of cores.
- `learn.exe` tunes the OCaml garbage collector for learning.
  Set `OCAMLRUNPARAM` to choose other settings.
- `ALVIE_PROFILE=1` prints at the end of a run how much time each part of the learner and of the simulator took.
  Send the signal `SIGUSR1` to a running `learn.exe` to print the profile so far.

## Related pages

- [Executables Reference](/alvie/reference/executables-reference/) lists every option.
- [Troubleshooting](/alvie/reference/troubleshooting/) helps when a run is too slow or gives an unexpected model.
- [Glossary](/alvie/reference/glossary/) defines ε, δ, and the other terms.
