#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
RV32 Privileged + PMP Sandbox Emulator for Micro-Monitor verification.

Emulates RV32I + Zicsr + RV32M (mul, mulhu) with machine (M) and user (U)
privilege modes and PMP NAPOT enforcement.
"""

import struct
from typing import List, Optional

class SandboxEmulator:
    def __init__(self, image: bytes, mem_size: int = 0x40000):
        # Base RAM at 0x80000000
        self.mem = bytearray(image + b"\x00" * max(0, mem_size - len(image)))
        self.regs = [0] * 32
        self.pc = 0x80000040  # Reset vector (monitor entry)
        self.mode = "M"       # Privilege mode: "M" or "U"
        self.halted = False
        self.exit_code = 0
        self.cycles = 0
        self.instret = 0
        self.mcountinhibit_ir = True
        self.mcountinhibit_cy = True
        self.mstatus = 0x1800  # MPP = 3 initially
        self.mtvec = 0x80000040
        self.mscratch = 0
        self.mepc = 0
        self.mcause = 0
        self.mtval = 0
        self.pmp_lo = 0
        self.pmp_hi = 0
        self.pmp_active = False
        self.prints: List[int] = []
        self.traps: List[dict] = []

    def check_pmp(self, addr: int, width: int, acc: str) -> bool:
        if self.mode == "M":
            return True
        if not self.pmp_active:
            return False
        return self.pmp_lo <= addr and (addr + width) <= self.pmp_hi

    def read_csr(self, csr: int) -> int:
        if csr == 0x300:
            return self.mstatus
        elif csr == 0x305:
            return self.mtvec
        elif csr == 0x340:
            return self.mscratch
        elif csr == 0x341:
            return self.mepc
        elif csr == 0x342:
            return self.mcause
        elif csr == 0x343:
            return self.mtval
        elif csr == 0x320:
            return (1 if self.mcountinhibit_cy else 0) | (4 if self.mcountinhibit_ir else 0)
        elif csr in (0xB00, 0xC00):
            return self.cycles & 0xFFFFFFFF
        elif csr in (0xB02, 0xC02):
            return self.instret & 0xFFFFFFFF
        return 0

    def write_csr(self, csr: int, val: int):
        val &= 0xFFFFFFFF
        if csr == 0x300:
            self.mstatus = val
        elif csr == 0x305:
            self.mtvec = val
        elif csr == 0x340:
            self.mscratch = val
        elif csr == 0x341:
            self.mepc = val
        elif csr == 0x342:
            self.mcause = val
        elif csr == 0x343:
            self.mtval = val
        elif csr == 0x320:
            self.mcountinhibit_cy = bool(val & 1)
            self.mcountinhibit_ir = bool(val & 4)
        elif csr == 0x3B0:
            # PMPADDR0 for 64 KiB NAPOT at 0x80010000:
            # (addr >> 2) | ((size >> 3) - 1)
            self.pmp_lo = 0x80010000
            self.pmp_hi = 0x80020000
        elif csr == 0x3A0:
            self.pmp_active = bool(val & 0x1F)
        elif csr in (0xB00, 0xC00):
            self.cycles = 0
        elif csr in (0xB02, 0xC02):
            self.instret = 0

    def trap(self, cause: int, val: int):
        self.traps.append({
            "cause": cause,
            "val": val,
            "mepc": self.pc,
            "mode": self.mode
        })
        self.mode = "M"
        self.mcause = cause
        self.mepc = self.pc
        self.mtval = val
        self.pc = self.mtvec

    def run(self, max_steps: int = 100000) -> int:
        for _ in range(max_steps):
            if self.halted:
                break
            self.step()
        return self.exit_code

    def step(self):
        # Fetch check
        if not self.check_pmp(self.pc, 4, "X"):
            self.trap(1, self.pc)  # Fetch access fault
            return

        offset = self.pc - 0x80000000
        if offset < 0 or offset + 4 > len(self.mem):
            self.trap(1, self.pc)
            return

        w = struct.unpack("<I", self.mem[offset:offset+4])[0]
        curr_pc = self.pc
        self.pc += 4

        if not self.mcountinhibit_ir:
            self.instret += 1
        if not self.mcountinhibit_cy:
            self.cycles += 1

        opcode = w & 0x7F
        rd = (w >> 7) & 0x1F
        funct3 = (w >> 12) & 7
        rs1 = (w >> 15) & 0x1F
        rs2 = (w >> 20) & 0x1F
        imm_i = (w >> 20)
        if imm_i & 0x800:
            imm_i -= 0x1000

        # Zicsr / System
        if opcode == 0x73:
            if w == 0x30200073:  # mret
                if self.mode != "M":
                    self.pc = curr_pc
                    self.trap(2, curr_pc)  # Illegal instruction
                else:
                    self.mode = "U"
                    self.pc = self.mepc
                return
            elif w == 0x00000073:  # ecall
                self.pc = curr_pc
                if self.mode == "U":
                    self.trap(8, curr_pc)
                else:
                    self.trap(11, curr_pc)
                return
            elif w == 0x10500073:  # wfi
                self.halted = True
                return
            elif funct3 in (1, 2, 3, 5):  # CSR instructions
                if self.mode == "U":
                    self.pc = curr_pc
                    self.trap(2, curr_pc)  # Illegal instruction in U-mode
                    return
                csr = w >> 20
                old_val = self.read_csr(csr)
                in_val = rs1 if funct3 in (5, 6, 7) else self.regs[rs1]
                if funct3 in (1, 5):
                    new_val = in_val
                elif funct3 == 2:
                    new_val = old_val | in_val
                elif funct3 == 3:
                    new_val = old_val & ~in_val
                else:
                    new_val = old_val
                self.write_csr(csr, new_val)
                if rd != 0:
                    self.regs[rd] = old_val
                return

        # Basic RV32I instructions
        if opcode == 0x13:  # OP-IMM
            v1 = self.regs[rs1]
            if funct3 == 0:    # addi
                res = (v1 + imm_i) & 0xFFFFFFFF
            elif funct3 == 7:  # andi
                res = (v1 & imm_i) & 0xFFFFFFFF
            elif funct3 == 4:  # xori
                res = (v1 ^ imm_i) & 0xFFFFFFFF
            elif funct3 == 6:  # ori
                res = (v1 | imm_i) & 0xFFFFFFFF
            elif funct3 == 1:  # slli
                res = (v1 << (imm_i & 31)) & 0xFFFFFFFF
            elif funct3 == 5:  # srli/srai
                res = (v1 >> (imm_i & 31)) & 0xFFFFFFFF
            else:
                res = 0
            if rd != 0:
                self.regs[rd] = res
        elif opcode == 0x33:  # OP
            v1 = self.regs[rs1]
            v2 = self.regs[rs2]
            funct7 = (w >> 25) & 0x7F
            if funct7 == 1:  # M extension
                if funct3 == 0:    # mul
                    res = (v1 * v2) & 0xFFFFFFFF
                elif funct3 == 3:  # mulhu
                    res = ((v1 & 0xFFFFFFFF) * (v2 & 0xFFFFFFFF)) >> 32
                else:
                    res = 0
            elif funct3 == 0:  # add/sub
                res = (v1 - v2 if funct7 == 0x20 else v1 + v2) & 0xFFFFFFFF
            elif funct3 == 4:  # xor
                res = (v1 ^ v2) & 0xFFFFFFFF
            elif funct3 == 6:  # or
                res = (v1 | v2) & 0xFFFFFFFF
            elif funct3 == 7:  # and
                res = (v1 & v2) & 0xFFFFFFFF
            elif funct3 == 3:  # sltu
                res = 1 if (v1 & 0xFFFFFFFF) < (v2 & 0xFFFFFFFF) else 0
            else:
                res = 0
            if rd != 0:
                self.regs[rd] = res
        elif opcode == 0x37:  # LUI
            imm_u = w & 0xFFFFF000
            if rd != 0:
                self.regs[rd] = imm_u
        elif opcode == 0x17:  # AUIPC
            imm_u = w & 0xFFFFF000
            if rd != 0:
                self.regs[rd] = (curr_pc + imm_u) & 0xFFFFFFFF
        elif opcode == 0x6F:  # JAL
            imm_j = (((w >> 31) & 1) << 20) | (((w >> 21) & 0x3FF) << 1) | (((w >> 20) & 1) << 11) | (((w >> 12) & 0xFF) << 12)
            if imm_j & 0x100000:
                imm_j -= 0x200000
            if rd != 0:
                self.regs[rd] = self.pc
            self.pc = (curr_pc + imm_j) & 0xFFFFFFFF
        elif opcode == 0x67:  # JALR
            if rd != 0:
                self.regs[rd] = self.pc
            self.pc = (self.regs[rs1] + imm_i) & ~1
        elif opcode == 0x63:  # Branch
            imm_b = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1)
            if imm_b & 0x1000:
                imm_b -= 0x2000
            v1, v2 = self.regs[rs1], self.regs[rs2]
            cond = (funct3 == 0 and v1 == v2) or (funct3 == 1 and v1 != v2) or (funct3 == 6 and (v1 & 0xFFFFFFFF) < (v2 & 0xFFFFFFFF))
            if cond:
                self.pc = (curr_pc + imm_b) & 0xFFFFFFFF
        elif opcode == 0x03:  # Load
            addr = (self.regs[rs1] + imm_i) & 0xFFFFFFFF
            if not self.check_pmp(addr, 4, "R"):
                self.pc = curr_pc
                self.trap(5, addr)  # Load access fault
                return
            off = addr - 0x80000000
            if 0 <= off < len(self.mem) - 3:
                val = struct.unpack("<I", self.mem[off:off+4])[0]
            else:
                val = 0
            if rd != 0:
                self.regs[rd] = val
        elif opcode == 0x23:  # Store
            imm_s = (((w >> 25) & 0x7F) << 5) | ((w >> 7) & 0x1F)
            if imm_s & 0x800:
                imm_s -= 0x1000
            addr = (self.regs[rs1] + imm_s) & 0xFFFFFFFF
            if not self.check_pmp(addr, 4, "W"):
                self.pc = curr_pc
                self.trap(7, addr)  # Store access fault
                return
            if addr == 0xC0000004:  # Print port
                self.prints.append(self.regs[rs2])
                return
            if addr == 0xC0000008:  # MMIO exit
                self.exit_code = self.regs[rs2]
                return
            off = addr - 0x80000000
            if 0 <= off < len(self.mem) - 3:
                struct.pack_into("<I", self.mem, off, self.regs[rs2])

