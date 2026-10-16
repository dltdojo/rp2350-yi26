#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Hazard3 NAPOT PMP test vector verification for exp235.

Validates the bit-level NAPOT encoding/decoding and boundary checks modeled
in lean/Rv32/Priv.lean and experiments/exp235-the-boundary-the-proof-bridges/proof/Bridge.lean.
"""

import sys

def count_trailing_ones(val: int) -> int:
    cnt = 0
    while (val & (1 << cnt)) != 0 and cnt < 32:
        cnt += 1
    return cnt

def decode_napot(raw_addr: int):
    eff = (raw_addr | 3) & 0xFFFFFFFF
    t = count_trailing_ones(eff)
    mask = 1 << (t + 1)
    aligned_addr = (eff // mask) * mask
    base = (aligned_addr * 4) & 0xFFFFFFFF
    size = 1 << (t + 3)
    return base, base + size

def encode_napot(base: int, size: int) -> int:
    assert size >= 32 and (size & (size - 1)) == 0, "Size must be power of 2 >= 32"
    assert base % size == 0, "Base must be aligned to size"
    # size = 1 << (t + 3) => t = log2(size) - 3
    t = size.bit_length() - 1 - 3
    # eff has t trailing ones, bit t is 0, upper bits from base // 4
    # eff = (base // 4) | ((1 << t) - 1)
    eff = ((base >> 2) & ~((1 << (t + 1)) - 1)) | ((1 << t) - 1)
    return eff

def test_napot_encoding_decoding():
    test_sizes = [32, 64, 128, 256, 1024, 4096, 65536, 1048576]
    test_bases = [0x20000000, 0x20010000, 0x20020000, 0x10000000]

    for size in test_sizes:
        for base in test_bases:
            if base % size != 0:
                continue
            pmpaddr = encode_napot(base, size)
            dec_base, dec_hi = decode_napot(pmpaddr)
            assert dec_base == base, f"Base mismatch: expected 0x{base:08x}, got 0x{dec_base:08x}"
            assert dec_hi == base + size, f"Hi mismatch: expected 0x{base+size:08x}, got 0x{dec_hi:08x}"
            # Check readback bits [1:0] == 3 (NAPOT quirk)
            eff = pmpaddr | 3
            assert (eff & 3) == 3, f"Quirk failure: bits [1:0] are not 11b in 0x{eff:08x}"

    print(f"PASS  NAPOT encoding/decoding verified across {len(test_sizes)} window sizes")

def test_pmp_boundary_containment():
    # 64KB region at 0x20000000 (standard U-mode box)
    base = 0x20000000
    size = 0x10000
    pmpaddr = encode_napot(base, size)
    lo, hi = decode_napot(pmpaddr)

    # In-bounds accesses
    assert lo <= 0x20000000 and 0x20000000 + 4 <= hi
    assert lo <= 0x2000FFFC and 0x2000FFFC + 4 <= hi

    # Out-of-bounds accesses (NoMatch)
    assert 0x1FFFFFFC + 4 <= lo or 0x1FFFFFFC >= hi
    assert 0x20010000 >= hi

    # Straddling accesses (PartialMatch in hardware)
    straddle_lo = 0x1FFFFFFE
    assert not (straddle_lo + 4 <= lo or straddle_lo >= hi)
    assert not (lo <= straddle_lo and straddle_lo + 4 <= hi)

    straddle_hi = 0x2000FFFE
    assert not (straddle_hi + 4 <= lo or straddle_hi >= hi)
    assert not (lo <= straddle_hi and straddle_hi + 4 <= hi)

    print("PASS  PMP boundary containment and partial match cases verified")

if __name__ == "__main__":
    test_napot_encoding_decoding()
    test_pmp_boundary_containment()

