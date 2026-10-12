#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp234 — the world kernel's image and history, and the rate M7 predicts,
from exp232's cure.py, which writes the rule cell by cell and shares nothing
with the kernel.

  world.py            the divisions each enrolled lump leaves to chance, and
                      the rate they predict, beside cure.py's world over many
                      patients
  world.py --check    the D that proof/World.lean proves is cure.py's, lump by
                      lump, and the rate it predicts exactly 3276629119 /
                      25769803776
  world.py --board LOG...
                      what a board running exp234 sent, against cure.py, as
                      exp232's were (cure.board_logs), its minstret build/
                      world.h's
"""
import re
import os
import struct
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "exp232-the-cure-the-proof-predicts"))
import cure  # noqa: E402

INIT_OFF, MASKS_OFF, HIST_OFF = 0x200, 0x300, 0x400


def world_image(kernel, t, h, s, masks):
    img = bytearray(HIST_OFF)
    img[:len(kernel)] = kernel
    img[INIT_OFF:INIT_OFF + 12] = struct.pack("<III", t, h, s)
    img[MASKS_OFF:MASKS_OFF + 256] = struct.pack("<64I", *masks)
    return bytes(img)


def history_bytes(t, h, s, masks):
    return b"".join(struct.pack("<III", *g) for g in cure.lived(t, h, s, masks))


def divisions(width, sched):
    """The cells the model's tumour divides into, all 64 generations: M7's D."""
    t, h, s, n = cure.lump(width), ~cure.lump(width) & cure.M, sched, 0
    for _ in range(cure.GENS):
        t1, t2, h2 = cure.dose_and_grow(t, h, s)
        n += cure.pc(t2 & ~t1)
        t, h, s = t2, h2, s >> 1
    return n


def predicted(sched):
    """The share of treated patients not cured, exactly, if each mask bit is one
    with probability 1/16, all independently: 1 - mean over widths of (15/16)^D."""
    q = Fraction(15, 16)
    widths = list(cure.WIDTHS)
    return 1 - sum(q ** divisions(w, sched) for w in widths) / len(widths)


def lean_d():
    """proof/World.lean's D, read from the source: the widths it names, 0 else."""
    src = open(os.path.join(HERE, "proof", "World.lean"), encoding="utf-8").read()
    row = re.search(r"def D : Nat → Nat\n  ((?:\| \d+ => \d+ )+)\| _ => 0", src).group(1)
    named = {int(a): int(b) for a, b in re.findall(r"\| (\d+) => (\d+)", row)}
    return {w: named.get(w, 0) for w in cure.WIDTHS}


def rate_check():
    answer = cure.search()[0]
    ours, proved = {w: divisions(w, answer) for w in cure.WIDTHS}, lean_d()
    p = predicted(answer)
    if ours == proved and p == Fraction(3276629119, 25769803776):
        print(f"PASS  the divisions answer_world proves, {proved}, are cure.py's cell by cell, lump by lump; "
              f"with each mask bit one 1 time in 16 the treated fail {p} = {float(p):.4%}")
        return 0
    print(f"FAIL  the divisions: cure.py {ours}, proof/World.lean {proved}; predicted {p}")
    return 1


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        sys.exit(rate_check())
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        h = open(os.path.join(HERE, "build", "world.h")).read()
        minstret = re.search(r"#define INSTRET (\d+)u", h).group(1)
        sys.exit(1 if cure.board_logs(sys.argv[2:], "exp234", minstret) else 0)
    import random
    answer = cure.search()[0]
    q, N = Fraction(15, 16), 40000
    rng = random.Random(234)
    seen = {w: [0, 0] for w in cure.WIDTHS}
    for _ in range(N):
        r = rng.getrandbits(32) | 1          # the low bit: treated
        _, w, _, hist, _, _ = cure.world(r, answer)
        seen[w][0] += 1
        seen[w][1] += cure.outcome(hist) != 0
    print(f"the treated, by lump width: M7's prediction beside cure.py's world, {N} patients")
    for w in cure.WIDTHS:
        d = divisions(w, answer)
        n, bad = seen[w]
        print(f"  width {w}: {d} divisions, predicted {float(1 - q ** d):.4f}, cure.py {bad / n:.4f} ({bad} of {n})")
    p = predicted(answer)
    bad = sum(b for _, b in seen.values())
    print(f"  all: predicted {p} = {float(p):.4%}, cure.py {bad} of {N} = {bad / N:.4%}")
