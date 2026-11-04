---
title: Testing ALVIE
description: The ALVIE test suites, what each one needs, when to run it, and how to add a test.
sidebar:
  order: 8
  badge:
    text: A
    variant: caution
isNew: true
---

This guide is for people who change the ALVIE code, the specifications, or the documentation.
It explains which tests exist, which tools each test needs, and which tests to run after each kind of change.

All commands run from `alvie/code`, unless the text says otherwise.
Run `dune build` first.

## The test suites

| Suite | Command | Needs | Time |
| --- | --- | --- | --- |
| Isolated features | `dune exec test/features.exe -- test --color=never` | Nothing outside OCaml. | Under 1 second. |
| Diagnostics | `dune exec test/diagnostics.exe -- --color=never` | Nothing outside OCaml. | Under 1 second. |
| CLI diagnostics | `bash test/cli_diagnostics.sh` | Nothing outside OCaml. | A few seconds. |
| Input generation corpus | `dune exec tt_inputgen_golden -- check` | Nothing outside OCaml. | About 1 second. |
| Simulator regression | `dune exec test/attack.exe -- test --color=never` | The Sancus checkout, Verilator, the MSP430 toolchain. | About 2 minutes. |
| Witness regression | `./regression.sh witnesses` (from the repository root) | mCRL2. | A few minutes. |
| Learning regression | `./regression.sh learning` (from the repository root) | The Sancus checkout, Verilator, the MSP430 toolchain, mCRL2. | About 5 minutes on 16 cores. |

The first four suites are the fast checks.
They do not need the simulator, mCRL2, or a `sancus-core-gap` checkout.
This is a design rule.
Keep them independent of external tools, so that every contributor can run them.

### Isolated features (`tt_features`)

This suite tests the ALVIE parts in isolation.
It has 24 tests in four groups:

- TestDL parsing (syntax, operators, rejected input).
- Specification semantics (secret expansion, code generation, derivatives).
- Input generation (sections, interrupts, `reti`, illegal outputs).
- Models and observations (the observation tree, serialization, payload merge, output equality).

### Diagnostics (`diagnostics.exe`)

This suite checks that a simulator that does not finish becomes an `ALVIE incomplete` message with exit code 3.

### CLI diagnostics (`cli_diagnostics.sh`)

This script runs the built executables with wrong input.
It checks the exit code and the text of the message.
It covers the input errors that the [Troubleshooting](/alvie/reference/troubleshooting/) page lists.

### Input generation corpus (`tt_inputgen_golden`)

This suite pins down what the input generator offers.
The corpus `test/golden/inputgen.sexp` holds random walks, with a fixed seed, on the learned models in `results/`.
For every prefix of a walk, it records the actions that `Inputgen.get_options` offers next.
Each prefix is a history that the learner really observed, so the check needs neither the simulator nor mCRL2.

`check` recomputes the options of every prefix and prints each difference, with the model and the length of the prefix.
It exits with code 1 when it finds a difference, and with code 2 when the corpus, a model or a specification is missing.

A change to the input generator must keep the corpus unless the change is on purpose.
When it is on purpose, regenerate the corpus, look at the difference, and explain it in the commit message:

```bash
dune exec tt_inputgen_golden -- generate
git diff --stat test/golden/inputgen.sexp
```

### Simulator regression (`tt_attack`)

This suite replays attack traces on the simulator.
It compares the output with the expected output for each processor commit, secret, and interrupt mode.
It needs `sancus-core-gap` at `../../sancus-core-gap` from `alvie/code`.

The suite has 38 tests in groups named after the attacks (`example`, `b1`, `b2`, …).
Run one group by its name:

```bash
dune exec test/attack.exe -- test --color=never b6
```

The complete suite took about 2 minutes on a 16-core machine, once the simulators were compiled and cached (see `ALVIE_SIM_CACHE`).
Run the complete suite before you change anything that touches the simulator interface.

### Checking changes to the learner

The learner keeps several caches so that it does not recompute apartness and the frontier after every query.
Set `ALVIE_CHECK_APART=1` to check every answer of these caches against a computation from scratch: `learn.exe` stops at the first difference.
The run becomes much slower, so use a small specification, for example `spec-lib/fast/b4.atdl` or the Getting Started example.
A change that only makes the learner faster must also give the same model and the same `--report` statistics as before.

### Witness and learning regression (`regression.sh`)

`regression.sh` checks that a change leaves the checked-in results unchanged.
Run it from the repository root.

- `./regression.sh witnesses` compares the checked-in models of `results/` again with `fa.exe`.
  Every witness graph must be identical to the one in `counterexamples/`, and every witness count must be the one in `alvie/code/test/regression/witness-counts.txt`.
  These are the counts of the [Attack Catalogue](/alvie/reference/attack-catalogue/).
