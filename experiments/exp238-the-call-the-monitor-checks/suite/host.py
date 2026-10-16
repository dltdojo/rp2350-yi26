#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
The host exp238's monitor forwards to, and the runs that use it.

`ServiceEmulator` is tools/monitor's emulator with one more device: the service port at
0xc0000010, four words. Writing the first three records a call's arguments, writing the
fourth is the request, reading it back is the answer. The host behind it is deliberately
credulous: it does exactly what the arguments say, with M-mode's authority, reading and
writing any address it is given (modulo 2^32, and nothing where there is no memory). It does
not check a bound, so that a monitor which fails to is caught by what the host was made to do,
and `requests` records every call it was handed, for the tests to read.

`reference_run` runs the same payload with no monitor at all: M-mode, no PMP, `ecall` answered
by the same host functions in place. It is the oracle the monitor's run is compared with, for
the result and for the instruction count.
"""

import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP238 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP238, "../.."))
EXP228 = os.path.join(REPO, "experiments", "exp228-the-script-the-kernel-runs")
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
sys.path.insert(0, EXP228)
import harness
from monitor.emulator import SandboxEmulator, Trap, C_LOAD_ACCESS, C_STORE_ACCESS, BASE, M32

import cases as script_cases        # exp228's: the 34 scripts, the key, the message

SVC = 0xC0000010
BOX_LO, BOX_HI = 0x80010000, 0x80020000
MONITOR_WORDS = 0x80008000         # the M-mode stack: where trap entry saves the payload's t0..t3
TAG_HALT, TAG_FAULT = harness.TAG_HALT, harness.TAG_FAULT


def kernel() -> bytes:
    with open(os.path.join(EXP228, "kernel.bin"), "rb") as f:
        return f.read()


def hashb(mem_read, a0: int, a1: int) -> bytes:
    return hashlib.sha256(mem_read(a0, a1)).digest()


class Host:
    """The two services, over whatever memory `emu` has. Shared by both kinds of run."""

    def __init__(self, emu):
        self.emu = emu
        self.requests = []          # (call, a0, a1, a2) of every request the host was handed
        self.valid = []             # the answers CHECKSIG gave, in order

    def read(self, addr: int, n: int) -> bytes:
        emu, out = self.emu, bytearray()
        for i in range(n):
            off = ((addr + i) & M32) - BASE
            out.append(emu.mem[off] if 0 <= off < len(emu.mem) else 0)
        return bytes(out)

    def write(self, addr: int, data: bytes):
        emu = self.emu
        for i, b in enumerate(data):
            off = ((addr + i) & M32) - BASE
            if 0 <= off < len(emu.mem):
                emu.mem[off] = b

    def serve(self, call: int, a0: int, a1: int, a2: int) -> int:
        self.requests.append((call, a0, a1, a2))
        if call == 2:
            self.write(a2, hashlib.sha256(self.read(a0, a1)).digest())
            return 0
        ok = int(script_cases.valid(self.read(a0, 32), self.read(a1, 64)))
        self.valid.append(ok)
        return ok


class ServiceEmulator(SandboxEmulator):
    def __init__(self, image: bytes):
        super().__init__(image)
        self.host = Host(self)
        self.args = [0, 0, 0]
        self.answer = 0

    def load(self, addr, width):
        if SVC <= addr < SVC + 16:
            if width != 4 or addr % 4 or not self.pmp_ok(addr, 4, "R"):
                raise Trap(C_LOAD_ACCESS, addr)
            return self.answer if addr == SVC + 12 else 0
        return super().load(addr, width)

    def store(self, addr, width, val):
        if SVC <= addr < SVC + 16:
            if width != 4 or addr % 4 or not self.pmp_ok(addr, 4, "W"):
                raise Trap(C_STORE_ACCESS, addr)
            if addr == SVC + 12:
                self.answer = self.host.serve(val & M32, *self.args)
            else:
                self.args[(addr - SVC) // 4] = val & M32
            return
        super().store(addr, width, val)


class ReferenceEmulator(SandboxEmulator):
    """M-mode, no PMP, no monitor: the payload alone, `ecall` answered in place."""

    def __init__(self, image: bytes, entry: int, sp: int):
        super().__init__(image)
        self.host = Host(self)
        self.pc = entry
        self.regs = [0] * 32
        self.regs[2] = sp

    def step(self):
        off = self.pc - BASE
        if int.from_bytes(self.mem[off:off + 4], "little") != 0x00000073:
            return super().step()
        self.count()
        R = self.regs
        call = R[5]
        if call == 1:
            self.exit_code, self.halted = R[10], True
        elif call == 2:
            self.host.serve(2, R[10], R[11], R[12])
        elif call == 3:
            R[10] = self.host.serve(3, R[10], R[11], R[12])
        else:
            raise AssertionError(f"reference run: call {call}")
        self.pc = (self.pc + 4) & M32


def image(monitor: bytes, pay: bytes) -> bytes:
    return harness.image(monitor, pay)


def run(monitor: bytes, pay: bytes, steps: int = 400000) -> ServiceEmulator:
    emu = ServiceEmulator(image(monitor, pay))
    emu.run(steps)
    return emu


def reference_run(pay: bytes, steps: int = 400000) -> ReferenceEmulator:
    emu = ReferenceEmulator(bytes(0x10000) + pay, BOX_LO, BOX_HI)
    emu.run(steps)
    return emu


def box(emu) -> bytes:
    return bytes(emu.mem[BOX_LO - BASE:BOX_HI - BASE])


def boxed(request) -> bool:
    """Every range one request names lies wholly inside the box: the monitor's duty, stated outside it."""
    call, a0, a1, a2 = request
    ranges = [(a0, a1), (a2, 32)] if call == 2 else [(a0, 32), (a1, 64)]
    return all(BOX_LO <= p and p + n <= BOX_HI for p, n in ranges)


def stack_words(emu) -> list:
    return [harness.word(emu, MONITOR_WORDS + 4 * i) for i in range(4)]


def check_parked(emu, monitor: bytes, a0: int) -> list:
    """harness.check_parked, and the two more saved words this monitor leaves on its stack."""
    bad = harness.check_parked(emu, monitor, a0)
    if any(w for w in stack_words(emu)[2:]):
        bad.append("the saved t2/t3 are still on the M-mode stack")
    return bad


def check_refused(emu, monitor: bytes, cause: int = 8, asked: int = 0) -> list:
    """A payload the monitor must end: parked, scrubbed, FAULT with `cause`, and the host asked `asked` times."""
    bad = check_parked(emu, monitor, 1)
    if TAG_FAULT not in emu.prints:
        bad.append("no FAULT report")
    if emu.mcause != cause:
        bad.append(f"mcause {emu.mcause}, wanted {cause}")
    if len(emu.host.requests) != asked:
        bad.append(f"the host was asked {len(emu.host.requests)} times, not {asked}: {emu.host.requests}")
    return bad


def pack(pay: bytes, at: int, data: bytes) -> bytes:
    """`pay` (a box image, zero-padded to 64 KiB) with `data` written at box address `at`."""
    img = bytearray(pay) + bytes(max(0, 0x10000 - len(pay)))
    img[at - BOX_LO:at - BOX_LO + len(data)] = data
    return bytes(img)
