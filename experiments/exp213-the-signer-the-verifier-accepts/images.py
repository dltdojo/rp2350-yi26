#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp213 — the MSS key generator and signer, test images, and the check of
what each kernel left. Written independently of the Lean: the scheme is
exp206's images.py's, with hashlib.

  EXP213_KERNEL=keygen|sign images.py build DIR
  EXP213_KERNEL=keygen|sign images.py verify NAME SIG

Which kernel's cases is chosen by EXP213_KERNEL, so that
tools/hazard3/kernelcompare.sh can run each kernel's cases with its own
count. `build` prints each name, 0 (neither kernel has a verdict: both halt
with 0) and S, the HASH calls that depend on the input — none for keygen,
`sum(d_i)` for sign.

  keygen     in:  the seed at 0x1000
             out: the tree at 0x3000, 31 nodes of 32 bytes, level by level —
                  leaves 0..15, then level 1 at 16..23, 2 at 24..27, 3 at
                  28..29, the root at 30. Node 16 + t is H(node 2t || node
                  2t + 1), which are next to each other: the tree is built
                  in place
  sign       in:  the message at 0x1000, the leaf l at 0x1020 (one byte, l <
                  16), the seed at 0x1040, keygen's tree at 0x5000
             out: the WOTS signature at 0x2000, the path at 0x4000 and the
                  root at 0x4080 — exactly where exp206's verifier reads
                  them, with the message and the index where it reads those
                  too

Scratch, all starting as 0xee: for keygen the PRF input (0x1040), the chain
buffer (0x1080) and the ends (0x2000); for sign the PRF input (0x1080) and
exp205's 131 bytes at 0x8000.
"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "hazard3"))
from kernelimages import command  # noqa: E402
from wots import H, chain, digits, secret  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
N, HEIGHT = 67, 4
LEVEL = [0, 16, 24, 28, 30]          # where each level starts, in nodes
K_SEED, K_PRF, K_BUF, K_ENDS, K_TREE = 0x1000, 0x1040, 0x1080, 0x2000, 0x3000
S_MSG, S_IDX, S_SEED, S_PRF, S_SIG, S_AUTH, S_ROOT, S_TREE, S_SCR = (
    0x1000, 0x1020, 0x1040, 0x1080, 0x2000, 0x4000, 0x4080, 0x5000, 0x8000)


def tree_of(seed):
    """The 31 nodes, level by level, as keygen writes them."""
    nodes = [H(b"".join(chain(secret(seed, l, i), 15) for i in range(N)) + bytes(32)) for l in range(16)]
    for t in range(15):
        nodes.append(H(nodes[2 * t] + nodes[2 * t + 1]))
    return nodes


def signed(seed, nodes, leaf, m):
    sig = [chain(secret(seed, leaf, i), d) for i, d in enumerate(digits(m))]
    auth = [nodes[LEVEL[j] + ((leaf >> j) ^ 1)] for j in range(HEIGHT)]
    return sig, auth, nodes[30]


def seeds():
    """The three keygen cases' seeds; endtoend.py signs under the first."""
    rng = random.Random(213)
    return rng, [bytes(rng.getrandbits(8) for _ in range(32)) for _ in range(3)]


def cases():
    rng, seeds_ = seeds()
    if os.environ.get("EXP213_KERNEL") == "keygen":
        return {f"keygen-{k}": ("keygen", s) for k, s in enumerate(seeds_)}
    nodes = tree_of(seeds_[0])
    out = {}
    for l in (0, 5, 10, 15):
        m = bytes(rng.getrandbits(8) for _ in range(32))
        out[f"sign-leaf-{l:02d}"] = ("sign", seeds_[0], nodes, l, m)
    out["sign-zero-message"] = ("sign", seeds_[0], nodes, 3, bytes(32))
    out["sign-ones-message"] = ("sign", seeds_[0], nodes, 12, bytes([0xFF] * 32))
    return out


def image(case):
    kind = case[0]
    kernel = open(os.path.join(HERE, kind + ".bin"), "rb").read()
    if kind == "keygen":
        img = bytearray(K_TREE + 31 * 32)
        img[:len(kernel)] = kernel
        img[K_SEED:K_SEED + 32] = case[1]
        for a, n in ((K_PRF, 64), (K_BUF, 64), (K_ENDS, 2176), (K_TREE, 31 * 32)):
            img[a:a + n] = bytes([0xEE] * n)
        return bytes(img)
    _, seed, nodes, leaf, m = case
    img = bytearray(S_SCR + 131)
    img[:len(kernel)] = kernel
    img[S_MSG:S_MSG + 32] = m
    img[S_IDX] = leaf
    img[S_SEED:S_SEED + 32] = seed
    img[S_TREE:S_TREE + 31 * 32] = b"".join(nodes)
    for a, n in ((S_PRF, 64), (S_SIG, 32 * N), (S_AUTH, 160), (S_SCR, 131)):
        img[a:a + n] = bytes([0xEE] * n)
    return bytes(img)


def hashes(case):
    return 0 if case[0] == "keygen" else sum(digits(case[4]))


def kernel_left(case, after):
    if case[0] == "keygen":
        if bytes(after[K_TREE:K_TREE + 31 * 32]) != b"".join(tree_of(case[1])):
            return "the tree is not the one Python builds from the seed"
        return None
    _, seed, nodes, leaf, m = case
    sig, auth, root = signed(seed, nodes, leaf, m)
    if bytes(after[S_SIG:S_SIG + 32 * N]) != b"".join(sig):
        return "the signature is not the one Python signs"
    if bytes(after[S_AUTH:S_AUTH + 128]) != b"".join(auth) or bytes(after[S_ROOT:S_ROOT + 32]) != root:
        return "the path or the root is not the tree's"
    return None


if __name__ == "__main__":
    keygen = os.environ.get("EXP213_KERNEL") == "keygen"
    lo, hi, also = ((K_PRF, K_BUF + 64, [(K_ENDS, K_ENDS + 2176), (K_TREE, K_TREE + 31 * 32)]) if keygen else
                    (S_SCR, S_SCR + 131, [(S_PRF, S_PRF + 64), (S_SIG, S_SIG + 32 * N), (S_AUTH, S_AUTH + 160)]))
    sys.exit(command(__doc__, cases(), image, lo, hi, describe=lambda case: (0, hashes(case)),
                     check=kernel_left, also=also))
