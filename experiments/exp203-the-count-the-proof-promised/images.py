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
from kernelimages import command  # noqa: E402

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


def copy_image(data):
    kernel = open(os.path.join(HERE, "kernel.bin"), "rb").read()
    img = bytearray(DST + 128)
    img[:len(kernel)] = kernel
    img[SRC:SRC + 64] = data
    img[DST - 64:DST] = bytes([BEFORE] * 64)
    img[DST:DST + 64] = bytes([0xEE] * 64)       # something to overwrite
    img[DST + 64:DST + 128] = bytes([AFTER] * 64)
    return bytes(img)


# The command line — build, verify — is tools/hazard3/kernelimages.py's, as
# every kernel experiment's is; what is here is only this experiment's cases.
def copied(data, after):
    if after[DST:DST + 64] != data:
        return "the destination is not the source"
    return None


if __name__ == "__main__":
    sys.exit(command(__doc__, data_sets(), copy_image, DST, DST + 64, check=copied))