- `./regression.sh learning` learns every checked-in model again, with the settings of the wrapper scripts.
  Every model must be identical, byte for byte, to the checked-in one: learning is deterministic, because the learner uses a fixed random seed.
  It then runs the witness check on the new models.
  It writes the learning time of each model, slowest first, to `logs/regression/learning/learning-times.txt`.
- `./regression.sh all` runs both.

The script writes everything under `results/regression/`, `counterexamples/regression/` and `logs/regression/`, and never changes the checked-in files.
Each difference is printed on a line that starts with `DIFFERENT:`, and the script reports all of them before it exits.
The exit code is 0 when there is no difference, 1 when there are differences, and 2 when a tool or a file is missing or a step fails.

If a model, a graph or a count changes, find out why before you accept it.
A change can show a bug, or a real improvement.
When it is on purpose, regenerate the checked-in files with the wrapper scripts, update the counts in `witness-counts.txt` and in the attack catalogue together, and write the reason in the commit message.

## What continuous integration runs

The workflow `alvie-tests.yml` runs on every pull request and on every push to `main`.
It runs these steps:

1. `dune build`
2. `dune exec tt_features -- test --color=never`
3. `bash test/cli_diagnostics.sh`
4. `dune exec tt_inputgen_golden -- check`

A second job runs the simulator-backed suites in the published Docker image, which has the simulator toolchain and mCRL2:
`./regression.sh all` and `tt_attack`.

The workflow `docs.yml` runs on pull requests that change `docs/`, `site/`, or the Dockerfile.
It copies `docs/` into the site, builds the site, and checks every internal link.
It also checks that the published Docker image has Graphviz, the Sancus checkout, and a working `dune build`.

The simulator job takes much longer than the fast checks.
Run the suites yourself before you push a change that needs them, as the next table shows.

## What to run after a change

| You changed | Run |
| --- | --- |
| The TestDL parser, the specification types, or code generation | `tt_features` |
| Input generation or the observation tree | `tt_features` and `tt_inputgen_golden -- check` |
| A command-line option or an error message | `cli_diagnostics.sh` and `diagnostics.exe` |
| The simulator interface, the VCD analysis, or the output payload | `tt_attack` and `./regression.sh learning` |
| The learner or the oracles | `./regression.sh learning` |
| The model comparison (`cexfinder.ml`, `fa.exe`) | `./regression.sh witnesses` |
| A specification in `spec-lib/` | A short learning run and a comparison |
| A page in `docs/` | The documentation check below |

## Known-answer check for the comparison

`./regression.sh witnesses` checks all the checked-in models at once.
To check one attack by hand, run `fa.exe` with `--debug` on its four checked-in models.
For example, for B6 on the original commit, the count must be 49.
The command is in [Reading and Checking a Witness](/alvie/guides/interpreting-results/#8-run-a-known-answer-check).

## Documentation check

Run the same steps as `docs.yml`.
You need Node.js 22.
Run these commands from the repository root:

```bash
cd site
npm ci
rm -rf src/content/docs
mkdir -p src/content/docs
cp -R ../docs/. src/content/docs/
npm run build
node scripts/check-links.mjs
```

The check fails when a link points to a page that does not exist.
Git ignores the copied files in `site/src/content/docs`.

For every command that you add to a guide, run it once, and compare the output with the text.

## Add a test

### A fast test

Add a test to `test/features.ml` when the code does not need the simulator.

1. Write a function that checks one fact with Alcotest:

   ```ocaml
   let test_reject_invalid_attack_trace () =
     Alcotest.(check bool) "negative timer is rejected" true
       (Result.is_error (Testdl.Parser.parse_attack_trace "att: timer_enable -1"))
   ```

2. Add it to the list at the end of the file, in the group that fits:

   ```ocaml
   Alcotest.test_case "reject invalid attack trace" `Quick test_reject_invalid_attack_trace;
   ```

3. Run the suite.

Keep each test small, and test one fact.
Do not call external tools.

### A test for an error message

Add a case to `test/cli_diagnostics.sh` with the helper `expect_status`.
Give it the expected exit code, a part of the message, and the command.

### A simulator test

Add a test to `test/attack.ml`.
Use the `exec` helper.
It needs these items:

- The attacker specification name.
- The input trace, in the readable form `att: …; enc: …`.
- The commit.
- Whether interrupts are ignored.
- The expected outputs for secret 0 and secret 1.

Mark the test `` `Slow ``.
Take the expected values from a run that you checked by hand.
Do not copy the actual output without a check, because the test then confirms only the current behavior.

## When a simulator test fails

An expected value can fail for three reasons.

1. **You found a regression.**
   Your change altered the behavior.
   Fix the change.
2. **The environment is different.**
   A different MSP430 toolchain, Verilator version, or Sancus commit can change cycle counts.
   Use the Docker image to compare.
3. **The expected value is out of date.**
   Update it only when you know that the new value is correct.
   Explain it in the commit message.

Never update an expected value only to make the test pass.
A test that shows a changed timing value can show a security-relevant change.
