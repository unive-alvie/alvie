#!/usr/bin/env bash
# alvie property on checked-in models: needs mCRL2 (lts2pbes, pbes2bool, ltscompare), as tt_properties does.
# Each check gives the expected exit status (0: holds, 4: does not hold) and a line of the output.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/alvie-property.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$REPO_ROOT/alvie/code"
dune build bin/alvie.exe
ALVIE=_build/default/bin/alvie.exe
R="$REPO_ROOT/results"
B1="$R/bf89c0b-b1-enclave-complete"

expect() {
  local expected_status="$1" expected_text="$2" status=0
  shift 2
  "$@" >"$TMP_DIR/output" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ] || ! grep -q -- "$expected_text" "$TMP_DIR/output"; then
    echo "Unexpected result (exit $status, expected $expected_status) from: $*" >&2
    cat "$TMP_DIR/output" >&2
    exit 1
  fi
}

T=(--tmpdir "$TMP_DIR/mcrl2")

# A model is equivalent to itself and included in itself
expect 0 'holds: .* have the same traces' $ALVIE property equivalence "$B1-0-0.01-0.01-int.dot" "$B1-0-0.01-0.01-int.dot" "${T[@]}"
expect 0 'holds: every trace' $ALVIE property inclusion "$B1-1-0.01-0.01-nint.dot" "$B1-1-0.01-0.01-nint.dot" "${T[@]}"
# B1 tells the secrets apart (with interrupts): a trace of one model only, with what the attacker sees
expect 4 'does not hold: a trace of .*-0-0.01-0.01-int.dot that' \
  $ALVIE property inclusion "$B1-0-0.01-0.01-int.dot" "$B1-1-0.01-0.01-int.dot" "${T[@]}"
expect 4 'does not hold: a trace of .* only' \
  $ALVIE property equivalence "$B1-0-0.01-0.01-int.dot" "$B1-1-0.01-0.01-int.dot" "${T[@]}"

# Formulas
echo 'true' >"$TMP_DIR/true.mcf"
echo '[true*]false' >"$TMP_DIR/no-step.mcf"
echo '<true>true' >"$TMP_DIR/a-step.mcf"
expect 0 'holds: .* satisfies' $ALVIE property formula "$B1-0-0.01-0.01-int.dot" --formula "$TMP_DIR/true.mcf" "${T[@]}"
expect 0 'holds: .* satisfies' $ALVIE property formula "$B1-0-0.01-0.01-int.dot" -f "$TMP_DIR/a-step.mcf" "${T[@]}"
expect 4 'does not hold: .* does not satisfy' $ALVIE property formula "$B1-0-0.01-0.01-int.dot" -f "$TMP_DIR/no-step.mcf" "${T[@]}"
# With --debug the files of mCRL2 stay, and actions.txt names the actions of the labels
expect 0 'The files of mCRL2 are in' $ALVIE property formula "$B1-0-0.01-0.01-int.dot" -f "$TMP_DIR/true.mcf" "${T[@]}" --debug
dir=$(sed -n 's/^The files of mCRL2 are in \(.*\) (actions.txt.*/\1/p' "$TMP_DIR/output")
grep -q 'timer_enable' "$dir/actions.txt" || { echo "actions.txt does not list the labels: $dir" >&2; exit 1; }
# A formula that mCRL2 rejects: an error that says where its log is
echo '<undeclared_action>true' >"$TMP_DIR/bad.mcf"
expect 2 'lts2pbes failed with exit code' $ALVIE property formula "$B1-0-0.01-0.01-int.dot" -f "$TMP_DIR/bad.mcf" "${T[@]}"

echo "alvie property checks passed."
