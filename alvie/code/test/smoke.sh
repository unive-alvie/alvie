#!/usr/bin/env bash
#
# Short execution smoke tests, for use as a gate while refactoring.
#
# Two kinds of check per backend:
#
#   1. Trace replay. Groups from the trace-replay suites, which assert exact
#      observations for a fixed input sequence. These catch changes in code
#      emission, the SUL step loop and observation analysis.
#   2. End-to-end learning. Learns the paper example and compares the model
#      against the one committed under results/example[-fpga]/. This is the
#      broader proxy: it exercises TestDL parsing, input generation, L#, the
#      oracle, the SUL and model output together, which trace replay does not.
#
# The full suites pass (tt_attack 38/38, tt_attack_fpga 20/20) but the simulator
# one takes about an hour, so this runs a subset covering the paths a refactor is
# most likely to break. Run the full suites before merging.
#
# Usage:
#   bash test/smoke.sh --sim              # simulator checks
#   bash test/smoke.sh --fpga             # FPGA checks, needs the board
#   bash test/smoke.sh --sim --fpga       # both
#   bash test/smoke.sh --sim --update     # refresh the learned reference models
#
#   SMOKE_SIM_GROUPS="b6 b9" bash test/smoke.sh --sim    # override replay groups
#   SMOKE_SKIP_LEARN=1 bash test/smoke.sh --sim          # replay only
#   SMOKE_SKIP_REPLAY=1 bash test/smoke.sh --sim         # learning only
#
# --update rewrites the committed reference models. Use it only for deliberate
# changes and review the diff: an unexpected change there is exactly the
# regression this is meant to catch.
#
# A warning learned the hard way: these expectations are sensitive to the MSP430
# toolchain. Ubuntu 24.04 ships a binutils-msp430 that apt prefers over jammy's,
# and the two assemble differently, which shifts every cycle count. If
# everything suddenly disagrees, check that msp430-as reports the mspgcc LTS
# 20120406 build before concluding the code is at fault.

set -uo pipefail

RUN_SIM=0
RUN_FPGA=0
UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --sim) RUN_SIM=1 ;;
    --fpga) RUN_FPGA=1 ;;
    --update) UPDATE=1 ;;
    *) echo "Usage: $0 [--sim] [--fpga] [--update]" >&2; exit 2 ;;
  esac
done

if [ "$RUN_SIM" -eq 0 ] && [ "$RUN_FPGA" -eq 0 ]; then
  echo "Usage: $0 [--sim] [--fpga] [--update]" >&2
  exit 2
fi

TEST_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CODE_DIR=$(cd "$TEST_DIR/.." && pwd)
ROOT_DIR=$(cd "$CODE_DIR/../.." && pwd)

# Replay groups. Entries are a group name, or group:index for a single case.
#
# example is the paper case and is also what the learning check below learns, so
# a disagreement between the two localises quickly. b6 is the case the FPGA work
# and the recorded benchmarks both use. b9 covers a reset path the others do not.
#
# The simulator runs part of b6 rather than the whole group only to keep the
# runtime tolerable; every case in both suites passes.
SMOKE_SIM_GROUPS="${SMOKE_SIM_GROUPS:-example b6:0 b6:1}"
SMOKE_FPGA_GROUPS="${SMOKE_FPGA_GROUPS:-example b6 b9}"

SMOKE_SKIP_LEARN="${SMOKE_SKIP_LEARN:-0}"
SMOKE_SKIP_REPLAY="${SMOKE_SKIP_REPLAY:-0}"

FPGA_PORT="${FPGA_PORT:-/dev/ttyUSB1}"

# The learned example: paper running example, PAC oracle, both secrets.
LEARN_COMMIT=bf89c0b
LEARN_EPS=0.01
LEARN_DELTA=0.01

fail () { echo "$@" >&2; exit 2; }

