# Changelog

## Unreleased

### Performance

Learning is much faster; for example, `spec-lib/fast/b4` (`ef753b6`, interrupts,
secret 0) went from 2235s to about 11s of learning, and all the models of
`learn_all.sh` are learned in about 6 minutes on 16 cores.

- L#: apartness is cached across the run (it is monotone in the observation
  tree), frontier-to-basis candidates are tracked incrementally node by node,
  and the frontier, rule 2 and rule 3 no longer rescan the whole tree after
  every output query. Learned models and queries are unchanged;
  `ALVIE_CHECK_APART=1` cross-checks all of this against the original
  computations.
- Observation trees are updated incrementally.
- Verilog SUL: native VCD parser (no more Python), only the analysed signals
  are traced, the toolchain and the simulator are run without shell scripts,
  symbols are read from the ELF file, the program image is built with a
  one-time setup, and a no-op shell command run at every step is gone.
- Compiled simulators are cached across runs (`ALVIE_SIM_CACHE`).
- The GC is tuned for learning (`OCAMLRUNPARAM` overrides it).
- Experiment wrappers run at most `ALVIE_JOBS` experiments at a time
  (default: number of cores) instead of all of them at once.

### Fixes

- B3 on unpatched Sancus (`ef753b6`, interrupts) did not terminate: the
  instruction counter used by the SUL was compared as part of the
  observations, and repeated enclave re-entries kept producing new states.
  The counter is no longer compared, and the SUL identifies a re-entry
  segment with an identical one immediately preceding it
  (`--keep-repeated-reentries` disables this).

### Tooling

- `ALVIE_PROFILE=1` prints a wall-clock profile (also on `SIGUSR1`);
  `--info` logs PAC rounds and counterexamples.
- Learning logs end with a statistics line (`--report`), including the
  learning time.
- Drops the obsolete `tt_genall` and `tt_derive` programs and the `py` and
  `Verilog_VCD` dependencies.

### Results

- Regenerates `results/` and `counterexamples/`. Models differ from the
  CSF'24 ones because of the current toolchain (today's `main` produces the
  same models) and of the fixes above; witnesses report the same attacks.
  The models for the attack `a` are now learned from `spec-lib/a.atdl`
  (the previous ones were copies of those of `b6`/`b7`).

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
