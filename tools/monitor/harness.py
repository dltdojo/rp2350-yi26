#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Run a micro-monitor and a payload together on the emulator, and say what is wrong.

An image is the monitor at 0x80000000, zero-padded to 64 KiB, then the payload at
0x80010000 (the 64 KiB region the monitor's PMP is meant to fence the payload into).
`check_*` return a list of what went wrong — empty is a pass — so that a test can
assert that a *broken* monitor is caught, not only that a good one passes.
"""

import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import asm
import binary
from monitor.emulator import SandboxEmulator, BASE, C_FETCH_ACCESS, C_LOAD_ACCESS, C_STORE_ACCESS, MIE, MPIE

PAYLOAD_AT = 0x80010000
PAYLOAD_LEN = 0x10000
STACK0, STACK1 = 0x80008000, 0x80008004
TAG_HALT, TAG_FAULT = 0x48414C54, 0x4641554C


def assemble_at(src_text: str, at: int) -> bytes:
    """Assemble RV32IM + Zicsr text to a flat binary placed at address `at`."""
    with tempfile.TemporaryDirectory() as d:
        s, b = os.path.join(d, "p.S"), os.path.join(d, "p.bin")
        with open(s, "w") as f:
            f.write(".section .text\n.globl _start\n_start:\n" + src_text + "\n")
        asm.assemble(s, b, at)
        with open(b, "rb") as f:
            return f.read()


def payload(src_text: str) -> bytes:
    return assemble_at(src_text, PAYLOAD_AT)


def image(monitor: bytes, pay: bytes) -> bytes:
    assert len(monitor) <= PAYLOAD_AT - BASE
    assert len(pay) <= PAYLOAD_LEN
    return monitor + b"\x00" * (PAYLOAD_AT - BASE - len(monitor)) + pay


def run(monitor: bytes, pay: bytes, steps: int = 400000) -> SandboxEmulator:
    emu = SandboxEmulator(image(monitor, pay))
    emu.run(steps)
    return emu


def word(emu: SandboxEmulator, addr: int) -> int:
    return struct.unpack("<I", emu.mem[addr - BASE:addr - BASE + 4])[0]


def check_parked(emu: SandboxEmulator, monitor: bytes, a0: int) -> list:
    """What the monitor owes whatever the payload did: parked, scrubbed, intact."""
    bad = []
    if not emu.halted:
        bad.append("the monitor never parked")
    if emu.mode != "M":
        bad.append(f"parked in {emu.mode}-mode")
    if emu.exit_code != a0:
        bad.append(f"exit code {emu.exit_code}, wanted {a0}")
    if emu.regs[10] != a0:
        bad.append(f"a0 = {emu.regs[10]:#x}, wanted {a0:#x}")
    for r in range(1, 32):
        if r != 10 and emu.regs[r] != 0:
            bad.append(f"x{r} = {emu.regs[r]:#x} was not scrubbed")
    if emu.mscratch != 0:
        bad.append(f"mscratch = {emu.mscratch:#x} was not cleared")
    if word(emu, STACK0) != 0 or word(emu, STACK1) != 0:
        bad.append("the saved t0/t1 are still on the M-mode stack")
    if bytes(emu.mem[:len(monitor)]) != monitor:
        bad.append("the monitor's own words were modified")
    return bad


def check_halt(emu: SandboxEmulator, monitor: bytes, a0: int) -> list:
    bad = check_parked(emu, monitor, a0)
    if TAG_HALT not in emu.prints:
        bad.append("no HALT report")
    return bad


def check_fault(emu: SandboxEmulator, monitor: bytes, cause: int = None, tval: int = None) -> list:
    """A fault, reported and parked. An access fault must be the PMP's: the bus's, at an address with nothing there,
    has the same `mcause` and `mtval`, and means the PMP let the access through."""
    bad = check_parked(emu, monitor, 1)
    if TAG_FAULT not in emu.prints:
        bad.append("no FAULT report")
    if cause is not None and emu.mcause != cause:
        bad.append(f"mcause {emu.mcause}, wanted {cause}")
    if tval is not None and emu.mtval != tval:
        bad.append(f"mtval {emu.mtval:#x}, wanted {tval:#x}")
    if cause in (C_FETCH_ACCESS, C_LOAD_ACCESS, C_STORE_ACCESS):
        by = [t["by"] for t in emu.traps if t["cause"] == cause]
        if by != ["pmp"]:
            bad.append(f"the access fault came from {by}, wanted the PMP's alone: "
                       "the bus refuses an address the PMP let through to nothing")
    return bad


# ---- from exp239 on: what a monitor that scrubs the payload's memory is held to ---------------

class ReferenceEmulator(SandboxEmulator):
    """The payload alone: M-mode, no PMP, no monitor, at the start of its box with `sp` at the end.

    The only `ecall` it answers is HALT (`t0 = 1`), in place, as the monitor's HALT would report it.
    The oracle for a payload that asks the monitor for nothing else: what it computes, and how many
    instructions it takes.
    """

    def __init__(self, pay: bytes):
        super().__init__(bytes(PAYLOAD_AT - BASE) + pay)
        self.pc = PAYLOAD_AT
        self.regs = [0] * 32
        self.regs[2] = PAYLOAD_AT + PAYLOAD_LEN

    def step(self):
        off = self.pc - BASE
        if int.from_bytes(self.mem[off:off + 4], "little") != 0x00000073:
            return super().step()
        assert self.regs[5] == 1, f"reference run: ecall {self.regs[5]}"
        self.count()
        self.exit_code, self.halted = self.regs[10], True


def reference_run(pay: bytes, steps: int = 1000000) -> ReferenceEmulator:
    emu = ReferenceEmulator(pay)
    emu.run(steps)
    return emu


def run_snapshot(monitor: bytes, pay: bytes, steps: int = 1000000):
    """`run`, and the whole of memory as the payload left it: at its first trap, before the monitor writes a byte.

    Returns (emulator, snapshot), the snapshot None if the payload never trapped.
    """
    return snapshot(SandboxEmulator(image(monitor, pay)), steps)


def snapshot(emu: SandboxEmulator, steps: int = 1000000):
    """Run `emu` to the park, taking the whole of memory at its first trap, before the monitor writes a byte.

    Returns (emulator, snapshot), the snapshot None if the payload never trapped.
    """
    snap = None
    for _ in range(steps):
        if emu.halted:
            break
        emu.step()
        if snap is None and emu.traps:
            snap = bytes(emu.mem)
    return emu, snap


def box(emu: SandboxEmulator) -> bytes:
    return bytes(emu.mem[PAYLOAD_AT - BASE:PAYLOAD_AT - BASE + PAYLOAD_LEN])


def sub(src: str, old: str, new: str, which: str = "first") -> str:
    """`src` with one thing changed, for a monitor with one thing wrong."""
    assert old in src, f"{old!r} is not in monitor.S"
    if which == "all":
        return src.replace(old, new)
    i = src.index(old) if which == "first" else src.rindex(old)
    return src[:i] + new + src[i + len(old):]


def build(src: str) -> bytes:
    """monitor.S text assembled afresh, as a flat binary at the monitor's base."""
    return binary.assembled(src)


# ---- from exp240 on: a monitor that is entered again and again --------------------------------

def reenter(emu: SandboxEmulator, junk_csrs: bool = False) -> SandboxEmulator:
    """A reset, as the hardware does it: a new run of the core over the RAM the last run left.

    The core starts again at the reset vector, in M-mode, with the CSRs at their reset values and junk in the registers
    (`SandboxEmulator` puts it there); nothing of the last run is carried but memory.

    With `junk_csrs`, a reset as weak as one can be, the one exp240's `monitor_reentry` is about: the CSRs are not reset
    either, and hold junk -- `MPP` M-mode and both interrupt enables, a trap vector, a cause, a value, four PMP entries
    on and covering what they cover -- but for the PMP's lock bits, which a monitor that never sets them does not find
    set. A monitor that reads anything from a CSR it has not written finds this.
    """
    new = SandboxEmulator(bytes(emu.mem))
    if junk_csrs:
        new.mstatus = (3 << 11) | MIE | MPIE
        new.mtvec, new.mscratch, new.mepc = 0xA5A5A5A4, 0xA5A5A5A5, 0xA5A5A5A6
        new.mcause, new.mtval = 0xA5A5A5A7, 0xA5A5A5A8
        new.pmpcfg0 = 0x1F1F1F1F                       # four entries NAPOT, read, write and execute; none locked
        new.pmpaddr = [0x2000403F, 0x200041FF, 0x20007FFF, 0x00000000]
        new.mcycle, new.minstret = 0xA5A5A5A9, 0xA5A5A5AA
    return new


def differences(want: bytes, got: bytes, limit: int = 4) -> list:
    """The ranges, as addresses, where `got` is not `want`: at most `limit` of them, then a count."""
    out, i, n = [], 0, len(want)
    while i < n:
        if want[i] != got[i]:
            j = i
            while j < n and want[j] != got[j]:
                j += 1
            out.append((BASE + i, BASE + j))
            i = j
        else:
            i += 1
    shown = [f"[{lo:#x}, {hi:#x})" for lo, hi in out[:limit]]
    return shown + ([f"and {len(out) - limit} more"] if len(out) > limit else [])


def reported(emu: SandboxEmulator, tag: int):
    """The words of the last report that began with `tag` (HALT: a0, minstret, mcycle), or None."""
    p = emu.prints
    for i in range(len(p) - 1, -1, -1):
        if p[i] == tag:
            return p[i + 1:i + 4]
    return None
