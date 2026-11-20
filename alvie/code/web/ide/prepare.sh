#!/usr/bin/env bash
# prepare.sh WEB_DIR SIM_DIR: what the IDE serves, in public/ (then: npm ci && npm run build, into dist/).
#   public/alvie/   alvie-web (WEB_DIR: the output of web/build.sh), the shim of Node (web/browser/node-shim.js), and
#                   the simulators of SIM_DIR (web/sim/build-sim.sh; one directory per commit), with sim/index.json
#   public/files/   the files of a first visit: spec-lib/, the models of results/example/, and an empty models/, with
#                   files/index.json
# runner.js (public/alvie) is a source file; everything else in public/ is made here.
set -euo pipefail
if [ "$#" -ne 2 ]; then echo "Usage: $0 WEB_DIR SIM_DIR" >&2; exit 2; fi
here=$(dirname "$(readlink -f "$0")"); web=$(readlink -f "$1"); sim=$(readlink -f "$2")
root=$(readlink -f "$here/../../../..")
pub=$here/public
find "$pub/alvie" -mindepth 1 ! -name runner.js -exec rm -rf {} + 2>/dev/null || true
rm -rf "$pub/files"; mkdir -p "$pub/alvie/sim" "$pub/files"
cp "$web/alvie-web.js" "$pub/alvie/"; cp -r "$web/alvie-web.assets" "$pub/alvie/"
cp "$here/../browser/node-shim.js" "$pub/alvie/"
commits=()
for d in "$sim"/*/; do
  c=$(basename "$d"); [ -f "$d/sim.js" ] || continue
  mkdir -p "$pub/alvie/sim/$c"; cp "$d/sim.js" "$d/sim.wasm" "$pub/alvie/sim/$c/"; cp -r "$d/files" "$pub/alvie/sim/$c/"
  commits+=("\"$c\"")
done
(IFS=,; echo "[${commits[*]}]") > "$pub/alvie/sim/index.json"
cp -r "$root/spec-lib" "$pub/files/spec-lib"
mkdir -p "$pub/files/results/example" "$pub/files/models"
cp "$root"/results/example/*.dot "$pub/files/results/example/"
: > "$pub/files/models/.keep"
(cd "$pub/files" && find . -type f ! -name index.json | sed 's|^\.||' | sort | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin]))') > "$pub/index.json.tmp"
mv "$pub/index.json.tmp" "$pub/files/index.json"
echo "public/: alvie-web, ${#commits[@]} simulators, $(python3 -c "import json; print(len(json.load(open('$pub/files/index.json'))))" ) files"
