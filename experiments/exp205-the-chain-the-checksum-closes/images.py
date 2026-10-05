#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp205 — Winternitz one-time signatures (WOTS, w = 16), test images, and
the check of what the kernel left. Written independently of the Lean: keys,
signatures and the expected verdict come from Python and hashlib.

  images.py build DIR        write DIR/<name>.bin for each case, and print
                             each name, the verdict Python expects (0 accept,
                             1 reject) and the number of HASH calls a verifier
                             makes for it
  images.py verify NAME SIG  check a region dump (the testbench's --sigfile
                             format): the message, signature and public key
                             are untouched, only the 131 bytes of scratch
                             changed, and the digits the kernel wrote there
                             are the message's and the checksum's

The scheme, as the kernel and the proof have it:

  F(x)       SHA-256 of x || 32 zero bytes: one step along a chain
  F^k(x)     k steps
  digits     the 32-byte message as 64 base-16 digits, low nibble of each
             byte first; then the checksum c = sum(15 - a_i) over those 64,
             at most 960, as 3 more digits, low first: 67 in all
  keygen     sk[i] 32 random bytes for i < 67; pk[i] = F^15(sk[i])
  sign(m)    sig[i] = F^d_i(sk[i]) for the 67 digits d of m
  verify     F^(15 - d_i)(sig[i]) == pk[i] for every i

This is WOTS without WOTS+'s bitmasks and tweaks: the plainest Winternitz
there is, and what the road's design asks for. The checksum is what stops a
forger from walking a chain forward — raising a message digit lowers the
checksum, and walking a checksum chain backward means inverting F.

The image: kernel.bin at 0, the message at 0x1000, the signature at 0x2000
(67 x 32 bytes), the public key at 0x3000 (67 x 32), and 131 bytes of scratch
at 0x8000 — the 64-byte HASH buffer, then the 67 digits — that start as
something other than zero, because the kernel must not rely on them.
"""
import hashlib
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "hazard3"))
from kernelimages import command  # noqa: E402
from wots import F, chain, digits, hashes  # noqa: E402,F401

HERE = os.path.dirname(os.path.abspath(__file__))
MSG, SIG, PK, SCR = 0x1000, 0x2000, 0x3000, 0x8000
N = 67
ZERO = bytes(32)








def keygen(rng):
    sk = [bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(N)]
    return sk, [chain(s, 15) for s in sk]


def sign(sk, m):
    return [chain(s, d) for s, d in zip(sk, digits(m))]


def verdict(pk, m, sig):
    ok = all(chain(s, 15 - d) == p for s, d, p in zip(sig, digits(m), pk))
    return 0 if ok else 1




def wots_cases():
    rng = random.Random(205)
    sk, pk = keygen(rng)
    sk2, pk2 = keygen(rng)
    m = bytes(rng.getrandbits(8) for _ in range(32))
    m2 = bytes(rng.getrandbits(8) for _ in range(32))
    zeros, ones = bytes(32), bytes([0xFF] * 32)
    sig = sign(sk, m)

    def with_sig(i, value):
        s = list(sig)
        s[i] = value
        return s

    # The forgery the checksum is there to stop: raise digit 0 of the
    # message by one and walk its chain one step forward — which anybody can.
    # Only the checksum, now one lower, gives it away.
    d0 = m[0] & 15
    raised = bytes([m[0] + 1 if d0 < 15 else m[0] - 15]) + m[1:]
    walked = with_sig(0, F(sig[0])) if d0 < 15 else sig
    swapped = list(pk)
    swapped[0], swapped[1] = pk[1], pk[0]
    return {
        "valid": (pk, m, sig),
        "valid-other-key": (pk2, m2, sign(sk2, m2)),
        "valid-zero-message": (pk, zeros, sign(sk, zeros)),
        "valid-ones-message": (pk, ones, sign(sk, ones)),
        "first-chain-wrong": (pk, m, with_sig(0, bytes([sig[0][0] ^ 1]) + sig[0][1:])),
        "checksum-chain-wrong": (pk, m, with_sig(64, bytes([sig[64][0] ^ 1]) + sig[64][1:])),
        "last-chain-wrong": (pk, m, with_sig(66, bytes([sig[66][0] ^ 1]) + sig[66][1:])),
        "chain-walked-forward": (pk, raised, walked),
        "other-message-signature": (pk, m2, sig),
        "public-key-swapped": (swapped, m, sig),
        "zero-signature": (pk, m, [ZERO] * N),
    }


def wots_image(pk, m, sig):
    kernel = open(os.path.join(HERE, "kernel.bin"), "rb").read()
    img = bytearray(SCR + 131)
    img[:len(kernel)] = kernel
    img[MSG:MSG + 32] = m
    for i in range(N):
        img[SIG + 32 * i:SIG + 32 * i + 32] = sig[i]
        img[PK + 32 * i:PK + 32 * i + 32] = pk[i]
    img[SCR:SCR + 131] = bytes([0xEE] * 131)
    return bytes(img)


# The command line — build, verify — is tools/hazard3/kernelimages.py's, as
# every kernel experiment's is; what is here is only this experiment's cases.
def digits_written(case, after):
    pk, m, sig = case
    if list(after[SCR + 64:SCR + 131]) != digits(m):
        return "the digits in scratch are not the message's and the checksum's"
    return None


if __name__ == "__main__":
    sys.exit(command(__doc__, wots_cases(), lambda case: wots_image(*case), SCR, SCR + 131,
                     describe=lambda case: (verdict(*case), hashes(case[1])), check=digits_written))
