#!/usr/bin/env bash

# Regression suite for the ALVIE/Sancus results.
#
# It checks that a change leaves the checked-in learned models (results/) and witnesses
# (counterexamples/) unchanged:
#
#   witnesses  compares the checked-in models again with fa.exe and checks that the witness graphs
#              and the witness counts are the recorded ones. Needs mCRL2. A few minutes.
#   learning   learns every checked-in model again (learn_all.sh and the Getting Started example),
#              checks that the models are identical to the checked-in ones, then runs the witnesses
#              check on the new models. Needs the simulator toolchain and sancus-core-gap. About
#              10 minutes on 16 cores (ALVIE_JOBS limits the parallel experiments).
#   all        both.
#
# Everything is written under results/regression/, counterexamples/regression/ and logs/regression/,
# which are removed at the start of each run. The checked-in files are never modified.
#
# Exit codes: 0 no differences, 1 differences found, 2 usage error or incomplete run.
#
# Usage:
#   ./regression.sh witnesses|learning|all

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 witnesses|learning|all" >&2
  exit 2
fi
mode=$1
case "$mode" in
  witnesses|learning|all) ;;
  *) echo "Unknown mode '$mode'. Usage: $0 witnesses|learning|all" >&2; exit 2 ;;
esac

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "$SCRIPT_DIR/script_helpers.sh"
MM_DIR=$SCRIPT_DIR/alvie/code
EXPECTED_COUNTS=$MM_DIR/test/regression/witness-counts.txt
EPS=0.01
DELTA=0.01

cd "$SCRIPT_DIR" || exit 2

differences=0

# Reports a difference without stopping, so that one run lists all of them
difference() {
  echo "DIFFERENT: $*" >&2
  differences=1
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Regression incomplete: '$1' is not on PATH. $2" >&2
    exit 2
  fi
}

# What kind of difference two models have: their states are numbered differently, they differ in the
# bookkeeping only, or they answer some inputs differently (alvie-model-compare prints the shortest ones)
explain_model_difference() {
  local tool=$MM_DIR/_build/default/lib/core/tools/model_compare_main.exe
  if [ ! -x "$tool" ]; then echo "build alvie/code to see how"; return; fi
  if "$tool" "$1" "$2" >/dev/null 2>&1; then echo "isomorphic: only the state numbers differ"
  elif "$tool" --observations-only "$1" "$2" >/dev/null 2>&1; then echo "isomorphic except for the bookkeeping of the outputs"
  else echo "not isomorphic: $tool --observations-only $1 $2 shows the first difference"
  fi
}

# compare_models <expected dir> <actual dir>: the .dot files of the two directories must be identical
compare_models() {
  local expected_dir=$1 actual_dir=$2 expected actual n=0
  shopt -s nullglob
  for expected in "$expected_dir"/*.dot; do
    actual="$actual_dir/$(basename "$expected")"
    n=$((n + 1))
    if [ ! -f "$actual" ]; then
      difference "model $actual was not learned"
    elif ! cmp -s "$expected" "$actual"; then
      difference "model $actual differs from $expected ($(explain_model_difference "$expected" "$actual"))"
    fi
  done
  shopt -u nullglob
  echo "Compared $n models of $expected_dir"
}

# check_witnesses <subdirectory>: runs check_all.sh on results/<subdirectory> and compares the
# witnesses written to counterexamples/<subdirectory> with the checked-in ones
check_witnesses() {
  local sub=$1 expected actual att commit log count expected_count n=0
  rm -rf "counterexamples/$sub" "logs/$sub"/compare-*.log "logs/$sub"/example/compare-*.log
  if ! ./check_all.sh "$sub"; then
    echo "Regression incomplete: check_all.sh failed. See logs/$sub." >&2
    exit 2
  fi
  shopt -s nullglob
  for expected in counterexamples/*/*_int.dot; do
    case "$expected" in counterexamples/example/*) continue ;; esac
    att=$(basename "$(dirname "$expected")")
    actual="counterexamples/$sub/$att/$(basename "$expected")"
    n=$((n + 1))
    if [ ! -f "$actual" ]; then
      difference "witness graph $actual was not produced"
    elif ! cmp -s "$expected" "$actual"; then
      difference "witness graph $actual differs from $expected"
    fi
  done
  shopt -u nullglob
  # The Getting Started example compares two interrupt-enabled models only, as check_example.sh does
  if [ -d "results/$sub/example" ]; then
    mkdir -p "counterexamples/$sub/example" "logs/$sub/example"
    log="logs/$sub/example/compare-bf89c0b-example.log"
    if ! (cd "$MM_DIR" && _build/default/bin/fa.exe --tmpdir "$SCRIPT_DIR/tmp/$sub/example" \
          --m1-int "$SCRIPT_DIR/results/$sub/example/bf89c0b-attacker-enclave-0-$EPS-$DELTA.dot" \
          --m2-int "$SCRIPT_DIR/results/$sub/example/bf89c0b-attacker-enclave-1-$EPS-$DELTA.dot" \
          --witness-file-basename "$SCRIPT_DIR/counterexamples/$sub/example/bf89c0b-attacker" --debug > "$SCRIPT_DIR/$log" 2>&1); then
      echo "Regression incomplete: the comparison of the example failed. See $log." >&2
      exit 2
    fi
    n=$((n + 1))
    if ! cmp -s counterexamples/example/bf89c0b-attacker_int.dot "counterexamples/$sub/example/bf89c0b-attacker_int.dot"; then
      difference "witness graph counterexamples/$sub/example/bf89c0b-attacker_int.dot differs from counterexamples/example/bf89c0b-attacker_int.dot"
    fi
  fi
  echo "Compared $n witness graphs"
  # The counts are those of the attack catalogue (docs/reference/attack-catalogue.md)
  while read -r att commit expected_count; do
    case "$att" in ''|'#'*) continue ;; esac
    log="logs/$sub/compare-$commit-$att.log"
    [ "$att" = example ] && log="logs/$sub/example/compare-bf89c0b-example.log"
    count=$(sed -n 's/.*found \([0-9]*\) FA violations.*/\1/p' "$log" 2>/dev/null | tail -1)
    if [ -z "$count" ]; then
      difference "no witness count for $att at $commit (see $log)"
    elif [ "$count" != "$expected_count" ]; then
      difference "$att at $commit: $count witnesses, expected $expected_count"
    fi
  done < "$EXPECTED_COUNTS"
  echo "Checked the witness counts of $EXPECTED_COUNTS"
}

