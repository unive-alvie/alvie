#!/usr/bin/env bash

# This script is the entry point for the learning and does everything needed automatically.
# It takes all the possible enclave (.etdl files)/attacker (.atdl files)
# combinations and learn them all for all the "interesting" commits.
# Processes are spawned automatically on all the available cores.
#
# Usage:
#   ./learn_one_nospecial.sh <att_spec> <subdirectory>
# specialcommit=$1
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <att_spec> <subdirectory>" >&2
  exit 2
fi
attspecbn=$1
subdir=$2
EPS=0.01
DELTA=0.01

# Useful paths
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/script_helpers.sh"

LOGS_DIR=$SCRIPT_DIR/logs/$subdir
RES_DIR=$SCRIPT_DIR/results/$subdir
TMP_DIR=$SCRIPT_DIR/tmp/$subdir

SCG_DIR=$SCRIPT_DIR/sancus-core-gap
SPEC_DIR=$SCRIPT_DIR/spec-lib/$subdir
MM_DIR=$SCRIPT_DIR/alvie/code

if [ ! -d "$SPEC_DIR" ]; then
  SPEC_DIR=$SCRIPT_DIR/spec-lib
fi

if [ ! -f "$SPEC_DIR/$attspecbn.atdl" ] || [ ! -f "$SPEC_DIR/enclave-complete.etdl" ]; then
  echo "Missing specifications in $SPEC_DIR" >&2
  exit 2
fi

# Cleanup existing files
# echo "Cleaning up"
# rm -rf $RES_DIR
# rm -rf $LOGS_DIR

mkdir -p $RES_DIR
mkdir -p $LOGS_DIR
# mkdir -p $TMP_DIR

# Commits in chronological order:
#   original  fix B3    fix B6    fix B4    fix B1    fix B7(1) final
# ("ef753b6" "6475709" "d54f031" "3636536" "e8cf011" "264f135" "bf89c0b")

declare -a EXPERIMENTS=(
  "${attspecbn} enclave-complete 0 ef753b6"
  "${attspecbn} enclave-complete 0 bf89c0b"
  "${attspecbn} enclave-complete 1 ef753b6"
  "${attspecbn} enclave-complete 1 bf89c0b"
)

# Move to the project's directory
cd $MM_DIR

# Compile the project
alvie_build_or_exit

# Then, iterate over all the possible combinations and learn
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

    # Run the learning only if it has not been done already!
    if [ -f "$resfile_int" ]; then
      echo "$name_int ... [OK - Done before]"
    else
      # Invoke the learning process in background and send the stderr/stdout to the log file
      alvie_run_background "$name_int" "_build/default/bin/learn.exe --att-spec \"$SPEC_DIR/$attack_name.atdl\" --encl-spec \"$SPEC_DIR/$enclave_name.etdl\" --res \"$resfile_int\" --tmpdir \"$TMP_DIR\" --commit $commit --sancus \"$SCG_DIR\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac > \"$logfile_int\" 2>&1" "$logfile_int"
    fi

    if [ -f "$resfile_nint" ]; then
      echo "$name_nint ... [OK - Done before]"
    else
      # Invoke the learning process in background and send the stderr/stdout to the log file
      alvie_run_background "$name_nint" "_build/default/bin/learn.exe --att-spec \"$SPEC_DIR/$attack_name.atdl\" --encl-spec \"$SPEC_DIR/$enclave_name.etdl\" --res \"$resfile_nint\" --tmpdir \"$TMP_DIR\" --commit $commit --sancus \"$SCG_DIR\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac --ignore-interrupts > \"$logfile_nint\" 2>&1" "$logfile_nint"
    fi
done

if ! alvie_wait_for_jobs; then
  echo "Learning incomplete: one or more models failed. See $LOGS_DIR." >&2
  exit 1
fi

echo ""
