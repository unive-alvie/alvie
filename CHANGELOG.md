# Changelog

## 2026.09

This is the first release since the CSF'24 artifact (`csf24.v1`).

### ALVIE UI

ALVIE now has an easy-to-use graphical interface,
[alvie-ui](https://github.com/unive-alvie/alvie-ui): a user interface for the
ALVIE research tool from Ca’ Foscari University of Venice, developed by Marco
Ballarin and Giovanni Quacchia during their thesis work at Ca’ Foscari
University of Venice.

### Build and distribution

- Ports ALVIE to OCaml 4.14 and updates library calls.
- Merges the Dockerfiles into a single multi-platform image for amd64 and arm64,
  published as `matteobusi/alvie`, and adds `docker-build.sh`.
- Tracks `sancus-core-gap` as a git submodule.
- Trims unused simulator dependencies from the Docker image.
- Adds the MIT License.

### Features and fixes

- Adds a new TestDL action and human-readable trace markers (#20).
- Adds actionable CLI diagnostics (#23).
- Aligns executable behavior, `--help`, and the reference docs (#34).
  `pbt.exe --step-limit` is renamed to `--test-count`, and the old name
  remains as a deprecated alias.
- Fixes VCD signal lookup and macOS script compatibility.
- Fixes `mm_exec` to load its input from a file.

### Documentation

- Adds a documentation website, published from `main`, with getting-started,
  V-B1 tutorial, reproduction, and native-installation guides
  (#18, #19, #24, #25, #26, #30, #31, #33).
- Completes the TestDL specification reference and extension guide.

### Tests and CI

- Adds the isolated `tt_features` Alcotest suite (#22).
- Covers malformed specs and incomplete simulations (#29).
- Verifies the documentation in CI, and caches OCaml dependencies (#36).

### Removed

- Removes the archived L# prototypes. They remain on the
  `archive/minimal-lsharp-prototypes` branch (#35).

## csf24.v1

The artifact accompanying the CSF'24 paper.
