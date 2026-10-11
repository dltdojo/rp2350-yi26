#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp229 — the field, in Python's integers, and the images the kernel runs on.

  field_ref(op, a, b)      what the kernel must leave in R: (a + b), (a - b) or
                           (a · b), modulo p
  field_image(kernel, op, a, b)
                           kernel.bin with the operation and a, b where the
                           kernel reads them
  field_cases(n, seed)     every edge pair for each operation, then n drawn
  carry_witness()          a pair whose product reaches the third fold

The layout is kernel.py's; the numbers are kernel.py's names for it.
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from kernel import A, B, OPW, P, R  # noqa: E402

OPS = {0: "add", 1: "sub", 2: "mul"}


def field_ref(op, a, b):
    return [(a + b) % P, (a - b) % P, (a * b) % P][op]


def words8(x):
    return struct.pack("<8I", *[(x >> (32 * i)) & 0xFFFFFFFF for i in range(8)])


def field_image(kernel, op, a, b):
    img = bytearray(kernel) + bytes(max(0, R + 36 - len(kernel)))
    img[OPW:OPW + 4] = struct.pack("<I", op)
    img[A:A + 32] = words8(a)
    img[B:B + 32] = words8(b)
    return bytes(img)


def result_of(region):
    return int.from_bytes(region[R:R + 32], "little")


EDGES = [0, 1, 2, 3, 977, 2**32 - 1, 2**32, 2**32 + 977, 2**64 - 1, 2**128, 2**224 - 1, 2**255,
         P // 2, P // 2 + 1, P - 2**32, P - 977, P - 3, P - 2, P - 1]


def field_cases(n, seed=229):
    out = [(op, a, b) for op in OPS for a in EDGES for b in EDGES]
    rng = random.Random(seed)
    for _ in range(n):
        out.append((rng.randrange(3), rng.randrange(P), rng.randrange(P)))
    return out


def fold_words(x):
    """The kernel's folds of a product, as integers: after each, the value is
    the same modulo p and smaller."""
    lo, hi = x % 2**256, x >> 256
    return lo + hi * (2**32 + 977)
