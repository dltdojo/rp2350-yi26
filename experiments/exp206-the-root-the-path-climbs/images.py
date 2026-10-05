#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp206 — the Merkle signature scheme (MSS: WOTS under a Merkle tree of
height 4), test images, and the check of what the kernel left. Written
independently of the Lean: keys, signatures and the expected verdict come
from Python and hashlib.

  images.py build DIR        write DIR/<name>.bin for each case, and print
                             each name, the verdict Python expects (0 accept,
                             1 reject) and the number of HASH calls the
                             verifier's WOTS part makes for it
  images.py verify NAME SIG  check a region dump (the testbench's --sigfile
                             format): only the two scratch areas changed, the
                             67 digits there are the message's and the
                             checksum's, and the chain ends the kernel wrote
                             are the ones Python computes

The scheme, as the kernel and the proof have it. WOTS is exp205's, and the
tree is the plainest there is: no bitmasks, no tweaks, no L-tree.

  H(x)        SHA-256 of x, whose length is a multiple of 64
  F(x)        H(x || 32 zero bytes): one step along a chain
  WOTS        exp205's, w = 16: 67 chains, digits of the message low nibble
              first, then the checksum's three
  sk          sk[l][i] = H(seed || l || i || 30 zero bytes), l < 16, i < 67:
              32 secret bytes give all 16 one-time keys
  leaf l      H(e_0 || ... || e_66 || 32 zero bytes), e_i = F^15(sk[l][i]):
              the 67 chain ends of key l, made 2176 bytes long, hashed once
  node        H(left || right); the root is the tree's top, the public key
  sign(l, m)  the WOTS signature of m under key l, the index l, and the four
              siblings on the way from leaf l to the root
  verify      e_i = F^(15 - d_i)(sig_i); node = the leaf of those ends; for
              level j < 4, node = H(node || auth_j) when bit j of the index is
              0 and H(auth_j || node) when it is 1; accept when node is the root

The index is one byte, and only its low four bits are read: an index of
16 + l verifies as l. Which leaf is used is the signer's business — an MSS
signer must never use one twice, and keeping count is the shell's (exp211).

The image: kernel.bin at 0, the message at 0x1000 and the index at 0x1020,
the signature at 0x2000 (67 x 32 bytes), the authentication path at 0x4000
(4 x 32) and the root at 0x4080. Two scratch areas, both starting as 0xee:
0x3000, where the kernel writes the 67 chain ends, 32 zeros after them, then
the node (0x3880) and the 64-byte HASH input of a tree step (0x38c0); and
0x8000, exp205's chain buffer and 67 digits.
"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "hazard3"))
from kernelimages import command  # noqa: E402
from wots import H, F, chain, digits, hashes  # noqa: E402,F401

HERE = os.path.dirname(os.path.abspath(__file__))
MSG, IDX, SIG, WORK, AUTH, ROOT, SCR = 0x1000, 0x1020, 0x2000, 0x3000, 0x4000, 0x4080, 0x8000
WORK_LEN, SCR_LEN = 0x900, 131
N, HEIGHT = 67, 4
ZERO = bytes(32)









def secret(seed, leaf, i):
    return H(seed + bytes([leaf, i]) + bytes(30))


def leaf_of(ends):
    return H(b"".join(ends) + ZERO)


