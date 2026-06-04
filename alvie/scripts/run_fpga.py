#!/usr/bin/env python3

import argparse
import sys
import time
import serial as pyserial
from elftools.elf.elffile import ELFFile

def parse_elf(path: str):
    with open(path, "rb") as f:
        elf = ELFFile(f)
        entry = elf.header.e_entry

        text = None
        vectors = None

        for section in elf.iter_sections():
            if section.name == ".text":
                text = {
                    "data": section.data(),
                    "start": section["sh_addr"],
                    "offset": section["sh_addr"] - entry,
                }
            elif section.name == ".vectors":
                vectors = {
                    "data": section.data(),
                    "start": section["sh_addr"],
                    "offset": section["sh_addr"] - entry,
                }

        return entry, text, vectors

def swap_bytes(data: list) -> list:
    if len(data) % 2 != 0:
        data.append(0x00)
    swapped = [0] * len(data)
    swapped[0::2] = data[1::2]
    swapped[1::2] = data[0::2]
    return swapped

def main():
    parser = argparse.ArgumentParser(description="Upload ELF to Sancus FPGA via custom UART and dump traces")
    parser.add_argument("elf_file", help="ELF file to load")
    parser.add_argument("--inst-number", required=True, type=int, help="Instruction number breakpoint (inst_number firmware mode)")
    parser.add_argument("--port", default="/dev/ttyUSB1", help="Serial port")
    parser.add_argument("--baudrate", default=5000000, type=int, help="Baud rate")
    args = parser.parse_args()

    # Parse ELF
    entry, text, vectors = parse_elf(args.elf_file)
    if not text:
        print("ERROR: No .text section found in ELF", file=sys.stderr)
        sys.exit(1)
    if not vectors:
        print("ERROR: No .vectors section found in ELF", file=sys.stderr)
        sys.exit(1)

    # Connect to serial port
    try:
        ser = pyserial.Serial(
            port=args.port,
            baudrate=args.baudrate,
            bytesize=pyserial.EIGHTBITS,
            parity=pyserial.PARITY_NONE,
            stopbits=pyserial.STOPBITS_ONE,
            timeout=2.0,  # 2 seconds timeout for safety
        )
    except Exception as e:
        print(f"ERROR: Failed to open serial port {args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    # Prepare payload
    pmem = swap_bytes(list(text['data']))
    pmem_len = list(len(pmem).to_bytes(2, byteorder='little'))

    irq = swap_bytes(list(vectors['data']))
    irq_len = list(len(irq).to_bytes(2, byteorder='little'))

    inst_bytes = list(args.inst_number.to_bytes(2, byteorder='little'))

    payload = [0xff] + pmem_len + pmem + irq_len + irq + inst_bytes

    time.sleep(0.005)
    ser.reset_input_buffer()

    # Transmit payload
    ser.write(bytes(payload))

    # Read back 800 bytes trace (50 entries × 16 bytes)
    raw = ser.read(800)
    ser.close()

    if len(raw) < 800:
        # Signal divergence if we timed out
        print("DIVERGED")
        sys.exit(0)

    # Parse and print entries
    tmp = list(raw)
    for entry_idx in range(50):
        b = tmp[entry_idx * 16:(entry_idx + 1) * 16]
        pc           = (b[0] << 8)  | b[1]
        irq_val      = b[2] & 0x1
        sm_executing = b[3] & 0x1
        gie          = b[4] & 0x1
        inst_number  = (b[5] << 24) | (b[6] << 16) | (b[7] << 8) | b[8]
        e_state      = b[9] & 0x1f
        r4           = (b[10] << 8) | b[11]
        timerA       = (b[12] << 8) | b[13]
        umem         = (b[14] << 8) | b[15]
        
        print(f"{pc} {inst_number} {irq_val} {sm_executing} {e_state} {r4} {gie} {timerA} {umem}")

if __name__ == "__main__":
    main()
