---
title: ALVIE in Your Browser
description: ALVIE in a web page, with nothing to install - tutorials to run step by step, and VS Code with the files, terminals and models of ALVIE.
sidebar:
  order: 0
isNew: true
---

ALVIE runs in your browser: ALVIE/Sancus (on the simulators of the 8 commits of the experiments), ALVIE/VaultLink (on
its services in memory) and Tiny.
Nothing is installed, and your files and models stay in your browser: ALVIE and the simulators are WebAssembly, and
they run in the page.
It needs a browser with WebAssembly GC; it is tested in Chromium and Firefox. Chromium is the fastest: there, ALVIE
learns as fast as the native ALVIE; Firefox takes about three times as long.

Open it at [/alvie/play/](/alvie/play/). The first page lists the tutorials and an empty session; both open VS Code
for the Web.

## The tutorials

A tutorial is a notebook: text, and cells of commands of ALVIE. Run a cell with the ▷ on its left (or Ctrl+Enter), or
all of them with *Run All*; its output shows below it, and `view` draws models in the cell.

| Tutorial | What it shows | Time |
| --- | --- | --- |
| Getting started | Learn two models of a Sancus enclave, compare them, read the witness; the scripts of the guides | less than a minute |
| Tiny | A timing leak, a leak that only interrupts reveal, and a mitigation, on a small processor | seconds |
| Reproduce an attack on Sancus | The twelve models of B6 (`learn_one`, `check_one`), the witness, and a check that they are the models of the paper | a few minutes |

The first time you open a tutorial, VS Code asks whether you trust the authors of the notebook: the tutorials come
with the site, and their cells run only commands of ALVIE.
Everything is computed in your browser as the cells run: the tutorials learn every model they show.
A cell stops at the first command that fails; `alvie tiny compare` and `alvie vaultlink compare` "fail" when they find a
difference, as the tutorials say.
A tutorial is a file of the session (`tutorials/`): you can change it, add cells, or write your own (`.alvienb`).

## The empty session

VS Code with the files of ALVIE:

| Part | What it does |
| --- | --- |
| Explorer | The files are the folder `alvie:/`, kept in your browser: `spec-lib/` (the specifications of the experiments and of VaultLink), `results/` (the models of the paper, learned by the native ALVIE), `tutorials/`, `models/`. New files, folders, renames and uploads (drag them in) are files of ALVIE; a model that a command learns appears at once. To save a file on your computer, right-click it and choose *Download*. |
| Editor | The languages of the specifications (TestDL for `.atdl`, `.etdl`, `.spec`; VTDL for `.vtdl`) and of models (`.dot`). |
| Problems | The mistakes that ALVIE's own parsers find in the open specifications, as you type. |
| Terminal | An ALVIE terminal (`+` in the panel opens another; terminals run their commands in parallel). Type `help`. |
| Preview | *Preview Model* (on a `.dot`, in the title bar of the editor or in the Explorer) draws a model; *Preview Model Next to Another* draws two. |

*ALVIE: Reset the Files to Those of a First Visit* (in the Command Palette, Ctrl+Shift+P) brings back the files of a
first visit.
When the site gets new tutorials or new versions of them, a session gets them at the next visit, unless you changed
your copy.

## The commands

The commands are those of ALVIE, as in the [Executables Reference](/alvie/reference/executables-reference/); `alvie`
may be left out.

```text
alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 0 --commit bf89c0b --res models/ex-0.dot
alvie vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot
alvie vaultlink compare models/reference.dot models/firmware.dot
view models/reference.dot models/firmware.dot --inputs HELLO,ID_ME,PASS_OK,AUDIT,AUDIT
```

For ALVIE/Sancus, `--sancus` and `--tmpdir` are not needed: the simulators come with the site (the commits `ef753b6`,
`e8cf011`, `3170d5d`, `6475709`, `3636536`, `d54f031`, `264f135` and `bf89c0b`, built with the key `cafe`).
Formulas (`alvie property formula`) are not available: they need mCRL2.

`view A [B] --inputs ...` draws one or two models and follows the inputs on them from their initial states: the
transitions taken are blue, and a state where an input has no transition is red. It is the way to look at a sequence
that `compare` printed.

The programs and the scripts of the guides work as they are written there, from the root of the files:

```text
_build/default/bin/learn.exe --report --att-spec spec-lib/b3.atdl --encl-spec spec-lib/enclave-complete.etdl --res results/b3/m.dot --commit 6475709 --secret 0 --epsilon 0.01 --delta 0.01 --oracle pac
./learn_one.sh 6475709 b3 mine
./check_one.sh b3 mine
```

`learn.exe` is `alvie learn`, `fa.exe` is `alvie compare` and `exec.exe` is `alvie exec`; the path before them and
`--sancus` may be left out. The scripts `learn_example`, `learn_one`, `learn_one_nospecial`, `learn_all`,
`check_example`, `check_one` and `check_all` give the same commands as the scripts of the repository, with the same
models (`results/<subdir>/`), counterexamples (`counterexamples/<subdir>/`) and logs (`logs/<subdir>/`). A model that is
there is not learned again ("Done before"). The commands of a script run in parallel, up to four at once (half of the
cores of the computer): `learn_one` learns its twelve models in a few minutes; `learn_all` learns 96, which takes much
longer (`spec-lib/fast` has smaller specifications of the same attacks: `learn_all fast`).

`Ctrl-C` (in a terminal) or ■ (in a cell) stops a command. Each command runs in its own Web Worker, so the page stays
responsive.

## What needs the native ALVIE

ALVIE in the browser learns the same models as the native ALVIE, but some parts need a computer:

- formulas (`alvie property formula`), which need mCRL2, and `pbt.exe`;
- Sancus at other commits, or with another key, than the eight simulators that come with the site, and the FPGA board
  ([Sancus on the FPGA](/alvie/sancus/fpga/));
- ALVIE/VaultLink over TCP (`--target`, `serve`): a page cannot open connections;
- long experiments: a script runs at most four commands at once, and the page must stay open.

The [Executables Reference](/alvie/reference/executables-reference/#in-the-browser) lists what runs where, and
[Getting Started](/alvie/getting-started/) installs ALVIE on a computer.
