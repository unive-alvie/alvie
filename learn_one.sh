#!/usr/bin/env bash

# Learn models for a specific attacker spec against all "interesting" commits.
#
# Usage:
#   ./learn_one.sh <special_commit> <att_spec> <subdirectory> [--fpga]
#
# --fpga  Use the physical FPGA backend instead of the Verilog simulator.
#         Experiments are run sequentially to avoid serial-port conflicts.

FPGA=false
FPGA_FLAG=""
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--fpga" ]; then
    FPGA=true; FPGA_FLAG="--fpga"
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]}"

specialcommit=$1
attspecbn=$2
EPS=0.01
DELTA=0.01

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

DIR_SUFFIX=$( $FPGA && echo "-fpga" || true )
LOGS_DIR=$SCRIPT_DIR/logs/$3${DIR_SUFFIX}
RES_DIR=$SCRIPT_DIR/results/$3${DIR_SUFFIX}
TMP_DIR=$SCRIPT_DIR/tmp/$3${DIR_SUFFIX}

SCG_DIR=$SCRIPT_DIR/sancus-core-gap
SPEC_DIR=$SCRIPT_DIR/spec-lib/$3
MM_DIR=$SCRIPT_DIR/alvie/code

mkdir -p $RES_DIR
mkdir -p $LOGS_DIR

# Commits in chronological order:
#   original  fix B3    fix B6    fix B4    fix B1    fix B7(1) final
# ("ef753b6" "6475709" "d54f031" "3636536" "e8cf011" "264f135" "bf89c0b")

declare -a EXPERIMENTS=(
  "${attspecbn} enclave-complete 0 ef753b6"
  "${attspecbn} enclave-complete 0 $specialcommit"
  "${attspecbn} enclave-complete 0 bf89c0b"
  "${attspecbn} enclave-complete 1 ef753b6"
  "${attspecbn} enclave-complete 1 $specialcommit"
  "${attspecbn} enclave-complete 1 bf89c0b"
)

# Move to the project's directory
cd $MM_DIR

# Compile the project
dune build

run_bg() {
  local name="$1"; local cmd="$2"; local logfile="$3"
  echo "$cmd"
  (eval "$cmd" & wait $!
  if [[ $? -ne 0 ]]; then echo -e "$name ... [KO - $logfile]"
  else echo "$name ... [OK - $logfile]"; fi) &
}

run_seq() {
  local name="$1"; local cmd="$2"; local logfile="$3"
  echo "$cmd"
  eval "$cmd"
  if [[ $? -ne 0 ]]; then echo -e "$name ... [KO - $logfile]"
  else echo "$name ... [OK - $logfile]"; fi
}

echo -e "\nLearning started: refer to files in $LOGS_DIR for details"

for experiment in "${EXPERIMENTS[@]}"
do
    read -a exp_arr <<< "$experiment"
    attack_name=${exp_arr[0]%%[[:space:]]}
    enclave_name=${exp_arr[1]%%[[:space:]]}
    secret=${exp_arr[2]%%[[:space:]]}
    commit=${exp_arr[3]%%[[:space:]]}

    name_int="$commit-$attack_name-$enclave_name-$secret-$EPS-$DELTA-int"
    name_nint="$commit-$attack_name-$enclave_name-$secret-$EPS-$DELTA-nint"
    logfile_int="$LOGS_DIR/learn-$name_int.log"
    logfile_nint="$LOGS_DIR/learn-$name_nint.log"
    resfile_int="$RES_DIR/$name_int.dot"
    resfile_nint="$RES_DIR/$name_nint.dot"

    if [ -f "$resfile_int" ]; then
      echo "$name_int ... [OK - Done before]"
    else
      cmd_int="_build/default/bin/learn.exe $FPGA_FLAG --att-spec \"$SPEC_DIR/$attack_name.atdl\" --encl-spec \"$SPEC_DIR/$enclave_name.etdl\" --res \"$resfile_int\" --tmpdir \"$TMP_DIR\" --commit $commit --sancus \"$SCG_DIR\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac > $logfile_int 2>&1"
      if $FPGA; then run_seq "$name_int"  "$cmd_int"  "$logfile_int"
      else            run_bg  "$name_int"  "$cmd_int"  "$logfile_int"; fi
    fi

    if [ -f "$resfile_nint" ]; then
      echo "$name_nint ... [OK - Done before]"
    else
      cmd_nint="_build/default/bin/learn.exe $FPGA_FLAG --att-spec \"$SPEC_DIR/$attack_name.atdl\" --encl-spec \"$SPEC_DIR/$enclave_name.etdl\" --res \"$resfile_nint\" --tmpdir \"$TMP_DIR\" --commit $commit --sancus \"$SCG_DIR\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac --ignore-interrupts > $logfile_nint 2>&1"
      if $FPGA; then run_seq "$name_nint" "$cmd_nint" "$logfile_nint"
      else            run_bg  "$name_nint" "$cmd_nint" "$logfile_nint"; fi
    fi
done

wait

echo ""
