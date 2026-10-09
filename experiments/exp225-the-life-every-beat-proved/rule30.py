#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp225 — Rule 30 on a ring of 32 cells, written cell by cell, the way the
rule is usually stated: each cell becomes left XOR (centre OR right), its left
neighbour the next bit up and its right the next bit down, round the ring.
Nothing here is shared with the kernel's formula of shifts; that is the point
of having it.

  rule30.py          the centre column of the first life, as the LED plays it
"""
import struct

N = 256
SEED_OFF, HIST_OFF = 0x100, 0x200
SEED0 = 1 << 16          # one live cell, in the middle
CENTRE = 16


def rule30(x):
    y = 0
    for i in range(32):
        left, centre, right = (x >> ((i + 1) % 32)) & 1, (x >> i) & 1, (x >> ((i - 1) % 32)) & 1
        y |= (left ^ (centre | right)) << i
    return y


def history(seed, n=N):
    out, x = [], seed
    for _ in range(n):
        x = rule30(x)
        out.append(x)
    return out


def history_bytes(seed):
    return struct.pack(f"<{N}I", *history(seed))


def image(kernel, seed):
    img = bytearray(HIST_OFF)
    img[:len(kernel)] = kernel
    img[SEED_OFF:SEED_OFF + 4] = struct.pack("<I", seed)
    return bytes(img)


if __name__ == "__main__":
    col = "".join("█" if (g >> CENTRE) & 1 else "·" for g in history(SEED0))
    for i in range(0, N, 64):
        print(col[i:i + 64])
