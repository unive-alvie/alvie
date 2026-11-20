---
title: ALVIE in the Browser
description: How ALVIE and ALVIE/Sancus run in WebAssembly, in Node and in a browser, how to build them, and how they are checked against the native ALVIE.
sidebar:
  order: 4
  badge:
    text: A
    variant: caution
isNew: true
---

ALVIE can run without installing anything: its OCaml code compiles to WebAssembly with `wasm_of_ocaml`, and the
testbench of ALVIE/Sancus compiles to WebAssembly with Verilator and Emscripten.
The result, `alvie-web`, runs the commands of ALVIE/Core for Tiny and for ALVIE/Sancus, and `alvie vaultlink` on the
services in memory, and learns the same models as the native ALVIE.
It runs in Node and in a Web Worker of a browser (Chromium and Firefox); the IDE that will run it in a page is the next step.

## What runs where

| Part | Native ALVIE | `alvie-web` |
| --- | --- | --- |
| L#, the oracles, the plugin files, the input generator, the comparison, the commands of Core | `alvie-core` | the same libraries, compiled by `wasm_of_ocaml` |
| The step of ALVIE/Sancus (programs, assembler, analysis of the trace) | `sancus_core` | the same library |
| The simulator | `simv`, compiled by Verilator, started for each step | the testbench compiled by Verilator and Emscripten, loaded once and called for each step |
| Programs of a step | `Msp430_asm` (the toolchain prepares the first build) | `Msp430_asm`; the files of the first build come with the simulator, made without the toolchain |
| Plugin files (YAML) | libyaml | `alvie-core.yaml-table`: the YAML files of `plugins/`, read when ALVIE is built |
| Witnesses | `Ltscompare.Weak_trace` | the same |
| Formulas (`alvie property formula`) | mCRL2 | not available |

The [code architecture](/alvie/development/code-architecture/) describes the portable part of ALVIE/Core and
`sancus_core`; `test/portable` checks that they need no C code and run no program.

## The files

Everything is in `alvie/code/web`:

| File | What it is |
| --- | --- |
| `alvie_web.ml` | `alvie-web`: `alvie-web tiny ...` and `alvie-web sancus ...`, the commands of Core (for Sancus with its codec, as `learn.exe`) |
| `command_web.ml` | `Command_unix` without Unix: runs a command of Core from an argv given by the host |
| `host.jsoo.ml` | The host of `alvie-web` in JavaScript: the simulators (`Sancus_core.Wasm_target.host`, from `globalThis.alvieSancus`), the argv and the files of the page (`host.none.ml` without `js_of_ocaml`) |
| `node/alvie-web.cjs` | That host in Node, and the runner of `alvie-web` |
| `build.sh` | Compiles `alvie-web` to WebAssembly |
| `runtime/` | The WebAssembly runtime of Jane Street's libraries, which their releases do not have yet (see its README) |
| `sim/build-sim.sh` | The simulator of a commit of `sancus-core-gap` in WebAssembly, and the files of its programs |
| `sim/harness.cpp`, `sim/pre.js`, `sim/post.js` | The harness of the simulator: `run(mem)` gives the status of `scripts/simulate` and the VCD trace |
| `validate/validate.sh` | Learns models with `alvie-web` and compares them with the native ones |
| `browser/node-shim.js` | The Node that the runtime of `wasm_of_ocaml` needs in a browser: an in-memory file system, `process` and the modules it asks for |
| `browser/worker.js` | `alvie-web` in a Web Worker, with the simulator of a commit and the files the page gives |
| `browser/smoke.html`, `browser/smoke.py` | Learn a model in headless Chromium or Firefox and check it |

## Build and run

The OCaml side needs an OCaml 5 switch with the dependencies of ALVIE, `wasm_of_ocaml-compiler`, `js_of_ocaml` and
`js_of_ocaml-ppx`, and Binaryen 119 or later (`wasm-opt`) on the `PATH`.
The simulators need Verilator 5.002 (the version of ALVIE's Docker image; the runtime of 5.020 does not compile with the
libc++ of Emscripten) and Emscripten (`emcc` on the `PATH`); `build-sim.sh` makes the files of the programs
of a commit (`pmem.sh`, `pmem.x`, `pmem_defs.asm`) as the setup of `scripts/build_pmem` does, with the C preprocessor of
the host instead of the MSP430 toolchain.

