#!/usr/bin/env bash
# build-sim.sh SANCUS_REPO COMMIT OUT_DIR: the simulator of a commit of sancus-core-gap for the browser build of ALVIE.
#
# It prepares the processor as ALVIE does (a clone at COMMIT, configured by scripts/build_config.sh with the key cafe
# and security 20), and writes in OUT_DIR/COMMIT:
#   sim.js, sim.wasm  the testbench compiled by Verilator and Emscripten (harness.cpp, pre.js, post.js): an ES-free
#                     module factory, createSancusSim(), whose instances have run(mem) -> { status, vcd }
#   files/            what the step of a program needs (Step): pmem_defs.asm, sancus_macros.asm, pmem.x, pmem.sh
#                     and the template (src/generic_template.s43), as the setup of scripts/build_pmem makes them on
#                     the first step of a native run
#
# Needs: Verilator (5.x), Emscripten (emcc on the PATH, e.g. source emsdk_env.sh), a C preprocessor (gcc -E, or CPP),
# git. Run from anywhere. FILES_ONLY=1 makes only files/.
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

# The files of the programs of a step, as the setup of scripts/build_pmem makes them (with scripts/asm2ihex.sh, for
# the toolchain msp430 that ALVIE uses): pmem.sh from the definitions of the core by the C preprocessor, pmem.x and
# pmem_defs.asm from the templates of the commit. The C preprocessor of the host is enough: the MSP430 toolchain only
# builds the program, which Msp430_asm does.
core=$work/sancus-core-gap/core
sed -e 's/`ifdef/#ifdef/g' -e 's/`ifndef/#ifndef/g' -e 's/`else/#else/g' -e 's/`endif/#endif/g' -e 's/`define/#define/g' \
    -e 's/`include/\/\/#include/g' -e 's/`//g' -e "s/'//g" "$core/rtl/verilog/openMSP430_defines.v" > "$work/pmem.h"
cp "$alvie/scripts/omsp_config.sh" "$work/omsp_config.sh"
${CPP:-gcc -E} -P -x c "$work/omsp_config.sh" > "$out/files/pmem.sh"
# shellcheck disable=SC1091
. "$out/files/pmem.sh"
pmem_base=$((0x10000 - pmemsize)); stack_init=$((persize + 0x0080))
sed -e "s/PMEM_BASE/$pmem_base/g" -e "s/PMEM_SIZE/$pmemsize/g" -e "s/DMEM_SIZE/$dmemsize/g" -e "s/PER_SIZE/$persize/g" \
    -e "s/STACK_INIT/$stack_init/g" "$core/sim/rtl_sim/bin/template.x" > "$out/files/pmem.x"
sed -e "s/PMEM_SIZE/$pmemsize/g" -e "s/PER_SIZE_HEX/$persize/g" -e "s/PER_SIZE/$persize/g" -e "s/PMEM_BASE_VAL/$pmem_base/g" \
    -e "s/PMEM_EDE_SIZE/$pmemsize/g" "$core/sim/rtl_sim/bin/template_defs.asm" > "$out/files/pmem_defs.asm"
cp "$alvie/src/sancus_macros.asm" "$out/files/sancus_macros.asm"
cp "$alvie/src/generic_template.s43" "$out/files/generic_template.s43"
if [ "${FILES_ONLY:-0}" = 1 ]; then echo "$commit: files: $(ls "$out/files" | tr '\n' ' ')"; exit 0; fi

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
