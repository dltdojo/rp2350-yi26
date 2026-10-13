#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-2 — the reference: what a kernel that tests its hash first must
leave, for any hash function, written from the plan and alice/tools/health.py,
and nothing like the kernel's registers.

  trust.py           print every stream in streams() and what it gives

The order is the plan's:

  1. the known-answer test: H of the 64-byte KAT message, written to the
     KAT's scratch; if it is not the expected digest the image carries,
     stop with 2;
  2. the start-up test: SP 800-90B section 4.3 item 4, the continuous tests
     over at least 1024 consecutive samples; one window of 1024. Its samples
     are discarded, which item 4 allows ("or may be discarded at any time").
     If it fails, stop with 1;
  3. one more window, the repetition count carried on from the start-up
     window (health.py's tests over both); if it fails, stop with 3;
  4. H of that window's 4096 bytes is the output; stop with 0.

  trust_outcome(words, want, H)
                     (code, writes, why): the halt code, and every byte the
                     kernel writes as {offset: bytes} — the KAT's answer
                     always, the output only with code 0
  image(kernel, words, want)
                     the region's image: the kernel, the KAT message and its
                     expected digest, the samples

A sample is the word the shell writes; the tests see its bit 0.
"""
import hashlib
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from health import N, fair, judge, longest, window_bytes  # noqa: E402

WINDOWS = 2
# Where things are in the 64 KiB region, from its base.
KAT_MSG, KAT_WANT, KAT_GOT = 0x300, 0x340, 0x360
SAMPLES = 0x400
OUTPUT = SAMPLES + 4 * N * WINDOWS   # 0x2400: right after the samples
IMAGE_END = OUTPUT

# 64 bytes, the KAT's message: one SHA-256 block of input, as HASH takes it.
KAT = b"vk26-alice-2: the hash is asked this before it is trusted, 64 B."
assert len(KAT) == 64


def sha256(b):
    return hashlib.sha256(b).digest()


def kat_want():
    return sha256(KAT)


def trust_outcome(words, want=None, H=sha256):
    want = kat_want() if want is None else want
    got = H(KAT)
    writes = {KAT_GOT: got}
    if got != want:
        return 2, writes, "the KAT's answer is not the expected digest"
    passed, why = judge([x & 1 for x in words], WINDOWS)
    if passed == 0:
        return 1, writes, f"start-up: {why}"
    if passed == 1:
        return 3, writes, why
    writes[OUTPUT] = H(window_bytes(words, 1))
    return 0, writes, None


def image(kernel, words, want=None):
    img = bytearray(IMAGE_END)
    img[:len(kernel)] = kernel
    img[KAT_MSG:KAT_MSG + 64] = KAT
    img[KAT_WANT:KAT_WANT + 32] = kat_want() if want is None else want
    img[SAMPLES:OUTPUT] = struct.pack(f"<{N * WINDOWS}I", *words)
    return bytes(img)


def streams():
    """Named streams of 2048 words: the start-up window, then the one whose
    digest is the output."""
    rng = random.Random(0xA11CE2)

    def run_at(start, bit, n):
        out = fair(rng, WINDOWS * N)
        out[start:start + n] = [bit] * n
        if start > 0:
            out[start - 1] = 1 - bit
        if start + n < WINDOWS * N:
            out[start + n] = 1 - bit
        return out

    s = {}
    s["fair"] = fair(rng, WINDOWS * N)
    # The start-up test fails: nothing after it, the output never computed.
    s["stuck at 1 from the start"] = [1] * N + fair(rng, N)
    s["21 alike in the start-up window"] = run_at(300, 0, 21)
    s["20 alike in the start-up window"] = run_at(300, 0, 20)
    # The run across the edge between the window discarded and the one used.
    s["seam 11+10"] = run_at(N - 11, 1, 21)
    s["seam 10+10"] = run_at(N - 10, 1, 20)
    s["seam 20+1"] = run_at(N - 20, 0, 21)
    # The adaptive proportion test, in each window.
    for w, k in ((0, 589), (1, 589), (1, 588)):
        out = fair(rng, WINDOWS * N)
        win = [1] * k + [0] * (N - k)
        rng2 = random.Random(k + 7 * w)
        while True:
            rng2.shuffle(win)
            if win[0] == 1 and longest(win) < 21:
                break
        out[w * N:(w + 1) * N] = win
        if w == 1 and out[N - 1] == out[N]:
            out[N - 1] = 1 - out[N]
        if w == 0 and out[N] == out[N - 1]:
            out[N] = 1 - out[N - 1]
        s[f"{k} of window {w + 1}"] = out
    s["nine ones then a zero, window 2"] = fair(rng, N - 1) + [0] + (([1] * 9 + [0]) * (N // 10 + 1))[:N]
    for k in range(2):
        r = random.Random(2000 + k)
        s[f"random {k + 1}"] = [r.getrandbits(32) for _ in range(WINDOWS * N)]
    s["noise above bit 0"] = [b | (rng.getrandbits(31) << 1) for b in fair(rng, WINDOWS * N)]
    for name, words in s.items():
        assert len(words) == WINDOWS * N, name
    return s


def bad_wants():
    """Expected digests the KAT must refuse: one bit of the right one flipped,
    in its first and its last byte, and all zeros."""
    w = kat_want()
    return {"first bit flipped": bytes([w[0] ^ 1]) + w[1:],
            "last bit flipped": w[:31] + bytes([w[31] ^ 0x80]),
            "all zeros": bytes(32)}


if __name__ == "__main__":
    for name, words in streams().items():
        code, writes, why = trust_outcome(words)
        print(f"{name:34} halt {code}  {'output written' if OUTPUT in writes else 'no output':14}  "
              f"{why or 'both windows passed'}")
    for name, want in bad_wants().items():
        code, _, why = trust_outcome(streams()["fair"], want)
        print(f"KAT: {name:28} halt {code}  {why}")
