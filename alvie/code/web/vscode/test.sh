#!/usr/bin/env bash
# test.sh: the self-test of the extension (src/selftest.js) in VS Code for the Web (stable), in headless Chromium.
# Build first: web/ide/prepare.sh, npm ci in web/ide and here, npm run build.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
npx vscode-test-web --quality "${VSCODE_QUALITY:-stable}" --browserType chromium --headless --port "${PORT:-3101}" \
  --extensionDevelopmentPath=. --extensionTestsPath=out/selftest.js --folder-uri alvie:/
