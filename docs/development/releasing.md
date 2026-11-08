---
title: Making a Release
description: The steps of an ALVIE release, from the checks to the tag, the documentation and the Docker image.
sidebar:
  order: 3
isNew: true
---

Releases are named after their month, `YYYY.MM` (`2026.10`), with `.N` for a second release in the same month.
The version is in one place, `alvie/code/dune-project`; `alvie --version`, the opam files and the header of model files take it from there.

## Before the release

1. Set the version in `dune-project`, and in the `version:` of the manifests of `plugins/sancus`, `plugins/tiny` and `plugins/tiny-py` (and in the `serve(...)` of `plugins/tiny-py/tiny.py`, which the handshake checks).
2. Run `./regression.sh all`. A new version changes only the first line of the learned models, so update the checked-in ones to it (the line `// alvie-model format 1; plugin sancus YYYY.MM; core 1`); the regression must then report no differences.
3. Run every suite of [Testing ALVIE](/alvie/development/testing-alvie/), including the fixtures of Sancus.
4. Turn `## Unreleased` of `CHANGELOG.md` into `## YYYY.MM`, and update [Migrating](/alvie/reference/migration/) for the changes that users must act on.
5. Update the documentation versions line of `README.md`.

## The release

1. Merge into `main` (through `alvie-ng` for the milestones of the framework).
2. Tag the commit of `main` and push the tag: `git tag YYYY.MM && git push origin YYYY.MM`. The workflow `pages.yml` adds the documentation of the release to the site, at `/alvie/YYYY.MM/`, and makes it the current one.
3. Build and push the Docker image (see the first lines of `Dockerfile`): `docker buildx build --platform linux/amd64,linux/arm64 -t matteobusi/alvie:YYYY.MM -t matteobusi/alvie:latest --push .`
4. Make a GitHub release from the tag, with the section of the CHANGELOG as its notes.

After the release, start a new `## Unreleased` section in the CHANGELOG.
