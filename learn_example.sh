#!/usr/bin/env bash

# Learns the models of the running example from the paper
#
# Usage:
#   ./learn_example.sh [--fpga]
#
# --fpga  Use the physical FPGA backend instead of the Verilog simulator.
#         Experiments are run sequentially to avoid serial-port conflicts.

FPGA=false
FPGA_FLAG=""
for arg in "$@"; do
  [ "$arg" = "--fpga" ] && { FPGA=true; FPGA_FLAG="--fpga"; }
done

EPS=0.01
DELTA=0.01

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

DIR_SUFFIX=$( $FPGA && echo "-fpga" || true )
LOGS_DIR=$SCRIPT_DIR/logs/example${DIR_SUFFIX}
RES_DIR=$SCRIPT_DIR/results/example${DIR_SUFFIX}
TMP_DIR=$SCRIPT_DIR/tmp/example${DIR_SUFFIX}

SCG_DIR=$SCRIPT_DIR/sancus-core-gap
SPEC_DIR=$SCRIPT_DIR/spec-lib/example
MM_DIR=$SCRIPT_DIR/alvie/code


mkdir -p $RES_DIR
mkdir -p $LOGS_DIR

declare -a EXPERIMENTS=(
  "attacker enclave 0 bf89c0b"
  "attacker enclave 1 bf89c0b"
)

# Move to the project's directory
cd $MM_DIR

# Compile the project
dune build

run_bg() {
  local name="$1"
  local cmd="$2"
  local logfile="$3"
  echo "$cmd"
  (eval "$cmd" & wait $!
  if [[ $? -ne 0 ]]; then
    echo -e "$name ... [KO - $logfile]"
  else
    echo "$name ... [OK - $logfile]"
  fi) &
}

run_seq() {
  local name="$1"
  local cmd="$2"
  local logfile="$3"
  echo "$cmd"
  eval "$cmd"
  if [[ $? -ne 0 ]]; then
    echo -e "$name ... [KO - $logfile]"
  else
    echo "$name ... [OK - $logfile]"
  fi
}

# Then, iterate over all the possible combinations and learn
echo -e "\nLearning started: refer to files in $LOGS_DIR for details"

for experiment in "${EXPERIMENTS[@]}"
do
    read -a exp_arr <<< "$experiment"
    attack_name=${exp_arr[0]%%[[:space:]]}
    enclave_name=${exp_arr[1]%%[[:space:]]}
    secret=${exp_arr[2]%%[[:space:]]}
    commit=${exp_arr[3]%%[[:space:]]}

    name="$commit-$attack_name-$enclave_name-$secret-$EPS-$DELTA"
    logfile="$LOGS_DIR/learn-$name.log"
    resfile="$RES_DIR/$name.dot"

    if [ -f "$resfile" ]; then
      echo "$name ... [OK - Done before]"
    else
      cmd="_build/default/bin/learn.exe $FPGA_FLAG --debug --att-spec \"$SPEC_DIR/$attack_name.atdl\" --encl-spec \"$SPEC_DIR/$enclave_name.etdl\" --res \"$resfile\" --tmpdir \"$TMP_DIR\" --commit $commit --sancus \"$SCG_DIR\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac > $logfile 2>&1"
      if $FPGA; then
        run_seq "$name" "$cmd" "$logfile"
      else
        run_bg  "$name" "$cmd" "$logfile"
      fi
    fi
done

wait

echo ""
