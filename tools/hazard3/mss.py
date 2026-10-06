# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3 — exp213's key generator and signer, their images and what
they write, in Python with hashlib: exp213 wrote it, exp207 needed it second.

  tree_of(seed)                   the 31 nodes keygen writes, level by level
  signed(seed, nodes, leaf, m)    the signature, path and root sign writes
  keygen_image(kernel, seed)      the key generator's image
  sign_image(kernel, seed, nodes, leaf, m)
                                  the signer's image

Scratch the kernels write starts as 0xee in both images.
"""
from wots import H, N, chain, digits, secret

HEIGHT = 4
LEVEL = [0, 16, 24, 28, 30]          # where each level starts, in nodes
K_SEED, K_PRF, K_BUF, K_ENDS, K_TREE = 0x1000, 0x1040, 0x1080, 0x2000, 0x3000
S_MSG, S_IDX, S_SEED, S_PRF, S_SIG, S_AUTH, S_ROOT, S_TREE, S_SCR = (
    0x1000, 0x1020, 0x1040, 0x1080, 0x2000, 0x4000, 0x4080, 0x5000, 0x8000)
# The scratch each kernel writes, as (address, length): 0xee before it runs.
K_FILL = ((K_PRF, 64), (K_BUF, 64), (K_ENDS, 2176), (K_TREE, 31 * 32))
S_FILL = ((S_PRF, 64), (S_SIG, 32 * N), (S_AUTH, 160), (S_SCR, 131))


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


def keygen_image(kernel, seed):
    img = bytearray(K_TREE + 31 * 32)
    img[:len(kernel)] = kernel
    img[K_SEED:K_SEED + 32] = seed
    for a, n in K_FILL:
        img[a:a + n] = bytes([0xEE] * n)
    return bytes(img)


def sign_image(kernel, seed, nodes, leaf, m):
    img = bytearray(S_SCR + 131)
    img[:len(kernel)] = kernel
    img[S_MSG:S_MSG + 32] = m
    img[S_IDX] = leaf
    img[S_SEED:S_SEED + 32] = seed
    img[S_TREE:S_TREE + 31 * 32] = b"".join(nodes)
    for a, n in S_FILL:
        img[a:a + n] = bytes([0xEE] * n)
    return bytes(img)
