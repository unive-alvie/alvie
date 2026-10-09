---
title: Testing ALVIE
description: The ALVIE test suites, what each one needs, when to run it, and how to add a test.
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
| Simulator regression | `dune exec test/attack.exe -- test --color=never` | The Sancus checkout, Verilator, the MSP430 toolchain. | Minutes for each group. |

The first three suites are the fast checks.
They do not need the simulator, mCRL2, or a `sancus-core-gap` checkout.
This is a design rule.
Keep them independent of external tools, so that every contributor can run them.

### Isolated features (`tt_features`)

This suite tests the ALVIE parts in isolation.
It has 23 tests in four groups:

- TestDL parsing (syntax, operators, rejected input).
- Specification semantics (secret expansion, code generation, derivatives).
- Input generation (sections, interrupts, `reti`, illegal outputs).
- Models and observations (the observation tree, serialization, payload merge).

### Diagnostics (`diagnostics.exe`)

This suite checks that a simulator that does not finish becomes an `ALVIE incomplete` message with exit code 3.

### CLI diagnostics (`cli_diagnostics.sh`)

This script runs the built executables with wrong input.
It checks the exit code and the text of the message.
It covers the input errors that the [Troubleshooting](/alvie/reference/troubleshooting/) page lists.

### Simulator regression (`tt_attack`)

This suite replays attack traces on the simulator.
It compares the output with the expected output for each processor commit, secret, and interrupt mode.
It needs `sancus-core-gap` at `../../sancus-core-gap` from `alvie/code`.

The suite has 38 tests in groups named after the attacks (`example`, `b1`, `b2`, …).
Run one group by its name:

```bash
dune exec test/attack.exe -- test --color=never b6
```

One group of four tests took about 3 minutes in a measured run.
Run the complete suite before you change anything that touches the simulator interface.

The files `derive.ml` and `genall.ml` in `test/` are not supported as general tests.
`derive.ml` has paths that belong to one machine.

## What continuous integration runs

The workflow `alvie-tests.yml` runs on every pull request and on every push to `main`.
It runs these steps:

1. `dune build`
2. `dune exec tt_features -- test --color=never`
3. `bash test/cli_diagnostics.sh`

The workflow `docs.yml` runs on pull requests that change `docs/`, `site/`, or the Dockerfile.
It copies `docs/` into the site, builds the site, and checks every internal link.
It also checks that the published Docker image has Graphviz, the Sancus checkout, and a working `dune build`.

Continuous integration does not run `tt_attack`.
Run it yourself when your change needs it.

## What to run after a change

| You changed | Run |
| --- | --- |
| The TestDL parser, the specification types, or code generation | `tt_features` |
| Input generation or the observation tree | `tt_features` |
| A command-line option or an error message | `cli_diagnostics.sh` and `diagnostics.exe` |
| The simulator interface, the VCD analysis, or the output payload | `tt_attack`, and a learning run of the example |
| The model comparison (`cexfinder.ml`, `fa.exe`) | The known-answer check below |
| A specification in `spec-lib/` | A short learning run and a comparison |
| A page in `docs/` | The documentation check below |

## Known-answer check for the comparison

The repository contains learned models and the violation counts that they give.
The counts are in the [Attack Catalogue](/alvie/reference/attack-catalogue/).
A change to the comparison code must keep them unless the change is on purpose.

Run `fa.exe` with `--debug` on the checked-in models of one attack.
For example, for B6 on the original commit, the count must be 15.
The command is in [Reading and Checking a Witness](/alvie/guides/interpreting-results/#8-run-a-known-answer-check).

If a count changes, find out why before you accept it.
A changed count can show a bug, or it can show a real improvement.
In both cases, write the reason in the commit message.

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
