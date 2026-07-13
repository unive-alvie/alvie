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
import time
import io
import hashlib
from elftools.elf.elffile import ELFFile

stats = {
    "queries": 0,
    "elf_cache_hits": 0,
    "elf_parse_s": 0.0,
    "payload_s": 0.0,
    "serial_write_s": 0.0,
    "serial_read_s": 0.0,
    "decode_s": 0.0,
}

elf_cache = {}

def parse_elf(path):
    t0 = time.perf_counter()
    with open(path, "rb") as f:
        elf_bytes = f.read()

    digest = hashlib.sha256(elf_bytes).hexdigest()
    cached = elf_cache.get(digest)
    if cached is not None:
        stats["elf_cache_hits"] += 1
        stats["elf_parse_s"] += time.perf_counter() - t0
        return cached

    with io.BytesIO(elf_bytes) as f:
        elf = ELFFile(f)
        text_data = None
        vec_data = None
        for section in elf.iter_sections():
            if section.name == ".text":
                text_data = section.data()
            elif section.name == ".vectors":
                vec_data = section.data()
        if text_data is None or vec_data is None:
            result = (None, None)
        else:
            pmem = swap_bytes(text_data)
            irq = swap_bytes(vec_data)
            pmem_len = len(pmem).to_bytes(2, byteorder='little')
            irq_len = len(irq).to_bytes(2, byteorder='little')
            result = (b'\xff' + pmem_len + pmem + irq_len + irq, digest)
        elf_cache.clear()
        elf_cache[digest] = result
        stats["elf_parse_s"] += time.perf_counter() - t0
        return result

def swap_bytes(data):
    if len(data) % 2 != 0:
        data = data + b'\x00'
    result = bytearray(len(data))
    result[0::2] = data[1::2]
    result[1::2] = data[0::2]
    return bytes(result)

def build_payload(upload_prefix, inst_number):
    t0 = time.perf_counter()
    inst_bytes = inst_number.to_bytes(2, byteorder='little')
    payload = upload_prefix + inst_bytes
    stats["payload_s"] += time.perf_counter() - t0
    return payload

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
        stats["queries"] += 1
        parts = line.split()
        if len(parts) != 2:
            print(f"ERROR: bad query line: {line!r}", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue

        elf_path, inst_str = parts[0], parts[1]
        inst_number = int(inst_str)

        try:
            upload_prefix, program_sha256 = parse_elf(elf_path)
        except Exception as e:
            print(f"ERROR: ELF parse failed: {e}", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue
        if upload_prefix is None:
            print("ERROR: missing .text or .vectors", file=sys.stderr)
            print("DONE")
            sys.stdout.flush()
            continue

        payload = build_payload(upload_prefix, inst_number)

        ser.reset_input_buffer()
        t0 = time.perf_counter()
        ser.write(payload)
        stats["serial_write_s"] += time.perf_counter() - t0

        t1 = time.perf_counter()
        raw = ser.read(800)
        stats["serial_read_s"] += time.perf_counter() - t1

        if len(raw) < 800:
            print("DIVERGED")
        else:
            t2 = time.perf_counter()
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
            stats["decode_s"] += time.perf_counter() - t2

        print("DONE")
        sys.stdout.flush()

    print(
        "[FPGA_DAEMON_STATS] "
        f"queries={stats['queries']} "
        f"elf_cache_hits={stats['elf_cache_hits']} "
        f"elf_parse_ms={stats['elf_parse_s'] * 1000.0:.1f} "
        f"payload_ms={stats['payload_s'] * 1000.0:.1f} "
        f"serial_write_ms={stats['serial_write_s'] * 1000.0:.1f} "
        f"serial_read_ms={stats['serial_read_s'] * 1000.0:.1f} "
        f"decode_ms={stats['decode_s'] * 1000.0:.1f}",
        file=sys.stderr,
    )
    ser.close()

if __name__ == "__main__":
    main()
