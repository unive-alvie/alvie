#!/usr/bin/env bash
# build.sh OUT_DIR: alvie-web (web/alvie_web.ml) compiled to WebAssembly in OUT_DIR, with the Node runner.
#
# Needs an OCaml 5 switch with the dependencies of ALVIE and wasm_of_ocaml (opam install wasm_of_ocaml-compiler
# js_of_ocaml js_of_ocaml-ppx), and Binaryen (wasm-opt) on the PATH. runtime/ has the WebAssembly runtime of the
# C functions of Jane Street's libraries v0.17, which their releases do not have yet (see runtime/README.md).
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "Usage: $0 OUT_DIR" >&2; exit 2; fi
here=$(dirname "$(readlink -f "$0")"); code=$(readlink -f "$here/..")
out=$(mkdir -p "$1" && readlink -f "$1")
(cd "$code" && dune build --build-dir _build-web web/alvie_web.bc)
wasm_of_ocaml compile "$here"/runtime/*.wat "$code/_build-web/default/web/alvie_web.bc" -o "$out/alvie-web.js"
cp "$here/node/alvie-web.cjs" "$out/alvie-web-node.cjs"
echo "alvie-web: $out/alvie-web.js ($(du -sh "$out/alvie-web.assets" | cut -f1) of WebAssembly); run it with node $out/alvie-web-node.cjs"
