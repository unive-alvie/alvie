#!/bin/bash
# Once-per-session setup for the Verilog simulator pmem build pipeline.
# Extracts memory sizes and generates linker script + defs file so
# build_pmem_sim only needs msp430-as, msp430-ld, msp430-objcopy,
# and ihex2mem.tcl per step.
#
# Usage: setup_sim.sh <tmpdir>

if [[ "$OSTYPE" == darwin* ]]; then
    shopt -s expand_aliases
    alias sed='gsed'
fi

tmpdir="$1"
scriptsdir="$(dirname "$0")"
srcdir="$scriptsdir/../src"

incfilev="$tmpdir/sancus-core-gap/core/rtl/verilog/openMSP430_defines.v"
incfile="$tmpdir/pmem.h"
linkfile="$tmpdir/sancus-core-gap/core/sim/rtl_sim/bin/template.x"
headfile="$tmpdir/sancus-core-gap/core/sim/rtl_sim/bin/template_defs.asm"
sancus_macro="sancus_macros.asm"

# Copy static files
cp "$srcdir/$sancus_macro" "$tmpdir/$sancus_macro"
cp "$scriptsdir/omsp_config.sh" "$tmpdir/omsp_config.sh"

# Transform Verilog defines → C preprocessor header
cp "$incfilev" "$incfile"
sed -i 's/`ifdef/#ifdef/g'   "$incfile"
sed -i 's/`ifndef/#ifndef/g' "$incfile"
sed -i 's/`else/#else/g'     "$incfile"
sed -i 's/`endif/#endif/g'   "$incfile"
sed -i 's/`define/#define/g' "$incfile"
sed -ie 's/`include/\/\/#include/g' "$incfile"
sed -i 's/`//g'              "$incfile"
sed -i "s/'//g"              "$incfile"

# Extract memory sizes
if command -v msp430-gcc >/dev/null; then
    msp430-gcc -E -P -x c "$tmpdir/omsp_config.sh" > "$tmpdir/pmem.sh"
    MSPGCC_PFX=msp430
else
    msp430-elf-gcc -E -P -x c "$tmpdir/omsp_config.sh" > "$tmpdir/pmem.sh"
    MSPGCC_PFX=msp430-elf
fi

source "$tmpdir/pmem.sh"

PER_SIZE=$persize
DMEM_SIZE=$dmemsize
PMEM_SIZE=$pmemsize
PMEM_BASE=$((0x10000 - PMEM_SIZE))
STACK_INIT=$((PER_SIZE + 0x0080))

# Generate linker script
cp "$linkfile" "$tmpdir/pmem.x"
sed -ie "s/PMEM_BASE/$PMEM_BASE/g"   "$tmpdir/pmem.x"
sed -ie "s/PMEM_SIZE/$PMEM_SIZE/g"   "$tmpdir/pmem.x"
sed -ie "s/DMEM_SIZE/$DMEM_SIZE/g"   "$tmpdir/pmem.x"
sed -ie "s/PER_SIZE/$PER_SIZE/g"     "$tmpdir/pmem.x"
sed -ie "s/STACK_INIT/$STACK_INIT/g" "$tmpdir/pmem.x"

# Generate assembler defs
cp "$headfile" "$tmpdir/pmem_defs.asm"
sed -ie "s/PMEM_SIZE/$PMEM_SIZE/g"         "$tmpdir/pmem_defs.asm"
sed -ie "s/PER_SIZE_HEX/$PER_SIZE/g"       "$tmpdir/pmem_defs.asm"
if [ "$MSPGCC_PFX" = "msp430-elf" ]; then
    sed -ie "s/PER_SIZE/.data/g"            "$tmpdir/pmem_defs.asm"
    sed -ie "s/PMEM_BASE_VAL/.text/g"       "$tmpdir/pmem_defs.asm"
    sed -ie "s/PMEM_EDE_SIZE/0/g"           "$tmpdir/pmem_defs.asm"
else
    sed -ie "s/PER_SIZE/$PER_SIZE/g"        "$tmpdir/pmem_defs.asm"
    sed -ie "s/PMEM_BASE_VAL/$PMEM_BASE/g"  "$tmpdir/pmem_defs.asm"
    sed -ie "s/PMEM_EDE_SIZE/$PMEM_SIZE/g"  "$tmpdir/pmem_defs.asm"
fi
