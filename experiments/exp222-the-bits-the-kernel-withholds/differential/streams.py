# SPDX-License-Identifier: Apache-2.0
"""exp222 — sample streams for the differential and for the chip's known
answers, and the health tests they are judged by: exp114's
crates/entropy-health `Health::push`, line for line, in Python.

  streams()     name -> 1024 sample words (bit 0 is the sample; the rest of
                each word is noise, which the tests must ignore)
  healthy(ws)   exp114's verdict on them: (True, None) or (False, reason)
"""
import random

N, RCT_CUTOFF, APT_WINDOW, APT_CUTOFF = 1024, 21, 1024, 589


def healthy(words):
    last, run = None, 0
    ref, seen, agree = None, 0, 0
    for w in words:
        bit = w & 1
        run = run + 1 if last == bit else 1
        last = bit
        if run >= RCT_CUTOFF:
            return False, f"repetition count {run}"
        if ref is None:
            ref, seen, agree = bit, 1, 1
        else:
            seen += 1
            agree += bit == ref
            if seen >= APT_WINDOW:
                if agree >= APT_CUTOFF:
                    return False, f"adaptive proportion {agree}"
                ref, seen, agree = None, 0, 0
    return True, None


def noisy(bits, r):
    """Each bit in bit 0 of a word whose other 31 bits are random."""
    return [(r.getrandbits(31) << 1) | b for b in bits]


def alternating_runs(run, total, r):
    bits, b = [], r.getrandbits(1)
    while len(bits) < total:
        bits += [b] * run
        b ^= 1
    return bits[:total]


def with_agreement(k, r):
    """1024 bits, the first among them, exactly k equal to the first, and no
    run of 21."""
    first = r.getrandbits(1)
    while True:
        rest = [first] * (k - 1) + [first ^ 1] * (N - k)
        r.shuffle(rest)
        bits = [first] + rest
        run, best, last = 0, 0, None
        for b in bits:
            run = run + 1 if b == last else 1
            last, best = b, max(best, run)
        if best < RCT_CUTOFF:
            return bits


def streams():
    r = random.Random(222)
    out = {}
    for k in range(6):
        out[f"random {k}"] = noisy([r.getrandbits(1) for _ in range(N)], r)
    out["stuck at 1"] = noisy([1] * N, r)
    out["stuck at 0"] = noisy([0] * N, r)
    out["runs of 20"] = noisy(alternating_runs(20, N, r), r)
    out["runs of 21"] = noisy(alternating_runs(21, N, r), r)
    late = [r.getrandbits(1) for _ in range(N)]
    for i in range(1000, 1021):
        late[i] = 1
    late[999], late[1021] = 0, 0
    out["a run of 21 at the end"] = noisy(late, r)
    out["588 agree"] = noisy(with_agreement(588, r), r)
    out["589 agree"] = noisy(with_agreement(589, r), r)
    out["nine ones then a zero"] = noisy(([1] * 9 + [0]) * 103, r)[:N]
    return out
