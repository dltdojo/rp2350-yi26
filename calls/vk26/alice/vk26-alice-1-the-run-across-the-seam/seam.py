#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-1 — the reference: SP 800-90B's two continuous health tests over
four windows of 1024 samples, written the way exp114's crate
(crates/entropy-health) writes them, one sample at a time, and nothing like
the kernel's registers. The tests themselves are alice/tools/health.py's,
shared with vk26-alice-2; this file is what alice-1 does with them.

  seam.py            print every stream in streams() and what it gives

The repetition count runs over the whole stream: a run is not reset at a
window's edge, as the crate's `run` is not. The adaptive proportion test
takes each window's first sample as its reference. A window fails if the
repetition count reaches 21 within it, or 589 of its 1024 samples match its
reference. The first window that fails stops everything: no digest is
written for it or for any window after it.

  judge(bits)        how many windows passed before the first failure (4 if
                     none failed), and why the first failure failed
  seam_outcome(words) what the kernel must leave: the halt code (0 if every
                     window passed, else the failing window's number, 1 to 4)
                     and the SHA-256 of each window that passed, in order
  by_window(bits)    the same tests with the repetition count started afresh
                     at each window, as lean/Rv32/Health.lean's `front` judges
                     one window: what the seam streams would give a kernel
                     that ran `front` window by window

A sample is the word the shell writes; the tests see its bit 0.
"""
import hashlib
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from health import APT_CUTOFF, N, RCT_CUTOFF, fair as _fair, judge as _judge, longest as _longest  # noqa: E402,F401
from health import window_bytes  # noqa: E402,F401

WINDOWS = 4

# Where things are in the 64 KiB region, from its base.
SAMPLES = 0x400                       # four windows of 1024 words, one after another
DIGESTS = SAMPLES + 4 * N * WINDOWS   # 0x4400: 32 bytes for each window that passed
IMAGE_END = DIGESTS


def judge(bits):
    """alice/tools/health.py's tests, over this experiment's four windows."""
    return _judge(bits, WINDOWS)


def by_window(bits):
    """Each window judged alone: (windows passed before the first failure,
    why it failed, each judged window's longest run)."""
    tops = []
    for w in range(WINDOWS):
        window = bits[w * N:(w + 1) * N]
        passed, why = _judge(window, 1)
        tops.append(_longest(window))
        if passed == 0:
            return w, why.replace("window 1", f"window {w + 1}"), tops
    return WINDOWS, None, tops


def seam_outcome(words):
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


if __name__ == "__main__":
    all_streams = streams()
    for name, words in all_streams.items():
        code, digests, why = seam_outcome(words)
        print(f"{name:34} halt {code}  digests {len(digests)}  {why or 'every window passed'}")
    print("each window alone, the count started afresh at its edge, as front's is:")
    for name in ("seam 11+10", "seam 1+20", "seam 15+6 at window 4"):
        passed, why, tops = by_window([x & 1 for x in all_streams[name]])
        print(f"  {name:32} {why or 'every window passed'}; longest run in each window {' '.join(map(str, tops))}")
