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
The result, `alvie-web`, runs the commands of ALVIE/Core for Tiny and for ALVIE/Sancus, and learns the same models as
the native ALVIE.
It runs in Node today; the web page that runs it in a browser is the next step.

## What runs where

| Part | Native ALVIE | `alvie-web` |
| --- | --- | --- |
| L#, the oracles, the plugin files, the input generator, the comparison, the commands of Core | `alvie-core` | the same libraries, compiled by `wasm_of_ocaml` |
| The step of ALVIE/Sancus (programs, assembler, analysis of the trace) | `sancus_core` | the same library |
| The simulator | `simv`, compiled by Verilator, started for each step | the testbench compiled by Verilator and Emscripten, loaded once and called for each step |
| Programs of a step | `Msp430_asm` (the toolchain prepares the first build) | `Msp430_asm`; the files of the first build come with the simulator |
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
| `sancus_host.ml` | The host of the simulators (`Sancus_core.Wasm_target.host`): the JavaScript object `globalThis.alvieSancus` |
| `node/alvie-web.cjs` | That host in Node, and the runner of `alvie-web` |
| `build.sh` | Compiles `alvie-web` to WebAssembly |
| `runtime/` | The WebAssembly runtime of Jane Street's libraries, which their releases do not have yet (see its README) |
| `sim/build-sim.sh` | The simulator of a commit of `sancus-core-gap` in WebAssembly, and the files of its programs |
| `sim/harness.cpp`, `sim/pre.js`, `sim/post.js` | The harness of the simulator: `run(mem)` gives the status of `scripts/simulate` and the VCD trace |
| `validate/validate.sh` | Learns models with `alvie-web` and compares them with the native ones |

## Build and run

The OCaml side needs an OCaml 5 switch with the dependencies of ALVIE, `wasm_of_ocaml-compiler`, `js_of_ocaml` and
`js_of_ocaml-ppx`, and Binaryen 119 or later (`wasm-opt`) on the `PATH`.
The simulators need Verilator 5, Emscripten (`emcc` on the `PATH`) and the MSP430 toolchain, which prepares the files
of the programs of a commit once.

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

The `web` job of CI builds `alvie-web` and the simulators of `bf89c0b` and `ef753b6`, and runs the fixtures of Tiny and
of ALVIE/Sancus with it.

## How it compares with the native ALVIE

Learning is deterministic for a seed, and `alvie-web` makes the same random choices as the native ALVIE
(`Learninglib.Rng`), so it learns the same models, byte for byte.

| Check | Result |
| --- | --- |
| The checked-in models (`results/`), learned by `alvie-web` | VALIDATION_RESULTS |
| The 320 learnings of the benchmark (8 commits, 10 specs, 2 secrets, with and without interrupts), by `learn.exe` and by `alvie-web` | VALIDATION_BENCH |
| The fixtures of Tiny and of ALVIE/Sancus | the same verdicts and witness counts |

Speed, on full-A on `bf89c0b` (605 steps on the simulator), in Node 22:

| | Native | `alvie-web` |
| --- | --- | --- |
| The whole learning | 13.2 s | 13.8 s |
| Simulation of a step | 12.6 ms (a process each) | 10.3 ms |
| Reading the VCD trace of a step | 3.6 ms | 7.6 ms |

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
