#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-1 — the reference: SP 800-90B's two continuous health tests over
four windows of 1024 samples, written the way exp114's crate
(crates/entropy-health) writes them, one sample at a time, and nothing like
the kernel's registers.

  seam.py            print every stream in streams() and what it gives

The repetition count runs over the whole stream: a run is not reset at a
window's edge, as the crate's `run` is not. The adaptive proportion test
takes each window's first sample as its reference. A window fails if the
repetition count reaches 21 within it, or 589 of its 1024 samples match its
reference. The first window that fails stops everything: no digest is
written for it or for any window after it.

  judge(bits)        how many windows passed before the first failure (4 if
                     none failed), and why the first failure failed
  outcome(words)     what the kernel must leave: the halt code (0 if every
                     window passed, else the failing window's number, 1 to 4)
                     and the SHA-256 of each window that passed, in order

A sample is the word the shell writes; the tests see its bit 0.
"""
import hashlib
import random
import struct

N, WINDOWS = 1024, 4
RCT_CUTOFF, APT_CUTOFF = 21, 589

# Where things are in the 64 KiB region, from its base.
SAMPLES = 0x400                       # four windows of 1024 words, one after another
DIGESTS = SAMPLES + 4 * N * WINDOWS   # 0x4400: 32 bytes for each window that passed
IMAGE_END = DIGESTS


def judge(bits):
    last, run = None, 0
    for w in range(WINDOWS):
        window = bits[w * N:(w + 1) * N]
        ref, matches, longest = window[0], 0, 0
        for b in window:
            run = run + 1 if b == last else 1
            last = b
            longest = max(longest, run)
            if b == ref:
                matches += 1
        if longest >= RCT_CUTOFF:
            return w, f"window {w + 1}: {longest} alike in a row"
        if matches >= APT_CUTOFF:
            return w, f"window {w + 1}: {matches} of 1024 equal its first"
    return WINDOWS, None


def window_bytes(words, w):
    return struct.pack(f"<{N}I", *words[w * N:(w + 1) * N])


def outcome(words):
    passed, why = judge([x & 1 for x in words])
    code = 0 if passed == WINDOWS else passed + 1
    digests = [hashlib.sha256(window_bytes(words, w)).digest() for w in range(passed)]
    return code, digests, why


def image(kernel, words):
    img = bytearray(IMAGE_END)
    img[:len(kernel)] = kernel
    img[SAMPLES:DIGESTS] = struct.pack(f"<{N * WINDOWS}I", *words)
    return bytes(img)


def _run(bit, n):
    return [bit] * n


def _fair(rng, n):
    """Alternating pairs, shuffled a little: never 21 alike, never 589 of a window alike."""
    out = []
    while len(out) < n:
        out += [0, 1] if rng.random() < 0.5 else [1, 0]
    return out[:n]


def streams():
    """Named streams of 4096 words. Edge cases first: the seam, the cutoffs,
    each window in turn the one that fails."""
    rng = random.Random(0x5EA4)
    fair = lambda n: _fair(rng, n)   # noqa: E731

    def run_at(start, bit, n):
        """A fair stream with exactly n of `bit` in a row from sample `start`,
        an opposite bit on each side so that the run is n and no more."""
        out = fair(4 * N)
        out[start:start + n] = [bit] * n
        if start > 0:
            out[start - 1] = 1 - bit
        if start + n < 4 * N:
            out[start + n] = 1 - bit
        return out

    s = {}
    # The seam: a run that straddles a window's edge.
    s["seam 11+10"] = run_at(N - 11, 1, 21)
    s["seam 10+10"] = run_at(N - 10, 1, 20)
    s["seam 1+20"] = run_at(N - 1, 0, 21)
    s["seam 15+6 at window 4"] = run_at(3 * N - 15, 1, 21)
    # The repetition count's cutoff, inside a window.
    s["21 alike in window 3"] = run_at(2 * N + 100, 0, 21)
    s["20 alike in window 3"] = run_at(2 * N + 100, 0, 20)

    # The adaptive proportion's cutoff: 589 and 588 of a window equal its first.
    def apt(k):
        win = [1] * k + [0] * (N - k)
        rng2 = random.Random(k)
        while True:
            rng2.shuffle(win)
            if win[0] == 1 and _longest(win) < RCT_CUTOFF:
                return win
    for k in (589, 588):
        out = fair(4 * N)
        out[N:2 * N] = apt(k)
        if out[N - 1] == out[N]:
            out[N - 1] = 1 - out[N]
        if out[2 * N] == out[2 * N - 1]:
            out[2 * N] = 1 - out[2 * N - 1]
        s[f"{k} of window 2"] = out
    # exp222's two broken sources, each in a window of its own.
    s["stuck at 1, window 1"] = _run(1, N) + [0] + fair(3 * N - 1)
    s["nine ones then a zero, window 4"] = fair(3 * N - 1) + [0] + (([1] * 9 + [0]) * (N // 10 + 1))[:N]
    # Healthy throughout, and two random-looking ones.
    s["fair throughout"] = fair(4 * N)
    for k in range(2):
        r = random.Random(1000 + k)
        s[f"random {k + 1}"] = [r.getrandbits(32) for _ in range(4 * N)]
    # Words whose upper bits are not zero: the tests read bit 0 only.
    s["noise above bit 0"] = [b | (rng.getrandbits(31) << 1) for b in fair(4 * N)]
    for name, words in s.items():
        assert len(words) == 4 * N, name
    return s


def _longest(bits):
    best = run = 0
    last = None
    for b in bits:
        run = run + 1 if b == last else 1
        last = b
        best = max(best, run)
    return best


if __name__ == "__main__":
    for name, words in streams().items():
        code, digests, why = outcome(words)
        print(f"{name:34} halt {code}  digests {len(digests)}  {why or 'every window passed'}")
