#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp222 — what the shell checks against, computed here and compiled in.

  gen.py OUT.h RV32RUN

  KERNEL, KERNEL_SHA      kernel.bin, as proof/Health.lean writes it, checked
                          against kernel.sha256
  INSTRET_PASS/_FAIL      the Hazard3 RTL's minstret for the kernel on a stream
                          that passes and on one that does not. By
                          `withholds` the count depends on the verdict alone,
                          so one of each is the count for every stream

and, before writing anything, the Lean model on the same two images: it must
halt with 0 after exactly 23574 on the first and with 1 after exactly 17427
on the second, the counts `withholds` proves. tools/hazard3/shell/
healthexpect.py does it.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "hazard3", "shell"))
from healthexpect import write_health  # noqa: E402
from streams import N  # noqa: E402

SAMPLES = 0x1000


def image(kernel, words):
    img = bytearray(0x10000)
    img[:len(kernel)] = kernel
    img[SAMPLES:SAMPLES + 4 * N] = struct.pack(f"<{N}I", *words)
    return bytes(img)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sha, counts = write_health(sys.argv[1], sys.argv[2], "exp222", os.path.join(HERE, "kernel"), image,
                               {True: 23574, False: 17427})
    print(f"{sys.argv[1]}: kernel {sha[:16]}…, RTL minstret {counts['pass']} healthy, {counts['fail']} withheld")
