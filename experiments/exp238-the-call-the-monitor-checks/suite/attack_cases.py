#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Payloads that lean on the monitor's calls, on the emulator, against a host that does whatever it is told.

The monitor's calls are a way for a payload to ask M-mode to read and write for it. Every range a call
names must lie wholly inside the box [0x80010000, 0x80020000), and a range that does not — below it, past
it, straddling either end, or whose end wraps past 2^32 — must end the payload: FAULT, parked, scrubbed, and
the host never asked. Three kinds of payload:

  refused   a call with one bad range: the monitor must fault with mcause 8 and the host's request log empty
  served    a call whose ranges are good down to the last byte: the monitor must forward it exactly, and the
            payload must end as it ends when no monitor stands between it and the host
  other     the registers a call must leave alone; a hundred calls in a row; the service port reached
            directly; a fault after a call; the calls that are not offered

`run_all(monitor)` returns the failures; `broken_monitors.py` uses it to show that a monitor with something
wrong in it is caught.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import host
from host import BOX_LO, BOX_HI, harness

HALT = "li t0, 1\n li a0, 7\n ecall"
WRAP = 0x100000000


def call(num: int, a0: int, a1: int, a2: int = 0) -> str:
    return f"li a0, {a0}\n li a1, {a1}\n li a2, {a2}\n li t0, {num}\n ecall\n" + HALT


def hashb(a0, a1, a2):
    return call(2, a0, a1, a2)


def checksig(key, sig):
    return call(3, key, sig)


OK = BOX_LO + 0x8000          # a good place to put 32 bytes of output

# name, source. Every one must be refused.
REFUSED = [
    # HASHB input range
    ("hashb: input in the monitor's code", hashb(0x80000000, 32, OK)),
    ("hashb: input is the M-mode stack", hashb(0x80008000, 16, OK)),
    ("hashb: input one byte below the box", hashb(BOX_LO - 1, 1, OK)),
    ("hashb: input in system SRAM", hashb(0x20000000, 64, OK)),
    ("hashb: input in the MMIO words", hashb(0xC0000000, 4, OK)),
    ("hashb: input starts at the end of the box", hashb(BOX_HI, 1, OK)),
    ("hashb: input one byte past the end", hashb(BOX_HI - 32, 33, OK)),
    ("hashb: input is the box and a byte more", hashb(BOX_LO, 0x10001, OK)),
    ("hashb: input of 2^32-1 bytes", hashb(BOX_LO, 0xFFFFFFFF, OK)),
    ("hashb: input of 2^31 bytes", hashb(BOX_LO, 0x80000000, OK)),
    ("hashb: input wraps past 2^32 to a low address", hashb(0xFFFFFFF0, 0x20, OK)),
    ("hashb: input wraps to the middle of the box", hashb(0xFFFFFFF0, BOX_LO + 0x4000 + 0x10, OK)),
    ("hashb: input in the box, length wraps back into it", hashb(BOX_LO + 0x8000, WRAP - 0x10, OK)),
    ("hashb: input in the box, length wraps to the pointer minus one", hashb(BOX_LO, 0xFFFFFFFF, OK)),
    # HASHB output range
    ("hashb: output over the monitor's code", hashb(BOX_LO, 32, 0x80000000)),
    ("hashb: output over the M-mode stack", hashb(BOX_LO, 32, 0x80008000)),
    ("hashb: output over the trap vector", hashb(BOX_LO, 32, 0x80000114)),
    ("hashb: output one byte below the box", hashb(BOX_LO, 32, BOX_LO - 1)),
    ("hashb: output 31 bytes from the end", hashb(BOX_LO, 32, BOX_HI - 31)),
    ("hashb: output at the end of the box", hashb(BOX_LO, 32, BOX_HI)),
    ("hashb: output wraps past 2^32", hashb(BOX_LO, 32, 0xFFFFFFF0)),
    ("hashb: output is the top word", hashb(BOX_LO, 32, 0xFFFFFFFF)),
    ("hashb: output zero", hashb(BOX_LO, 32, 0)),
    # CHECKSIG key range
    ("checksig: key in the monitor's code", checksig(0x80000000, OK)),
    ("checksig: key is the M-mode stack", checksig(0x80008000, OK)),
    ("checksig: key one byte below the box", checksig(BOX_LO - 1, OK)),
    ("checksig: key 31 bytes from the end", checksig(BOX_HI - 31, OK)),
    ("checksig: key at the end of the box", checksig(BOX_HI, OK)),
    ("checksig: key wraps past 2^32", checksig(0xFFFFFFF0, OK)),
    ("checksig: key zero", checksig(0, OK)),
    # CHECKSIG signature range
    ("checksig: signature in the monitor's code", checksig(OK, 0x80000000)),
    ("checksig: signature is the M-mode stack", checksig(OK, 0x80008000)),
    ("checksig: signature one byte below the box", checksig(OK, BOX_LO - 1)),
    ("checksig: signature 63 bytes from the end", checksig(OK, BOX_HI - 63)),
    ("checksig: signature at the end of the box", checksig(OK, BOX_HI)),
    ("checksig: signature wraps past 2^32", checksig(OK, 0xFFFFFFC0 + 1)),
    ("checksig: signature is the top word", checksig(OK, 0xFFFFFFFF)),
    # calls that are not offered
    ("call 0 (HASH of exp228's model) is not offered", call(0, OK, 64, OK)),
    ("call 4", call(4, OK, 0, OK)),
    ("call 0xffffffff", call(-1, OK, 0, OK)),
    ("call 0x102: only the low bits are 2", call(0x102, OK, 32, OK)),
    ("call 0x80000002", call(0x80000002, OK, 32, OK)),
    ("call 0x1000000001: HALT's number plus 2^32", call(0x80000001, 0, 0)),
]

