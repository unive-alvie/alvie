#!/usr/bin/env bash
# build-workbench.sh OUT_DIR [WORK_DIR]: builds VS Code for the Web from the sources of Code - OSS (MIT), at the tag
# VSCODE_TAG, into OUT_DIR (the static files of the workbench: out/, extensions/, node_modules/ that the web needs).
# It needs the version of Node of the tag (.nvmrc) and about 8 GB of memory; it takes about 30 minutes.
# CI caches OUT_DIR by VSCODE_TAG.
set -euo pipefail
VSCODE_TAG=${VSCODE_TAG:-1.146.0}
if [ "$#" -lt 1 ]; then echo "Usage: $0 OUT_DIR [WORK_DIR]" >&2; exit 2; fi
out=$(readlink -f "$1"); work=$(readlink -f "${2:-$out.src}")
if [ ! -d "$work/.git" ]; then
  git clone --depth 1 --branch "$VSCODE_TAG" https://github.com/microsoft/vscode.git "$work"
fi
cd "$work"
want=$(cat .nvmrc); have=$(node --version | sed 's/^v//')
if [ "$want" != "$have" ]; then echo "Node $want is needed (.nvmrc of $VSCODE_TAG); this is Node $have" >&2; exit 1; fi
export ELECTRON_SKIP_BINARY_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 VSCODE_SKIP_NODE_VERSION_CHECK=1
if [ -f pnpm-lock.yaml ]; then corepack pnpm install --frozen-lockfile; else npm ci; fi
npm run gulp vscode-web-min
# The result is ../vscode-web, next to the sources
rm -rf "$out"; mv ../vscode-web "$out"
echo "VS Code for the Web $VSCODE_TAG: $out ($(du -sh "$out" | cut -f1))"
