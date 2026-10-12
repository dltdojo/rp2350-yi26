#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp232 — the model, the search, the world and the trial, written cell by
cell where the kernel uses shifts, so that nothing here is shared with it.

A ring of 32 cells, each empty, tissue or tumour: two words, the tumour T and
the tissue H, never both at one cell. Each generation, in this order:

  a dose, if the schedule's bit for this generation is set: every cell at the
      edge of its own kind dies — a tumour cell with a neighbour that is not
      tumour, a tissue cell with a neighbour that is not tissue. Chemotherapy
      kills the cells that divide, and these are the ones that divide.
  growth: a tumour cell stays, and invades the cell above it, whatever is
      there — it has lost contact inhibition. A tissue cell stays unless
      invaded, and an empty cell with a tissue neighbour becomes tissue.

The kernel runs 64 generations; the schedule is 32 bits, generation g's dose
in bit g, so nothing is given after generation 31.

  cure.py              the search as the chip runs it, its answer, and a trial
"""
import struct

W, GENS = 32, 64
INIT_OFF, HIST_OFF = 0x100, 0x200
M = 0xFFFFFFFF

# The stated endpoint — the prompt: "find a schedule that passes the trial".
DAYS = 24          # the trial reads the scan after generation 24
DETECT = 2         # a scan does not see a tumour of two cells or fewer
TISSUE_MIN = 16    # the patient must keep half the tissue at every generation to 24
WIDTHS = range(1, 7)   # enrolled: one lump of 1 to 6 tumour cells

# The search, as the chip runs it: CANDIDATES schedules from xorshift32 seeded
# with SEARCH_SEED, each cut to the trial's DAYS; of those meeting the
# endpoint for every enrolled width, the one with fewest doses, the first on
# a tie.
SEARCH_SEED, CANDIDATES = 1, 1024

# The world: what the model leaves out. Each new tumour cell is resistant with
# probability 2^-MUT_BITS, and a dose never kills a resistant cell; a
# resistant cell's daughters are resistant.
MUT_BITS = 4


def cell(x, i):
    return (x >> (i % W)) & 1


def dose_and_grow(t, h, s, resistant=0):
    """One generation, cell by cell: (the tumour after the dose, then after
    growth, the tissue after growth)."""
    if s & 1:
        kill = 0
        for i in range(W):
            mine = t if cell(t, i) else h if cell(h, i) else None
            if mine is not None and not cell(resistant, i) and (not cell(mine, i - 1) or not cell(mine, i + 1)):
                kill |= 1 << i
        t, h = t & ~kill & M, h & ~kill & M
    t2 = h2 = 0
    for i in range(W):
        if cell(t, i) or cell(t, i - 1):
            t2 |= 1 << i
        elif cell(h, i) or (not cell(t, i) and (cell(h, i - 1) or cell(h, i + 1))):
            h2 |= 1 << i
    return t, t2, h2


def next_gen(t, h, s, resistant=0):
    """One generation. Returns (t, h, s >> 1)."""
    _, t2, h2 = dose_and_grow(t, h, s, resistant)
    return t2, h2, s >> 1


def lifetime(t, h, s, n=GENS):
    out = []
    for _ in range(n):
        t, h, s = next_gen(t, h, s)
        out.append((t, h))
    return out


def lifetime_bytes(t, h, s):
    return b"".join(struct.pack("<II", a, b) for a, b in lifetime(t, h, s))


def image(kernel, t, h, s):
    img = bytearray(HIST_OFF)
    img[:len(kernel)] = kernel
    img[INIT_OFF:INIT_OFF + 12] = struct.pack("<III", t, h, s)
    return bytes(img)


def lump(width, at=0):
    x = (1 << width) - 1
    return ((x << at) | (x >> (W - at))) & M if at else x


def pc(x):
    return bin(x).count("1")


def endpoint(hist):
    """The stated endpoint, on a history: no scan sees the tumour after DAYS,
    and the tissue never fell below TISSUE_MIN before it."""
    return pc(hist[DAYS - 1][0]) <= DETECT and all(pc(h) >= TISSUE_MIN for _, h in hist[:DAYS])


def xorshift(x):
    x ^= (x << 13) & M
    x ^= x >> 17
    x ^= (x << 5) & M
    return x


def search():
    """What the chip's search finds: (answer, accepted, relapsing, first relapsing).

    Accepted: meets the endpoint for every enrolled width. Relapsing: accepted,
    and yet, in the model, some enrolled tumour is still there at generation
    64 — which the search's goal never looks at."""
    x, best, accepted, relapsing, loophole = SEARCH_SEED, None, 0, 0, None
    for _ in range(CANDIDATES):
        x = xorshift(x)
        c = x & ((1 << DAYS) - 1)
        hists = [lifetime(lump(w), ~lump(w) & M, c) for w in WIDTHS]
        if not all(endpoint(hh) for hh in hists):
            continue
        accepted += 1
        if any(hh[-1][0] for hh in hists):
            relapsing += 1
            loophole = loophole if loophole is not None else c
        if best is None or pc(c) < pc(best):
            best = c
    return best, accepted, relapsing, loophole


