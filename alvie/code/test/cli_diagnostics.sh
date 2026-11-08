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

# A --sancus directory that is not a git checkout (e.g., the submodule was never initialized)
expect_status 1 'Could not clone Sancus repository from .* Check that it is a git checkout' \
  _build/default/bin/learn.exe \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --res "$TMP_DIR/model.dot" \
  --tmpdir "$TMP_DIR/not-a-checkout" \
  --sancus "$TMP_DIR/sancus" \
  --commit bf89c0b \
  --secret 0 \
  --oracle randomwalk

# A checkout that lacks the requested commit (e.g., a shallow clone)
git init -q "$TMP_DIR/shallow-sancus"
git -C "$TMP_DIR/shallow-sancus" -c user.name=ALVIE -c user.email=alvie@example.invalid commit -q --allow-empty -m init
expect_status 1 'Could not check out Sancus commit bf89c0b .* fetch --unshallow' \
  _build/default/bin/learn.exe \
  --att-spec ../../spec-lib/example/attacker.atdl \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --res "$TMP_DIR/model.dot" \
  --tmpdir "$TMP_DIR/missing-commit" \
  --sancus "$TMP_DIR/shallow-sancus" \
  --commit bf89c0b \
  --secret 0 \
  --oracle randomwalk

expect_status 2 '--test-count must be greater than zero' \
  _build/default/bin/pbt.exe \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --tmpdir "$TMP_DIR/pbt" \
  --sancus "$TMP_DIR/sancus" \
  --test-count 0

expect_status 2 'Use either --test-count or deprecated --step-limit, not both' \
  _build/default/bin/pbt.exe \
  --encl-spec ../../spec-lib/example/enclave.etdl \
  --att-spec1 ../../spec-lib/example/attacker.atdl \
  --att-spec2 ../../spec-lib/example/attacker.atdl \
  --tmpdir "$TMP_DIR/pbt-both-options" \
  --sancus "$TMP_DIR/sancus" \
  --test-count 1 \
  --step-limit 1

expect_status 0 'Deprecated alias for --test-count' \
  _build/default/bin/pbt.exe --help

expect_status 0 'Equivalence oracle:' \
  _build/default/bin/learn.exe --help

if _build/default/bin/learn.exe --help 2>&1 | grep -q -- 'pacprefix'; then
  echo 'learn.exe --help still advertises the removed pacprefix oracle' >&2
  exit 1
fi

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
# A file that is not a model: a mistake in the command, said as such
expect_status 2 'cannot read --m1-int (.*invalid.dot): .*parse error' \
  _build/default/bin/fa.exe \
  --debug \
  --tmpdir "$TMP_DIR/fa-debug" \
  --witness-file-basename "$TMP_DIR/fa-debug/witness" \
  --m1-int "$TMP_DIR/invalid.dot" \
  --m2-int "$TMP_DIR/invalid.dot" \
  --secrets 0,1

expect_status 2 'Cannot tell the secrets of the models from their names: give them with --secrets s1,s2' \
  _build/default/bin/fa.exe \
  --tmpdir "$TMP_DIR/fa" \
  --witness-file-basename "$TMP_DIR/fa/witness" \
  --m1-int "$TMP_DIR/invalid.dot" \
  --m2-int "$TMP_DIR/invalid.dot"

# A model of a format this ALVIE does not know: a clear error, not a crash
printf '// alvie-model format 99; plugin sancus 2099.01; core 9\ndigraph G {\n}\n' >"$TMP_DIR/future.dot"
expect_status 2 'made by a newer ALVIE' \
  _build/default/bin/fa.exe \
  --tmpdir "$TMP_DIR/fa" \
  --witness-file-basename "$TMP_DIR/fa/witness" \
  --m1-int "$TMP_DIR/future.dot" \
  --m2-int "$TMP_DIR/future.dot" \
  --secrets 0,1

