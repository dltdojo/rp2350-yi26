#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp223 — what the shell checks against, computed here and compiled in.

  gen.py OUT.h RV32RUN

  KERNEL, KERNEL_SHA      kernel.bin, as proof/Condition.lean writes it,
                          checked against kernel.sha256
  INSTRET_PASS/_FAIL      the Hazard3 RTL's minstret for the kernel on a stream
                          that passes and on one that does not, in the 128 KiB
                          region. By `conditions` the count depends on the
                          verdict alone, so one of each is the count for every
                          stream

and, before writing anything, the Lean model on the same two images: it must
halt with 0 after exactly 334284 on the first, its digest hashlib's, and with
1 after exactly 17425 on the second, the counts `conditions` proves.
tools/hazard3/shell/healthexpect.py does it.
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "hazard3", "shell"))
from healthexpect import write_health  # noqa: E402
from streams import N  # noqa: E402

SAMPLES, DIGEST = 0x3000, 0x2140


def image(kernel, words):
    img = bytearray(SAMPLES + 4 * N)
    img[:len(kernel)] = kernel
    img[SAMPLES:] = struct.pack(f"<{N}I", *words)
    return bytes(img)


def digest(ok, img, region):
    if ok and region[DIGEST:DIGEST + 32] != hashlib.sha256(img[SAMPLES:]).digest():
        return "the model's digest is not hashlib's"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sha, counts = write_health(sys.argv[1], sys.argv[2], "exp223", os.path.join(HERE, "kernel"), image,
                               {True: 334284, False: 17425}, wide=True, also=digest)
    print(f"{sys.argv[1]}: kernel {sha[:16]}…, RTL minstret {counts['pass']} conditioned, {counts['fail']} withheld")
