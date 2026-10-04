#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp204 — Lamport signatures, test images, and the check of what the kernel
left. Written independently of the Lean: keys, signatures and the expected
verdict come from Python and hashlib, so a check here is a third party's.

  images.py build DIR        write DIR/<name>.bin for each case, and print
                             each name with the verdict Python expects
  images.py expect NAME      the verdict Python expects: 0 accept, 1 reject
  images.py verify NAME SIG  check a region dump (one little-endian word per
                             line, the testbench's --sigfile format): the
                             message, signature and public key are untouched,
                             and only the 96 bytes of scratch changed

The scheme, as the kernel and the proof have it:

  H(x)       SHA-256 of x, which is always 64 bytes
  keygen     sk[i][b] 32 random bytes for i < 256, b in {0, 1};
             pk[i][b] = H(sk[i][b] || 32 zero bytes)
  sign(m)    for a 32-byte m, sig[i] = sk[i][bit i of m]
  verify     H(sig[i] || 32 zero bytes) == pk[i][bit i of m] for every i
  bit i of m (m[i // 8] >> (i % 8)) & 1 — low bit first

The padding — a 32-byte preimage with 32 zeros after it — is the briefing's
answer to HASH taking whole 64-byte blocks only.

The image: kernel.bin at 0, the message at 0x1000, the signature at 0x2000
(256 x 32 bytes), the public key at 0x4000 (256 x 2 x 32, pk[i][b] at
0x4000 + 64 i + 32 b), and 96 bytes of scratch at 0x8000 that start as
something other than zero, because the kernel must not rely on them.
"""
import hashlib
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "hazard3"))
from sigfile import read_sig  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MSG, SIG, PK, SCR = 0x1000, 0x2000, 0x4000, 0x8000
ZERO = bytes(32)


def H(x):
    assert len(x) == 64
    return hashlib.sha256(x).digest()


def bit(m, i):
    return (m[i // 8] >> (i % 8)) & 1


def keygen(rng):
    sk = [[bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(2)] for _ in range(256)]
    pk = [[H(s + ZERO) for s in pair] for pair in sk]
    return sk, pk


def sign(sk, m):
    return [sk[i][bit(m, i)] for i in range(256)]


def verdict(pk, m, sig):
    """0 when the signature verifies, 1 when it does not — the kernel's code."""
    return 0 if all(H(sig[i] + ZERO) == pk[i][bit(m, i)] for i in range(256)) else 1


def cases():
    rng = random.Random(204)
    sk, pk = keygen(rng)
    m = bytes(rng.getrandbits(8) for _ in range(32))
    good = sign(sk, m)
    m2 = bytes(rng.getrandbits(8) for _ in range(32))
    sk2, pk2 = keygen(rng)

    def flip(sig, i):
        s = list(sig)
        s[i] = bytes([s[i][0] ^ 1]) + s[i][1:]
        return s

    def other_half(sig, i):
        s = list(sig)
        s[i] = sk[i][1 - bit(m, i)]
        return s

    return {
        "valid": (pk, m, good),
        "valid-other-key": (pk2, m2, sign(sk2, m2)),
        "all-ones-message": (pk, bytes([0xff] * 32), sign(sk, bytes([0xff] * 32))),
        "first-preimage-flipped": (pk, m, flip(good, 0)),
        "last-preimage-flipped": (pk, m, flip(good, 255)),
        "message-bit-flipped": (pk, bytes([m[0] ^ 0x01]) + m[1:], good),
        "other-half-revealed": (pk, m, other_half(good, 100)),
        "other-message-signature": (pk, m, sign(sk, m2)),
        "public-key-swapped": (pk2, m, good),
        "zero-signature": (pk, m, [ZERO] * 256),
    }


def region(pk, m, sig):
    kernel = open(os.path.join(HERE, "kernel.bin"), "rb").read()
    img = bytearray(SCR + 96)
    img[:len(kernel)] = kernel
    img[MSG:MSG + 32] = m
    for i in range(256):
        img[SIG + 32 * i:SIG + 32 * i + 32] = sig[i]
        img[PK + 64 * i:PK + 64 * i + 32] = pk[i][0]
        img[PK + 64 * i + 32:PK + 64 * i + 64] = pk[i][1]
    img[SCR:SCR + 96] = bytes([0xEE] * 96)
    return bytes(img)


# Not called `main`: duplication.sh counts every Python `main` under
# experiments/ as a possible copy, and this one builds exp204's own images.
def build_expect_or_verify():
    every = cases()
    if sys.argv[1:2] == ["build"]:
        d = sys.argv[2]
        os.makedirs(d, exist_ok=True)
        for name, (pk, m, sig) in every.items():
            with open(os.path.join(d, name + ".bin"), "wb") as f:
                f.write(region(pk, m, sig))
            print(name, verdict(pk, m, sig))
        return 0
    if sys.argv[1:2] == ["expect"]:
        print(verdict(*every[sys.argv[2]]))
        return 0
    if sys.argv[1:2] == ["verify"]:
        before = region(*every[sys.argv[2]])
        after = read_sig(sys.argv[3])
        changed = [a for a in range(len(before)) if after[a] != before[a] and not SCR <= a < SCR + 96]
        if changed:
            print(f"{len(changed)} bytes outside the scratch changed, first at {changed[0]:#x}")
            return 1
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(build_expect_or_verify())
