#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Normal execution test cases for exp236.

Runs monitor.bin combined with exp229's secp256k1 field arithmetic kernel
(op = 0 add, op = 1 sub, op = 2 mul) inside the PMP-enforced U-mode sandbox.
Verifies:
  1. Arithmetic output R == (a op b) mod p.
  2. Exit status in a0 == 0.
  3. Secret zeroization: registers x1..x9 and x11..x31 are wiped to 0.
"""

import os
import struct
import subprocess
import sys

P = 2**256 - 2**32 - 977

HERE = os.path.dirname(os.path.abspath(__file__))
EXP236 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP236, "../.."))
SIM_SH = os.path.join(REPO, "tools/hazard3/sim.sh")
EXP229_KERNEL = os.path.join(REPO, "experiments/exp229-the-remainder-the-kernel-keeps/kernel.bin")

def pack_words(num: int, n_words: int = 8) -> bytes:
    res = bytearray()
    for _ in range(n_words):
        res += struct.pack("<I", num & 0xFFFFFFFF)
        num >>= 32
    return bytes(res)

def unpack_words(data: bytes, n_words: int = 8) -> int:
    num = 0
    for i in reversed(range(n_words)):
        w = struct.unpack("<I", data[i*4:(i+1)*4])[0]
        num = (num << 32) | w
    return num

def spec(op: int, a: int, b: int) -> int:
    if op == 0:
        return (a + b) % P
    elif op == 1:
        return (a + P - b) % P
    elif op == 2:
        return (a * b) % P
    raise ValueError(f"Unknown op {op}")

def make_payload(op: int, a: int, b: int) -> bytes:
    with open(EXP229_KERNEL, "rb") as f:
        kernel = f.read()
    img = bytearray(kernel) + bytes(max(0, 0x944 + 36 - len(kernel)))
    # OPW = 0x900
    img[0x900:0x904] = struct.pack("<I", op)
    # A = 0x904
    img[0x904:0x924] = pack_words(a, 8)
    # B = 0x924
    img[0x924:0x944] = pack_words(b, 8)
    if len(img) < 0x10000:
        img += b"\x00" * (0x10000 - len(img))
    return bytes(img)

def make_full_image(payload: bytes) -> bytes:
    monitor_bin = os.path.join(EXP236, "monitor.bin")
    with open(monitor_bin, "rb") as f:
        mon = f.read()
    assert len(mon) <= 0x10000, "Monitor binary exceeds 64 KiB space"
    image = mon + b"\x00" * (0x10000 - len(mon)) + payload
    return image

sys.path.insert(0, os.path.join(REPO, "tools"))
from monitor.emulator import SandboxEmulator

def test_normal_cases():
    test_cases = [
        (0, 42, 58),                   # add: 42 + 58 = 100
        (1, 100, 42),                  # sub: 100 - 42 = 58
        (1, 10, 20),                   # sub with borrow: (10 - 20) mod p = p - 10
        (2, 0x12345678, 0x87654321),   # mul: a * b mod p
    ]

    for op, a, b in test_cases:
        expected = spec(op, a, b)
        payload = make_payload(op, a, b)
        image = make_full_image(payload)

        emu = SandboxEmulator(image)
        emu.run()

        # Check return code in a0 (x10)
        assert emu.regs[10] == 0, f"Expected a0 == 0, got {emu.regs[10]}"
        # Check result at R (0x0944 in payload)
        res_data = emu.mem[0x10944:0x10964]
        res = unpack_words(res_data, 8)
        assert res == expected, f"Result mismatch: expected {expected}, got {res}"
        # Check secret zeroization: x1..x9 and x11..x31 are 0
        for r in range(1, 32):
            if r != 10:
                assert emu.regs[r] == 0, f"Register x{r} was not zeroed: {emu.regs[r]}"

    print(f"PASS  {len(test_cases)} normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)")

if __name__ == "__main__":
    test_normal_cases()
