#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
RV32IM + Zicsr emulator with machine/user privilege and a four-entry NAPOT PMP.

It exists to run the micro-monitor and a hostile payload against each other, and to say
something when the monitor is *wrong*: nothing about the monitor's configuration is written
into it. The PMP is whatever `pmpcfg0` and `pmpaddr0..3` say when the instruction runs,
`mret` returns to the privilege `mstatus.MPP` holds, and a CSR the model does not have traps.

It is a second, independent reading of the specification next to `lean/Rv32/Priv.lean`, written
for testing rather than proof: a monitor and a payload agree with it, or they do not.

Memory is flat RAM at `BASE`; two words of MMIO stand for the testbench's print and exit ports.
An access the PMP allows to an address with no RAM there faults with the same `mcause` and `mtval`
as one the PMP refuses, as a bus fault does on the chip; `Trap.by` and each entry of `traps` say
which it was (`"pmp"` or `"bus"`), so that a test can tell a box that held from a box that let the
access through to nothing.
Not modelled: interrupts, the C extension, `mcounteren`, `fence`, `ebreak` beyond its trap.
"""

import struct
from typing import List

BASE = 0x80000000
IO_PRINT = 0xC0000004
IO_EXIT = 0xC0000008

M32 = 0xFFFFFFFF

# mcause
C_FETCH_MISALIGNED = 0
C_FETCH_ACCESS = 1
C_ILLEGAL = 2
C_BREAKPOINT = 3
C_LOAD_MISALIGNED = 4
C_LOAD_ACCESS = 5
C_STORE_MISALIGNED = 6
C_STORE_ACCESS = 7
C_ECALL_U = 8
C_ECALL_M = 11

# CSR numbers
MSTATUS, MTVEC, MCOUNTINHIBIT = 0x300, 0x305, 0x320
MSCRATCH, MEPC, MCAUSE, MTVAL = 0x340, 0x341, 0x342, 0x343
PMPCFG0, PMPADDR0 = 0x3A0, 0x3B0
MCYCLE, MINSTRET, MCYCLEH, MINSTRETH = 0xB00, 0xB02, 0xB80, 0xB82
CYCLE, INSTRET = 0xC00, 0xC02

MIE, MPIE = 1 << 3, 1 << 7


def sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


class Trap(Exception):
    """A trap: `cause` and `tval`, and for an access fault `by`, what refused it -- `"pmp"`, or `"bus"`: no memory there."""
    def __init__(self, cause: int, tval: int = 0, by: str = None):
        self.cause, self.tval, self.by = cause, tval, by


class SandboxEmulator:
    def __init__(self, image: bytes, mem_size: int = 0x40000):
        self.mem = bytearray(image + b"\x00" * max(0, mem_size - len(image)))
        # Registers come out of reset holding whatever they hold: junk, so that a monitor that
        # trusts them to be zero is caught.
        self.regs = [0] + [0xA5A50000 | r for r in range(1, 32)]
        self.pc = BASE + 0x40            # reset vector: the monitor's first word after `_start`
        self.mode = "M"
        self.halted = False
        self.exit_code = 0
        self.mstatus = 0
        self.mtvec = 0
        self.mscratch = 0
        self.mepc = 0
        self.mcause = 0
        self.mtval = 0
        self.mcountinhibit = 0
        self.pmpcfg0 = 0
        self.pmpaddr = [0, 0, 0, 0]
        self.mcycle = 0
        self.minstret = 0
        self.prints: List[int] = []
        self.traps: List[dict] = []

    # ---- PMP -------------------------------------------------------------------------------

    def pmp_entry(self, i: int):
        """(mode, r, w, x, lock, lo, hi) of entry i; only OFF and NAPOT exist (PMP_GRAIN = 3)."""
        cfg = (self.pmpcfg0 >> (8 * i)) & 0xFF
        a = (cfg >> 3) & 3
        if a != 3:
            return ("OFF", False, False, False, bool(cfg & 0x80), 0, 0)
        eff = (self.pmpaddr[i] | 3) & M32
        t = 0
        while (eff >> t) & 1 and t < 32:
            t += 1
        base = ((eff >> (t + 1)) << (t + 1)) << 2
        size = 1 << (t + 3)
        return ("NAPOT", bool(cfg & 1), bool(cfg & 2), bool(cfg & 4), bool(cfg & 0x80), base, base + size)

    def pmp_ok(self, addr: int, width: int, acc: str) -> bool:
        for i in range(4):
            mode, r, w, x, lock, lo, hi = self.pmp_entry(i)
            if mode == "OFF":
                continue
            if addr + width <= lo or addr >= hi:
                continue
            if not (lo <= addr and addr + width <= hi):
                return False                      # partial match
            if self.mode == "M" and not lock:
                return True
            return {"R": r, "W": w, "X": x}[acc]
        return self.mode == "M"

    # ---- memory ----------------------------------------------------------------------------

    def load(self, addr: int, width: int) -> int:
        if addr % width:
            raise Trap(C_LOAD_MISALIGNED, addr)
        if not self.pmp_ok(addr, width, "R"):
            raise Trap(C_LOAD_ACCESS, addr, "pmp")
        off = addr - BASE
        if not (0 <= off and off + width <= len(self.mem)):
            raise Trap(C_LOAD_ACCESS, addr, "bus")
        return int.from_bytes(self.mem[off:off + width], "little")

    def store(self, addr: int, width: int, val: int):
        if addr % width:
            raise Trap(C_STORE_MISALIGNED, addr)
        if not self.pmp_ok(addr, width, "W"):
            raise Trap(C_STORE_ACCESS, addr, "pmp")
        if addr == IO_PRINT and width == 4:
            self.prints.append(val & M32)
            return
        if addr == IO_EXIT and width == 4:
            self.exit_code = val & M32
            return
        off = addr - BASE
        if not (0 <= off and off + width <= len(self.mem)):
            raise Trap(C_STORE_ACCESS, addr, "bus")
        self.mem[off:off + width] = (val & ((1 << (8 * width)) - 1)).to_bytes(width, "little")

    # ---- CSRs ------------------------------------------------------------------------------

    CSRS = {MSTATUS, MTVEC, MCOUNTINHIBIT, MSCRATCH, MEPC, MCAUSE, MTVAL, PMPCFG0,
            PMPADDR0, PMPADDR0 + 1, PMPADDR0 + 2, PMPADDR0 + 3,
            MCYCLE, MINSTRET, MCYCLEH, MINSTRETH, CYCLE, INSTRET}

    def csr_read(self, n: int) -> int:
        if n == MSTATUS:
            return self.mstatus
        if n == MTVEC:
            return self.mtvec
        if n == MCOUNTINHIBIT:
            return self.mcountinhibit
        if n == MSCRATCH:
            return self.mscratch
        if n == MEPC:
            return self.mepc
        if n == MCAUSE:
            return self.mcause
        if n == MTVAL:
            return self.mtval
        if n == PMPCFG0:
            return self.pmpcfg0
        if PMPADDR0 <= n < PMPADDR0 + 4:
            i = n - PMPADDR0
            cfg_a = (self.pmpcfg0 >> (8 * i + 3)) & 3
            return (self.pmpaddr[i] | 3) if cfg_a == 3 else (self.pmpaddr[i] & ~7 & M32)
        if n in (MCYCLE, CYCLE):
            return self.mcycle & M32
        if n in (MINSTRET, INSTRET):
            return self.minstret & M32
        return 0                                  # mcycleh / minstreth: the counters are 32 bits

    def csr_write(self, n: int, v: int):
        v &= M32
        if n == MSTATUS:
            self.mstatus = v & (MIE | MPIE | (3 << 11))
        elif n == MTVEC:
            self.mtvec = v & ~3 & M32
        elif n == MCOUNTINHIBIT:
            self.mcountinhibit = v & 5
        elif n == MSCRATCH:
            self.mscratch = v
        elif n == MEPC:
            self.mepc = v
        elif n == MCAUSE:
            self.mcause = v
        elif n == MTVAL:
            self.mtval = v
        elif n == PMPCFG0:
            new = 0
            for i in range(4):
                old_b = (self.pmpcfg0 >> (8 * i)) & 0xFF
                new_b = old_b if old_b & 0x80 else (v >> (8 * i)) & 0xFF
                new |= new_b << (8 * i)
            self.pmpcfg0 = new
        elif PMPADDR0 <= n < PMPADDR0 + 4:
            i = n - PMPADDR0
            if not ((self.pmpcfg0 >> (8 * i)) & 0x80):
                self.pmpaddr[i] = v
        elif n == MCYCLE:
            self.mcycle = v
        elif n == MINSTRET:
            self.minstret = v
        # mcycleh / minstreth: dropped

    # ---- traps -----------------------------------------------------------------------------

    def take_trap(self, cause: int, tval: int, by: str = None):
        self.traps.append({"cause": cause, "tval": tval, "mepc": self.pc, "mode": self.mode, "by": by})
        mpp = 3 if self.mode == "M" else 0
        mie = bool(self.mstatus & MIE)
        self.mstatus = (mpp << 11) | (MPIE if mie else 0)
        self.mepc, self.mcause, self.mtval = self.pc, cause, tval
        self.mode = "M"
        self.pc = self.mtvec
        self.count()

    def count(self):
        if not self.mcountinhibit & 1:
            self.mcycle = (self.mcycle + 1) & M32
        if not self.mcountinhibit & 4:
            self.minstret = (self.minstret + 1) & M32

    # ---- run -------------------------------------------------------------------------------

    def run(self, max_steps: int = 200000) -> int:
        for _ in range(max_steps):
            if self.halted:
                break
            self.step()
        return self.exit_code

    def step(self):
        try:
            self.execute()
        except Trap as t:
            self.take_trap(t.cause, t.tval, t.by)

    def execute(self):
        pc = self.pc
        if pc % 4:
            raise Trap(C_FETCH_MISALIGNED, pc)
        if not self.pmp_ok(pc, 4, "X"):
            raise Trap(C_FETCH_ACCESS, pc, "pmp")
        off = pc - BASE
        if not (0 <= off and off + 4 <= len(self.mem)):
            raise Trap(C_FETCH_ACCESS, pc, "bus")
        w = struct.unpack("<I", self.mem[off:off + 4])[0]
        op = w & 0x7F
        rd, f3, rs1, rs2, f7 = (w >> 7) & 31, (w >> 12) & 7, (w >> 15) & 31, (w >> 20) & 31, w >> 25
        R = self.regs
        a, b = R[rs1], R[rs2]
        nxt = (pc + 4) & M32
        res = None

        if op == 0x37:
            res = w & 0xFFFFF000
        elif op == 0x17:
            res = (pc + (w & 0xFFFFF000)) & M32
        elif op == 0x6F:
            imm = sext(((w >> 31) << 20) | (((w >> 12) & 0xFF) << 12) | (((w >> 20) & 1) << 11)
                       | (((w >> 21) & 0x3FF) << 1), 21)
            res, nxt = (pc + 4) & M32, (pc + imm) & M32
        elif op == 0x67 and f3 == 0:
            res, nxt = (pc + 4) & M32, (a + sext(w >> 20, 12)) & ~1 & M32
        elif op == 0x63 and f3 not in (2, 3):
            imm = sext(((w >> 31) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 0x3F) << 5)
                       | (((w >> 8) & 0xF) << 1), 13)
            sa, sb = sext(a, 32), sext(b, 32)
            take = [a == b, a != b, False, False, sa < sb, sa >= sb, a < b, a >= b][f3]
            if take:
                nxt = (pc + imm) & M32
        elif op == 0x03 and f3 in (0, 1, 2, 4, 5):
            addr = (a + sext(w >> 20, 12)) & M32
            width = (1, 2, 4, 0, 1, 2)[f3]
            v = self.load(addr, width)
            res = sext(v, 8 * width) & M32 if f3 < 3 else v
        elif op == 0x23 and f3 in (0, 1, 2):
            imm = sext(((w >> 25) << 5) | ((w >> 7) & 31), 12)
            self.store((a + imm) & M32, (1, 2, 4)[f3], b)
        elif op == 0x13:
            imm = sext(w >> 20, 12)
            if f3 == 0:
                res = (a + imm) & M32
            elif f3 == 2:
                res = int(sext(a, 32) < imm)
            elif f3 == 3:
                res = int(a < (imm & M32))
            elif f3 == 4:
                res = (a ^ imm) & M32
            elif f3 == 6:
                res = (a | imm) & M32
            elif f3 == 7:
                res = (a & imm) & M32
            elif f3 == 1 and f7 == 0:
                res = (a << rs2) & M32
            elif f3 == 5 and f7 in (0, 0x20):
                res = ((sext(a, 32) >> rs2) & M32) if f7 == 0x20 else (a >> rs2)
            else:
                raise Trap(C_ILLEGAL, w)
        elif op == 0x33:
            res = self.alu(f3, f7, a, b, w)
        elif op == 0x73:
            return self.system(w, pc, rd, f3, rs1)
        else:
            raise Trap(C_ILLEGAL, w)

        if res is not None and rd:
            R[rd] = res & M32
        self.pc = nxt
        self.count()

    def alu(self, f3, f7, a, b, w):
        sa, sb = sext(a, 32), sext(b, 32)
        if f7 == 1:
            if f3 == 0:
                return (a * b) & M32
            if f3 == 1:
                return ((sa * sb) >> 32) & M32
            if f3 == 2:
                return ((sa * b) >> 32) & M32
            if f3 == 3:
                return (a * b) >> 32
            if f3 in (4, 6):
                if b == 0:
                    return M32 if f3 == 4 else a
                q = abs(sa) // abs(sb)
                if (sa < 0) != (sb < 0):
                    q = -q
                return (q if f3 == 4 else sa - q * sb) & M32
            if f3 == 5:
                return M32 if b == 0 else a // b
            return a if b == 0 else a % b
        if f7 not in (0, 0x20) or (f7 == 0x20 and f3 not in (0, 5)):
            raise Trap(C_ILLEGAL, w)
        if f3 == 0:
            return (a - b if f7 == 0x20 else a + b) & M32
        if f3 == 1:
            return (a << (b & 31)) & M32
        if f3 == 2:
            return int(sa < sb)
        if f3 == 3:
            return int(a < b)
        if f3 == 4:
            return a ^ b
        if f3 == 5:
            return ((sa >> (b & 31)) & M32) if f7 == 0x20 else (a >> (b & 31))
        return a | b if f3 == 6 else a & b

    def system(self, w, pc, rd, f3, rs1):
        if f3 == 0:
            if w == 0x00000073:
                raise Trap(C_ECALL_U if self.mode == "U" else C_ECALL_M, 0)
            if w == 0x00100073:
                raise Trap(C_BREAKPOINT, pc)
            if w == 0x30200073:                               # mret
                if self.mode != "M":
                    raise Trap(C_ILLEGAL, w)
                mpp = (self.mstatus >> 11) & 3
                mpie = bool(self.mstatus & MPIE)
                self.mstatus = (MIE if mpie else 0) | MPIE
                self.mode = "M" if mpp == 3 else "U"
                self.pc = self.mepc
                self.count()
                return
            if w == 0x10500073:                               # wfi: park
                if self.mode != "M":
                    raise Trap(C_ILLEGAL, w)
                self.halted = True
                return
            raise Trap(C_ILLEGAL, w)
        if self.mode != "M" or f3 == 4:
            raise Trap(C_ILLEGAL, w)
        n = w >> 20
        if n not in self.CSRS:
            raise Trap(C_ILLEGAL, w)
        src = rs1 if f3 >= 5 else self.regs[rs1]
        writes = True if f3 in (1, 5) else src != 0
        if writes and (n >> 10) == 3:                         # read-only CSR
            raise Trap(C_ILLEGAL, w)
        old = self.csr_read(n)
        if f3 in (1, 5):
            new = src
        elif f3 in (2, 6):
            new = old | src
        else:
            new = old & ~src
        if writes:
            self.csr_write(n, new)
        if rd:
            self.regs[rd] = old
        self.pc = (pc + 4) & M32
        self.count()
        # a write to a counter is the last word on it
        if writes and n == MCYCLE:
            self.mcycle = new & M32
        if writes and n == MINSTRET:
            self.minstret = new & M32
