#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp230 — the fly, in Python's integers, and the frames it is shown.

  sees(before, now)        (up, down): what moved one cell up, what moved down
  fly_ref(frames)          every step's (up, down), and the two totals
  fly_image(kernel, frames)
                           kernel.bin with the 257 frames where the kernel reads them
  stimuli()                the named stimuli: Rule 30 from exp225's seeds, a
                           stripe moving up, down, one of period 2, flicker, still
  fly_cases(n, seed)       those, then n of random frames

Rule 30 is exp225's own rule30.py, written cell by cell; the moves here are
written with rotations. Neither is the kernel's formula of shifts.
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "exp225-the-life-every-beat-proved"))
from kernel import DOWN, FRAMES, N, STEPS, UP  # noqa: E402
from rule30 import SEED0, rule30  # noqa: E402

M = 0xFFFFFFFF


def rot_up(x):
    return ((x << 1) | (x >> 31)) & M


def rot_down(x):
    return ((x >> 1) | (x << 31)) & M


def sees(before, now):
    return bin(rot_up(before) & now).count("1"), bin(rot_down(before) & now).count("1")


def fly_ref(frames):
    steps = [sees(frames[t], frames[t + 1]) for t in range(N)]
    return steps, sum(u for u, _ in steps), sum(d for _, d in steps)


def fly_image(kernel, frames):
    assert len(frames) == N + 1
    img = bytearray(kernel) + bytes(max(0, STEPS + 8 * N - len(kernel)))
    img[FRAMES:FRAMES + 4 * (N + 1)] = struct.pack(f"<{N + 1}I", *frames)
    return bytes(img)


def result_of(region):
    steps = [struct.unpack_from("<II", region, STEPS + 8 * t) for t in range(N)]
    return steps, struct.unpack_from("<I", region, UP)[0], struct.unpack_from("<I", region, DOWN)[0]


def chain(x, f):
    out = [x]
    for _ in range(N):
        out.append(f(out[-1]))
    return out


def stimuli():
    return [
        ("life 0x00010000", chain(SEED0, rule30)),
        ("life 0x00000001", chain(1, rule30)),
        ("life 0x8001a5c3", chain(0x8001A5C3, rule30)),
        ("stripe up", chain(0x000000F0, rot_up)),
        ("stripe down", chain(0x000000F0, rot_down)),
        ("period 2, up", chain(0x55555555, rot_up)),
        ("flicker", chain(0x0F0F00FF, lambda x: x ^ M)),
        ("still", chain(0x12345678, lambda x: x)),
        ("dark", chain(0, lambda x: x)),
    ]


def fly_cases(n, seed=230):
    out = stimuli()
    rng = random.Random(seed)
    for k in range(n):
        out.append((f"random {k}", [rng.getrandbits(32) for _ in range(N + 1)]))
    return out
