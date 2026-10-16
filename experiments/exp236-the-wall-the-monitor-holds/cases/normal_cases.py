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
import sys

P = 2**256 - 2**32 - 977

HERE = os.path.dirname(os.path.abspath(__file__))
EXP236 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP236, "../.."))
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

sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness

CASES = [
    (0, 42, 58),                   # add: 42 + 58 = 100
    (1, 100, 42),                  # sub: 100 - 42 = 58
    (1, 10, 20),                   # sub with borrow: (10 - 20) mod p = p - 10
    (2, 0x12345678, 0x87654321),   # mul: a * b mod p
]


def run_all(monitor: bytes) -> list:
    out = []
    for op, a, b in CASES:
        emu = harness.run(monitor, make_payload(op, a, b))
        bad = harness.check_halt(emu, monitor, 0)
        res = unpack_words(emu.mem[0x10944:0x10964], 8)
        if res != spec(op, a, b):
            bad.append(f"result {res:#x}, wanted {spec(op, a, b):#x}")
        if bad:
            out.append((f"op {op}: {a:#x}, {b:#x}", bad))
    return out


def test_normal_cases():
    with open(os.path.join(EXP236, "monitor.bin"), "rb") as f:
        monitor = f.read()
    failed = run_all(monitor)
    for name, bad in failed:
        print(f"FAIL  {name}: {'; '.join(bad)}")
    if failed:
        sys.exit(1)
    print(f"PASS  {len(CASES)} normal cases verified (exp229 add/sub/mul, a0=0, secret scrubbed)")


if __name__ == "__main__":
    test_normal_cases()
