# ALVIE/VaultLink

ALVIE is an open-source security-analysis framework that learns finite-state models of a system's observable behavior and compares them for information-flow differences.
It combines active automata learning with model checking to produce witness traces when selected behaviors are distinguishable.

**This branch is ALVIE/VaultLink**, a training variant of ALVIE.
It replaces the Sancus/openMSP430 backend with a socket-based one: it learns a Mealy machine of a line-based TCP service instead of an enclave-protected processor.
It is not merged into `main`; the Sancus backend and its documentation live there instead.

This repository contains only the learning and comparison tools.
It does not contain any training exercise, service, or challenge content.

## Quick Start

Build the tool image:

```bash
docker build -t alvie-vaultlink .
docker run --rm -it --network host -v "$PWD/work:/work" alvie-vaultlink
```

Or build from source:

```bash
cd alvie/code
dune build
```

Then see [`docs/vaultlink.md`](docs/vaultlink.md) for the specification language and the three tools (`vl_learn`, `vl_compare`, `vl_replay`).

## What ALVIE/VaultLink Produces

- Learned Mealy-machine models in Graphviz `.dot` format, with inputs and outputs from a specification you write.
- Shortest distinguishing input sequences between two learned models, printed by `vl_compare`.
- A model carries an explicit guarantee when learned with the default W-method oracle: it is exact for any service with at most `--extra-states` more states than it.

A distinguishing sequence is evidence that two models disagree, for the inputs and observables your specification defines.
It is not an automatically generated exploit or remediation.

## Repository Layout

- `alvie/code/lib/lsharp/`: the generic L# learner, oracles, and observation tree. Backend-independent.
- `alvie/code/lib/vaultlink/`: the `.vtdl` specification language, the socket-based system-under-learning, and model comparison.
- `alvie/code/bin/`: `vl_learn`, `vl_compare`, `vl_replay`.
- `alvie/code/test/`: `vaultlink/` and `wmethod/`, both runnable without network access or external services.
- `docs/vaultlink.md`: the `.vtdl` language and tool reference.
- `design/vaultlink-language.md`: design rationale for the language and the tools.

## Learn More

- [`docs/vaultlink.md`](docs/vaultlink.md) documents the specification language, the three executables, and their exit statuses.
- [`design/vaultlink-language.md`](design/vaultlink-language.md) explains the design decisions behind the language and the comparison workflow.

## Research

ALVIE accompanies [Bridging the Gap: Automated Analysis of Sancus](https://ieeexplore.ieee.org/abstract/document/10664425) by Matteo Busi, Riccardo Focardi, and Flaminia Luccio.
This VaultLink variant reuses that project's L# learner outside the Sancus context it was built for.

## License And Acknowledgements

ALVIE is released under the [MIT License](LICENSE).
The project is supported by [CCAT – Cybersecurity Competence and Training](https://ccat.fi.muni.cz/), funded under Grant Agreement No. 101225878 and supported by the European Cybersecurity Competence Centre (ECCC).
