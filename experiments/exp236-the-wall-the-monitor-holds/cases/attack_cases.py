#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Hostile payloads against the micro-monitor, on the emulator of tools/monitor.

Every payload runs in U-mode in the 64 KiB the PMP is meant to fence it into. Each must end
the same way: the monitor reports, scrubs, and parks — every register but a0 zero, mscratch
and the two saved words zero, the monitor's own words untouched — and the cause the monitor
reports is the one the hardware rule gives.

`run_all(monitor)` returns the failures; `broken_monitors.py` uses it to show that a monitor
with something wrong in it is caught.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP236 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP236, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness

SECRETS = "\n".join(f"li x{r}, {0x11110000 + r}" for r in range(1, 32))

# name, payload source, expectation: ("fault", cause, mtval) or ("halt", a0)
ATTACKS = [
    ("store into the monitor's code",
     "lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7, 0x80000000)),
    ("load the monitor's code",
     "lui t0, 0x80000\n lw t1, 0(t0)", ("fault", 5, 0x80000000)),
    ("write the M-mode stack",
     "lui t0, 0x80008\n sw t0, 0(t0)", ("fault", 7, 0x80008000)),
    ("read system SRAM",
     "lui t1, 0x20000\n lw t0, 0(t1)", ("fault", 5, 0x20000000)),
    ("jump into the monitor",
     "lui t0, 0x80000\n addi t0, t0, 0x40\n jalr x0, 0(t0)", ("fault", 1, 0x80000040)),
    ("jump to the trap vector",
     "lui t0, 0x80000\n addi t0, t0, 0x114\n jalr x0, 0(t0)", ("fault", 1, 0x80000114)),
    ("read mstatus",
     "csrr t0, mstatus", ("fault", 2, None)),
    ("set a bit in mstatus",
     "csrrsi x0, mstatus, 8", ("fault", 2, None)),
    ("write mscratch",
     "csrw mscratch, t0", ("fault", 2, None)),
    ("read the cycle counter",
     "csrr t0, cycle", ("fault", 2, None)),
    ("mret to M-mode",
     "mret", ("fault", 2, None)),
    ("wfi",
     "wfi", ("fault", 2, None)),
    ("ebreak",
     "ebreak", ("fault", 3, None)),
    ("an illegal word",
     ".word 0xffffffff", ("fault", 2, None)),
    ("a misaligned load",
     "lui t0, 0x80010\n lw t1, 1(t0)", ("fault", 4, None)),
    ("an unknown syscall",
     "lui t0, 1\n addi t0, t0, 0x337\n ecall", ("fault", 8, None)),
    ("hash syscall (not offered)",
     "li t0, 0\n ecall", ("fault", 8, None)),
    ("a fault with secrets in every register",
     SECRETS + "\n lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7, 0x80000000)),
    ("a clean halt with secrets in every register",
     SECRETS + "\n li t0, 1\n li a0, 7\n ecall", ("halt", 7)),
    ("a fault with sp pointing into the monitor",
     "lui sp, 0x80000\n addi sp, sp, 0x100\n csrr t0, mstatus", ("fault", 2, None)),
    ("the registers it starts with",
     "or x1, x1, x10\n" + "\n".join(f"or x1, x1, x{r}" for r in range(3, 32) if r != 10)
     + "\n mv a0, x1\n li t0, 1\n ecall", ("halt", 0)),
    ("a clean halt, exit code 0",
     "li t0, 1\n li a0, 0\n ecall", ("halt", 0)),
    ("writes in the box are allowed",
     "lui t0, 0x80018\n li t1, 0x5a5a\n sw t1, 0(t0)\n lw t2, 0(t0)\n li t0, 1\n li a0, 3\n ecall",
     ("halt", 3)),
]


def run_all(monitor: bytes) -> list:
    out = []
    for name, src, want in ATTACKS:
        emu = harness.run(monitor, harness.payload(src))
        if want[0] == "fault":
            bad = harness.check_fault(emu, monitor, want[1], want[2])
        else:
            bad = harness.check_halt(emu, monitor, want[1])
        if bad:
            out.append((name, bad))
    return out


def main():
    with open(os.path.join(EXP236, "monitor.bin"), "rb") as f:
        monitor = f.read()
    failed = run_all(monitor)
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    print(f"PASS  {len(ATTACKS)} hostile payloads end parked and scrubbed, with the hardware's cause:")
    for name, _src, want in ATTACKS:
        what = (f"mcause={want[1]}" if want[0] == "fault" else f"exit={want[1]}")
        print(f"      {want[0]:5} {what:9} {name}")


if __name__ == "__main__":
    main()
