#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp227 — what life.html is tested against, written by exp225's rule30.py,
which shares nothing with the page: the lines a board running exp227 sends
(board_chip.c's formats), right and wrong in each of the ways the page must
tell apart.

  fixtures.py DIR      writes DIR/*.txt, one stream each, and DIR/pairs.txt:
                       random words and rule30.py's next generation of each
  fixtures.py --board LOG...
                       each GEN line a phone gave back, against rule30.py's
                       lives from SEED0 at the same round and generation —
                       independent of the page, which only checks each one
                       against the one before
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "exp225-the-life-every-beat-proved"))
from rule30 import SEED0, rule30, history  # noqa: E402

STATUS = ("exp227 usb=6 setups=31 stalls=3 dropped=0 errors=0 ref=00000000 sys=00000000 xosc=00000000 "
          "pll=00000001 usb_khz=48000 sys_khz=10950 sys48_khz=48000 ref_khz=10949 sof_khz=47999 "
          "lives={} minstret=3082")


def life_lines(rounds, seed=SEED0, minstret=3082):
    """[(round, g or None, line)]: what board_play sends, a status line every few beats."""
    out = []
    for r in range(rounds):
        h = history(seed)
        col = sum(((h[g] >> 16) & 1) << g for g in range(32))
        out.append((r, None, f"LIFE {r:08x} {minstret:08x} {h[0]:08x} {h[-1]:08x} {col:08x}"))
        out.append((r, None, f"SEED {r:08x} {seed:08x}"))
        for g, w in enumerate(h):
            if g % 3 == 0:
                out.append((r, None, STATUS.format(r + 1)))
            out.append((r, g, f"GEN {r:08x} {g:08x} {w:08x}"))
        seed = h[-1]
    return out


def write_fixtures(d):
    os.makedirs(d, exist_ok=True)

    def save(name, items):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for _, _, line in items))

    good = life_lines(2)
    save("good.txt", good)
    # Joined in the middle of life 0: no LIFE, no SEED, generation 100 first.
    save("midlife.txt", [x for x in good if x[0] == 1 or (x[1] is not None and x[1] >= 100)])
    # One bit of generation 37 of life 0 flipped on the way.
    save("flipped.txt", [(r, g, line[:-8] + f"{int(line[-8:], 16) ^ (1 << 5):08x}") if (r, g) == (0, 37)
                         else (r, g, line) for r, g, line in good])
    # Generation 120 of life 0 never arrived.
    save("lost.txt", [x for x in good if (x[0], x[1]) != (0, 120)])
    # Life 1 grown from a seed that is not life 0's last generation.
    other = life_lines(1, seed=0x12345678)
    save("badseam.txt", [x for x in good if x[0] == 0]
         + [(1, g, line.replace("LIFE 00000000", "LIFE 00000001").replace("SEED 00000000", "SEED 00000001")
             .replace("GEN 00000000", "GEN 00000001")) for _, g, line in other])
    # The kernel took another count of instructions.
    save("minstret.txt", life_lines(1, minstret=3083))
    # The LIFE line and the generations disagree about generation 255.
    def wrong_gen256(line):
        f = line.split()
        f[4] = f"{int(f[4], 16) ^ 1:08x}"
        return " ".join(f)
    save("lifeline.txt", [(r, g, wrong_gen256(line)) if line.startswith("LIFE 00000000") else (r, g, line)
                          for r, g, line in good])

    rng = random.Random(227)
    with open(os.path.join(d, "pairs.txt"), "w") as f:
        for x in [0, 0xffffffff, SEED0, 1, 0x80000000] + [rng.getrandbits(32) for _ in range(5000)]:
            f.write(f"{x:08x} {rule30(x):08x}\n")


def board_positions(logs):
    lives, failed = [history(SEED0)], 0
    for log in logs:
        got = {}
        for line in open(log, encoding="utf-8", errors="replace"):
            f = line.split()
            if len(f) == 4 and f[0] == "GEN":
                got[(int(f[1], 16), int(f[2], 16))] = int(f[3], 16)
        while got and len(lives) <= max(r for r, _ in got):
            lives.append(history(lives[-1][-1]))
        bad = [(r, g) for (r, g), w in sorted(got.items()) if lives[r][g] != w]
        name = os.path.basename(log)
        if got and not bad:
            print(f"PASS  {name}: all {len(got)} generations are rule30.py's, at their round and generation from SEED0")
        else:
            failed += 1
            print(f"FAIL  {name}: rule30.py from SEED0 disagrees at {bad[:5] if bad else 'no GEN line'}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(1 if board_positions(sys.argv[2:]) else 0)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write_fixtures(sys.argv[1])
