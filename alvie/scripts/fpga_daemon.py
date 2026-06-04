#!/usr/bin/env python3
"""
Persistent FPGA UART bridge daemon.
Holds the serial port open at 5 Mbaud across queries, eliminating Python startup cost.

Protocol (over stdin/stdout):
  stdin:  one line per query: "<elf_path> <inst_number>\n"
  stdout: 50 trace lines  "pc inst_number irq sm_executing e_state r4 gie timerA umem"
          followed by "DONE\n"
        OR "DIVERGED\nDONE\n" on timeout.
  stderr: debug/error messages (not parsed by OCaml)

Exits when stdin closes.
"""

import sys
import os
import serial as pyserial
from elftools.elf.elffile import ELFFile

def parse_elf(path):
    with open(path, "rb") as f:
        elf = ELFFile(f)
        entry = elf.header.e_entry
        text = None
        vectors = None
        for section in elf.iter_sections():
            if section.name == ".text":
                text = {"data": section.data(), "start": section["sh_addr"]}
            elif section.name == ".vectors":
                vectors = {"data": section.data(), "start": section["sh_addr"]}
        return text, vectors

def swap_bytes(data):
    if len(data) % 2 != 0:
        data = data + b'\x00'
    result = bytearray(len(data))
    result[0::2] = data[1::2]
    result[1::2] = data[0::2]
    return bytes(result)

def build_payload(text_data, vec_data, inst_number):
    pmem = swap_bytes(text_data)
    irq  = swap_bytes(vec_data)
    pmem_len = len(pmem).to_bytes(2, byteorder='little')
    irq_len  = len(irq).to_bytes(2, byteorder='little')
    inst_bytes = inst_number.to_bytes(2, byteorder='little')
    return b'\xff' + pmem_len + pmem + irq_len + irq + inst_bytes

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"

    try:
        ser = pyserial.Serial(
            port=port,
            baudrate=5000000,
            bytesize=pyserial.EIGHTBITS,
            parity=pyserial.PARITY_NONE,
            stopbits=pyserial.STOPBITS_ONE,
            timeout=2.0,
        )
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # Signal that the port is open and daemon is ready for queries
    print("READY")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            print(f"ERROR: bad query line: {line!r}", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue

        elf_path, inst_str = parts[0], parts[1]
        inst_number = int(inst_str)

        # Always re-parse: pmem.elf path stays the same each step but content changes
        try:
            text, vectors = parse_elf(elf_path)
        except Exception as e:
            print(f"ERROR: ELF parse failed: {e}", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue
        if text is None or vectors is None:
            print("ERROR: missing .text or .vectors", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue

        payload = build_payload(text["data"], vectors["data"], inst_number)

        ser.reset_input_buffer()
        ser.write(payload)
        raw = ser.read(800)

        if len(raw) < 800:
            print("DIVERGED")
        else:
            tmp = list(raw)
            for i in range(50):
                b = tmp[i * 16:(i + 1) * 16]
                pc           = (b[0]  << 8) | b[1]
                irq_val      = b[2] & 0x1
                sm_executing = b[3] & 0x1
                gie          = b[4] & 0x1
                inst_number_r= (b[5] << 24) | (b[6] << 16) | (b[7] << 8) | b[8]
                e_state      = b[9] & 0x1f
                r4           = (b[10] << 8) | b[11]
                timerA       = (b[12] << 8) | b[13]
                umem         = (b[14] << 8) | b[15]
                print(f"{pc} {inst_number_r} {irq_val} {sm_executing} {e_state} {r4} {gie} {timerA} {umem}")

        print("DONE")
        sys.stdout.flush()

    ser.close()

if __name__ == "__main__":
    main()
