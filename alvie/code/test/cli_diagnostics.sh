#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CODE_DIR="$REPO_ROOT/alvie/code"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/alvie-cli-diagnostics.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

expect_status() {
  local expected_status="$1"
  local expected_text="$2"
  shift 2
  local output="$TMP_DIR/output"
  local actual_status

  if "$@" >"$output" 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi

  if [ "$actual_status" -ne "$expected_status" ] || ! grep -q -- "$expected_text" "$output"; then
    echo "Unexpected diagnostic from: $*" >&2
    cat "$output" >&2
    exit 1
  fi
}

cd "$CODE_DIR"
dune build
dune exec test/diagnostics.exe -- --color=never

expect_status 2 'Unknown --oracle value' \
  _build/default/bin/learn.exe \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --res "$TMP_DIR/model.dot" \
  --tmpdir "$TMP_DIR/learn" \
  --sancus "$TMP_DIR/missing-sancus" \
  --commit bf89c0b \
  --secret 0 \
  --oracle invalid-oracle

mkdir "$TMP_DIR/sancus"
printf 'enclave { nop;\n' >"$TMP_DIR/invalid.etdl"
expect_status 2 'Could not parse the TestDL specifications' \
  _build/default/bin/learn.exe \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec "$TMP_DIR/invalid.etdl" \
  --res "$TMP_DIR/model.dot" \
  --tmpdir "$TMP_DIR/invalid-spec" \
  --sancus "$TMP_DIR/sancus" \
  --commit bf89c0b \
  --secret 0 \
  --oracle randomwalk

expect_status 2 '--step-limit must be greater than zero' \
  _build/default/bin/pbt.exe \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --tmpdir "$TMP_DIR/pbt" \
  --sancus "$TMP_DIR/sancus" \
  --step-limit 0

expect_status 2 'names a file that does not exist' \
  _build/default/bin/fa.exe \
  --tmpdir "$TMP_DIR/fa" \
  --witness-file-basename "$TMP_DIR/fa/witness" \
  --m1-int "$TMP_DIR/missing-0.dot" \
  --m2-int "$TMP_DIR/missing-1.dot"

touch "$TMP_DIR/model-0.dot" "$TMP_DIR/model-1.dot" "$TMP_DIR/model-nint.dot"
expect_status 2 '--m1-nint requires --m2-nint' \
  _build/default/bin/fa.exe \
  --tmpdir "$TMP_DIR/fa" \
  --witness-file-basename "$TMP_DIR/fa/witness" \
  --m1-int "$TMP_DIR/model-0.dot" \
  --m2-int "$TMP_DIR/model-1.dot" \
  --m1-nint "$TMP_DIR/model-nint.dot"

printf 'not a DOT model\n' >"$TMP_DIR/invalid.dot"
expect_status 1 'Raised at\|Raised by\|Called from' \
  _build/default/bin/fa.exe \
  --debug \
  --tmpdir "$TMP_DIR/fa-debug" \
  --witness-file-basename "$TMP_DIR/fa-debug/witness" \
  --m1-int "$TMP_DIR/invalid.dot" \
  --m2-int "$TMP_DIR/invalid.dot"

source "$REPO_ROOT/script_helpers.sh"
alvie_run_background success 'true' "$TMP_DIR/success.log"
alvie_run_background failure 'false' "$TMP_DIR/failure.log"
if alvie_wait_for_jobs; then
  echo "The wrapper job helper accepted a failed job." >&2
  exit 1
fi

expect_status 2 'Usage:' "$REPO_ROOT/check_one.sh"

echo "CLI diagnostics checks passed."
