#!/usr/bin/env bash
# make-site.sh WORKBENCH_DIR OUT_DIR: the static site of ALVIE in VS Code for the Web, in OUT_DIR:
#   index.html            the first page: the tutorials and an empty session
#   code.html, main.js    the workbench on alvie:/ with the extension built in (?tutorial=ID opens a tutorial)
#   vscode/               VS Code for the Web (WORKBENCH_DIR, from build-workbench.sh)
#   alvie/                the extension (npm run build first: out/ and bundle/)
# Any static server serves it; the page must be served over http(s) (not file:).
set -euo pipefail
if [ "$#" -ne 2 ]; then echo "Usage: $0 WORKBENCH_DIR OUT_DIR" >&2; exit 2; fi
here=$(dirname "$(readlink -f "$0")"); wb=$(readlink -f "$1"); out=$2
[ -f "$here/out/extension.js" ] && [ -d "$here/bundle" ] || { echo "Build the extension first (npm run build)" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out/alvie"
cp -r "$wb" "$out/vscode"
cp -r "$here/package.json" "$here"/language-configuration*.json "$here/syntaxes" "$here/out" "$here/bundle" "$out/alvie/"
rm -f "$out/alvie/out/selftest.js"
cp "$here/site/main.js" "$here/site/index.html" "$here/site/code.html" "$out/"
python3 "$here/site/patch-webview.py" "$out/vscode/out/vs/workbench/contrib/webview/browser/pre/index.html"
echo "The site: $out ($(du -sh "$out" | cut -f1))"