```bash
cd alvie/code
bash web/build.sh /tmp/alvie-web
for c in bf89c0b ef753b6; do bash web/sim/build-sim.sh ../../sancus-core-gap $c /tmp/alvie-web/sim; done
node /tmp/alvie-web/alvie-web-node.cjs tiny fixtures
node /tmp/alvie-web/alvie-web-node.cjs sancus learn --spec ../../spec-lib/a.atdl --spec ../../spec-lib/enclave-complete.etdl \
  --secret 0 --commit bf89c0b --sancus none --tmpdir /tmp/alvie-web-tmp --res a.dot
```

`--sancus` is required by the manifest of ALVIE/Sancus but not used: the simulators are in `ALVIE_WEB_SIM` (by default
`sim/` next to the runner). The simulators are built with the key `cafe`, as ALVIE's experiments.

### In a browser

A page runs `alvie-web` in a Web Worker (`browser/worker.js`): it posts the argv, the files to write and the files to read
back, and gets the output and those files.
The runtime of `wasm_of_ocaml` reaches files through Node only; `browser/node-shim.js` gives it an in-memory file system
with the calls of `node:fs` it uses, which the page reads and writes too.
The worker makes the simulator before it installs the shim, since Emscripten chooses its environment when it makes the
module.

```bash
python3 web/browser/smoke.py /tmp/alvie-web /tmp/alvie-web/sim ../../spec-lib/example
ALVIE_SMOKE_BROWSER=firefox python3 web/browser/smoke.py /tmp/alvie-web /tmp/alvie-web/sim ../../spec-lib out.json \
  'att=a.atdl&encl=enclave-complete.etdl&commit=bf89c0b'
```

`alvie-web` takes from the page, as JavaScript globals: `alvieArgv` (the command), `alvieFiles` (files to write),
`alvieCollect` (files to read back) and `alvieDone` (called when the command ends); `alvieSancus` is the host of the
simulators.

The `web` job of CI builds `alvie-web` and the simulators of `bf89c0b` and `ef753b6`, and runs the fixtures of Tiny and
of ALVIE/Sancus with it.

## How it compares with the native ALVIE

Learning is deterministic for a seed, and `alvie-web` makes the same random choices as the native ALVIE
(`Learninglib.Rng`), so it learns the same models, byte for byte.

| Check | Result |
| --- | --- |
| The checked-in models (`results/`), learned by `alvie-web` in Node | all 98 identical |
| The 320 learnings of the benchmark (8 commits, 10 specs, 2 secrets, with and without interrupts), by `learn.exe` and by `alvie-web` | all 320 identical |
| The fixtures of Tiny and of ALVIE/Sancus | the same verdicts and witness counts |
| The Getting Started example and full-A on `bf89c0b`, learned in Chromium 157 and Firefox 160 | identical |

Speed, on full-A on `bf89c0b` (605 steps on the simulator, 3561 queries), on the same machine with nothing else running:

| | Time of the learning |
| --- | --- |
| Native (the compiled simulator in its cache) | 10.6 s |
| `alvie-web` in Node 22 | 11.8 s |
| `alvie-web` in a Web Worker of Chromium 157 | 9.1 s |
| `alvie-web` in a Web Worker of Firefox 160 | 28.4 s |

The native ALVIE starts a simulator for each step; `alvie-web` calls the module it loaded once, which is why it can
be faster.

Firefox runs the OCaml code compiled by `wasm_of_ocaml` (WebAssembly GC) more slowly than Chromium: with
`ALVIE_PROFILE=1`, reading the VCD trace of a step takes 225 ms in Firefox and 10 ms in Chromium, the simulator (C++,
Emscripten) 55 ms and 16 ms. A build with `js_of_ocaml` for Firefox could close the gap.
The simulator alone, in one process, runs a step in 7.8 ms natively and 9.2 ms in WebAssembly (1.19 times as long).
The WebAssembly module of `alvie-web` is 1.3 MB; a simulator is about 320 KB.

## Why some things are as they are

- **OCaml 5 and `Rng`.** `wasm_of_ocaml` needs OCaml 5 (or 4.14). OCaml 5 changed the generator of `Random`, so the same
  seed gave other tests and other models; `Learninglib.Rng` is the generator of OCaml 4.13, so every compiler and
  target learns the models of `results/`.
- **The hash of Base.** `wasm_of_ocaml` has 31-bit integers, and Base hashes with them; the models do not depend on
  the order of hash tables, and are the same.
- **Verilator 5.002** includes `<experimental/coroutine>`, which the libc++ of Emscripten does not have;
  `build-sim.sh` uses `<coroutine>` in a copy of Verilator's runtime.
- **One `VerilatedContext` for each run**: `$finish` ends the run of its context only, so the module runs many steps.
