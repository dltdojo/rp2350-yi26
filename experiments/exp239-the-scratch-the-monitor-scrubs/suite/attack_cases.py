#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Payloads that leave secrets where the monitor must find them, and leave in every way a payload can.

Every payload first fills [BOX + 0x2100, BOX + 0x4010) with a recognisable word: the 64 bytes before the digest
window, the window, the 160 bytes between it and the scratch, the scratch, and the 16 bytes past its end. Then it
leaves: HALT with 0, HALT with other codes, a store into the monitor, a load from nowhere, an illegal word, an
`ecall` the monitor does not offer, a jump out of the box, a fault in the middle of the fill. Each ends the way
exp236's payloads do -- parked, every register but `a0` zero -- and, as exp239 adds, with memory as
suite/oracle.py says: the scratch zero, the digest window zero unless the exit code was 0, every byte beside
them as the payload left it.

`run_all(monitor)` returns the failures; `broken_monitors.py` uses it.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import oracle
import harness

# Fill [0x80012100, 0x80014010) with each word's own address XOR 0x5a5.
FILL = """
    lui   t0, 0x80012
    addi  t0, t0, 0x100
    lui   t1, 0x80014
    addi  t1, t1, 0x10
1:  xori  t2, t0, 0x5a5
    sw    t2, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, 1b
"""
SECRETS = "\n".join(f"li x{r}, {0x11110000 + r}" for r in range(1, 32) if r != 2)
HALT = "li t0, 1\n li a0, {}\n ecall"

# name, payload source, expectation: ("fault", cause) or ("halt", a0)
ATTACKS = [
    ("fills, halts with 0",
     FILL + HALT.format(0), ("halt", 0)),
    ("fills, halts with 1",
     FILL + HALT.format(1), ("halt", 1)),
    ("fills, halts with 2",
     FILL + HALT.format(2), ("halt", 2)),
    ("fills, halts with 0x80000000",
     FILL + HALT.format("0x80000000"), ("halt", 0x80000000)),
    ("fills, secrets in every register, halts with 0",
     FILL + SECRETS + "\n li t0, 1\n li a0, 0\n ecall", ("halt", 0)),
    ("fills, halts with 0 from the last word of the box",
     FILL + "lui t1, 0x80020\n addi t1, t1, -4\n li t2, 0x73\n sw t2, 0(t1)\n"      # an ecall at +0xfffc
     " li t0, 1\n li a0, 0\n jalr x0, 0(t1)", ("halt", 0)),
    ("fills, stores into the monitor's code",
     FILL + "lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7)),
    ("fills, loads from system SRAM",
     FILL + "lui t1, 0x20000\n lw t0, 0(t1)", ("fault", 5)),
    ("fills, an illegal word",
     FILL + ".word 0xffffffff", ("fault", 2)),
    ("fills, reads a CSR",
     FILL + "csrr t0, mstatus", ("fault", 2)),
    ("fills, ebreak",
     FILL + "ebreak", ("fault", 3)),
    ("fills, an ecall the monitor does not offer",
     FILL + "li t0, 2\n li a0, 0\n ecall", ("fault", 8)),
    ("fills, jumps out of the box",
     FILL + "lui t0, 0x80020\n jalr x0, 0(t0)", ("fault", 1)),
    ("fills, secrets in every register, then faults",
     FILL + SECRETS + "\n lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7)),
    ("fills only the scratch, halts with 0",
     "lui t0, 0x80012\n addi t0, t0, 0x200\n lui t1, 0x80014\n"
     "1: sw t0, 0(t0)\n addi t0, t0, 4\n bne t0, t1, 1b\n" + HALT.format(0), ("halt", 0)),
    ("one word on each side of the scratch, a fault",
     "lui t0, 0x80012\n li t1, -1\n sw t1, 0x1fc(t0)\n sw t1, 0x200(t0)\n"
     "lui t0, 0x80014\n sw t1, -4(t0)\n sw t1, 0(t0)\n"
     "lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7)),
    ("one word on each side of the digest window, halts with 1",
     "lui t0, 0x80012\n li t1, -1\n sw t1, 0x13c(t0)\n sw t1, 0x140(t0)\n sw t1, 0x15c(t0)\n sw t1, 0x160(t0)\n"
     + HALT.format(1), ("halt", 1)),
    ("one word on each side of the digest window, halts with 0",
     "lui t0, 0x80012\n li t1, -1\n sw t1, 0x13c(t0)\n sw t1, 0x140(t0)\n sw t1, 0x15c(t0)\n sw t1, 0x160(t0)\n"
     + HALT.format(0), ("halt", 0)),
    ("nothing written, halts with 0",
     HALT.format(0), ("halt", 0)),
]


def run_all(monitor: bytes) -> list:
    out = []
    for name, src, want in ATTACKS:
        emu, snap = oracle.run(monitor, harness.payload(src))
        if want[0] == "fault":
            bad = harness.check_fault(emu, monitor, want[1])
            a0 = 1
        else:
            bad = harness.check_halt(emu, monitor, want[1])
            a0 = want[1]
        bad += oracle.check_memory(emu, snap, a0)
        if bad:
            out.append((name, bad))
    return out


def main():
    mon = oracle.monitor()
    failed = run_all(mon)
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    print(f"PASS  {len(ATTACKS)} payloads that leave secrets in memory end parked and scrubbed, "
          "the digest window kept only for exit code 0:")
    for name, _src, want in ATTACKS:
        what = f"mcause={want[1]}" if want[0] == "fault" else f"exit={want[1]:#x}"
        print(f"      {want[0]:5} {what:16} {name}")


if __name__ == "__main__":
    main()
