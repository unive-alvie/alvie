#!/usr/bin/env bash
#
# Replays every tracked model comparison through fa.exe and byte-compares the
# resulting witness against the counterexample checked into the repository.
#
# This is the deterministic regression gate for the analysis layer. It needs
# only the built fa.exe and mCRL2; it does not need Verilator, the FPGA board,
# or a sancus-core-gap checkout, because it consumes learned models that are
# already committed.
#
# Usage:
#   bash test/fa_regression.sh            # all tracked cases
#   bash test/fa_regression.sh --fast     # small cases only, for inner loops
#   bash test/fa_regression.sh --update   # overwrite the tracked witnesses
#
# --update exists for deliberate changes to the analysis layer, where the new
# witnesses are the intended result. Review the resulting diff before committing:
# an unexpected change there is exactly the regression this harness is meant to
# catch.
#
# Witnesses are written to a scratch directory. The tracked files under
# counterexamples/ are read but never modified.
#
# Comparison is exact, byte for byte. The committed witnesses are stored exactly
# as fa.exe emits them, so any difference at all is a real change in behaviour.

set -uo pipefail

FAST=0
UPDATE=0
if [ "$#" -gt 0 ]; then
  case "$1" in
    --fast) FAST=1 ;;
    --update) UPDATE=1 ;;
    *) echo "Usage: $0 [--fast|--update]" >&2; exit 2 ;;
  esac
fi

TEST_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CODE_DIR=$(cd "$TEST_DIR/.." && pwd)
ROOT_DIR=$(cd "$CODE_DIR/../.." && pwd)

RES_DIR="$ROOT_DIR/results"
CEX_DIR="$ROOT_DIR/counterexamples"
FA="$CODE_DIR/_build/default/bin/fa.exe"

# Small cases, used by --fast. The excluded ones (b1, b3, b4) carry the
# largest witnesses and dominate the runtime.
FAST_CASES="a b2 b6 b7 b8 b9"

if [ ! -x "$FA" ]; then
  echo "fa.exe not built at $FA; run 'dune build' first." >&2
  exit 2
fi

for tool in ltscompare tracepp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required mCRL2 tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

passed=0
failed=0
skipped=0
failed_cases=""

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/alvie-fa-regression.XXXXXX")
mkdir -p "$SCRATCH/tmp" "$SCRATCH/out" "$SCRATCH/logs"

# Keep the scratch directory when something fails, so the produced witnesses and
# fa.exe logs can be inspected.
cleanup () {
  if [ "$failed" -eq 0 ]; then
    rm -rf "$SCRATCH"
  else
    echo "Produced witnesses and logs kept in $SCRATCH" >&2
  fi
}
trap cleanup EXIT

# Compares one produced witness against its tracked counterpart.
#
# $1 case label, $2 produced file, $3 expected file, $4 log file
check_result () {
  local label="$1" produced="$2" expected="$3" log="$4"
  local violations

  if [ ! -f "$produced" ]; then
    echo "  FAIL $label: fa.exe produced no witness (see $log)"
    failed=$((failed + 1))
    failed_cases="$failed_cases $label"
    return
  fi

  violations=$(grep -o 'found [0-9]* FA violations' "$log" | tail -1 | grep -o '[0-9]*')
  : "${violations:=?}"

  if [ "$UPDATE" -eq 1 ]; then
    mkdir -p "$(dirname "$expected")"
    if cmp -s "$produced" "$expected"; then
      echo "  ok   $label (unchanged, $violations violations)"
    else
      cp "$produced" "$expected"
      echo "  UPD  $label ($violations violations, $(wc -l < "$produced") lines)"
    fi
    passed=$((passed + 1))
    return
  fi

  if cmp -s "$produced" "$expected"; then
    echo "  ok   $label ($violations violations, $(wc -l < "$produced") lines)"
    passed=$((passed + 1))
  else
    echo "  FAIL $label: witness differs from $expected"
    echo "       produced $(wc -l < "$produced") lines, expected $(wc -l < "$expected") lines"
    failed=$((failed + 1))
    failed_cases="$failed_cases $label"
  fi
}

