#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Hostile payloads against exp240's box, on the emulator of tools/monitor.

A payload is loaded at the start of the code entry and runs in U-mode. The box it is held in has three places and a
guard (suite/oracle.py), and each place is tried from both sides: the first byte that is inside and the first byte that
is not. A payload that does what the box forbids must end the way every payload ends under these monitors -- the monitor
reports, and parks, every register but `a0` zero -- with the cause the PMP rule gives and the address that caused it
(the emulator's record of the trap: Hazard3's `mtval` is hardwired to 0, so the monitor reports 0), refused by the PMP
and not by the bus (an address with no memory faults the same way), and the code entry's bytes as the payload was
loaded: the store that was refused wrote nothing. A payload that does what the box allows must run on.

`CONTRASTS` are the payloads exp236's box -- one RWX entry over the same 64 KiB -- lets through: they patch their own
code, or run what they wrote. exp240 stops them, exp236 does not, and that is the whole difference.

`run_all(monitor)` returns the failures; `broken_monitors.py` uses it.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import oracle
import harness

HALT0 = "li t0, 1\n li a0, 0\n ecall"
HALT_KEEP = "li t0, 1\n ecall"                  # HALT with whatever a0 holds
NOPS = lambda n: "nop\n" * n

# 20 registers, a word each: the whole payload has to fit in the 128 bytes of the code entry
SECRET_REGS = [1, 3, 4, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]
SECRETS = "\n".join(f"lui x{r}, {0x11110 + r}" for r in SECRET_REGS)
START_REGS = "or x1, x1, x10\n" + "\n".join(f"or x1, x1, x{r}" for r in [*range(3, 10), *range(11, 32)])