# The alvie command: the plugin files, the options generated from the manifest, alvie property
expect_status 0 'OK: plugin sancus' _build/default/bin/alvie.exe plugin check
expect_status 0 'OK: plugin toy' _build/default/bin/alvie.exe plugin check test/fixtures/toy
mkdir -p "$TMP_DIR/bad-plugin"
cp test/fixtures/toy/*.yaml "$TMP_DIR/bad-plugin/"
printf 'name: toy\nversion: yes\n' >"$TMP_DIR/bad-plugin/alvie-plugin.yaml"
expect_status 2 'ALVIE error: the plugin has' _build/default/bin/alvie.exe plugin check "$TMP_DIR/bad-plugin"
expect_status 0 'wrote .*sancus-atoms.values.schema.json' _build/default/bin/alvie.exe plugin schemas "$TMP_DIR/schemas"
expect_status 0 '--keep-repeated-reentries' _build/default/bin/alvie.exe learn -help
expect_status 0 '--sancus path' _build/default/bin/alvie.exe learn -help
expect_status 2 'M1 names a file that does not exist' \
  _build/default/bin/alvie.exe property inclusion "$TMP_DIR/missing.dot" "$TMP_DIR/future.dot" --tmpdir "$TMP_DIR/property"
expect_status 2 'made by a newer ALVIE' \
  _build/default/bin/alvie.exe property equivalence "$TMP_DIR/future.dot" "$TMP_DIR/future.dot" --tmpdir "$TMP_DIR/property"
expect_status 2 '--formula names a file that does not exist' \
  _build/default/bin/alvie.exe property formula "$REPO_ROOT/results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot" \
  --formula "$TMP_DIR/missing.mcf" --tmpdir "$TMP_DIR/property"

# The commands of Core on a native plugin (alvie tiny): the spec, the options of the manifest, models, fixtures
TINY=plugins/tiny/fixtures
expect_status 2 'the spec uses the secret (?): give its value with --secret' \
  _build/default/bin/alvie.exe tiny learn --spec "$TINY/leak-time.spec" --res "$TMP_DIR/tiny.dot"
expect_status 2 '--variant fast: plugin tiny has the variants no-interrupts' \
  _build/default/bin/alvie.exe tiny learn --spec "$TINY/leak-time.spec" --secret 0 --variant fast --res "$TMP_DIR/tiny.dot"
expect_status 1 'is not one of none or constant-time' \
  _build/default/bin/alvie.exe tiny learn --spec "$TINY/leak-time.spec" --secret 0 --mitigation fast --res "$TMP_DIR/tiny.dot"
expect_status 2 'cannot use "7" as the secret' \
  _build/default/bin/alvie.exe tiny learn --spec "$TINY/leak-time.spec" --secret 7 --res "$TMP_DIR/tiny.dot"
printf 'prepare { call };\nenclave { mov r9, 1; ret };\n' >"$TMP_DIR/bad.spec"
expect_status 2 'bad.spec:2:' _build/default/bin/alvie.exe tiny learn --spec "$TMP_DIR/bad.spec" --res "$TMP_DIR/tiny.dot"
expect_status 0 'Learned a model' _build/default/bin/alvie.exe tiny learn --spec "$TINY/leak-time.spec" --secret 0 --res "$TMP_DIR/tiny.dot"
expect_status 2 'is a model of plugin tiny, not of sancus' \
  _build/default/bin/alvie.exe property equivalence "$TMP_DIR/tiny.dot" "$TMP_DIR/tiny.dot" --tmpdir "$TMP_DIR/property"
expect_status 2 '--secrets takes the two values of the secret' \
  _build/default/bin/alvie.exe tiny compare --m1 "$TMP_DIR/tiny.dot" --m2 "$TMP_DIR/tiny.dot" --secrets 0 --witnesses "$TMP_DIR/w.dot"
expect_status 2 'is a model of plugin sancus, not of tiny' \
  _build/default/bin/alvie.exe tiny compare --m1 "$REPO_ROOT/results/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot" --m2 "$TMP_DIR/tiny.dot" --secrets 0,1 --witnesses "$TMP_DIR/w.dot"
printf 'timer 1\ncall\nmov r0, 0\nhalt\n' >"$TMP_DIR/inputs.txt"
expect_status 2 'inputs.txt:4: the spec does not allow halt here (in isr); it allows: reti' \
  _build/default/bin/alvie.exe tiny exec --spec "$TINY/leak-time.spec" --secret 0 --inputs "$TMP_DIR/inputs.txt"
expect_status 2 'there is no fixture nope in plugins/tiny/fixtures' _build/default/bin/alvie.exe tiny fixtures nope --out "$TMP_DIR/fx"
printf 'format: 1\nspec: leak-time.spec\nsecrets: [0, 0]\nexpect: leak\n' >"$TMP_DIR/fixtures-bad.yaml"
mkdir -p "$TMP_DIR/fixtures" && mv "$TMP_DIR/fixtures-bad.yaml" "$TMP_DIR/fixtures/bad.yaml"
expect_status 2 'secrets: give two different values of the secret' _build/default/bin/alvie.exe tiny fixtures --dir "$TMP_DIR/fixtures" --out "$TMP_DIR/fx"
expect_status 2 '--tests must be greater than zero' _build/default/bin/alvie.exe tiny conformance --spec "$TINY/leak-time.spec" --secret 0 --tests 0
expect_status 0 'PASS clone' _build/default/bin/alvie.exe tiny conformance --spec "$TINY/leak-time.spec" --secret 0 --tests 5

source "$REPO_ROOT/script_helpers.sh"
alvie_run_background success 'true' "$TMP_DIR/success.log"
alvie_run_background failure 'false' "$TMP_DIR/failure.log"
if alvie_wait_for_jobs; then
  echo "The wrapper job helper accepted a failed job." >&2
  exit 1
fi

expect_status 2 'Usage:' "$REPO_ROOT/check_one.sh"

echo "CLI diagnostics checks passed."
