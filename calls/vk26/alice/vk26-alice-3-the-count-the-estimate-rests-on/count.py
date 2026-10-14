#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-3 — the reference: what the kernel must leave, written from SP
800-90B §6.3.1 and nothing like the kernel's registers, and the estimate the
count is for.

  count.py           print every stream in count_streams(), its count, and
                     the estimate; then §6.3.1's own example

  count_outcome(samples)
                     the bytes the kernel writes, as {offset: bytes}: at
                     0x1400 the 256 counts as little-endian words, at 0x1800
                     the largest of them
  count_image(kernel, samples)
                     the region's image: the kernel, the 4096 samples at 0x400
  mcv(count, L)      §6.3.1, from the commonest value's count: (p̂, p_u, H)
  per_bit(samples)   the same estimate with each sample's eight bits as
                     samples of their own, k = 2

The count is what the kernel computes and the proof covers. p_u and H need a
square root and a logarithm, which are here, in the page, and nowhere in the
proof.
"""
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from trng_sim import stand_in_words  # noqa: E402

L = 4096
SAMPLES, HIST, MOST = 0x400, 0x1400, 0x1800
IMAGE_END = SAMPLES + L


def histogram(samples):
    counts = [0] * 256
    for s in samples:
        counts[s] += 1
    return counts


def count_outcome(samples):
    counts = histogram(samples)
    return {HIST: struct.pack("<256I", *counts), MOST: struct.pack("<I", max(counts))}


def count_image(kernel, samples):
    assert len(samples) == L and all(0 <= s < 256 for s in samples)
    img = bytearray(IMAGE_END)
    img[:len(kernel)] = kernel
    img[SAMPLES:IMAGE_END] = bytes(samples)
    return bytes(img)


def mcv(count, n):
    """§6.3.1: p̂ the commonest value's proportion, p_u the upper end of its
    99% confidence interval, H = -log2 p_u bits per sample."""
    p = count / n
    pu = min(1.0, p + 2.576 * math.sqrt(p * (1 - p) / (n - 1)))
    return p, pu, -math.log2(pu)


def per_bit(samples):
    ones = sum(bin(s).count("1") for s in samples)
    n = 8 * len(samples)
    return mcv(max(ones, n - ones), n)


def from_words(words):
    """A TRNG's words as the shell lays them out: sample i is byte i % 4 of word i / 4."""
    return list(struct.pack(f"<{len(words)}I", *words))


def count_streams():
    """Named streams of 4096 samples, each a byte."""
    rng = random.Random(0xA11CE3)
    s = {}
    uniform = [v for v in range(256) for _ in range(16)]
    rng.shuffle(uniform)
    s["each value 16 times"] = uniform
    s["each value 16 times, in order"] = [i % 256 for i in range(L)]
    s["all 0"] = [0] * L
    s["all 255"] = [255] * L
    biased = [rng.randrange(256) for _ in range(L)]
    for i in rng.sample(range(L), 1000):
        biased[i] = 0xa5
    s["0xa5 at 1000 places"] = biased
    tied = [v for v in range(256) if v not in (7, 200) for _ in range(14)][:L - 600]
    tied += [7] * 300 + [200] * 300
    tied += [9] * (L - len(tied))
    rng.shuffle(tied)
    s["7 and 200 tied"] = tied
    one_more = uniform[:]
    one_more[one_more.index(1)] = 0
    s["0 once more than the rest"] = one_more
    last = uniform[:]
    last[last.index(254)] = 255
    s["255 once more than the rest"] = last
    for k in range(2):
        r = random.Random(3000 + k)
        s[f"random {k + 1}"] = [r.randrange(256) for _ in range(L)]
    # Each bit 1 three times in four: the bytes spread over all 256 values, the bits do not.
    s["bits 1 three times in four"] = [sum((rng.random() < 0.75) << b for b in range(8)) for _ in range(L)]
    s["the RTL's stand-in TRNG"] = from_words(stand_in_words(1024))
    for name, smp in s.items():
        assert len(smp) == L and all(0 <= x < 256 for x in smp), name
    return s


# §6.3.1's example: L = 20, the commonest value 1, p̂ = 0.4. The text gives
# p_u = 0.6895 and then writes log2(0.6822); 0.6895 is right, and H = 0.5363.
EXAMPLE = [0, 1, 1, 2, 0, 1, 2, 2, 0, 1, 0, 1, 1, 0, 2, 2, 1, 0, 2, 1]


def example():
    count = max(EXAMPLE.count(v) for v in set(EXAMPLE))
    return mcv(count, len(EXAMPLE))


if __name__ == "__main__":
    for name, smp in count_streams().items():
        most = max(histogram(smp))
        p, pu, h = mcv(most, L)
        _, _, hb = per_bit(smp)
        print(f"{name:32} most {most:5}  p̂ {p:.5f}  p_u {pu:.5f}  H {h:.4f} bits a byte  "
              f"per bit {hb:.4f}")
    p, pu, h = example()
    print(f"§6.3.1's example: p̂ {p:.4f}  p_u {pu:.4f}  H {h:.4f}")
