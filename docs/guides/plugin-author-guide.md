---
title: Plugin Author Guide
description: Make an ALVIE plugin for a new platform with alvie plugin new, check its files, its backend (conformance) and its verdicts (fixtures).
sidebar:
  order: 9
  badge:
    text: Preview
    variant: note
isNew: true
---

A plugin connects ALVIE/Core to a platform: its files declare what tests are made of and what the attacker sees, and its backend runs the tests.
Core does the rest: it generates the inputs that a spec allows, learns models, and compares them.
This guide takes you from nothing to a plugin that learns, checks and finds a leak.
Read the [Tiny tutorial](/alvie/guides/tiny-tutorial/) first: it uses a finished plugin.

This release supports **native** plugins, whose backend is OCaml, linked with Core.
External plugins (a program in any language that speaks a protocol with Core) come in a later release; the manifest already has their fields.

## 1. Make a plugin from the template

From `alvie/code`:

```bash
_build/default/bin/alvie.exe plugin new my-chip
dune build
```

This writes two directories:

```
plugins/my-chip/              the plugin files (see the Plugin Files Reference)
  alvie-plugin.yaml  sections.yaml  atoms.yaml  observations.yaml  phases.yaml  view.yaml
  fixtures/                   leak.spec, leak.yaml, safe.spec, safe.yaml
lib/plugins/my-chip/
  alvie_my_chip.ml            the backend
  main.ml                     alvie-my-chip: the commands of Core on the plugin
  dune
```

The template works from the start: a victim whose instruction `wait n` takes `n` cycles, so `wait ?` leaks the secret through the time the victim takes.
Check it:

```bash
_build/default/bin/alvie.exe plugin check plugins/my-chip
_build/default/lib/plugins/my-chip/main.exe conformance --spec plugins/my-chip/fixtures/leak.spec --secret 0
_build/default/lib/plugins/my-chip/main.exe fixtures
```

`main.exe` (installed as `alvie-my-chip`) has the commands of `alvie tiny`: `learn`, `compare`, `property`, `exec`, `conformance` and `fixtures`.
Then change the template into your platform, one step at a time, and check again after each.

## 2. Describe the platform

The [Plugin Files Reference](/alvie/reference/plugin-files/) documents each file; Tiny (`plugins/tiny`) and Sancus (`plugins/sancus`) are examples.
In the order that usually works:

1. **`sections.yaml`**: the parts of a test, who writes them (attacker or victim) and which atoms each runs. Most platforms have the attacker before and after the victim (`prepare` and `cleanup`), and an interrupt handler if the attacker can interrupt it.
2. **`atoms.yaml`**: the instructions or actions of each section, with their syntax, as a spec writes them. Mark the variant that is the secret.
3. **`observations.yaml`**: what the backend reports after each input. Report what an attacker could measure, and anything Core needs to follow the test (for example that the victim was entered).
4. **`phases.yaml`**: how each observation moves the test between sections.
5. **`view.yaml`**: what the attacker sees of each observation. Hide what only the platform knows.
6. **`alvie-plugin.yaml`**: the configuration of the backend (each parameter becomes an option, `--name`), the variants (such as a baseline without interrupts) and the capabilities.

`alvie plugin check plugins/my-chip` reports every problem with its file, line and column; editors with JSON Schema support complete the fields as you type.

## 3. Write the backend

The backend implements `Alvie_backend.Backend.S` (`lib/core/backend/backend.ml`), the contract between Core and a platform:

| Function | Does |
| --- | --- |
| `pre` | Starts a test from the initial state of the platform. |
| `step` | Runs one input and returns its observations (values of `observations.yaml`) and its bookkeeping. |
| `restore` | A dry step: Core already knows the observations; update the state as if the step ran. |
| `clone` | An independent copy, for learning in parallel. |
| `post` | Ends a test. |

