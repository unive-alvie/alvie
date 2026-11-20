#!/usr/bin/env bash
# prepare.sh WEB_DIR SIM_DIR: what the extension serves to the browser, in bundle/ (then: npm ci && npm run build).
#   bundle/alvie/   alvie-web (WEB_DIR: the output of web/build.sh), the shim of Node (web/browser/node-shim.js), the
#                   runner of commands (runtime/runner.js), and the simulators of SIM_DIR (web/sim/build-sim.sh; one
#                   directory per commit), with sim/index.json
#   bundle/files/   the files of a first visit, with files/index.json: spec-lib/, the models of the paper
#                   (results/*.dot; not results/example/, which the tutorials learn), the tutorials (tutorials/*.alvienb), the fixtures of the
#                   plugins (plugins/<name>/fixtures), and an empty models/
set -euo pipefail
if [ "$#" -ne 2 ]; then echo "Usage: $0 WEB_DIR SIM_DIR" >&2; exit 2; fi
here=$(dirname "$(readlink -f "$0")"); web=$(readlink -f "$1"); sim=$(readlink -f "$2")
root=$(readlink -f "$here/../../../..")
out=$here/bundle
rm -rf "$out"; mkdir -p "$out/alvie/sim" "$out/files"
cp "$web/alvie-web.js" "$here/runtime/runner.js" "$here/../browser/node-shim.js" "$out/alvie/"
cp -r "$web/alvie-web.assets" "$out/alvie/"
commits=()
for d in "$sim"/*/; do
  c=$(basename "$d"); [ -f "$d/sim.js" ] || continue
  mkdir -p "$out/alvie/sim/$c"; cp "$d/sim.js" "$d/sim.wasm" "$out/alvie/sim/$c/"; cp -r "$d/files" "$out/alvie/sim/$c/"
  commits+=("\"$c\"")
done
(IFS=,; echo "[${commits[*]}]") > "$out/alvie/sim/index.json"
f=$out/files
cp -r "$root/spec-lib" "$f/spec-lib"
mkdir -p "$f/results" "$f/models" "$f/tutorials"
cp "$root"/results/*.dot "$f/results/"
cp "$here"/tutorials/* "$f/tutorials/"
rm -f "$f/tutorials/unpublished.txt"
# The tutorials of tutorials/unpublished.txt are not published yet (ALVIE_ALL_TUTORIALS=1 keeps them)
if [ "${ALVIE_ALL_TUTORIALS:-0}" != 1 ]; then
  grep -v '^#' "$here/tutorials/unpublished.txt" | while read -r t; do [ -n "$t" ] && rm -f "$f/tutorials/$t"; done
  # The mark of a bundle that can be published: the website (.github/workflows/pages.yml) publishes no other
  (cd "$f/tutorials" && ls *.alvienb) > "$out/publishable"
fi
: > "$f/models/.keep"
# The fixtures of the plugins, where alvie <plugin> fixtures looks for them (plugins/<name>/fixtures, from /)
for p in sancus tiny; do mkdir -p "$f/plugins/$p"; cp -r "$root/alvie/code/plugins/$p/fixtures" "$f/plugins/$p/"; done
# files/index.json: { path: SHA-256 of the file }, for the updates of the defaults (see src/core/files.js)
python3 - "$f" > "$out/index.json.tmp" <<'EOF'
import hashlib, json, os, sys
root = sys.argv[1]; index = {}
for d, _, names in os.walk(root):
    for n in names:
        p = os.path.join(d, n)
        index["/" + os.path.relpath(p, root)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
print(json.dumps(dict(sorted(index.items())), indent=0))
EOF
mv "$out/index.json.tmp" "$f/index.json"
# The list of the tutorials, for the first page of the site: the file, its title (its first heading) and its summary
# (the first paragraph after the heading)
python3 - "$f/tutorials" > "$out/tutorials.json" <<'EOF'
import json, os, re, sys
d = sys.argv[1]; out = []
for name in sorted(os.listdir(d)):
    if not name.endswith(".alvienb"): continue
    lines = open(os.path.join(d, name), encoding="utf-8").read().split("\n")
    title = next(l[2:].strip() for l in lines if l.startswith("# "))
    i = next(k for k, l in enumerate(lines) if l.startswith("# ")) + 1
    while i < len(lines) and not lines[i].strip(): i += 1
    summary = []
    while i < len(lines) and lines[i].strip() and not lines[i].startswith(("```", "#")): summary.append(lines[i].strip()); i += 1
    plain = lambda t: re.sub(r"[*_`]", "", t)  # the first page shows text, not Markdown
    out.append({"file": f"/tutorials/{name}", "id": name[:-len(".alvienb")], "title": plain(title), "summary": plain(" ".join(summary))})
print(json.dumps(out, indent=2))
EOF
echo "bundle/: alvie-web, ${#commits[@]} simulators, $(python3 -c "import json; print(len(json.load(open('$f/index.json'))))") files, $(python3 -c "import json; print(len(json.load(open('$out/tutorials.json'))))") tutorials"
