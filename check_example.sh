#!/usr/bin/env bash

# Compare learned models for the running example (secret 0 vs secret 1).
#
# Usage:
#   ./check_example.sh [--fpga]
#
# --fpga  Look for models produced by the FPGA backend (results/example-fpga/).

FPGA=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--fpga" ]; then
    FPGA=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]}"

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--fpga]" >&2
  exit 2
fi

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/script_helpers.sh"

DIR_SUFFIX=$( $FPGA && echo "-fpga" || true )
LOGS_DIR=$SCRIPT_DIR/logs/example${DIR_SUFFIX}
RES_DIR=$SCRIPT_DIR/results/example${DIR_SUFFIX}
CEX_DIR=$SCRIPT_DIR/counterexamples/example${DIR_SUFFIX}
TMP_DIR=$SCRIPT_DIR/tmp

MM_DIR=$SCRIPT_DIR/alvie/code

cd $SCRIPT_DIR

mkdir -p $LOGS_DIR
mkdir -p $CEX_DIR

# Loads the list of all available models
shopt -s nullglob
ZERO_MODELS=("$RES_DIR"/*-attacker-*-0-*.dot)
shopt -u nullglob
if [ "${#ZERO_MODELS[@]}" -eq 0 ]; then
  echo "Comparison incomplete: no secret-0 example models found in $RES_DIR." >&2
  exit 2
fi

# Move to the project's directory
cd $MM_DIR

# Compile the project
alvie_build_or_exit

echo -e "\nComparison started: refer to files in $LOGS_DIR for details"

comparison_incomplete=0

for m1 in "${ZERO_MODELS[@]}"
do
    m1_name="$(basename $m1 .dot)"
    commit=${m1_name:0:7}
    shopt -s nullglob
    ONE_MODELS=("$RES_DIR"/$commit-attacker-*-1-*.dot)
    shopt -u nullglob
    if [ "${#ONE_MODELS[@]}" -eq 0 ]; then
      echo "Comparison incomplete: missing secret-1 model for $commit in $RES_DIR." >&2
      comparison_incomplete=1
      continue
    fi

    for m2 in "${ONE_MODELS[@]}"
    do
        m1_nint=${m1//int/nint}
        m2_nint=${m2//int/nint}
        m2_name="$(basename $m2 .dot)"

        if [ "$m1_name" = "$m2_name" ]; then
          continue
        fi

        cexlimit=""
        cexfile="$CEX_DIR/$commit-attacker"
        logfile="$LOGS_DIR/compare-$commit-attacker.log"
        name="$commit-attacker"

        # Call the comparison process
        alvie_run_background "$name" "_build/default/bin/fa.exe --tmpdir \"$TMP_DIR\" --m1-int \"${m1%%[[:space:]]}\" --m2-int \"${m2%%[[:space:]]}\" --witness-file-basename \"$cexfile\" $cexlimit > \"$logfile\" 2>&1" "$logfile"
    done
done

comparison_failed=0
if ! alvie_wait_for_jobs; then
  comparison_failed=1
fi

if [ "$comparison_incomplete" -ne 0 ]; then
  echo "Comparison incomplete: required models are missing. See $RES_DIR." >&2
  exit 2
fi

if [ "$comparison_failed" -ne 0 ]; then
  echo "Comparison incomplete: one or more comparisons failed. See $LOGS_DIR." >&2
  exit 1
fi

echo ""
