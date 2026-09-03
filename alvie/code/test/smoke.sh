#!/usr/bin/env bash
#
# Short execution smoke tests, for use as a gate while refactoring.
#
# Runs a small subset of the trace-replay suites rather than the whole thing:
# both suites are marked `Slow` and the full matrix takes far too long to sit in
# an edit/build/test loop. The subset is chosen to exercise the paths a refactor
# is most likely to break, namely input generation, code emission, the SUL step
# loop and observation analysis.
#
# Usage:
#   bash test/smoke.sh --sim              # simulator subset
#   bash test/smoke.sh --fpga             # FPGA subset, needs the board
#   bash test/smoke.sh --sim --fpga       # both
#   SMOKE_SIM_GROUPS="b6 b9" bash test/smoke.sh --sim     # override the subset
#
# Prerequisites are checked before anything runs, so a missing toolchain fails
# immediately with an actionable message instead of a confusing test failure.

set -uo pipefail

RUN_SIM=0
RUN_FPGA=0
for arg in "$@"; do
  case "$arg" in
    --sim) RUN_SIM=1 ;;
    --fpga) RUN_FPGA=1 ;;
    *) echo "Usage: $0 [--sim] [--fpga]" >&2; exit 2 ;;
  esac
done

if [ "$RUN_SIM" -eq 0 ] && [ "$RUN_FPGA" -eq 0 ]; then
  echo "Usage: $0 [--sim] [--fpga]" >&2
  exit 2
fi

TEST_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CODE_DIR=$(cd "$TEST_DIR/.." && pwd)
ROOT_DIR=$(cd "$CODE_DIR/../.." && pwd)

# One attack each, not the whole matrix. b6 is the case the FPGA work and the
# recorded benchmarks in AGENTS.md both use, so a regression there is the most
# informative; the FPGA subset adds the paper example because it is quick and
# has committed reference models under results/example-fpga/.
SMOKE_SIM_GROUPS="${SMOKE_SIM_GROUPS:-b6}"
SMOKE_FPGA_GROUPS="${SMOKE_FPGA_GROUPS:-example b6}"

FPGA_PORT="${FPGA_PORT:-/dev/ttyUSB1}"

fail () { echo "$@" >&2; exit 2; }

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
    echo "docs/getting-started.md describes adding the Jammy repository:" >&2
    echo "  sudo apt-get install -y binutils-msp430 gcc-msp430 msp430-libc msp430mcu" >&2
    echo "" >&2
    if [ -d /opt/ti ]; then
      echo "Note: TI's toolchain under /opt/ti uses msp430-elf-* names and does" >&2
      echo "not satisfy the scripts, which invoke msp430-as and msp430-ld." >&2
    fi
    exit 2
  fi
}

status=0

if [ "$RUN_SIM" -eq 1 ]; then
  check_msp430
  command -v verilator >/dev/null 2>&1 || fail "verilator not found on PATH."
  [ -d "$ROOT_DIR/sancus-core-gap" ] || fail "Missing $ROOT_DIR/sancus-core-gap checkout."

  echo "== simulator smoke: $SMOKE_SIM_GROUPS =="
  for group in $SMOKE_SIM_GROUPS; do
    echo "-- tt_attack $group"
    if ! dune exec test/attack.exe -- test --color=never "$group"; then
      echo "simulator smoke FAILED for group $group" >&2
      status=1
    fi
  done
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
      exit 2
    fi
  fi

  echo "== FPGA smoke: $SMOKE_FPGA_GROUPS =="
  for group in $SMOKE_FPGA_GROUPS; do
    echo "-- tt_attack_fpga $group"
    if ! dune exec test/attack_fpga.exe -- test --color=never "$group"; then
      echo "FPGA smoke FAILED for group $group" >&2
      status=1
    fi
  done
fi

if [ "$status" -ne 0 ]; then
  echo "smoke tests FAILED" >&2
  exit 1
fi
echo "smoke tests passed."
