# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3 — WOTS (w = 16) in Python, as exp205 wrote it and exp206
needed it second: independent of the Lean, with hashlib for HASH.

  H(x)         SHA-256 of x, whose length must be a multiple of 64 — HASH's rule
  F(x)         H(x || 32 zero bytes): one step along a chain
  chain(x, k)  k steps
  digits(m)    the 32-byte message as 64 base-16 digits, low nibble of each
               byte first; then the checksum c = sum(15 - a_i), at most 960,
               as 3 more digits, low first: 67 in all
  hashes(m)    the HASH calls a verifier's walks make: sum(15 - d) over the 67
"""
import hashlib

N = 67
ZERO = bytes(32)


def H(x):
    assert len(x) % 64 == 0
    return hashlib.sha256(x).digest()


def F(x):
    return H(x + ZERO)


def chain(x, k):
    for _ in range(k):
        x = F(x)
    return x


def digits(m):
    a = []
    for b in m:
        a += [b & 15, b >> 4]
    c = sum(15 - d for d in a)
    return a + [c & 15, (c >> 4) & 15, c >> 8]


def hashes(m):
    return sum(15 - d for d in digits(m))


def secret(seed, leaf, i):
    """MSS: the secret of chain i of one-time key `leaf`, H(seed || leaf || i ||
    30 zero bytes) — 32 secret bytes give all 16 keys. exp206's and exp213's."""
    return H(seed + bytes([leaf, i]) + bytes(30))
