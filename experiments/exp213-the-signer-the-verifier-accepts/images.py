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
from wots import digits  # noqa: E402
from mss import (K_PRF, K_BUF, K_ENDS, K_TREE, S_PRF, S_SIG, S_AUTH, S_ROOT, S_SCR,  # noqa: E402,F401
                 K_SEED, S_MSG, S_IDX, S_SEED, S_TREE, keygen_image, sign_image, signed, tree_of)

HERE = os.path.dirname(os.path.abspath(__file__))
N = 67


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
    kernel = open(os.path.join(HERE, case[0] + ".bin"), "rb").read()
    return keygen_image(kernel, case[1]) if case[0] == "keygen" else sign_image(kernel, *case[1:])


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
