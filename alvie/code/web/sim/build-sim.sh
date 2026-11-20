#!/usr/bin/env bash
# build-sim.sh SANCUS_REPO COMMIT OUT_DIR: the simulator of a commit of sancus-core-gap for the browser build of ALVIE.
#
# It prepares the processor as ALVIE does (a clone at COMMIT, configured by scripts/build_config.sh with the key cafe
# and security 20), and writes in OUT_DIR/COMMIT:
#   sim.js, sim.wasm  the testbench compiled by Verilator and Emscripten (harness.cpp, pre.js, post.js): an ES-free
#                     module factory, createSancusSim(), whose instances have run(mem) -> { status, vcd }
#   files/            what the step of a program needs (Step): pmem_defs.asm, sancus_macros.asm, pmem.x, pmem.sh
#                     and the template (src/generic_template.s43), the first four
#                     made by scripts/build_pmem once, as on the first step of a native run
#
# Needs: Verilator (5.x), Emscripten (emcc on the PATH, e.g. source emsdk_env.sh), the MSP430 toolchain (for pmem.sh
# and pmem_defs.asm), git. Run from anywhere.
set -euo pipefail
if [ "$#" -ne 3 ]; then echo "Usage: $0 SANCUS_REPO COMMIT OUT_DIR" >&2; exit 2; fi
repo=$(readlink -f "$1"); commit=$2; out=$(mkdir -p "$3" && readlink -f "$3")/$commit
here=$(dirname "$(readlink -f "$0")"); alvie=$(readlink -f "$here/../../..")
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$out/files"

# The processor, as Simulator.make prepares it
git clone -q --no-hardlinks "$repo" "$work/sancus-core-gap"
git -C "$work/sancus-core-gap" checkout -q "$commit"
(cd "$alvie/code" && ../scripts/build_config.sh "$work/sancus-core-gap/" 20 cafe > /dev/null)
sed "s|{{tmp_dir}}|$work|g" "$alvie/src/submit.f" > "$work/submit.f"
cp "$alvie/src/generic.v" "$work/stimulus.v"

# The files of a step: build_pmem's setup on the template
cp "$alvie/src/generic_template.s43" "$work/generic.s43"
(cd "$alvie/code" && ../scripts/build_pmem "$work" generic --no-mem > "$work/build_pmem.log" 2>&1) || { cat "$work/build_pmem.log" >&2; exit 1; }
for f in pmem_defs.asm sancus_macros.asm pmem.x pmem.sh; do cp "$work/$f" "$out/files/$f"; done
cp "$alvie/src/generic_template.s43" "$out/files/generic_template.s43"

# Verilator's runtime, with the C++20 coroutines of libc++ (Verilator 5.002 includes <experimental/coroutine>)
vroot="$work/verilator"; cp -r "$(verilator --getenv VERILATOR_ROOT)" "$vroot"
perl -0pi -e 's|# include <experimental/coroutine>\n\s*namespace std \{\n\s*using namespace experimental;[^\n]*\n\s*\}|# include <coroutine>|' "$vroot/include/verilated_timing.h"
grep -q 'experimental/coroutine' "$vroot/include/verilated_timing.h" && { echo "could not patch verilated_timing.h" >&2; exit 1; }

# The testbench, as scripts/verilog_compile builds it, with the harness instead of the main of Verilator
(cd "$alvie/code" && verilator -O3 --noassert -I"$work" -f "$work/submit.f" --cc --exe --timing -Wno-fatal \
   --trace --trace-depth 1 --Mdir "$work/obj" -o sim "$here/harness.cpp" > "$work/verilator.log" 2>&1) \
  || { cat "$work/verilator.log" >&2; exit 1; }
(cd "$work/obj" && emmake make -j"$(nproc)" -f Vtb_openMSP430.mk VERILATOR_ROOT="$vroot" CXX=em++ LINK=em++ AR=emar \
   CFG_LDLIBS_THREADS= CFG_CXXFLAGS_COROUTINES= CFG_CXXFLAGS_STD_NEWEST=-std=c++20 \
   CFG_CXXFLAGS_NO_UNUSED="-Wno-unused-parameter -Wno-unused-variable -Wno-unused-but-set-variable" \
   OPT_FAST=-O3 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
   LDFLAGS="-O3 -sMODULARIZE=1 -sEXPORT_NAME=createSancusSim -sEXPORTED_RUNTIME_METHODS=FS -sINVOKE_RUN=0 \
            -sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8MB -sENVIRONMENT=web,worker,node \
            --pre-js $here/pre.js --post-js $here/post.js" > "$work/emmake.log" 2>&1) \
  || { tail -30 "$work/emmake.log" >&2; exit 1; }
cp "$work/obj/sim" "$out/sim.js"; cp "$work/obj/sim.wasm" "$out/sim.wasm"
echo "$commit: $(du -h "$out/sim.wasm" | cut -f1) simulator, files: $(ls "$out/files" | tr '\n' ' ')"
