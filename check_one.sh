#!/usr/bin/env bash

# Compare learned models for one attacker spec (secret 0 vs secret 1).
#
# Usage:
#   ./check_one.sh <att_spec> <subdirectory> [--fpga]
#
# --fpga  Look for models produced by the FPGA backend (<subdirectory>-fpga).

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

specbn=$1

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

DIR_SUFFIX=$( $FPGA && echo "-fpga" || true )
LOGS_DIR=$SCRIPT_DIR/logs/$2${DIR_SUFFIX}
RES_DIR=$SCRIPT_DIR/results/$2${DIR_SUFFIX}
CEX_DIR=$SCRIPT_DIR/counterexamples/$2${DIR_SUFFIX}
TMP_DIR=$SCRIPT_DIR/tmp

MM_DIR=$SCRIPT_DIR/alvie/code

cd $SCRIPT_DIR

mkdir -p $LOGS_DIR
mkdir -p $CEX_DIR

# Loads the list of all available models
readarray ZERO_MODELS <<< "$(ls $RES_DIR/*-${specbn}-*-0-*-int.dot)"

# Move to the project's directory
cd $MM_DIR

# Compile the project
dune build

run() {
  local status=0

  (eval $2 & wait $!;
  status=$?;
  if [[ $status -ne 0 ]]; then
    echo -e "$1 ... [KO - $3]"
  else
    echo "$1 ... [OK - $3]"
  fi) &
}

echo -e "\nComparison started: refer to files in $LOGS_DIR for details"

for m1 in "${ZERO_MODELS[@]}"
do
    m1_name="$(basename $m1 .dot)"
    commit=${m1_name:0:7}
    readarray ONE_MODELS <<< "$(ls $RES_DIR/$commit-${specbn}-*-1-*-int.dot)"

    for m2 in "${ONE_MODELS[@]}"
    do
        m1_nint=${m1//int/nint}
        m2_nint=${m2//int/nint}
        m2_name="$(basename $m2 .dot)"

        if [ "$m1_name" = "$m2_name" ]; then
          continue
        fi

        cexlimit=""
        cexfile="$CEX_DIR/$specbn/$commit-$specbn"
        logfile="$LOGS_DIR/compare-$commit-$specbn.log"
        name="$commit-$specbn"

        run "$name" "_build/default/bin/fa.exe --tmpdir \"$TMP_DIR\" --m1-int \"${m1%%[[:space:]]}\" --m2-int \"${m2%%[[:space:]]}\"  --m1-nint \"${m1_nint%%[[:space:]]}\" --m2-nint \"${m2_nint%%[[:space:]]}\" --witness-file-basename \"$cexfile\" --debug $cexlimit > \"$logfile\" 2>&1" "$logfile"
    done
done

wait

echo ""