def mss_keygen(seed):
    """The 16 leaves, and the tree as levels: levels[0] the leaves, levels[4]
    the root alone."""
    leaves = [leaf_of([chain(secret(seed, l, i), 15) for i in range(N)]) for l in range(16)]
    levels = [leaves]
    while len(levels[-1]) > 1:
        lv = levels[-1]
        levels.append([H(lv[2 * k] + lv[2 * k + 1]) for k in range(len(lv) // 2)])
    return levels


def mss_sign(seed, levels, leaf, m):
    sig = [chain(secret(seed, leaf, i), d) for i, d in enumerate(digits(m))]
    auth = [levels[j][(leaf >> j) ^ 1] for j in range(HEIGHT)]
    return sig, leaf, auth


def mss_verify(root, m, sig, idx, auth):
    """0 when the signature verifies, 1 when it does not — the kernel's code."""
    node = leaf_of([chain(s, 15 - d) for s, d in zip(sig, digits(m))])
    for j in range(HEIGHT):
        node = H(node + auth[j]) if (idx >> j) & 1 == 0 else H(auth[j] + node)
    return 0 if node == root else 1




def mss_cases():
    rng = random.Random(206)
    seed = bytes(rng.getrandbits(8) for _ in range(32))
    levels = mss_keygen(seed)
    root = levels[-1][0]
    other = mss_keygen(bytes(rng.getrandbits(8) for _ in range(32)))
    msgs = [bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(16)]

    cases = {}
    # Completeness, as tests: every one of the 16 leaves signs, and verifies.
    for l in range(16):
        sig, idx, auth = mss_sign(seed, levels, l, msgs[l])
        cases[f"leaf-{l:02d}"] = (root, msgs[l], sig, idx, auth)

    m = msgs[5]
    sig, idx, auth = mss_sign(seed, levels, 5, m)

    def flip(b):
        return bytes([b[0] ^ 1]) + b[1:]

    def with_auth(j, value):
        a = list(auth)
        a[j] = value
        return a

    def with_sig(i, value):
        s = list(sig)
        s[i] = value
        return s

    for j in range(HEIGHT):
        cases[f"auth-{j}-wrong"] = (root, m, sig, idx, with_auth(j, flip(auth[j])))
    cases.update({
        "index-bit-0-flipped": (root, m, sig, idx ^ 1, auth),
        "index-bit-3-flipped": (root, m, sig, idx ^ 8, auth),
        "index-plus-16": (root, m, sig, idx + 16, auth),
        "other-root": (other[-1][0], m, sig, idx, auth),
        "message-changed": (root, msgs[6], sig, idx, auth),
        "first-chain-wrong": (root, m, with_sig(0, flip(sig[0])), idx, auth),
        "checksum-chain-wrong": (root, m, with_sig(66, flip(sig[66])), idx, auth),
        "other-leafs-signature": (root, m, mss_sign(seed, levels, 6, m)[0], idx, auth),
        "zero-signature": (root, m, [ZERO] * N, idx, auth),
    })
    return cases


def mss_image(root, m, sig, idx, auth):
    kernel = open(os.path.join(HERE, "kernel.bin"), "rb").read()
    img = bytearray(SCR + SCR_LEN)
    img[:len(kernel)] = kernel
    img[MSG:MSG + 32] = m
    img[IDX] = idx
    for i in range(N):
        img[SIG + 32 * i:SIG + 32 * i + 32] = sig[i]
    for j in range(HEIGHT):
        img[AUTH + 32 * j:AUTH + 32 * j + 32] = auth[j]
    img[ROOT:ROOT + 32] = root
    img[WORK:WORK + WORK_LEN] = bytes([0xEE] * WORK_LEN)
    img[SCR:SCR + SCR_LEN] = bytes([0xEE] * SCR_LEN)
    return bytes(img)


def what_it_wrote(case, after):
    root, m, sig, idx, auth = case
    if list(after[SCR + 64:SCR + 131]) != digits(m):
        return "the digits in scratch are not the message's and the checksum's"
    ends = [chain(s, 15 - d) for s, d in zip(sig, digits(m))]
    if bytes(after[WORK:WORK + 32 * N]) != b"".join(ends) or any(after[WORK + 32 * N:WORK + 32 * N + 32]):
        return "the chain ends written at 0x3000 are not the ones Python computes"
    return None


# The command line — build, verify — is tools/hazard3/kernelimages.py's, as
# every kernel experiment's is; what is here is only this experiment's cases.
if __name__ == "__main__":
    sys.exit(command(__doc__, mss_cases(), lambda case: mss_image(*case), SCR, SCR + SCR_LEN,
                     describe=lambda case: (mss_verify(*case), hashes(case[1])), check=what_it_wrote,
                     also=[(WORK, WORK + WORK_LEN)]))
