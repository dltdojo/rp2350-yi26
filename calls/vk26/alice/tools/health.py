#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/tools — SP 800-90B's two continuous health tests, as
alice's experiments state them, one sample at a time, the way exp114's crate
(crates/entropy-health) runs them, and nothing like any kernel's registers.
vk26-alice-1 wrote it; vk26-alice-2 is the second to need it.

The repetition count runs over the whole stream: a run is not reset at a
window's edge, as the crate's `run` is not. The adaptive proportion test
takes each window's first sample as its reference. A window fails if the
repetition count reaches 21 within it, or 589 of its 1024 samples match its
reference. Judging stops at the first window that fails.

  judge(bits, windows)   how many windows passed before the first failure
                         (`windows` if none failed), and why the first
                         failure failed
  fair(rng, n)           n samples in alternating pairs, shuffled a little:
                         never 21 alike, never 589 of a window alike
  longest(bits)          the longest run of alike samples
  window_bytes(words, w) window w's 4096 bytes, as HASH reads them
"""
import struct

N = 1024
RCT_CUTOFF, APT_CUTOFF = 21, 589


def judge(bits, windows):
    last, run = None, 0
    for w in range(windows):
        window = bits[w * N:(w + 1) * N]
        ref, matches, top = window[0], 0, 0
        for b in window:
            run = run + 1 if b == last else 1
            last = b
            top = max(top, run)
            if b == ref:
                matches += 1
        if top >= RCT_CUTOFF:
            return w, f"window {w + 1}: {top} alike in a row"
        if matches >= APT_CUTOFF:
            return w, f"window {w + 1}: {matches} of 1024 equal its first"
    return windows, None


def fair(rng, n):
    out = []
    while len(out) < n:
        out += [0, 1] if rng.random() < 0.5 else [1, 0]
    return out[:n]


def longest(bits):
    best = run = 0
    last = None
    for b in bits:
        run = run + 1 if b == last else 1
        last = b
        best = max(best, run)
    return best


def window_bytes(words, w):
    return struct.pack(f"<{N}I", *words[w * N:(w + 1) * N])