# name, payload source, expectation: ("fault", cause, address) or ("halt", a0)
ATTACKS = [
    # ---- the code entry: read and execute, not write
    ("store into the code, first word",
     "lui t0, 0x80010\n sw x0, 0(t0)", ("fault", 7, 0x80010000)),
    ("store into the code, last word",
     "lui t0, 0x80010\n sw x0, 0x7c(t0)", ("fault", 7, 0x8001007c)),
    ("store into the code, last byte",
     "lui t0, 0x80010\n sb x0, 0x7f(t0)", ("fault", 7, 0x8001007f)),
    ("rewrite the next instruction (self-modifying code)",
     "auipc t0, 0\n li t1, 0x00700513\n sw t1, 20(t0)\n nop\n nop\n" + HALT_KEEP, ("fault", 7, 0x80010014)),
    ("store into the code with secrets in 20 registers",
     SECRETS + "\n lui t0, 0x80010\n sw x0, 0x40(t0)", ("fault", 7, 0x80010040)),
    ("read the code",
     "lui t0, 0x80010\n lw t1, 0(t0)\n lw t1, 0x7c(t0)\n" + HALT0, ("halt", 0)),
    ("a payload of 32 words runs to its last word",
     NOPS(29) + HALT0, ("halt", 0)),
    ("a payload of 33 words cannot fetch its 33rd",
     NOPS(30) + HALT0, ("fault", 1, 0x80010080)),
    # ---- the data entry: read and write, not execute
    ("store into the data, first byte past the code",
     "lui t0, 0x80010\n li t1, 0x5a5a\n sw t1, 0x80(t0)\n lw t2, 0x80(t0)\n" + HALT0, ("halt", 0)),
    ("store into the data, last word",
     "lui t0, 0x80011\n li t1, 0x5a5a\n sw t1, -4(t0)\n lw t2, -4(t0)\n" + HALT0, ("halt", 0)),
    ("run the data, first byte past the code",
     "lui t0, 0x80010\n addi t0, t0, 0x80\n jalr x0, 0(t0)", ("fault", 1, 0x80010080)),
    ("write an ecall into the data and run it",
     "lui t3, 0x80010\n addi t3, t3, 0x400\n li t1, 0x73\n sw t1, 0(t3)\n li t0, 1\n li a0, 0\n jalr x0, 0(t3)",
     ("fault", 1, 0x80010400)),
    ("write an ecall where the kernel keeps its seed and run it",
     "lui t3, 0x80010\n addi t3, t3, 0x100\n li t1, 0x73\n sw t1, 0(t3)\n li t0, 1\n li a0, 0\n jalr x0, 0(t3)",
     ("fault", 1, 0x80010100)),
    # ---- the guard: nothing
    ("store into the guard, first word",
     "lui t0, 0x80011\n sw x0, 0(t0)", ("fault", 7, 0x80011000)),
    ("load from the guard, first word",
     "lui t0, 0x80011\n lw t1, 0(t0)", ("fault", 5, 0x80011000)),
    ("run the guard",
     "lui t0, 0x80011\n jalr x0, 0(t0)", ("fault", 1, 0x80011000)),
    ("store into the guard, last word",
     "lui t0, 0x8001f\n sw x0, -4(t0)", ("fault", 7, 0x8001effc)),
    ("load from the guard, last word",
     "lui t0, 0x8001f\n lw t1, -4(t0)", ("fault", 5, 0x8001effc)),
    # ---- the stack entry: read and write, not execute
    ("store into the stack, bottom word",
     "lui t0, 0x8001f\n li t1, 0x5a5a\n sw t1, 0(t0)\n lw t2, 0(t0)\n" + HALT0, ("halt", 0)),
    ("store into the stack, top word",
     "li t1, 0x5a5a\n sw t1, -4(sp)\n lw t2, -4(sp)\n" + HALT0, ("halt", 0)),
    ("overflow the stack by recursion",
     "1: addi sp, sp, -16\n sw ra, 0(sp)\n j 1b", ("fault", 7, 0x8001eff0)),
    ("underflow the stack: load past the top",
     "lw t0, 0(sp)", ("fault", 5, 0x80020000)),
    ("underflow the stack: store past the top",
     "sw x0, 0(sp)", ("fault", 7, 0x80020000)),
    ("write an ecall onto the stack and run it",
     "addi t3, sp, -16\n li t1, 0x73\n sw t1, 0(t3)\n li t0, 1\n li a0, 0\n jalr x0, 0(t3)",
     ("fault", 1, 0x8001fff0)),
    ("run the stack",
     "lui t0, 0x8001f\n jalr x0, 0(t0)", ("fault", 1, 0x8001f000)),
    # ---- outside the box
    ("store into the monitor's code",
     "lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7, 0x80000000)),
    ("load the monitor's code",
     "lui t0, 0x80000\n lw t1, 0(t0)", ("fault", 5, 0x80000000)),
    ("write the M-mode stack",
     "lui t0, 0x80008\n sw t0, 0(t0)", ("fault", 7, 0x80008000)),
    ("read system SRAM",
     "lui t1, 0x20000\n lw t0, 0(t1)", ("fault", 5, 0x20000000)),
    ("write past the box",
     "lui t0, 0x80020\n sw x0, 0(t0)", ("fault", 7, 0x80020000)),
    ("jump into the monitor",
     "lui t0, 0x80000\n addi t0, t0, 0x40\n jalr x0, 0(t0)", ("fault", 1, 0x80000040)),
    ("jump to the trap vector",
     "lui t0, 0x80000\n addi t0, t0, 0x134\n jalr x0, 0(t0)", ("fault", 1, 0x80000134)),
    # where there is no memory at all: the PMP must refuse it before the bus does (harness.check_fault)
    ("load from address 0",
     "lw t1, 0(x0)", ("fault", 5, 0x00000000)),
    ("store to address 0",
     "sw x0, 0(x0)", ("fault", 7, 0x00000000)),
    ("run address 0",
     "jalr x0, 0(x0)", ("fault", 1, 0x00000000)),
    # ---- the PMP and the CSRs are not the payload's
    ("write pmpcfg0 to unlock the code",
     "li t0, 0x1f\n csrw pmpcfg0, t0", ("fault", 2, None)),
    ("read pmpaddr0",
     "csrr t0, pmpaddr0", ("fault", 2, None)),
    ("set a bit in mstatus",
     "csrrsi x0, mstatus, 8", ("fault", 2, None)),
    ("read the cycle counter",
     "csrr t0, cycle", ("fault", 2, None)),
    ("write mscratch",
     "csrw mscratch, t0", ("fault", 2, None)),
    ("mret to M-mode",
     "mret", ("fault", 2, None)),
    ("wfi",
     "wfi", ("fault", 2, None)),
    ("ebreak",
     "ebreak", ("fault", 3, None)),
    ("an illegal word",
     ".word 0xffffffff", ("fault", 2, None)),
    ("a misaligned load",
     "lui t0, 0x80010\n lw t1, 0x81(t0)", ("fault", 4, None)),
    ("a misaligned store",
     "lui t0, 0x80010\n sw x0, 0x81(t0)", ("fault", 6, None)),
    ("an unknown syscall",
     "lui t0, 1\n addi t0, t0, 0x337\n ecall", ("fault", 8, None)),
    ("hash syscall (not offered)",
     "li t0, 0\n ecall", ("fault", 8, None)),
    # ---- what the monitor owes however the payload leaves
    ("a fault with secrets in 20 registers",
     SECRETS + "\n lui t0, 0x80000\n sw x0, 0(t0)", ("fault", 7, 0x80000000)),
    ("a clean halt with secrets in 20 registers",
     SECRETS + "\n li t0, 1\n li a0, 7\n ecall", ("halt", 7)),
    ("a fault with sp pointing into the monitor",
     "lui sp, 0x80000\n addi sp, sp, 0x100\n csrr t0, mstatus", ("fault", 2, None)),
    ("the registers it starts with",
     START_REGS + "\n mv a0, x1\n li t0, 1\n ecall", ("halt", 0)),
    ("the stack pointer it starts with",
     "mv a0, sp\n li t0, 1\n ecall", ("halt", 0x80020000)),
    ("a clean halt, exit code 0",
     HALT0, ("halt", 0)),
    ("a clean halt, exit code 0x80000000",
     "li t0, 1\n lui a0, 0x80000\n ecall", ("halt", 0x80000000)),
]

# Payloads exp236's one RWX entry lets through. name, payload, what exp236 does, what exp240 does.
CONTRASTS = [
    ("rewrite the next instruction (self-modifying code)",
     "auipc t0, 0\n li t1, 0x00700513\n sw t1, 20(t0)\n nop\n nop\n" + HALT_KEEP, ("halt", 7), ("fault", 7, 0x80010014)),
    ("write an ecall into the data and run it",
     "lui t3, 0x80010\n addi t3, t3, 0x400\n li t1, 0x73\n sw t1, 0(t3)\n li t0, 1\n li a0, 0\n jalr x0, 0(t3)",
     ("halt", 0), ("fault", 1, 0x80010400)),
    ("write an ecall onto the stack and run it",
     "addi t3, sp, -16\n li t1, 0x73\n sw t1, 0(t3)\n li t0, 1\n li a0, 0\n jalr x0, 0(t3)",
     ("halt", 0), ("fault", 1, 0x8001fff0)),
]


def check(mon: bytes, pay: bytes, want: tuple) -> list:
    """What is wrong with one payload's run under `mon`, against `want`; empty is a pass."""
    emu = harness.run(mon, pay)
    if want[0] == "fault":
        bad = harness.check_fault(emu, mon, want[1], want[2])
    else:
        bad = harness.check_halt(emu, mon, want[1])
    code = slice(oracle.CODE[0] - harness.BASE, oracle.CODE[0] - harness.BASE + len(pay[:oracle.CODE[1] - oracle.CODE[0]]))
    if want[0] == "fault" and bytes(emu.mem[code]) != pay[:oracle.CODE[1] - oracle.CODE[0]]:
        bad.append("the code entry's bytes are not what the payload was loaded with")
    return bad


_ASSEMBLED = {}


def assembled(src: str) -> bytes:
    """A payload, assembled once: the same bytes whichever monitor it runs under."""
    if src not in _ASSEMBLED:
        _ASSEMBLED[src] = harness.payload(src)
    return _ASSEMBLED[src]


def run_all(mon: bytes, first: bool = False) -> list:
    """The failures of `mon` against ATTACKS; with `first`, only the first, which is all a broken monitor needs."""
    out = []
    for name, src, want in ATTACKS:
        bad = check(mon, assembled(src), want)
        if bad:
            out.append((name, bad))
            if first:
                break
    return out


def main():
    mon = oracle.monitor()
    failed = run_all(mon)
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    for name, src, was, now in CONTRASTS:
        pay = assembled(src)
        for who, m, want in (("exp236", oracle.monitor236(), was), ("exp240", mon, now)):
            bad = check(m, pay, want)
            if bad:
                failed.append((name, bad))
                print(f"FAIL  {who}, {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    print(f"PASS  {len(ATTACKS)} payloads end parked and scrubbed, with the cause and the address the PMP rule gives:")
    for name, _src, want in ATTACKS:
        what = f"mcause={want[1]}" + (f" addr={want[2]:#x}" if want[2] is not None else "") if want[0] == "fault" \
            else f"exit={want[1]:#x}"
        print(f"      {want[0]:5} {what:30} {name}")
    print(f"PASS  {len(CONTRASTS)} payloads that exp236's one RWX entry lets run are stopped by the three:")
    for name, _src, was, now in CONTRASTS:
        print(f"      exp236 halt exit={was[1]:#x}; exp240 fault mcause={now[1]} addr={now[2]:#x}  {name}")


if __name__ == "__main__":
    main()
