#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp210 — sha_hw.h against the fake block (host/shafake.c), at the lengths
HASH is called with and some it is not.

  shatest.py SHAFAKE     PASS/FAIL lines; exit 0 = all pass

For each length: the message the block was fed must be the input padded as
SHA-256 defines (FIPS 180-4, 5.1.1), and the bytes sha_hw wrote must be the
digest hashlib computes, which the fake was handed for SUM0..7. The fake does
not hash, so this is everything around the compression, and only as far as
the fake is the block.
"""
import hashlib
import random
import subprocess
import sys


def padded(m):
    return m + b"\x80" + bytes((55 - len(m)) % 64) + (8 * len(m)).to_bytes(8, "big")


def main():
    fake, bad = sys.argv[1], 0
    rng = random.Random(210)
    lengths = [64, 128, 192, 4096, 65536]   # HASH's 64 (exp204, exp205) and others
    for n in lengths:
        m = bytes(rng.getrandbits(8) for _ in range(n))
        digest = hashlib.sha256(m).hexdigest()
        out = subprocess.run([fake, digest], input=m, capture_output=True).stdout.decode().split()
        fed_ok = out[:1] == [padded(m).hex()]
        out_ok = out[1:] == [digest, "ok"]
        if not (fed_ok and out_ok):
            print(f"FAIL  sha_hw at {n} bytes: " + ("" if fed_ok else "the block was not fed the padded message; ")
                  + ("" if out_ok else f"wrote {' '.join(out[1:])}, not {digest}"))
            bad = 1
    if not bad:
        print(f"PASS  sha_hw feeds the fake block SHA-256's padded message and returns its digest, "
              f"at {len(lengths)} lengths from 64 to 65536 bytes")
    return bad


if __name__ == "__main__":
    sys.exit(main())
