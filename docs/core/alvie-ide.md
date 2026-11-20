---
title: The ALVIE IDE
description: ALVIE in the browser, with nothing to install - files, an editor, a terminal for the commands of ALVIE, and a viewer of models.
sidebar:
  order: 0
isNew: true
---

The ALVIE IDE runs ALVIE in your browser: ALVIE/Sancus (on the simulators of the 8 commits of the experiments),
ALVIE/VaultLink (on its services in memory) and Tiny.
Nothing is installed, and your files and models stay in your browser: ALVIE and the simulators are WebAssembly, and
they run in the page.
It needs a browser with WebAssembly GC; it is tested in Chromium 157 and Firefox 160. Chromium is the fastest: there,
ALVIE learns as fast as the native ALVIE; Firefox takes about three times as long.

## The page

| Panel | What it does |
| --- | --- |
| Files (left) | The files of the IDE: `spec-lib/` (the specs of the experiments and of VaultLink), `results/example/` and `models/`. Click a file to edit it, double-click a model (`.dot`) to draw it. `+` makes a file, `↑` uploads files from your computer (into `uploads/`), `↓` downloads the selected file. |
| Editor (centre) | The open file, saved as you type. Specs (`.atdl`, `.etdl`, `.vtdl`) are checked by ALVIE's own parsers as you type: a mistake is underlined, and its message is shown when you point at it. |
| Terminal (bottom) | The commands of ALVIE, and commands on the files (type `help`). |
| Viewer (right) | One or two models, drawn. Drag to move, use the wheel to zoom, double-click to fit. |

The files stay in your browser (in its storage for this site) when you close the page.
`reset-files` brings back the files of a first visit; `download FILE` saves a file to your computer.

## Learn and compare

The commands are those of ALVIE, as in the [Executables Reference](/alvie/reference/executables-reference/); `alvie`
may be left out.

```text
alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 0 --commit bf89c0b --res models/ex-0.dot
alvie sancus learn --spec spec-lib/example/attacker.atdl --spec spec-lib/example/enclave.etdl --secret 1 --commit bf89c0b --res models/ex-1.dot
alvie sancus compare -help
alvie sancus fixtures
```

For ALVIE/Sancus, `--sancus` and `--tmpdir` are not needed: the simulators come with the IDE (the commits `ef753b6`,
`e8cf011`, `3170d5d`, `6475709`, `3636536`, `d54f031`, `264f135` and `bf89c0b`, built with the key `cafe`).
Formulas (`alvie property formula`) are not available: they need mCRL2.

```text
alvie vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service reference --res models/reference.dot
alvie vaultlink learn --spec spec-lib/vaultlink/vault.vtdl --service firmware --res models/firmware.dot
alvie vaultlink compare models/reference.dot models/firmware.dot
view models/reference.dot models/firmware.dot --inputs HELLO,ID_ME,PASS_OK,AUDIT,AUDIT
```

`view A [B] --inputs ...` draws one or two models and follows the inputs on them from their initial states: the
transitions taken are blue, and a state where an input has no transition is red. It is the way to look at a
sequence that `compare` printed. The [ALVIE/VaultLink Reference](/alvie/vaultlink/vaultlink-reference/) describes
the services in memory.

`Ctrl-C` stops a command. Each command runs in its own Web Worker, so the page stays responsive.
