#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Hazard3 NAPOT PMP test vectors for exp235.

Two checks. The arithmetic below is written from the RISC-V PMP rule, in a
different form from the Lean model's (bit tricks here, a trailing-ones loop
there), and is run against the model itself: `napot_eval.lean` evaluates
`decodeNapotRange` and `pmpCheck` from lean/Rv32/Priv.lean on the same vectors
and the two must agree on every one. With no Lean toolchain installed
(tools/lean/setup.sh not run) that half says SKIP and the Python half still runs.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LEAN_SH = os.path.join(HERE, "..", "..", "tools", "lean", "lean.sh")
M32 = 0xFFFFFFFF


def decode_napot(raw_addr: int):
    """[lo, hi) of a Hazard3 NAPOT pmpaddr (PMP_GRAIN = 3, so bits [1:0] read as 11)."""
    eff = (raw_addr | 3) & M32
    base = ((eff & (eff + 1)) << 2)           # clear the trailing ones, shift to bytes
    size = ((eff ^ (eff + 1)) + 1) << 2       # 2^(t+1) << 2 = 2^(t+3)
    return base, base + size


def encode_napot(base: int, size: int) -> int:
    """The pmpaddr the spec says to write for a naturally aligned power-of-two window."""
    assert size >= 32 and (size & (size - 1)) == 0, "size must be a power of 2 >= 32"
    assert base % size == 0, "base must be aligned to size"
    return (base | (size // 2 - 1)) >> 2


def in_box(lo, hi, addr, width):
    return lo <= addr and addr + width <= hi


def vectors():
    """(pmpaddr, addr, width) triples: every window size, and each boundary of each window."""
    out = []
    for size in [32, 64, 128, 256, 1024, 4096, 65536, 1048576]:
        for base in [0x20000000, 0x20010000, 0x20020000, 0x10000000]:
            if base % size:
                continue
            p = encode_napot(base, size)
            end = base + size
            for addr in [base - 4, base - 2, base - 1, base, base + 1, base + 4,
                         end - 8, end - 4, end - 3, end - 2, end - 1, end, end + 4]:
                for width in [1, 2, 4]:
                    out.append((p, addr & M32, width))
    # raw pmpaddr words that no encoder would write: the low bits are ignored,
    # the trailing ones set the size
    for p in [0x00000000, 0x00000003, 0x00000007, 0x0000000F, 0x08000003,
              0x08000004, 0x0800FFFF, 0x1FFFFFFF, 0x7FFFFFFF, 0xFFFFFFFF]:
        for addr in [0, 4, 0x20000000, 0xFFFFFFFC]:
            out.append((p, addr, 4))
    return out


def test_napot_encoding_decoding():
    sizes = [32, 64, 128, 256, 1024, 4096, 65536, 1048576]
    for size in sizes:
        for base in [0x20000000, 0x20010000, 0x20020000, 0x10000000]:
            if base % size:
                continue
            lo, hi = decode_napot(encode_napot(base, size))
            assert (lo, hi) == (base, base + size), \
                f"size {size} base 0x{base:08x}: decoded [0x{lo:08x}, 0x{hi:08x})"
    # the minimum window, and the whole address space, written out by hand
    assert decode_napot(0x00000000) == (0, 32)
    assert decode_napot(0xFFFFFFFF) == (0, 1 << 35)
    print(f"PASS  NAPOT encoding/decoding verified across {len(sizes)} window sizes")


def test_pmp_boundary_containment():
    lo, hi = decode_napot(encode_napot(0x20000000, 0x10000))
    assert (lo, hi) == (0x20000000, 0x20010000)
    assert in_box(lo, hi, 0x20000000, 4) and in_box(lo, hi, 0x2000FFFC, 4)
    assert not in_box(lo, hi, 0x1FFFFFFC, 4)       # wholly below
    assert not in_box(lo, hi, 0x20010000, 4)       # wholly above
    assert not in_box(lo, hi, 0x1FFFFFFE, 4)       # straddles the low edge
    assert not in_box(lo, hi, 0x2000FFFE, 4)       # straddles the high edge
    print("PASS  PMP boundary containment and partial match cases verified")


def test_against_the_lean_model():
    if not os.path.isdir(os.path.join(HERE, "..", "..", "tools", "lean", "lean-4.34.0-linux")):
        print("SKIP  Lean model cross-check: needs tools/lean/setup.sh")
        return
    vs = vectors()
    stdin = "".join(f"{p:x} {a:x} {w}\n" for p, a, w in vs)
    r = subprocess.run([LEAN_SH, "exec", os.path.join(HERE, "napot_eval.lean")],
                       input=stdin, capture_output=True, text=True)
    assert r.returncode == 0, f"lean exec failed: {r.stderr[-400:]}"
    lines = r.stdout.splitlines()
    assert len(lines) == len(vs), f"{len(lines)} answers for {len(vs)} vectors"
    for (p, a, w), line in zip(vs, lines):
        lo_s, hi_s, chk = line.split()
        lo, hi = decode_napot(p)
        assert (int(lo_s), int(hi_s)) == (lo, hi), \
            f"pmpaddr 0x{p:08x}: Lean [{lo_s}, {hi_s}) vs Python [{lo}, {hi})"
        assert (chk == "true") == in_box(lo, hi, a, w), \
            f"pmpaddr 0x{p:08x} addr 0x{a:08x} width {w}: Lean says {chk}"
    print(f"PASS  the Lean model agrees on all {len(vs)} vectors "
          f"(NAPOT range and U-mode load check)")


if __name__ == "__main__":
    try:
        test_napot_encoding_decoding()
        test_pmp_boundary_containment()
        test_against_the_lean_model()
    except AssertionError as e:
        print(f"FAIL  {e}")
        sys.exit(1)