run_witnesses() {
  echo "=== Witnesses of the checked-in models"
  require_tool ltscompare "Install mCRL2 or use the Docker image."
  local sub=regression/witnesses
  rm -rf "results/$sub"
  mkdir -p "results/$sub"
  cp results/*.dot "results/$sub/"
  mkdir -p "results/$sub/example"
  cp results/example/*.dot "results/$sub/example/"
  check_witnesses "$sub"
}

run_learning() {
  echo "=== Learning again every checked-in model"
  require_tool ltscompare "Install mCRL2 or use the Docker image."
  require_tool verilator "Install Verilator or use the Docker image."
  if [ ! -f sancus-core-gap/README.md ]; then
    echo "Regression incomplete: sancus-core-gap is missing. Run: git submodule update --init sancus-core-gap" >&2
    exit 2
  fi
  local sub=regression/learning start end
  rm -rf "results/$sub" "logs/$sub"
  start=$(date +%s)
  if ! ./learn_all.sh "$sub"; then
    echo "Regression incomplete: learn_all.sh failed. See logs/$sub." >&2
    exit 2
  fi
  # The Getting Started example (learn_example.sh always writes to results/example)
  mkdir -p "results/$sub/example" "logs/$sub/example"
  (
    cd "$MM_DIR" || exit 2
    for secret in 0 1; do
      name="bf89c0b-attacker-enclave-$secret-$EPS-$DELTA"
      alvie_run_background "$name" "_build/default/bin/learn.exe --report --att-spec \"$SCRIPT_DIR/spec-lib/example/attacker.atdl\" --encl-spec \"$SCRIPT_DIR/spec-lib/example/enclave.etdl\" --res \"$SCRIPT_DIR/results/$sub/example/$name.dot\" --tmpdir \"$SCRIPT_DIR/tmp/$sub/example\" --commit bf89c0b --sancus \"$SCRIPT_DIR/sancus-core-gap\" --secret $secret --epsilon $EPS --delta $DELTA --oracle pac > \"$SCRIPT_DIR/logs/$sub/example/learn-$name.log\" 2>&1" "$SCRIPT_DIR/logs/$sub/example/learn-$name.log"
    done
    alvie_wait_for_jobs
  ) || { echo "Regression incomplete: learning the example failed. See logs/$sub/example." >&2; exit 2; }
  end=$(date +%s)
  echo "Learning took $((end - start))s with ALVIE_JOBS=$ALVIE_JOBS"
  compare_models results "results/$sub"
  compare_models results/example "results/$sub/example"
  # Learning times in milliseconds: the last field of the statistics line that --report prints at the end of each log
  for log in logs/$sub/learn-*.log logs/$sub/example/learn-*.log; do
    echo "$(basename "$log" .log | sed 's/^learn-//') $(tail -1 "$log" | awk -F', ' '{print $NF}')"
  done | sort -k2 -n -r > "logs/$sub/learning-times.txt"
  echo "Learning times (ms), slowest first, in logs/$sub/learning-times.txt:"
  head -5 "logs/$sub/learning-times.txt"
  check_witnesses "$sub"
}

case "$mode" in
  witnesses) run_witnesses ;;
  learning) run_learning ;;
  all) run_witnesses; run_learning ;;
esac

if [ "$differences" -ne 0 ]; then
  echo "Regression: differences found (see the DIFFERENT lines above)." >&2
  exit 1
fi
echo "Regression: no differences."
