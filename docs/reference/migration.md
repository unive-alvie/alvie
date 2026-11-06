---
title: Migrating from 2026.10
description: What changes for users of ALVIE 2026.10 in the version in development (commands, files, results, the documentation) and what to do.
sidebar:
  order: 1
isNew: true
---

The version of ALVIE in development (the `main` branch, after 2026.10) makes ALVIE a framework: **ALVIE/Core**, which learns and compares models for any platform, and plugins, of which **ALVIE/Sancus** is one (see [How ALVIE Works](/alvie/core/concepts/#alvie-core-and-its-plugins)).
For an experiment on Sancus, little changes: the same specs, the same commands, the same model files.
This page lists what does change, and what to do.
The [CHANGELOG](https://github.com/unive-alvie/alvie/blob/main/CHANGELOG.md) has every detail.

## Commands

The executables of 2026.10 remain, with their options and their output, and are now also subcommands of one command, `alvie`:

| 2026.10 | Now |
| --- | --- |
| `_build/default/bin/learn.exe` | `_build/default/bin/alvie.exe learn` |
| `_build/default/bin/fa.exe` | `_build/default/bin/alvie.exe compare` |
| `_build/default/bin/exec.exe` | `_build/default/bin/alvie.exe exec` |
| `_build/default/bin/pbt.exe` | `_build/default/bin/alvie.exe pbt` |

**What to do:** nothing yet.
The former names stay for this release, for scripts and for alvie-ui, which runs `bin/learn.exe` and reads its output; use `alvie` in new scripts.

The options of the backend of `learn` (`--sancus`, `--commit`, `--sancus-master-key`, `--tmpdir`, `--keep-repeated-reentries`) are the same; they now come from the manifest of the plugin (`plugins/sancus/alvie-plugin.yaml`).

New commands, which 2026.10 did not have:

| Command | Does |
| --- | --- |
| `alvie property inclusion\|equivalence\|formula` | Other properties than noninterference on learned models |
| `alvie plugin check`, `schemas`, `new`, `types` | For plugin authors |
| `alvie sancus conformance`, `fixtures` | Check the Sancus backend and its known verdicts |
| `alvie tiny ...`, `alvie external DIR ...` | The commands of Core on Tiny, the reference platform, and on external plugins |
| `alvie-model-compare A.dot B.dot` | Whether two models are the same up to the numbering of their states |

The [Executables Reference](/alvie/reference/executables-reference/) documents them.

## Specs

The TestDL files of 2026.10 work unchanged: the same `.atdl` and `.etdl` files give the same tests.
Specs can now also have comments (`// ...`) and constraints between sections (see [Constraints](/alvie/sancus/testdl-specification-reference/#constraints)).

## Model files

Models now start with a line that says what made them:

```text
// alvie-model format 1; plugin sancus 2026.10; core 1
```

**What to do:** nothing.
Models of 2026.10, without this line, read as before; `fa.exe` and `alvie compare` take both.
A model of another plugin, or of a later format, is refused with a message.

## Results

Some witness counts and models change, because 2026.10 got them wrong.
Each change has its cause in the CHANGELOG, and the checked-in models, witness graphs and the [Attack Catalogue](/alvie/sancus/attack-catalogue/) are the new ones.

| What changes | Why |
| --- | --- |
| Most witness counts (for example B3 on `ef753b6`: 3619 in 2026.10) | The comparison looked for witnesses in one direction only, and counted some witnesses more than once. |
| B3 on `ef753b6`: 11 witnesses | The enclave re-entered by `reti` ran other code than it had run at that point, both in the input generator and in the simulator. |
| B1 on `ef753b6`: 31 witnesses | The simulated enclave code lost instructions after two or more interrupts; and mCRL2 now compares what the attacker sees, without the cycle count `k`. |
| 8 models; others only renumbered | The same causes. |
| The labels of witness graphs: `ubr/Time(k = 2, ...)`, `(hidden)` | Witness graphs show what the attacker sees of each output. |

**What to do:** compare your own results with the new ones, not with those of 2026.10.
To check that a change of yours leaves the checked-in results as they are, run `./regression.sh all` (see [Testing ALVIE](/alvie/development/testing-alvie/)).

## Building

- **New OCaml libraries:** `yaml` and `yojson`. Install the dependencies with `opam install . --deps-only --with-test` in `alvie/code`.
- **Python 3** runs the external plugins (`plugins/tiny-py`) and their tests; ALVIE/Sancus does not need it.
- **The Docker image** of the next release will have everything; until then, install the new libraries in `matteobusi/alvie:latest` (`opam install -y yaml yojson`), as CI does.
- The OCaml code is split into three opam packages: `alvie-core`, `alvie-rtl-util` and `alvie-sancus`. `dune build` builds them all, and the executables keep their paths.

## The documentation

The pages are now grouped by reader: ALVIE/Core, ALVIE/Sancus, Writing Plugins, Reference, and Developing ALVIE.
The addresses of the moved pages lead to their new ones, for example `/alvie/reference/attack-catalogue/` to [`/alvie/sancus/attack-catalogue/`](/alvie/sancus/attack-catalogue/).
The documentation of each release stays at its own address: `/alvie/2026.10/` for the previous one.

## For developers

- The comparison engine is generic: its hooks come from the plugin files (`Ltscompare.Plugin_hooks`), and `lib/sancus-compare` is gone.
- The input generator is that of Core (`lib/core/inputgen`), driven by the plugin files; `learn.exe --inputgen legacy` is gone, and the former generator remains only to compare with, in `tt_inputgen_golden check --engine legacy`.
- The simulator is a backend of the contract of Core (`Alvie_backend.Backend.S`).
- [Code Architecture](/alvie/development/code-architecture/) describes the modules, and the [Plugin Author Guide](/alvie/plugin-authors/plugin-author-guide/) how to add a platform.
