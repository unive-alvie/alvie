---
title: Running on an FPGA
description: ALVIE/Sancus-FPGA, the plugin that runs Sancus on an openMSP430/Sancus board instead of the simulator.
sidebar:
  order: 9
---

ALVIE/Sancus-FPGA is the plugin of Sancus on an FPGA board: it runs the programs of ALVIE/Sancus on the board instead of the Verilator simulator.
Its commands are `alvie sancus-fpga learn`, `compare`, `property`, `exec`, `conformance` and `fixtures`.
It takes the same specs as ALVIE/Sancus, and its models have the inputs and outputs of the simulator's: `alvie sancus-fpga compare` finds their witnesses, and `alvie-model-compare` compares a model of the board with one of the simulator.
A step takes 15 to 30 ms on the board, against about a second in the simulator.

## Requirements

- An Arty S7-50 board, connected over USB.
- An image of the `arty_s7_openmsp430_sancus` project (an openMSP430 with Sancus, instrumented to send a trace over the UART), and Vivado to program it.
- Linux: the serial port runs at 5 Mbaud, which is set with the `termios2` interface of Linux.
- The MSP430 toolchain, as for the simulator (`msp430-as`, `msp430-ld`); Verilator is not needed.
- The `sancus-core-gap` checkout, as for the simulator: the programs are built with the headers and the linker script of the image's commit.

## Images

An image fixes the Sancus commit and how the board records a trace.
ALVIE needs an image whose name contains `inst_number_50`: a breakpoint by instruction number, and a trace of 50 clock cycles.

| Image | Sancus commit | SHA-256 of the bitstream |
| --- | --- | --- |
| `openMSP430_fpga_inst_number_50_ef753b6.bit` | `ef753b6` | `8270dd57894434a9a05e58c2ee84791f47ec830f4904f3d2cc6b3b7fe5272eb3` |
| `openMSP430_fpga_inst_number_50.bit` | `bf89c0b` | `c9f88a18a68b7a84c51062753f7b5f9cf83a62f65a39cd8dba3951788f567b9b` |

A name without a commit is for `bf89c0b`.
The images `inst_number` and `inst_pc` record 10 cycles, or break by program counter: ALVIE does not support them.

## Program the Board

The project's scripts program the board, and check the SHA-256 of the bitstream first.
From the `scripts` directory of the project, we run the script of the image:

```bash
vivado -mode batch -source program_inst_number_50_ef753b6.tcl
```

The board keeps the image until it loses power.
ALVIE cannot ask the board which image it runs, so `--commit` must be the commit of the image.
With another commit, the programs are built for a processor that is not on the board, and the results are wrong without any error.

## Check the Serial Port

The board appears as two serial ports: the first is JTAG, the second the UART.
The UART is usually `/dev/ttyUSB1`, the default of `--fpga-port`.
While Vivado's hardware server runs, the JTAG port disappears, and the UART can become `/dev/ttyUSB0`.

The user that runs ALVIE must be able to open the port, for example by being in the group `dialout`:

```bash
ls -l /dev/ttyUSB1
id -nG
```

The latency timer of the FTDI chip must be 1 ms; with the default of 16 ms, every step waits for it.
ALVIE stops with a message when it is not 1.
We set it until the next reboot with:

```bash
echo 1 | sudo tee /sys/bus/usb-serial/devices/ttyUSB1/latency_timer
```

To set it whenever the board is plugged in, we add a udev rule, for example in `/etc/udev/rules.d/99-ftdi-latency.rules`:

```text
ACTION=="add", SUBSYSTEM=="usb-serial", DRIVER=="ftdi_sio", ATTR{latency_timer}="1"
```

## Run

With the image of `ef753b6` on the board, we check that ALVIE and the board work together, from `alvie/code`:

```bash
_build/default/bin/alvie.exe sancus-fpga conformance --commit ef753b6 \
  --spec ../../spec-lib/example/attacker.atdl --spec ../../spec-lib/example/enclave.etdl --secret 0 \
  --sancus ../../sancus-core-gap --tmpdir /tmp/alvie
```

