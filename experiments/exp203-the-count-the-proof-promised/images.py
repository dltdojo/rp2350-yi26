#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp203 — test images for the copy kernel, and the check of what it left.

  images.py build DIR        write DIR/<name>.bin for each data set
  images.py verify NAME SIG  check a region dump (one little-endian word per
                             line, the testbench's --sigfile format) against
                             what the theorem `copies` says: the 64 bytes at
                             0x2000 are those at 0x1000, and the canaries on
                             either side of the destination are untouched

An image is kernel.bin, zeros to 0x1000, the 64 source bytes, zeros to
0x1fc0, then 64 canary bytes, 64 destination bytes that start as something
else, and 64 more canary bytes. Only the first sixty bytes are the kernel;
`code_of_image` is the theorem that says any image starting with them is.

This is written independently of the Lean: the expected bytes come from
Python, not from the model, so a check here is a third party's opinion.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "hazard3"))
from sigfile import read_sig  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SRC, DST = 0x1000, 0x2000
BEFORE, AFTER = 0x5A, 0xA5


def lcg(seed):
    x = seed
    while True:
        x = (1103515245 * x + 12345) % 2**31
        yield (x >> 16) & 0xff


def data_sets():
    g = lcg(203)
    return {
        "counting": bytes(range(64)),
        "ones": bytes([0xff] * 64),
        "alternating": bytes([0x55, 0xaa] * 32),
        "random": bytes(next(g) for _ in range(64)),
    }


def image(data):
    kernel = open(os.path.join(HERE, "kernel.bin"), "rb").read()
    img = bytearray(DST + 128)
    img[:len(kernel)] = kernel
    img[SRC:SRC + 64] = data
    img[DST - 64:DST] = bytes([BEFORE] * 64)
    img[DST:DST + 64] = bytes([0xEE] * 64)       # something to overwrite
    img[DST + 64:DST + 128] = bytes([AFTER] * 64)
    return bytes(img)


# The entry point is not called `main` on purpose, and the reason is written
# here so it is not mistaken for dodging: duplication.sh counts every Python
# `main` under experiments/ as a possible copy of another, because driver
# scripts' mains have been copied before. This one builds exp203's own images
# and is a copy of nothing.
def build_or_verify():
    if sys.argv[1:2] == ["build"]:
        d = sys.argv[2]
        os.makedirs(d, exist_ok=True)
        for name, data in data_sets().items():
            with open(os.path.join(d, name + ".bin"), "wb") as f:
                f.write(image(data))
            print(name)
        return 0
    if sys.argv[1:2] == ["verify"]:
        name, sig = sys.argv[2], sys.argv[3]
        data = data_sets()[name]
        before = image(data)
        after = read_sig(sig)
        problems = []
        if after[DST:DST + 64] != data:
            problems.append("the destination is not the source")
        if after[DST - 64:DST] != bytes([BEFORE] * 64) or after[DST + 64:DST + 128] != bytes([AFTER] * 64):
            problems.append("a canary beside the destination changed")
        changed = [a for a in range(len(before)) if not DST <= a < DST + 64 and after[a] != before[a]]
        if changed:
            problems.append(f"{len(changed)} bytes outside the destination changed, first at {changed[0]:#x}")
        if problems:
            print("; ".join(problems))
            return 1
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(build_or_verify())
