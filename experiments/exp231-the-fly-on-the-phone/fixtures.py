#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp231 — what fly.html is tested against, written by exp225's rule30.py and
exp230's fly.py, which share nothing with the page: the lines a board running
exp231 sends (board_chip.c's formats), right and wrong in each of the ways the
page must tell apart.

  fixtures.py DIR      writes DIR/*.txt, one stream each, and DIR/pairs.txt:
                       random pairs of words, rule30.py's next generation of
                       the first and fly.py's two counts from the first to the
                       second
  fixtures.py --board LOG...
                       each SEES line a phone gave back, against rule30.py's
                       lives and fly.py's counts from SEED0 at the same round
                       and step — independent of the page, which only checks
                       each one against the one before
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "exp230-the-motion-the-fly-sees"))
from fly import sees  # noqa: E402
from rule30 import SEED0, history, rule30  # noqa: E402

LIFE_MINSTRET, FLY_MINSTRET = 3082, 70927
STATUS = ("exp231 usb=6 setups=31 stalls=3 dropped=0 errors=0 ref=00000000 sys=00000000 xosc=00000000 "
          "pll=00000001 usb_khz=48000 sys_khz=10950 sys48_khz=48000 ref_khz=10949 sof_khz=47999 "
          "lives={} minstret=70927")


def fly_round_lines(rounds, seed=SEED0, fly_minstret=FLY_MINSTRET):
    """[(round, g or None, line)]: what board_play sends, a status line every few beats."""
    out = []
    for r in range(rounds):
        h = history(seed)
        frames = [seed] + h
        steps = [sees(frames[g], frames[g + 1]) for g in range(len(h))]
        col = sum(((h[g] >> 16) & 1) << g for g in range(32))
        up, down = sum(u for u, _ in steps), sum(d for _, d in steps)
        out.append((r, None, f"LIFE {r:08x} {LIFE_MINSTRET:08x} {h[0]:08x} {h[-1]:08x} {col:08x}"))
        out.append((r, None, f"FLY {r:08x} {fly_minstret:08x} {up:08x} {down:08x}"))
        out.append((r, None, f"SEED {r:08x} {seed:08x}"))
        for g, (w, (u, d)) in enumerate(zip(h, steps)):
            if g % 3 == 0:
                out.append((r, None, STATUS.format(r + 1)))
            out.append((r, g, f"SEES {r:08x} {g:08x} {w:08x} {u:08x} {d:08x}"))
        seed = h[-1]
    return out


def with_field(line, k, f):
    parts = line.split()
    parts[k] = f"{f(int(parts[k], 16)) & 0xFFFFFFFF:08x}"
    return " ".join(parts)


def write_fly_fixtures(d):
    os.makedirs(d, exist_ok=True)

    def save(name, items):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for _, _, line in items))

    def at(items, where, k, f):
        return [(r, g, with_field(line, k, f)) if (r, g) == where else (r, g, line) for r, g, line in items]

    good = fly_round_lines(2)
    save("good.txt", good)
    # Joined in the middle of round 0: no LIFE, no FLY, no SEED, step 100 first.
    save("midround.txt", [x for x in good if x[0] == 1 or (x[1] is not None and x[1] >= 100)])
    # One bit of generation 37 flipped on the way, its counts left as the board sent them.
    save("flipped.txt", at(good, (0, 37), 3, lambda w: w ^ (1 << 5)))
    # Step 50's up count one more than the fly saw.
    save("miscount.txt", at(good, (0, 50), 4, lambda u: u + 1))
    # Step 60 sent as if the fly had seen it move down: up and down crossed.
    crossed = [(r, g, " ".join(line.split()[:4] + line.split()[4:][::-1])) if (r, g) == (0, 60) else (r, g, line)
               for r, g, line in good]
    save("crossed.txt", crossed)
    # Step 120 of round 0 never arrived.
    save("lost.txt", [x for x in good if (x[0], x[1]) != (0, 120)])
    # The FLY line's down total one more than the steps add up to.
    save("total.txt", [(r, g, with_field(line, 4, lambda v: v + 1)) if line.startswith("FLY 00000000") else (r, g, line)
                       for r, g, line in good])
    # The fly's kernel took another count of instructions.
    save("minstret.txt", fly_round_lines(1, fly_minstret=FLY_MINSTRET + 1))

    rng = random.Random(231)
    with open(os.path.join(d, "pairs.txt"), "w") as f:
        firsts = [0, 0xFFFFFFFF, SEED0, 1, 0x80000000, 0x55555555, 0xAAAAAAAA]
        for x in firsts + [rng.getrandbits(32) for _ in range(5000)]:
            y = rng.choice([rule30(x), rng.getrandbits(32), ((x << 1) | (x >> 31)) & 0xFFFFFFFF])
            u, dn = sees(x, y)
            f.write(f"{x:08x} {y:08x} {rule30(x):08x} {u:02x} {dn:02x}\n")


def fly_board_positions(logs):
    lives, failed = [[SEED0] + history(SEED0)], 0
    for log in logs:
        got = {}
        for line in open(log, encoding="utf-8", errors="replace"):
            f = line.split()
            if len(f) == 6 and f[0] == "SEES":
                got[(int(f[1], 16), int(f[2], 16))] = tuple(int(v, 16) for v in f[3:])
        while got and len(lives) <= max(r for r, _ in got):
            lives.append([lives[-1][-1]] + history(lives[-1][-1]))
        bad = [(r, g) for (r, g), (w, u, d) in sorted(got.items())
               if (lives[r][g + 1], *sees(lives[r][g], lives[r][g + 1])) != (w, u, d)]
        name = os.path.basename(log)
        if got and not bad:
            print(f"PASS  {name}: all {len(got)} steps are rule30.py's generation and fly.py's counts, "
                  "at their round and step from SEED0")
        else:
            failed += 1
            print(f"FAIL  {name}: rule30.py and fly.py from SEED0 disagree at {bad[:5] if bad else 'no SEES line'}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(1 if fly_board_positions(sys.argv[2:]) else 0)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write_fly_fixtures(sys.argv[1])
