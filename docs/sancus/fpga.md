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
- The image of the Sancus commit (see [Images](#images)), and Vivado to program the board with it.
- Linux: the serial port runs at 5 Mbaud, which is set with the `termios2` interface of Linux.
- The MSP430 toolchain, as for the simulator (`msp430-as`, `msp430-ld`); Verilator is not needed.
- The `sancus-core-gap` checkout, as for the simulator: the programs are built with the memory sizes and the linker script of the image's commit, which ALVIE reads from the checkout without cloning it.

## Images

An image is the bitstream of the board for one Sancus commit: an openMSP430 with that commit's Sancus core, and the logic that runs a query and sends its trace.
`alvie/fpga/images` has an image for each commit of the experiments of `learn_all.sh`, compressed with gzip:

| Sancus commit | Image | SHA-256 of the bitstream (uncompressed) |
| --- | --- | --- |
| `ef753b6` | `inst_number_50_ef753b6.bit.gz` | `a042472d3ee9f42c8bac72d8e9af7803a07fbbe83751083e422647cbb9e794db` |
| `e8cf011` (fix of B1) | `inst_number_50_e8cf011.bit.gz` | `d404b163748bccf52ab082a8808807147e76cd1dfaab1117106b8c75dc21bac5` |
| `3170d5d` (fix of B2) | `inst_number_50_3170d5d.bit.gz` | `c72770d7e1bb0b08f128bc190408b2a79e56fb964603a2e1d0fd89aa4019ee65` |
| `6475709` (fix of B3) | `inst_number_50_6475709.bit.gz` | `eb3992a94d101de44f0b5d71265a2a48a42b693dab9af626ccd0e929b6669358` |
| `3636536` (fix of B4) | `inst_number_50_3636536.bit.gz` | `1da80c4df0f8b79756a6ef6f846ecd8d802df68d727917bfcfa9f6ada881d5aa` |
| `d54f031` (fix of B6) | `inst_number_50_d54f031.bit.gz` | `669241632c2418627ef5e95c54aea41e7a7cdbaa421e3c01e4035447f7373860` |
| `bf89c0b`, and `264f135` (fix of B7) | `inst_number_50_bf89c0b.bit.gz` | `7df7abc941dddf7a97723e814f220463dd4c573f62767e74af6aec922e44f5d0` |

`264f135` and `bf89c0b` have the same core (`git diff 264f135 bf89c0b -- core/rtl/verilog` is empty), so the image of `bf89c0b` runs both.
All images break by instruction number and record 50 clock cycles (`inst_number_50`), as ALVIE needs.

An image says which commit it runs.
When a command starts, ALVIE asks the image, and stops with an error when the image runs another commit than `--commit`, unless the two commits have the same core in the `--sancus` checkout.
The earlier images (`openMSP430_fpga_inst_number_50_ef753b6.bit` and `openMSP430_fpga_inst_number_50.bit`, the second for `bf89c0b`) do not say it: ALVIE then shows a warning, and `--commit` must be the commit of the image.
With another commit, the programs are built for a processor that is not on the board, and the results are wrong without an error.

## Program the Board

`alvie/scripts/program_fpga.tcl` programs the board with an image.
It takes a commit, for the image of `alvie/fpga/images`, or a bitstream (`.bit` or `.bit.gz`).
It checks the SHA-256 of the bitstream first, refuses a file that is not a known image, and prints the commit of the image.
From `alvie/code`, we program the board with the image of `bf89c0b`:

```bash
vivado -mode batch -nojournal -nolog -source ../scripts/program_fpga.tcl -tclargs bf89c0b
```

The script ends with the commit to give to ALVIE:

```text
--- Programmed with image inst_number_50_bf89c0b: run alvie sancus-fpga with --commit bf89c0b ---
```

The board keeps the image until it loses power.

## Build an Image

The images are built with Vivado from the board project (`arty_s7_openmsp430_sancus`, branch `custom-debug`), which is not public.
Its `scripts/sancus_core.sh` exports the core of a commit of `sancus-core-gap` as ALVIE's simulator configures it (security 20, key `cafe`, reset on violation, Nemesis-resistant), and `scripts/build.tcl` builds the bitstream:

```bash
scripts/sancus_core.sh ../sancus-core-gap e8cf011 build/core-e8cf011
cd scripts && vivado -mode batch -nojournal -source build.tcl -tclargs ../build/e8cf011.bit 50 1 ../build/core-e8cf011 Default
```

The arguments are the bitstream, the window (50), the trigger (1: by instruction number), the core and the placement directive of `place_design`.
A build takes about 7 minutes; three builds at a time need more than 15 GB of memory.

**An image is accepted only if it passes `tt_stress_fpga`.**
The Sancus core has combinational loops (e.g., in the crypto of `sancus_enable`), which timing analysis does not cover.
On the board, their result depends on where Vivado places the logic, and some builds do not run `sancus_enable` reliably: the board does not answer some of the queries after it, at random (often a third of them).
The timing reports of these builds are as good as the others', so only a test on the board finds them.
`tt_stress_fpga` runs 12 programs that create an enclave, with each breakpoint from the first after the boot code to the end of the program, 20 times each, and requires the same answer every time:

```bash
dune exec test/stress_fpga.exe
```

It takes 1 to 2 minutes and ends with `PASS` or `FAIL`.
When a build fails, we build it again with another directive: `Default` and `Explore` give the same placement for this design, `ExtraNetDelay_high` another.
Of the images above, `3170d5d` and `bf89c0b` failed with `Default` and passed with `ExtraNetDelay_high`; the others passed with `Default`.

Then we check that the board learns the models of the simulator: `alvie sancus-fpga learn` of each model of `results/` for the commit, compared with the checked-in model except for `k` of `create` (see [Differences from the Simulator](#differences-from-the-simulator)), and `tt_attack_fpga` for `ef753b6` and `bf89c0b`.
A new image goes into `alvie/fpga/images` (`gzip -9n`), with its SHA-256 in `program_fpga.tcl` and in the table above.

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

The suite `tt_attack_fpga` replays the attack traces of `tt_attack` on the board, for the commit of its image, `ef753b6` or `bf89c0b`:

```bash
dune exec test/attack_fpga.exe
```

It is not part of CI, since it needs the board, and neither is `tt_stress_fpga` (see [Build an Image](#build-an-image)).
`ALVIE_FPGA_PORT` gives their serial port, and `ALVIE_FPGA_COMMIT` the commit of an image that does not say it.

## Options

The options of `alvie sancus-fpga` are those of `plugins/sancus-fpga/alvie-plugin.yaml`:

| Option | Default | Meaning |
| --- | --- | --- |
| `--commit COMMIT` | required | The Sancus commit: that of the image on the board, or one with the same core |
| `--fpga-port PATH` | `/dev/ttyUSB1` | The serial port of the board |
| `--sancus PATH` | required | The `sancus-core-gap` checkout |
| `--tmpdir PATH` | required | Where the programs are built |
| `--sancus-master-key HEX` | `cafe` | The key the image was built with |
| `--keep-repeated-reentries` | | As in ALVIE/Sancus |

The commands have the other options of ALVIE/Core: `--spec`, `--secret`, `--variant no-interrupts`, `--oracle`, `--seed`, and so on (see the [Executables Reference](/alvie/reference/executables-reference/#the-commands-of-a-plugin)).

## How a Step Runs

For each step, ALVIE builds the program of the test, as for the simulator, and sends its program memory and interrupt vectors to the board with a breakpoint: the number of the first instruction of the step.
On the board, every program starts by clearing the variables of the test template (`DMEM_240` to `DMEM_26E`): the board does not clear its data memory between queries, and the simulator starts each step with it cleared.
The board runs the program from reset and sends back the 50 clock cycles from the breakpoint: the program counter, the instruction number, the interrupt and Sancus state, `r4`, `gie`, the counter of Timer A, and a word of unprotected memory.
ALVIE finds the step's instructions in this trace and reads them as the simulator reads its trace: `r4`, `gie` and Timer A in the last cycle of each instruction, the memory word in the first cycle of the next one (where the simulator already sees a store), and a reset when the window goes on after an instruction but the next instruction never comes (the instruction numbers start again from 0).
When the step's code is not in the window and the program has not ended (no end-of-test sentinel, no reset), ALVIE asks for the next window, from the last instruction of the trace.

The board answers in 2 to 5 ms. If no trace comes within 50 ms, the program reset or stopped before the breakpoint: ALVIE asks again for the window of the previous instruction.
If no trace comes again, the step diverged (`OMaybeDiverge`).

The simulator stops a run after 10000 clock cycles (500 µs at 20 MHz, the timeout of ALVIE's testbench), and reports a step whose code did not run as diverged.
On the board, a step diverged when its windows reach 10000 cycles without the step's code and without the end of the program.

A query sends the whole program, runs it from reset and clears the data memory first, so a step does not depend on the previous query.
Copies of a backend and several ALVIE processes can share a board: their queries take turns on the serial port.

`alvie sancus-fpga learn` has the option `--bad-probability`, with the default of `learn.exe` (0.2): the oracle offers an input outside the spec with this probability.
Learning on Sancus needs these inputs to finish (see issue #63).

## Differences from the Simulator

With the same settings, the board learns the models of the simulator, except for the number of cycles `k` of `create`.
On the 72 experiments of `learn_all.sh` that the two images can run, the models are the same up to that `k`, and the witnesses are the same.

- **The window bounds what the board sees.** An instruction longer than 50 cycles shows `k = 50`: `sancus_enable` (the instruction of `create`) takes 648 cycles in the simulator.
  `k` is not part of what the attacker observes (`view.yaml`), so the witnesses of a comparison do not depend on it.
  A reset right after an instruction cut by the end of the window is not seen.
- **The simulator's timeout.** The simulator counts its 10000 cycles from the start of the program, the board from the step's breakpoint; the tests of the experiments stay far below it unless they loop.