# "b6" -> "b6";  "b6:2" -> "b6 2".  Alcotest takes an optional case index after
# the group name.
split_entry () {
  case "$1" in
    *:*) echo "${1%%:*} ${1#*:}" ;;
    *)   echo "$1" ;;
  esac
}

# Both suites assemble MSP430 programs, so they need the Debian-style binutils
# (msp430-as, msp430-ld), not just TI's msp430-elf-* toolchain.
check_msp430 () {
  local missing=""
  for tool in msp430-gcc msp430-as msp430-ld; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    echo "Missing MSP430 toolchain:$missing" >&2
    echo "" >&2
    echo "These suites assemble MSP430 programs and need the Debian-style" >&2
    echo "binutils. On Ubuntu 24.04 they are not in the default repositories;" >&2
    echo "add the jammy repository, then pin the package:" >&2
    echo "  sudo apt-get install -y binutils-msp430=2.22~msp20120406-5.1 gcc-msp430 msp430-libc msp430mcu" >&2
    echo "  sudo apt-mark hold binutils-msp430" >&2
    echo "" >&2
    if [ -d /opt/ti ]; then
      echo "Note: TI's toolchain under /opt/ti uses msp430-elf-* names and does" >&2
      echo "not satisfy the scripts, which invoke msp430-as and msp430-ld." >&2
    fi
    exit 2
  fi
  # A newer binutils assembles differently and shifts every cycle count, which
  # looks like widespread fixture rot rather than a toolchain problem.
  if ! msp430-as --version 2>&1 | head -1 | grep -q "mspgcc"; then
    echo "WARNING: msp430-as is not the mspgcc build:" >&2
    echo "  $(msp430-as --version 2>&1 | head -1)" >&2
    echo "Cycle counts will not match the committed expectations." >&2
    echo "Install binutils-msp430=2.22~msp20120406-5.1 and hold it." >&2
  fi
}

status=0
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/alvie-smoke.XXXXXX")
cleanup () {
  if [ "$status" -eq 0 ]; then
    rm -rf "$SCRATCH"
  else
    echo "Learned models and logs kept in $SCRATCH" >&2
  fi
}
trap cleanup EXIT

# Runs the trace-replay groups for one backend.
#
# $1 backend label, $2 test executable, $3 space-separated entries
run_replay () {
  local label="$1" exe="$2" entries="$3"
  echo "== $label replay: $entries =="
  local entry
  for entry in $entries; do
    echo "-- $exe $entry"
    # shellcheck disable=SC2086
    if ! dune exec "test/$exe.exe" -- test --color=never $(split_entry "$entry"); then
      echo "$label replay FAILED for $entry" >&2
      status=1
    fi
  done
}

