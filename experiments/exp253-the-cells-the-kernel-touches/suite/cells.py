#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp253 on the emulator: exp225's Rule 30 kernel alone, every access recorded, against what proof/Cells.lean says.

`life_reach` says every state of the run is at one of the kernel's 19 instructions, loads only the seed at +0x100,
stores only into the history at [+0x200, +0x600), and calls only HALT with t0 = 1. The emulator is a separate program
that can disagree. The kernel runs alone in its box, with exp248's recorder, on a hundred seeds drawn from a fixed
seed and the four that are not random (0, 1, a single live cell in the middle, all ones):

  the fetches   every pc one of the 19 instructions, all 19 of them reached
  the loads     every load the seed word, and it is read
  the stores    every store inside the history, every one of its 256 words written, once
  the call      one ecall, the last instruction, HALT 0 with t0 = 1, after 3079 instructions
  the history   rule30.py's 256 generations from the seed; every other byte of the box as it was

`run_all()` returns the failures and the lines to print.
"""

import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
EXP225 = os.path.join(REPO, "experiments", "exp225-the-life-every-beat-proved")
sys.path.insert(0, os.path.join(REPO, "experiments", "exp248-the-samples-the-front-reads", "suite"))
sys.path.insert(0, EXP225)
from front_reach import Recorder, harness  # noqa: E402
import rule30  # noqa: E402

SEED, HIST, WORDS, STEPS = 0x100, 0x200, 19, 3079


def kernel() -> bytes:
    with open(os.path.join(EXP225, "kernel.bin"), "rb") as f:
        return f.read()


def payload(seed: int, junk: random.Random) -> bytes:
    box = bytearray(junk.randbytes(0x10000))
    k = kernel()
    box[:len(k)] = k
    box[SEED:SEED + 4] = struct.pack("<I", seed)
    return bytes(box)


def run_case(seed: int, junk: random.Random):
    pay = payload(seed, junk)
    emu = Recorder(pay)
    emu.run(STEPS + 10)
    bad = []
    if set(emu.pcs) != {4 * k for k in range(WORDS)}:
        bad.append(f"seed {seed:#x}: pcs {sorted(set(emu.pcs) ^ {4 * k for k in range(WORDS)})} differ from the 19")
    if [(a, w) for _, a, w in emu.loads] != [(SEED, 4)]:
        bad.append(f"seed {seed:#x}: loads {emu.loads}")
    st = [a for _, a, w in emu.stores if w == 4]
    if len(st) != len(emu.stores) or sorted(st) != list(range(HIST, HIST + 0x400, 4)):
        bad.append(f"seed {seed:#x}: the stores are not the 256 history words, each once")
    if emu.calls != [(4 * (WORDS - 1), 1)] or not emu.halted or emu.exit_code != 0 or emu.minstret != STEPS:
        bad.append(f"seed {seed:#x}: calls {emu.calls}, exit {emu.exit_code}, {emu.minstret} instructions")
    box = bytes(emu.mem[harness.PAYLOAD_AT - harness.BASE:harness.PAYLOAD_AT - harness.BASE + 0x10000])
    if box[HIST:HIST + 0x400] != rule30.history_bytes(seed):
        bad.append(f"seed {seed:#x}: the history is not rule30.py's")
    outside = [o for o in range(0x10000) if not (HIST <= o < HIST + 0x400) and box[o] != pay[o]]
    if outside:
        bad.append(f"seed {seed:#x}: {len(outside)} bytes outside the history changed, the first at +{outside[0]:#x}")
    return bad


def run_all(n: int = 100):
    r = random.Random(253)
    seeds = [0, 1, 1 << 16, 0xFFFFFFFF] + [r.getrandbits(32) for _ in range(n)]
    junk = random.Random(225)
    bad = []
    for s in seeds:
        bad += run_case(s, junk)
    lines = [f"PASS  {len(seeds)} seeds -- 0, 1, one live cell, all ones, and {n} from seed 253 -- exp225's kernel alone in a box",
             "      of junk, every access recorded: every pc one of its 19 instructions, all reached; one load, the seed at",
             "      +0x100; 256 stores, each history word in [+0x200, +0x600) once; one call, HALT 0 with t0 = 1, after 3079;",
             "      the history rule30.py's, every other byte of the box as it was"]
    return bad, lines


def main():
    bad, lines = run_all()
    for b in bad[:20]:
        print(f"FAIL  {b}")
    if bad:
        sys.exit(1)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
