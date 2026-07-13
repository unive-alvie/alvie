#!/usr/bin/env bash

# Learn all standard bug experiments.
#
# Usage:
#   ./learn_all.sh <subdirectory> [--fpga]
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

usage() {
  echo "Usage: $0 <subdirectory> [--fpga]" >&2
  exit 2
}

if [ "$#" -ne 1 ]; then
  usage
fi

subdir=$1

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

DIR_SUFFIX=$( $FPGA && echo "-fpga" || true )
LOGS_DIR=$SCRIPT_DIR/logs/$subdir${DIR_SUFFIX}
RES_DIR=$SCRIPT_DIR/results/$subdir${DIR_SUFFIX}
TMP_DIR=$SCRIPT_DIR/tmp/$subdir${DIR_SUFFIX}

SCG_DIR=$SCRIPT_DIR/sancus-core-gap
SPEC_ROOT=$SCRIPT_DIR/spec-lib
SPEC_DIR=$SPEC_ROOT/$subdir
MM_DIR=$SCRIPT_DIR/alvie/code

EPS=0.01
DELTA=0.01

if [ ! -d "$SPEC_DIR" ]; then
  SPEC_DIR=$SPEC_ROOT
fi

if [ ! -f "$SPEC_DIR/enclave-complete.etdl" ]; then
  echo "Missing enclave specification in $SPEC_DIR" >&2
  exit 2
fi

mkdir -p "$RES_DIR"
mkdir -p "$LOGS_DIR"

# Commits in chronological order:
#   original  fix B2    fix B3    fix B6    fix B4    fix B1    fix B7(1) final
# ("ef753b6" "3170d5d" "6475709" "d54f031" "3636536" "e8cf011" "264f135" "bf89c0b")

declare -a EXPERIMENTS=(
  # B3 experiments
  "b3 enclave-complete 0 ef753b6"
  "b3 enclave-complete 0 6475709"
  "b3 enclave-complete 0 bf89c0b"
  "b3 enclave-complete 1 ef753b6"
  "b3 enclave-complete 1 6475709"
  "b3 enclave-complete 1 bf89c0b"
  # B4 experiments
  "b4 enclave-complete 0 ef753b6"
  "b4 enclave-complete 0 3636536"
  "b4 enclave-complete 0 bf89c0b"
  "b4 enclave-complete 1 ef753b6"
  "b4 enclave-complete 1 3636536"
  "b4 enclave-complete 1 bf89c0b"
  # B6 experiments
  "b6 enclave-complete 0 ef753b6"
  "b6 enclave-complete 0 d54f031"
  "b6 enclave-complete 0 bf89c0b"
  "b6 enclave-complete 1 ef753b6"
  "b6 enclave-complete 1 d54f031"
  "b6 enclave-complete 1 bf89c0b"
  # B7 experiments
  "b7 enclave-complete 0 ef753b6"
  "b7 enclave-complete 0 264f135"
  "b7 enclave-complete 0 bf89c0b"
  "b7 enclave-complete 1 ef753b6"
  "b7 enclave-complete 1 264f135"
  "b7 enclave-complete 1 bf89c0b"
  # B8 experiments
  "b8 enclave-complete 0 ef753b6"
  "b8 enclave-complete 0 bf89c0b"
  "b8 enclave-complete 1 ef753b6"
  "b8 enclave-complete 1 bf89c0b"
  # B9 experiments
  "b9 enclave-complete 0 ef753b6"
  "b9 enclave-complete 0 bf89c0b"
  "b9 enclave-complete 1 ef753b6"
  "b9 enclave-complete 1 bf89c0b"
  # B1 experiments
  "b1 enclave-complete 0 ef753b6"
  "b1 enclave-complete 0 e8cf011"
  "b1 enclave-complete 0 bf89c0b"
  "b1 enclave-complete 1 ef753b6"
  "b1 enclave-complete 1 e8cf011"
  "b1 enclave-complete 1 bf89c0b"
  # B2 experiments
  "b2 enclave-complete 0 ef753b6"
  "b2 enclave-complete 0 3170d5d"
  "b2 enclave-complete 0 bf89c0b"
  "b2 enclave-complete 1 ef753b6"
  "b2 enclave-complete 1 3170d5d"
  "b2 enclave-complete 1 bf89c0b"
)

cd $MM_DIR
dune build

run_bg() {
  local name="$1"; local cmd="$2"; local logfile="$3"
  echo "$cmd"
  (eval "$cmd" & wait $!
  if [[ $? -ne 0 ]]; then echo -e "$name ... [KO - $logfile]"
  else echo "$name ... [OK]"; fi) &
}

run_seq() {
  local name="$1"; local cmd="$2"; local logfile="$3"
  echo "$cmd"
  eval "$cmd"
  if [[ $? -ne 0 ]]; then echo -e "$name ... [KO - $logfile]"
  else echo "$name ... [OK]"; fi
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