# Learns the paper example on one backend and compares against the committed
# model. This is the end-to-end check.
#
# $1 backend label, $2 extra learn.exe flag, $3 reference directory
run_learn_example () {
  local label="$1" flag="$2" refdir="$3"
  local spec_dir="$ROOT_DIR/spec-lib/example"
  local secret out ref log name

  echo "== $label learning: paper example, secrets 0 and 1 =="

  if [ ! -d "$refdir" ]; then
    echo "  skip: no reference directory $refdir" >&2
    return
  fi

  for secret in 0 1; do
    name="$LEARN_COMMIT-attacker-enclave-$secret-$LEARN_EPS-$LEARN_DELTA"
    out="$SCRATCH/$name.dot"
    ref="$refdir/$name.dot"
    log="$SCRATCH/learn-$label-$secret.log"

    if [ ! -f "$ref" ]; then
      echo "  skip secret $secret: no reference $ref" >&2
      continue
    fi

    # --sancus must be absolute: Verilog.make changes into a temporary
    # directory before cloning the repository.
    if ! dune exec bin/learn.exe -- $flag \
        --att-spec "$spec_dir/attacker.atdl" \
        --encl-spec "$spec_dir/enclave.etdl" \
        --res "$out" \
        --tmpdir "$SCRATCH/tmp-$label-$secret" \
        --commit "$LEARN_COMMIT" \
        --sancus "$ROOT_DIR/sancus-core-gap" \
        --secret "$secret" \
        --epsilon "$LEARN_EPS" --delta "$LEARN_DELTA" \
        --oracle pac > "$log" 2>&1; then
      echo "  FAIL secret $secret: learn.exe failed (see $log)"
      status=1
      continue
    fi

    if [ ! -f "$out" ]; then
      echo "  FAIL secret $secret: no model produced (see $log)"
      status=1
      continue
    fi

    if [ "$UPDATE" -eq 1 ]; then
      if cmp -s "$out" "$ref"; then
        echo "  ok   secret $secret (unchanged, $(wc -l < "$out") lines)"
      else
        cp "$out" "$ref"
        echo "  UPD  secret $secret ($(wc -l < "$out") lines)"
      fi
    elif cmp -s "$out" "$ref"; then
      echo "  ok   secret $secret ($(wc -l < "$out") lines)"
    else
      echo "  FAIL secret $secret: model differs from $ref"
      echo "       produced $(wc -l < "$out") lines, expected $(wc -l < "$ref") lines"
      diff "$ref" "$out" | head -12 | sed 's/^/       /'
      status=1
    fi
  done
}

if [ "$RUN_SIM" -eq 1 ]; then
  check_msp430
  command -v verilator >/dev/null 2>&1 || fail "verilator not found on PATH."
  [ -d "$ROOT_DIR/sancus-core-gap" ] || fail "Missing $ROOT_DIR/sancus-core-gap checkout."

  [ "$SMOKE_SKIP_REPLAY" -eq 1 ] || run_replay "simulator" attack "$SMOKE_SIM_GROUPS"
  [ "$SMOKE_SKIP_LEARN" -eq 1 ] || run_learn_example "simulator" "" "$ROOT_DIR/results/example"
fi

if [ "$RUN_FPGA" -eq 1 ]; then
  check_msp430
  [ -e "$FPGA_PORT" ] || fail "FPGA port $FPGA_PORT not present. Set FPGA_PORT to override."
  [ -r "$FPGA_PORT" ] && [ -w "$FPGA_PORT" ] || fail "No read/write access to $FPGA_PORT."

  # Sancus.Fpga.make refuses to start unless the FTDI latency timer is 1, so
  # check it here and say how to fix it rather than failing deeper in.
  latency_file="/sys/bus/usb-serial/devices/$(basename "$FPGA_PORT")/latency_timer"
  if [ -r "$latency_file" ]; then
    latency=$(cat "$latency_file")
    if [ "$latency" != "1" ]; then
      echo "FTDI latency timer for $(basename "$FPGA_PORT") is $latency, must be 1." >&2
      echo "Set it with:" >&2
      echo "  echo 1 | sudo tee $latency_file" >&2
      echo "A udev rule makes it survive replug:" >&2
      echo "  ACTION==\"add\", SUBSYSTEM==\"usb-serial\", DRIVER==\"ftdi_sio\", ATTR{latency_timer}=\"1\"" >&2
      exit 2
    fi
  fi

  # An Arty S7 holds its bitstream in SRAM and loses it when disconnected. A
  # board with no design returns short reads, which surface as OMaybeDiverge on
  # the first step and OIllegal for everything after. Reprogram before assuming
  # the learner or the analyser is at fault.
  [ "$SMOKE_SKIP_REPLAY" -eq 1 ] || run_replay "FPGA" attack_fpga "$SMOKE_FPGA_GROUPS"
  [ "$SMOKE_SKIP_LEARN" -eq 1 ] || run_learn_example "FPGA" "--fpga" "$ROOT_DIR/results/example-fpga"
fi

if [ "$status" -ne 0 ]; then
  echo "smoke tests FAILED" >&2
  exit 1
fi
echo "smoke tests passed."