def patient_of(r):
    """A patient from one random word: arm (bit 0: 1 treated), the lump's
    width and where it sits, and the seed of what happens to it."""
    return r & 1, 1 + ((r >> 1) % 6), (r >> 4) & 31, r if r else 1


def world(r, sched):
    """One patient in the world: (arm, width, at, world history, model history, resistant ever).

    The model's history is the kernel's for the same patient; the world's is
    the same rule with resistance, drawn from xorshift32 seeded by the word."""
    arm, width, at, x = patient_of(r)
    s = sched if arm else 0
    t = lump(width, at)
    h, res, out, ever = ~t & M, 0, [], 0
    model = lifetime(t, h, s)
    for _ in range(GENS):
        mut = M
        for _ in range(MUT_BITS):
            x = xorshift(x)
            mut &= x
        t1, t2, h2 = dose_and_grow(t, h, s, res)
        born = t2 & ~t1      # every cell the tumour divided into this generation
        res = (res | ((res << 1 | res >> 31) & M) | (born & mut)) & t2
        ever |= res
        t, h, s = t2, h2, s >> 1
        out.append((t, h))
    return arm, width, at, out, model, ever != 0


def outcome(hist):
    """0 the endpoint met and the tumour gone at 64; 1 met, and back by 64; 2 missed."""
    if not endpoint(hist):
        return 2
    return 0 if hist[-1][0] == 0 else 1


def lcg_words(n, x=222):
    """tools/hazard3/shell/trng_sim.h's stand-in for the TRNG: the RTL's patients."""
    out = []
    for _ in range(n):
        x = (x * 1664525 + 1013904223) & M
        out.append(x)
    return out


def patient_words(n, r, sched):
    """What the shell prints for patient n drawn from word r: n word arm width
    at model world resistant t24 tissue t64."""
    arm, width, at, hist, model, ever = world(r, sched)
    return [n, r, arm, width, at, outcome(model), outcome(hist), int(ever), pc(hist[DAYS - 1][0]),
            min(pc(h) for _, h in hist[:DAYS]), pc(hist[-1][0])]


if __name__ == "__main__":
    best, accepted, relapsing, loophole = search()
    print(f"search: {CANDIDATES} schedules, {accepted} meet the endpoint, {relapsing} of them relapse in the model")
    print(f"answer: {best:06x}, {pc(best)} doses; first loophole {loophole:06x}")
    import random
    rng = random.Random(232)
    tally = {}
    for _ in range(2000):
        arm, w, at, hist, model, ever = world(rng.getrandbits(32), best)
        k = ("treated" if arm else "control", outcome(model), outcome(hist))
        tally[k] = tally.get(k, 0) + 1
    for k in sorted(tally):
        print(f"  {k[0]:8} model {k[1]} world {k[2]}: {tally[k]}")