# name, source, the host's requests in order (call, a0, a1, a2). Every one must be forwarded as given.
SERVED = [
    ("hashb: the last 32 bytes of the box, into the same 32", hashb(BOX_HI - 32, 32, BOX_HI - 32),
     [(2, BOX_HI - 32, 32, BOX_HI - 32)]),
    ("hashb: nothing, at the end of the box", hashb(BOX_HI, 0, OK), [(2, BOX_HI, 0, OK)]),
    ("hashb: nothing, anywhere in the box", hashb(BOX_LO + 5, 0, OK), [(2, BOX_LO + 5, 0, OK)]),
    ("hashb: the whole box, the payload's own code included", hashb(BOX_LO, 0x10000, OK),
     [(2, BOX_LO, 0x10000, OK)]),
    ("hashb: one odd byte", hashb(BOX_LO + 0x1001, 1, OK + 3), [(2, BOX_LO + 0x1001, 1, OK + 3)]),
    ("checksig: key and signature at the very end", checksig(BOX_HI - 32, BOX_HI - 64),
     [(3, BOX_HI - 32, BOX_HI - 64, 0)]),
    ("checksig: key and signature at the very start", checksig(BOX_LO, BOX_LO), [(3, BOX_LO, BOX_LO, 0)]),
    ("checksig: signature at the very end", checksig(OK, BOX_HI - 64), [(3, OK, BOX_HI - 64, 0)]),
]

REGS = [r for r in range(1, 32) if r not in (2, 5, 10, 11, 12)]      # x2 is the dump's base; x5, a0..a2 hold the call


ARG1 = {2: 40, 3: OK + 0x200}        # HASHB's length, CHECKSIG's signature


def preserved(num: int) -> str:
    """Every register a pattern, the call, and then every register stored: the call must leave them alone."""
    src = [f"li x{r}, {0x11110000 + r}" for r in REGS]
    src += ["lui sp, 0x80019"]
    src += [f"li a0, {OK}", f"li a1, {ARG1[num]}", f"li a2, {OK + 0x100}", f"li t0, {num}", "ecall"]
    src += [f"sw x{r}, {4 * r}(sp)" for r in range(1, 32) if r != 2]
    src += ["sw sp, 8(sp)", "li t0, 1", "li a0, 0", "ecall"]
    return "\n".join(src)


def dump(emu) -> list:
    return [harness.word(emu, 0x80019000 + 4 * r) for r in range(32)]


LOOPS = 100
LOOP = f"""
    li s0, {LOOPS}
again:
    li a0, {BOX_LO}
    li a1, 64
    li a2, {BOX_LO + 0xf000}
    li t0, 2
    ecall
    addi s0, s0, -1
    bnez s0, again
    li t0, 1
    li a0, 5
    ecall
"""

