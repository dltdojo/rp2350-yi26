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
from monitor.emulator import SandboxEmulator, BASE

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
    bad = check_parked(emu, monitor, 1)
    if TAG_FAULT not in emu.prints:
        bad.append("no FAULT report")
    if cause is not None and emu.mcause != cause:
        bad.append(f"mcause {emu.mcause}, wanted {cause}")
    if tval is not None and emu.mtval != tval:
        bad.append(f"mtval {emu.mtval:#x}, wanted {tval:#x}")
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
    emu = SandboxEmulator(image(monitor, pay))
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