Every check must say `PASS`.
Then we learn a model of the same spec:

```bash
_build/default/bin/alvie.exe sancus-fpga learn --commit ef753b6 \
  --spec ../../spec-lib/example/attacker.atdl --spec ../../spec-lib/example/enclave.etdl --secret 0 \
  --sancus ../../sancus-core-gap --tmpdir /tmp/alvie --res /tmp/model-fpga-0.dot
```

The fixtures of the plugin are those of ALVIE/Sancus, each for the image of its commit.
We run only the fixtures of the image on the board, by name:

```bash
_build/default/bin/alvie.exe sancus-fpga fixtures --commit ef753b6 \
  --sancus ../../sancus-core-gap --tmpdir /tmp/alvie attack-a-ef753b6
```

With the image of `bf89c0b`, the fixtures are `attack-a-bf89c0b`, `planted-leak` and `safe`.
A fixture sets its own commit, so a fixture of another image runs without an error, and gives a wrong verdict.

The suite `tt_attack_fpga` replays the attack traces of `tt_attack` on the board, which must run the image of `ef753b6`:

```bash
dune exec test/attack_fpga.exe
```

It is not part of CI, since it needs the board.
`ALVIE_FPGA_PORT` gives its serial port.

## Options

The options of `alvie sancus-fpga` are those of `plugins/sancus-fpga/alvie-plugin.yaml`:

| Option | Default | Meaning |
| --- | --- | --- |
| `--commit COMMIT` | required | The commit of the image on the board |
| `--fpga-port PATH` | `/dev/ttyUSB1` | The serial port of the board |
| `--sancus PATH` | required | The `sancus-core-gap` checkout |
| `--tmpdir PATH` | required | Where the programs are built |
| `--sancus-master-key HEX` | `cafe` | The key the image was built with |
| `--keep-repeated-reentries` | | As in ALVIE/Sancus |

The commands have the other options of ALVIE/Core: `--spec`, `--secret`, `--variant no-interrupts`, `--oracle`, `--seed`, and so on (see the [Executables Reference](/alvie/reference/executables-reference/#the-commands-of-a-plugin)).

## How a Step Runs

For each step, ALVIE builds the program of the test, as for the simulator, and sends its program memory and interrupt vectors to the board with a breakpoint: the number of the first instruction of the step.
The board runs the program from reset and sends back the 50 clock cycles from the breakpoint: the program counter, the instruction number, the interrupt and Sancus state, `r4`, `gie`, the counter of Timer A, and a word of unprotected memory.
ALVIE finds the step's instructions in this trace and turns them into observations as it does for the simulator.

If no trace comes within 2 seconds, the program reset or stopped before the breakpoint: ALVIE asks again for the window of the previous instruction.
If no trace comes again, the step diverged (`OMaybeDiverge`).

A query sends the whole program and runs it from reset, so a step does not depend on the previous query, except for the data memory (see below).
Copies of a backend and several ALVIE processes can share a board: their queries take turns on the serial port.

## Differences from the Simulator

The board and the simulator agree on most observations, but not on all of them.
`tt_attack_fpga` lists the attack traces where they differ, and why.

- **The window bounds what the board sees.** An instruction longer than 50 cycles shows `k = 50`: `sancus_enable`, for example, takes 648 cycles in the simulator.
  A reset or a divergence after the end of the window is not seen: the board reports the last instruction in the window.
- **State is read after the instruction.** `r4`, `gie` and the unprotected memory word are read at the first cycle of the next instruction, so a store is visible in its own observation; the simulator reads them before that cycle.
  The counter of Timer A is read in the last cycle of the instruction in both.
- **`r4` can carry over between tests.** The board does not clear its data memory between queries, so `reg_val` can depend on the previous test.
- **Timing.** At the end of the window, cycle counts and the counter of Timer A can differ from the simulator's by one.
