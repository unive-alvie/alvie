# ALVIE

ALVIE is an open-source security-analysis framework that learns finite-state models of a system's observable behavior and compares them for information-flow differences.
It combines active automata learning with model checking to produce witness traces when selected behaviors are distinguishable.
**ALVIE/Sancus** is the current backend and workflow for Sancus/openMSP430 systems.

[Homepage](https://unive-alvie.github.io/alvie/) · [Documentation](https://unive-alvie.github.io/alvie/guides/walkthrough-repro/) · [Getting Started](https://unive-alvie.github.io/alvie/getting-started/) · [Docker Hub](https://hub.docker.com/r/matteobusi/alvie) · [ALVIE UI](https://github.com/unive-alvie/alvie-ui) · [Paper](https://ieeexplore.ieee.org/abstract/document/10664425)

Documentation versions: [2026.09, extended documentation](https://unive-alvie.github.io/alvie/2026.09v2/) (current) · [development version](https://unive-alvie.github.io/alvie/dev/) (`main`, including unreleased changes) · [2026.09 as released](https://unive-alvie.github.io/alvie/2026.09/)

## Quick Start

The published Docker image is the quickest way to run ALVIE/Sancus:

```bash
docker pull matteobusi/alvie
docker run --rm -it matteobusi/alvie
```

Inside the container, start with the [Getting Started guide](https://unive-alvie.github.io/alvie/getting-started/).
It builds the project, runs the included example, renders a witness graph, and explains the resulting artifacts.

For a local development checkout, build the OCaml project with:

```bash
cd alvie/code
dune build
```

The complete native setup, Docker output mount, command-line interfaces, and simulation workflows are maintained in the [documentation](https://unive-alvie.github.io/alvie/guides/walkthrough-repro/).

## Graphical Interface

[alvie-ui](https://github.com/unive-alvie/alvie-ui) is an easy-to-use user interface for ALVIE.
It was developed at Ca’ Foscari University of Venice by Marco Ballarin and Giovanni Quacchia during their thesis work.

## What ALVIE Produces

- Learned Mealy-machine models in Graphviz `.dot` format.
- Witness graphs containing behaviors that distinguish the compared models.
- Logs and generated simulator artifacts for inspection and reproduction.

A witness is evidence of distinguishability under the selected specifications and learned models.
It is not an automatically generated remediation.

## Repository Layout

- `alvie/code/`: OCaml implementation and tests.
- `spec-lib/`: TestDL attacker and enclave specifications.
- `results/`: checked-in learned models.
- `counterexamples/`: checked-in witness graphs.
- `docs/`: canonical guides and technical references.

## Learn More

Start here:

- [Getting Started](https://unive-alvie.github.io/alvie/getting-started/) provides a first end-to-end exercise.
- [How ALVIE Works](https://unive-alvie.github.io/alvie/guides/concepts/) explains the experiment, the four models, and what a result means.
- [Reading and Checking a Witness](https://unive-alvie.github.io/alvie/guides/interpreting-results/) shows how to read and replay a result.
- [Troubleshooting](https://unive-alvie.github.io/alvie/reference/troubleshooting/) lists common problems and fixes.

Go further:

- [Reproducing the Simulation Experiments](https://unive-alvie.github.io/alvie/guides/walkthrough-repro/) documents the experiment wrappers and output layout.
- [Attack Catalogue](https://unive-alvie.github.io/alvie/reference/attack-catalogue/) lists the known Sancus attacks, their commits, and the expected results.
- [TestDL Tutorial: V-B1 Example](https://unive-alvie.github.io/alvie/guides/testdl-tutorial-vb1/) explains a published vulnerability and its witness.
- [Choosing Learner Settings](https://unive-alvie.github.io/alvie/guides/learning-settings/) explains the oracles and how to balance time and confidence.
- [Designing Your Own Specifications](https://unive-alvie.github.io/alvie/guides/writing-specifications/) shows how to plan and check a new experiment.
- [Executable Reference](https://unive-alvie.github.io/alvie/reference/executables-reference/) documents `learn.exe`, `fa.exe`, `exec.exe`, and `pbt.exe`.
- [Testing ALVIE](https://unive-alvie.github.io/alvie/guides/testing-alvie/) explains the test suites for contributors.

## Research

ALVIE accompanies [Bridging the Gap: Automated Analysis of Sancus](https://ieeexplore.ieee.org/abstract/document/10664425) by Matteo Busi, Riccardo Focardi, and Flaminia Luccio.
The project builds on ideas from [Mind the Gap](https://mici.hu/papers/bognar22gap.pdf) by Marton Bognar, Jo Van Bulck, and Frank Piessens.

## License And Acknowledgements

ALVIE is released under the [MIT License](LICENSE).
The project is supported by [CCAT – Cybersecurity Competence and Training](https://ccat.fi.muni.cz/), funded under Grant Agreement No. 101225878 and supported by the European Cybersecurity Competence Centre (ECCC).