echo "Replaying tracked comparisons through fa.exe"
echo "  models:    $RES_DIR"
echo "  witnesses: $CEX_DIR"
[ "$FAST" -eq 1 ] && echo "  mode:      fast subset ($FAST_CASES)"
[ "$UPDATE" -eq 1 ] && echo "  mode:      UPDATE, tracked witnesses will be overwritten"
echo

# Four-model cases: secret 0 and 1, each with and without interrupts.
shopt -s nullglob
for m1 in "$RES_DIR"/*-0-0.01-0.01-int.dot; do
  base=$(basename "$m1" .dot)
  commit=${base:0:7}
  rest=${base#*-}
  specbn=${rest%%-*}
  label="$commit-$specbn"

  if [ "$FAST" -eq 1 ] && ! echo " $FAST_CASES " | grep -q " $specbn "; then
    continue
  fi

  m1_base=$(basename "$m1")
  m2_base=${m1_base/-0-0.01-0.01-int/-1-0.01-0.01-int}
  m1n_base=${m1_base/-0-0.01-0.01-int/-0-0.01-0.01-nint}
  m2n_base=${m1_base/-0-0.01-0.01-int/-1-0.01-0.01-nint}

  m2="$RES_DIR/$m2_base"
  m1_nint="$RES_DIR/$m1n_base"
  m2_nint="$RES_DIR/$m2n_base"
  expected="$CEX_DIR/$specbn/${commit}-${specbn}_int.dot"

  missing=""
  for f in "$m2" "$m1_nint" "$m2_nint" "$expected"; do
    [ -f "$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    echo "  skip $label: missing$missing"
    skipped=$((skipped + 1))
    continue
  fi

  log="$SCRATCH/logs/$label.log"
  "$FA" --tmpdir "$SCRATCH/tmp" \
    --m1-int "$m1" --m2-int "$m2" \
    --m1-nint "$m1_nint" --m2-nint "$m2_nint" \
    --witness-file-basename "$SCRATCH/out/$label" \
    --debug > "$log" 2>&1

  check_result "$label" "$SCRATCH/out/${label}_int.dot" "$expected" "$log"
done

# Two-model example case: no no-interrupt models, so no witness subtraction.
if [ "$FAST" -eq 0 ]; then
  ex_m1="$RES_DIR/example/bf89c0b-attacker-enclave-0-0.01-0.01.dot"
  ex_m2="$RES_DIR/example/bf89c0b-attacker-enclave-1-0.01-0.01.dot"
  ex_expected="$CEX_DIR/example/bf89c0b-attacker_int.dot"

  if [ -f "$ex_m1" ] && [ -f "$ex_m2" ] && [ -f "$ex_expected" ]; then
    log="$SCRATCH/logs/example.log"
    "$FA" --tmpdir "$SCRATCH/tmp" \
      --m1-int "$ex_m1" --m2-int "$ex_m2" \
      --witness-file-basename "$SCRATCH/out/bf89c0b-attacker" \
      --debug > "$log" 2>&1
    check_result "bf89c0b-attacker" "$SCRATCH/out/bf89c0b-attacker_int.dot" "$ex_expected" "$log"
  else
    echo "  skip bf89c0b-attacker: example models or witness missing"
    skipped=$((skipped + 1))
  fi
fi
shopt -u nullglob

echo
echo "passed $passed, failed $failed, skipped $skipped"
if [ "$failed" -ne 0 ]; then
  echo "failing cases:$failed_cases" >&2
  exit 1
fi
if [ "$passed" -eq 0 ]; then
  echo "No cases ran; check that results/ and counterexamples/ are populated." >&2
  exit 2
fi
echo "fa.exe regression checks passed."
