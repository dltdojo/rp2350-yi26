#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/tools — what vk26-alice-2's kernel, which tests its hash
before it trusts it, must leave, for any hash function; written from alice's
plan and health.py, nothing like the kernel's registers. vk26-alice-2 wrote
it (as its trust.py); vk26-alice-5, which runs that kernel first in its
chain, is the second to need it.

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
sys.path.insert(0, HERE)
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
