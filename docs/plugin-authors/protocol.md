---
title: External Plugin Protocol
description: The protocol between ALVIE/Core and the backend of an external plugin (version 1), its messages, errors, process management, and the Python SDK.
sidebar:
  order: 10
  badge:
    text: Preview
    variant: note
isNew: true
---

The backend of an **external** plugin is a program, in any language, that speaks this protocol with ALVIE/Core.
Its manifest says how to start it (`kind: external`, `command: [python3, backend.py]`), and its other files are those of any plugin (see the [Plugin Files Reference](/alvie/reference/plugin-files/)).
`alvie external DIR ...` runs the commands of Core on the plugin in `DIR`.
The [Plugin Author Guide](/alvie/guides/plugin-author-guide/) shows how to make one with the Python SDK.

## Transport

- Core starts the command of the manifest from the plugin's directory (a program given with a directory, such as `./backend`, is relative to it; a bare name is looked up in `PATH`).
- Messages are [JSON-RPC 2.0](https://www.jsonrpc.org/specification), one per line: Core writes its requests on the plugin's standard input, and the plugin writes its answers on its standard output.
- Core sends one request at a time and waits for its answer. The plugin never sends requests or notifications.
- **Standard output carries only the protocol.** The plugin's standard error is its log: Core writes it to a file and shows its last lines when the plugin fails.

## Methods

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `protocol` (1), `core` (`"1"`), `plugin` (its name), `config` (the values of the parameters of the manifest, as strings), `variant` (a name or `null`) | `protocol`, `name`, `version`, `capabilities` |
| `pre` | `instance` | `{}` |
| `step` | `instance`, `section`, `position`, `atom`, `programs` | `observations`, `bookkeeping` |
| `restore` | the params of `step`, and `observations` and `bookkeeping` | `{}` |
| `clone` | `instance` | `instance` (the new one) |
| `post` | `instance` | `{}` |
| `shutdown` | `{}` | `{}`, then the plugin exits |

These are the operations of the backend contract (see [Code Architecture](/alvie/reference/code-architecture/#the-backend-contract)):

- `initialize` is the handshake. It makes instance 0 for the configuration and the variant. Core checks that the plugin speaks version 1, and that its name, version and capabilities are those of the manifest.
- `pre` starts a test, and `post` ends it.
- `step` runs one input. `section` and `position` say where it is (its position in the section's current run, from 0), `atom` is the input, and `programs` gives the program of each section (an object from each section to its list of atoms). The answer gives the observations of the step, values of `observations.yaml`, and the *bookkeeping*: any JSON value that the backend needs to continue the test. Core keeps it and gives it back, but never compares it.
- `restore` is a dry step: Core already knows the observations of the step, from an earlier test with the same beginning, and gives them back with the bookkeeping of then. The plugin updates its state as if the step ran.
- `clone` makes an independent copy of an instance, in the same process.

Values are in the JSON form of Core:

- integers, booleans, strings (symbols) and lists are themselves;
- a node (a variant or a record) is an object with one member, its tag, whose value is the object of its fields, in the order of their declaration: `mov r0, 1` is `{"mov": {"r": {"reg": {"i": 0}}, "v": {"lit": {"num": 1}}}}`, and the observation `Exit(time = 3)` is `{"Exit": {"time": 3}}`.

`alvie plugin schemas OUT` writes `protocol.schema.json`, the JSON Schema of the protocol, and the schemas of the values of the plugin's atoms and observations.

A request and its answer, for a step of Tiny:

```json
{"jsonrpc":"2.0","id":5,"method":"step","params":{"instance":0,"section":"enclave","position":1,"atom":{"bz":{"r":{"reg":{"i":0}}}},"programs":{"prepare":[{"timer":{"cycles":2}},{"call":{}}],"enclave":[{"mov":{"r":{"reg":{"i":0}},"v":{"lit":{"num":0}}}},{"bz":{"r":{"reg":{"i":0}}}}],"isr":[],"cleanup":[]}}}
{"jsonrpc":"2.0","id":5,"result":{"observations":[{"Irq":{"latency":1}}],"bookkeeping":null}}
```

## Errors

A plugin that cannot answer a request answers with a JSON-RPC error: `{"jsonrpc": "2.0", "id": 5, "error": {"code": 1, "message": "...", "data": "..."}}`.
Core shows the message to the user, and logs `data` (for example a traceback).
The SDK answers code 1 for a `PluginError`, -32000 for any other exception, and -32601 for an unknown method.

Core stops a command with an `ALVIE backend error` (exit status 1) and the end of the plugin's log when the plugin:

| The plugin | The message |
| --- | --- |
| answers with an error | `plugin NAME failed in step: <its message>` |
| exits | `plugin NAME stopped during step (it exited with status 3)` |
| does not answer in time | `plugin NAME did not answer step within 60s (ALVIE_RPC_TIMEOUT), and was stopped` |
| writes something that is not JSON | `plugin NAME answered step with a line that is not JSON: ...`, with a hint to write logs on standard error |
| does not match its manifest | for example `the program of plugin NAME is version X, but its manifest is version Y` |
| cannot be started | `cannot start plugin NAME with <command> (from DIR): <why>` |

## Processes and environment

Each backend that a command makes is one process, whose clones are instances in it.
At exit, Core sends `shutdown` to each plugin and kills those that are still running after a second.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALVIE_RPC_TIMEOUT` | 60 | Seconds to wait for each answer. |
| `ALVIE_RPC_LOG_DIR` | the temporary directory | Where the plugins' logs go: `alvie-NAME-<pid>-<n>.log`. |
| `ALVIE_RPC_RECORD` | | Record every request and answer of the run in this file (JSON lines). |
| `ALVIE_RPC_REPLAY` | | Answer from such a recording without starting the plugin; the run fails at the first request that differs. |

A recording reproduces a run exactly, without the plugin's runtime: to report a problem, or to test a change of Core.

## Cost

Each call is a round trip between two processes: about 0.1 ms with the Python SDK, against nearly nothing for a native backend.
Learning a model of Tiny's `leak-interrupt.spec` makes about 19,000 calls (most are `restore`, `pre` and `post`): 1.9 s with Tiny in Python, 0.1 s with native Tiny, for the same model.
For a backend whose steps take milliseconds, such as a simulator of a processor (a step of Sancus takes about 35 ms), the protocol costs nothing that matters.

## The Python SDK

`sdk/python/alvie_plugin.py` is one module, with the standard library only (Python 3.8 or later):

| Name | Is |
| --- | --- |
| `Backend` | The class to extend: `__init__(config, variant)`, `pre()`, `step(step)` (returns the observations, or `(observations, bookkeeping)`), `restore(step, observations, bookkeeping)` (by default, the step runs again), `clone()` (by default, a deep copy), `post()`, and `capabilities` |
| `Step` | `section`, `position`, `atom`, `programs` |
| `serve(name, version, make)` | Answers the requests of Core until `shutdown` |
| `PluginError` | An error that Core shows as it is |
| `node`, `tag`, `fields`, `get` | Make and read values: `get(atom, "r", "i")` |
| `log` | Writes to standard error |

`alvie plugin types DIR OUT.py` writes a function for each kind of observation of the plugin (and each record type), which checks its fields: `Exit(time=3)`, `Irq(latency=1)`.
`plugins/tiny-py` is Tiny written with the SDK; it learns the same models as Tiny.