# name, source, mcause, calls the host was asked. Every one must fault with that cause.
FAULTING = [
    ("the service port, written from U-mode", "li t0, 0xc0000010\n sw t0, 12(t0)", 7, 0),
    ("the service port, read from U-mode", "li t0, 0xc0000010\n lw t1, 12(t0)", 5, 0),
    ("the print port, written from U-mode", "li t0, 0xc0000004\n sw t0, 0(t0)", 7, 0),
    ("a call, then a store into the monitor", hashb(BOX_LO, 32, OK).replace(HALT, "")
     + "\n lui t0, 0x80000\n sw x0, 0(t0)", 7, 1),
    ("a call, then the M-mode stack", hashb(BOX_LO, 32, OK).replace(HALT, "")
     + "\n lui t0, 0x80008\n lw t1, 0(t0)", 5, 1),
    ("a call, then mret", hashb(BOX_LO, 32, OK).replace(HALT, "") + "\n mret", 2, 1),
    ("a call, then a csr", hashb(BOX_LO, 32, OK).replace(HALT, "") + "\n csrw mscratch, t0", 2, 1),
    ("a store into the monitor's code", "lui t0, 0x80000\n sw x0, 0(t0)", 7, 0),
    ("an illegal word", ".word 0xffffffff", 2, 0),
    ("jump into the monitor", "lui t0, 0x80000\n addi t0, t0, 0x40\n jalr x0, 0(t0)", 1, 0),
]


def expect_served(emu, monitor, pay, requests, exit_code=7) -> list:
    bad = host.check_parked(emu, monitor, exit_code)
    if host.TAG_HALT not in emu.prints:
        bad.append("no HALT report")
    if emu.host.requests != requests:
        bad.append(f"the host was asked {emu.host.requests}, wanted {requests}")
    alone = host.reference_run(pay)
    if host.box(alone) != host.box(emu):
        bad.append("the box differs from the run with no monitor")
    n = len(emu.host.requests)
    if len(emu.prints) >= 2 and emu.prints[-2] != alone.minstret + 2 + 2 * n:
        bad.append(f"minstret {emu.prints[-2]}, wanted {alone.minstret} + 2 + 2*{n}")
    return bad


def run_all(monitor: bytes) -> list:
    out = []
    for name, src in REFUSED:
        emu = host.run(monitor, harness.payload(src))
        bad = host.check_refused(emu, monitor)
        if bad:
            out.append((name, bad))
    for name, src, requests in SERVED:
        pay = harness.payload(src)
        bad = expect_served(host.run(monitor, pay), monitor, pay, requests)
        if bad:
            out.append((name, bad))
    for num, name in ((2, "hashb"), (3, "checksig")):
        pay = harness.payload(preserved(num))
        emu = host.run(monitor, pay)
        bad = host.check_parked(emu, monitor, 0)
        alone = host.reference_run(pay)
        if dump(emu) != dump(alone):
            bad.append("the registers after the call are not the run alone's")
        got = dump(emu)
        want = {r: 0x11110000 + r for r in REGS} | {2: 0x80019000, 5: num, 11: ARG1[num], 12: OK + 0x100}
        want[10] = got[10] if num == 3 else OK
        if num == 3 and got[10] not in (0, 1):
            bad.append(f"checksig left a0 = {got[10]:#x}, not 0 or 1")
        for r, v in want.items():
            if got[r] != v:
                bad.append(f"x{r} = {got[r]:#x} after {name}, wanted {v:#x}")
        if bad:
            out.append((f"the registers a {name} must leave alone", bad))
    pay = harness.payload(LOOP)
    emu = host.run(monitor, pay)
    bad = expect_served(emu, monitor, pay, [(2, BOX_LO, 64, BOX_LO + 0xf000)] * LOOPS, exit_code=5)
    if bad:
        out.append((f"{LOOPS} calls in a row, minstret exact", bad))
    for name, src, cause, asked in FAULTING:
        emu = host.run(monitor, harness.payload(src))
        bad = host.check_refused(emu, monitor, cause, asked)
        if bad:
            out.append((name, bad))
    return out


def main():
    with open(os.path.join(host.EXP238, "monitor.bin"), "rb") as f:
        monitor = f.read()
    failed = run_all(monitor)
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    n = len(REFUSED) + len(SERVED) + 2 + 1 + len(FAULTING)
    print(f"PASS  {n} payloads that lean on the calls: {len(REFUSED)} refused with the host never asked, "
          f"{len(SERVED)} served to the last byte as the run with no monitor serves them,")
    print(f"      the registers a call must leave alone (both calls), {LOOPS} calls in a row at an exact "
          f"minstret, {len(FAULTING)} that fault with the hardware's cause:")
    for name, _ in REFUSED:
        print(f"      refused  {name}")
    for name, _src, _r in SERVED:
        print(f"      served   {name}")


if __name__ == "__main__":
    main()