For each step, Core gives the input's section, its position in the section's run, its atom, and the programs of all the sections (the code each runs in this test): a backend that compiles code, as Sancus does, generates it from them.
*Bookkeeping* is what the backend needs to continue a test that Core should not compare (Sancus: the code still to analyse); Core stores it and gives it back to `restore`.
The template and Tiny have none.

A native plugin is the module `Native` of the backend (`Alvie_backend.Native.S`): the plugin files, embedded in the program by the rule in `dune`, the backend, and `make`, which builds a backend from the values of the configuration parameters and the variant.

## 4. Check the backend: conformance

`conformance` runs random legal tests of a spec and checks that the backend keeps the contract:

```bash
_build/default/lib/plugins/my-chip/main.exe conformance --spec plugins/my-chip/fixtures/leak.spec --secret 0
```

```text
Conformance of plugin my-chip 0.1: 50 random tests, 224 steps (0.00 ms a step), seed 0
PASS observations  every step returns observations of observations.yaml, each matched by a phase rule (224 checks)
PASS phases        the backend's observations never make a legal test invalid (224 checks)
PASS determinism   the same inputs on a new backend observe the same (50 checks)
PASS reset         after pre, a backend that ran other tests observes as a new one (100 checks)
PASS prefixes      a test that begins as an earlier one observes the same on that beginning, whatever it does next (50 checks)
PASS restore       restoring steps (dry steps) and then stepping observes as stepping all along (50 checks)
PASS clone         a clone continues as the original would, and does not change it (50 checks)
```

| Check | A failure usually means |
| --- | --- |
| `observations` | The backend returns a kind or a field that `observations.yaml` does not declare, or a kind that no phase rule matches (add one with `do: []` if it changes nothing). |
| `phases` | The backend rejects an input that the spec allows: the phase rules do not follow the platform, or the backend does not support an atom. |
| `determinism` | The backend depends on something other than the inputs: time, randomness, files of an earlier run. Learning needs a deterministic system. |
| `reset` | `pre` does not reset everything, or a cache of the backend is keyed by less than it depends on. |
| `prefixes` | The same as `reset`, from another angle: state kept between tests. |
| `restore` | `restore` does not leave the state that `step` would. |
| `clone` | `clone` shares state with the original. |

`restore` and `clone` are checked only if the manifest declares the capability.
A failure prints the first test that shows it; replay it with `exec`.
Use `--tests`, `--length` and `--seed` for more or other tests, and run `conformance` on several specs: it only explores what a spec allows.

## 5. Check the verdicts: fixtures

A backend can keep the contract and still model the platform wrongly.
Fixtures pin down what the plugin must find: write a spec for a leak you know of, one that is safe, and the known attacks on your platform, each with its verdict (see [Fixtures](/alvie/reference/plugin-files/#fixtures)).

```bash
_build/default/lib/plugins/my-chip/main.exe fixtures
```

```text
PASS leak                     a leak (1 witness)
PASS safe                     no leak
2 fixtures, 0 failed (models and witnesses in /tmp/alvie/fixtures)
```

A failing fixture keeps its models and witness graph in `--out`.

## 6. Use the plugin

The commands of `alvie-my-chip` are those of the [Tiny tutorial](/alvie/guides/tiny-tutorial/): learn models of your specs, compare them, and read the witnesses.
To add the plugin to `alvie` itself, as `alvie my-chip ...`, add a line to `bin/alvie.ml` and the library to `bin/dune`, as for `tiny`.

## Limits of this release

- Plugins are native; the external protocol and its Python SDK come later.
- The comparison lists, for each counterexample, every path of each model that matches it. A spec whose attacker loops (`(timer 1 | nop)*` before the call) has many, and comparing can take very long: let the attacker choose once, as the fixtures of Tiny do.
- Errors of the command line itself (an unknown option, a value of the wrong type) are reported by the parser with exit status 1; the other mistakes in a command or its files exit with 2.
