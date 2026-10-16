#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Adversarial attack test cases against the Micro-Monitor sandbox for exp236.

Tests 5 hostile U-mode payload attacks:
  1. Attack 1: Out-of-bounds Store to Monitor Code (0x80000000).
     Expects PMP Store Access Fault (mcause = 7) and monitor abort (exit code 1).
  2. Attack 2: Privilege Escalation via CSR Access (csrr mstatus).
     Expects Illegal Instruction (mcause = 2) and monitor abort (exit code 1).
  3. Attack 3: Out-of-bounds Load from System SRAM (0x20000000).
     Expects PMP Load Access Fault (mcause = 5) and monitor abort (exit code 1).
  4. Attack 4: Execution Escape via Jump to Monitor Code (0x80000040).
     Expects PMP Fetch Access Fault (mcause = 1) and monitor abort (exit code 1).
  5. Attack 5: Confused-Deputy Invalid Syscall (ecall with syscall != 1).
     Expects Monitor Syscall Dispatch Rejection and monitor abort (exit code 1).
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP236 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP236, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
from monitor.emulator import SandboxEmulator

def make_attack_image(instructions: list) -> bytes:
    monitor_bin = os.path.join(EXP236, "monitor.bin")
    with open(monitor_bin, "rb") as f:
        mon = f.read()
    payload = bytearray(b"\x00" * 0x10000)
    for i, inst in enumerate(instructions):
        struct.pack_into("<I", payload, i * 4, inst)
    image = mon + b"\x00" * (0x10000 - len(mon)) + bytes(payload)
    return image

def run_all_attacks():
    # Attack 1: Store to 0x80000000 (Monitor Base)
    # lui t0, 0x80000; sw x0, 0(t0)
    img1 = make_attack_image([0x800002b7, 0x0002a023])
    emu1 = SandboxEmulator(img1)
    emu1.run()
    assert emu1.exit_code == 1, f"Attack 1: expected exit_code 1, got {emu1.exit_code}"
    assert emu1.mcause == 7, f"Attack 1: expected mcause 7 (Store Access Fault), got {emu1.mcause}"
    assert emu1.mtval == 0x80000000, f"Attack 1: expected mtval 0x80000000, got {hex(emu1.mtval)}"
    # Check monitor code is intact (first word must still be 0x0400006f)
    mon_w0 = struct.unpack("<I", emu1.mem[0:4])[0]
    assert mon_w0 == 0x0400006f, f"Attack 1: monitor code was modified! {hex(mon_w0)}"

    # Attack 2: Privilege Escalation via CSR (csrr t0, mstatus)
    # csrr t0, 0x300
    img2 = make_attack_image([0x300022f3])
    emu2 = SandboxEmulator(img2)
    emu2.run()
    assert emu2.exit_code == 1, f"Attack 2: expected exit_code 1, got {emu2.exit_code}"
    assert emu2.mcause == 2, f"Attack 2: expected mcause 2 (Illegal Instruction), got {emu2.mcause}"

    # Attack 3: Out-of-bounds Load from 0x20000000 (SRAM)
    # lui t1, 0x20000; lw t0, 0(t1)
    img3 = make_attack_image([0x20000337, 0x00032283])
    emu3 = SandboxEmulator(img3)
    emu3.run()
    assert emu3.exit_code == 1, f"Attack 3: expected exit_code 1, got {emu3.exit_code}"
    assert emu3.mcause == 5, f"Attack 3: expected mcause 5 (Load Access Fault), got {emu3.mcause}"
    assert emu3.mtval == 0x20000000, f"Attack 3: expected mtval 0x20000000, got {hex(emu3.mtval)}"

    # Attack 4: Jump into Monitor Code (0x80000040)
    # lui t0, 0x80000; addi t0, t0, 0x040; jalr x0, 0(t0)
    img4 = make_attack_image([0x800002b7, 0x04028293, 0x00028067])
    emu4 = SandboxEmulator(img4)
    emu4.run()
    assert emu4.exit_code == 1, f"Attack 4: expected exit_code 1, got {emu4.exit_code}"
    assert emu4.mcause == 1, f"Attack 4: expected mcause 1 (Fetch Access Fault), got {emu4.mcause}"
    assert emu4.mtval == 0x80000040, f"Attack 4: expected mtval 0x80000040, got {hex(emu4.mtval)}"

    # Attack 5: Confused Deputy - Invalid Syscall number
    # lui t0, 1; addi t0, t0, 0x337; ecall (t0 = 0x1337)
    img5 = make_attack_image([0x000012b7, 0x33728293, 0x00000073])
    emu5 = SandboxEmulator(img5)
    emu5.run()
    assert emu5.exit_code == 1, f"Attack 5: expected exit_code 1, got {emu5.exit_code}"
    # Monitor caught invalid syscall and exited with 1
    # Check TAG_FAULT was emitted to print port
    assert 0x4641554c in emu5.prints, "Attack 5: TAG_FAULT not emitted"

    print("PASS  5 adversarial attacks caught and rejected by Micro-Monitor:")
    print("      1. Store to monitor code (0x80000000) -> mcause=7 (Store Access Fault), exit=1")
    print("      2. CSR read from U-mode (mstatus)     -> mcause=2 (Illegal Instruction), exit=1")
    print("      3. Load from out-of-bounds (0x20000000) -> mcause=5 (Load Access Fault), exit=1")
    print("      4. Execution escape (0x80000040)      -> mcause=1 (Fetch Access Fault), exit=1")
    print("      5. Invalid syscall id (0x1337)        -> syscall rejected, fault exit=1")

if __name__ == "__main__":
    run_all_attacks()
