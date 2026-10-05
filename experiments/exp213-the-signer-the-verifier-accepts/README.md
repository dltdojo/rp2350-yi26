# exp213 — the signer the verifier accepts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Two more kernels, proved: an MSS key generator, 432 bytes, that writes the
seed's whole Merkle tree and halts with 0 after exactly 76456 instructions
whatever the seed; and a signer, 620 bytes, that writes a WOTS signature, the
leaf's path and the root where exp206's verifier reads them, in exactly
`2284 + 3·Σdᵢ`. And one theorem, `three_binaries`, that runs the three
binaries in a row: `keygen.bin`, then `sign.bin` on what it left, then exp206's
`kernel.bin` on what that left — and the verifier halts with 0. For every seed,
message and index below 16, and every function HASH might be. The model, the
Hazard3 RTL and Python agree on both kernels' cases, and the three binaries run
in a row are accepted on both executors.**

This is stage 2 of the [verified-kernel road](../README.md#the-verified-kernel-road),
its second half. exp206 proved completeness at the reference level and carried
it to the verifier's bytes: an image holding what a reference signer would
produce is accepted. What it could not say was that a *program* produced it.
Here the signer and the key generator are programs, and the theorem is about
their bytes and the verifier's, joined.

## The scheme

exp206's, unchanged, and its reference — `secret`, `leafRef`, `node`,
`authRef` in [`lean/Rv32/Mss.lean`](../../lean/Rv32/Mss.lean), and
`tools/hazard3/wots.py`'s `secret` beside [`images.py`](./images.py) — is
what both kernels are proved against:

| | |
| --- | --- |
| secret | `sk[l][i] = H(seed ‖ l ‖ i ‖ 0³⁰)`: one block, the seed, two bytes, thirty zeros |
| leaf `l` | `H(F¹⁵(sk[l][0]) ‖ … ‖ F¹⁵(sk[l][66]) ‖ 0³²)` |
| node | `H(left ‖ right)`, four levels, the root at the top |
| signature | chain `i` of key `l` walked `dᵢ` steps — the message's 64 digits, then the checksum's three — and the four siblings on the way up |

Which leaf signs is the caller's: the signer reads it from the index byte, and
MSS breaks if one leaf signs twice. The counter that prevents it is exp211's.

## The kernels

**The key generator**, `keygen.bin`. The seed at `0x1000`; it writes the tree
at `0x3000`, 31 nodes of 32 bytes, level by level — the leaves at nodes 0 to
15, then nodes 16 to 23, 24 to 27, 28 and 29, and the root at node 30. Node
`16 + t` is `H(node 2t ‖ node 2t + 1)`, which lie next to each other, so the
whole tree is one loop over 64-byte windows.

```text
  0000–00d4  pointers; the seed into the PRF input at 0x1040; zeros after
             it, after the chain buffer at 0x1080, and after the ends     (54)
  00d8–00e0  leaf l: chain 0, the first end's place, l into the PRF input (3)
  00e4–00f8  chain i: i into the PRF input, its secret by HASH            (6)
  00fc–0104  15 steps along the chain, in place                           (3)
  0108–0144  its end, after the ones before at 0x2000                     (16)
  0148–0154  on to the next chain, 67 of them                             (4)
  0158–017c  the leaf: HASH of 2176 bytes into the tree; on to the next   (10)
  0180–01a0  15 tree nodes, each HASH of the 64 bytes before it moves on  (4 + 5)
  01a4–01ac  HALT with 0                                                  (3)
```

**The signer**, `sign.bin`. Its first 46 instructions are exp205's — setup,
the 64 message digits, the checksum's three, the chains' registers — so the
digits it signs are, by the same lemmas, the ones the verifier computes.

```text
  0000–00b4  exp205's first 46 instructions
  00b8–0128  the seed (0x1040) into the PRF input (0x1080), its zeros, l  (29)
  012c–0134  chain i: i into the PRF input, its secret by HASH            (3)
  0138–0140  the digit; past the walk when it is 0                        (3)
  0144–014c  dᵢ steps along the chain                                     (3)
  0150–018c  the value into the signature at 0x2000 + 32 i                (16)
  0190–019c  on to the next chain                                         (4)
  01a0–01b8  the tree (0x5000), the path (0x4000), the level size, l, 4   (7)
  01bc–021c  one level, four times: the sibling (l >> j) ^ 1, 32 bytes
             of it onto the path; the tree pointer on by the level's size (25)
  0220–025c  the root, node 30, after the path at 0x4080                  (16)
  0260–0268  HALT with 0                                                  (3)
```

The signer finds level `j` of the tree at node `32 − 32 / 2ʲ`: 0, 16, 24, 28,
30. Its image is the verifier's layout with two things added — the seed at
`0x1040` and the tree at `0x5000` — so that what it writes is already where
exp206 reads it: the message at `0x1000` and the index at `0x1020` are left
alone, the signature goes to `0x2000`, the path to `0x4000`, the root to
`0x4080`.

`keygen.bin` is 108 instructions and `sign.bin` 155; their SHA-256 are in
`keygen.sha256` and `sign.sha256`.

## What is proved

The kernels and their proofs are in the library, where the join can reach
them: [`lean/Rv32/MssKeygen.lean`](../../lean/Rv32/MssKeygen.lean) and
[`lean/Rv32/MssSign.lean`](../../lean/Rv32/MssSign.lean). The join is
[`proof/Complete.lean`](./proof/Complete.lean). `H` is `env.hash`, and
**nothing is assumed about it**.

| Theorem | Says |
| --- | --- |
| `Keygen.generates` | from `base`, with the kernel there, it halts with 0 after exactly 76456 instructions, still running after 76455; node `n` at `0x3000 + 32 n` is `flat n`, the reference's node at that place, for all 31; and nothing outside the PRF input and chain buffer (`0x1040`, 128 bytes) and the ends and tree (`0x2000` to `0x33e0`) changed |
| `Sign.signs` | it halts with 0 after exactly `2284 + 3 · dsum`, still running one before; chain `i` at `0x2000 + 32 i` is `chain (secret seed l i) dᵢ`; the path's node `j` is the tree's node `lvl j + sib (l / 2ʲ)`; the root is the tree's node 30; and nothing outside `0x1080` to `0x4100` and the 131 bytes of scratch changed, so the message, the index, the seed and the tree are the input's |
| `flat_node` | the key generator's layout is the reference tree: node `k` of level `j` is at `lvl j + k` |
| `hashes_add_up` | the signer's `Σ dᵢ` and the verifier's `Σ (15 − dᵢ)` add up to `67 · 15`: between them every chain is walked 15 steps |
| `keygen_sign_verify` | on machine states: the key generator halts with 0; a signer given the same seed, the tree copied from `0x3000` to `0x5000` and an index below 16 halts with 0; a verifier given the signer's region from `0x1000` to `0x4100` halts with 0 — each after its own exact count |
| `three_binaries` | the same, from the state the shell builds, for any three images that begin with `keygen.bin`, `sign.bin` and exp206's `kernel.bin` |

What the join assumes is what the shell does between runs, and only that: it
copies the seed, the tree and the signer's region, and it picks an index
below 16. [`endtoend.py`](./endtoend.py) does exactly that copying on the
model and on the RTL.

Below those, the block contracts, one per loop, each stating what its
instructions leave and how many they take: `chain_iter` (71 instructions),
`leaf_iter` (4770), `tree_iter` (5) for the key generator; `to_chains`
(416), `chain_iter` (`26 + 3 dᵢ`), `level_iter` (25) for the signer. The walk
in place, `ecall; addi; bne` at any instruction over any buffer, and the
`beq` that skips it, are [`lean/Rv32/Walk.lean`](../../lean/Rv32/Walk.lean).
The frame both kernels state, `Within`, is
[`lean/Rv32/Frame.lean`](../../lean/Rv32/Frame.lean).

Twenty-seven wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are
each refused:
- **sixteen wrong kernels:** among them, chain `i`'s number one byte late in the PRF input, 14 steps instead of 15, 66 chains, 15 leaves, a tree step's window moving 32 bytes, the walk driven by the next chain's digit, a zero digit branching into the middle of the walk, the ancestor taken instead of its sibling, and three levels instead of four;
- **eleven wrong claims:** among them, a count one short, a frame that leaves out the chain buffer or the root, level 1 starting at node 17, a secret that hashes `i` before `l`, a seventeenth leaf, and a shell that does not copy the root.

All of it rests on `propext`, `Classical.choice` and `Quot.sound`.

## The count

| | key generator | signer |
| --- | --- | --- |
| the proof | `76456` | `2284 + 3 S` |
| the model, run | the same, at `0x80010000` and at `0x20070000` | the same, on all 6 cases, at both |
| HASH calls | `16 · 67 · 16 + 16 + 15 = 17183` | `S + 67` |
| the Hazard3 RTL, `minstret` | `76456 + 3 + 4 · 17183` | `2284 + 3 S + 3 + 4 (S + 67)` |

`S` is the signer's walks, `Σ dᵢ`; the 67 more are the secrets. The key
generator's count is the same for every seed: nothing it does branches on a
secret byte. exp207 is about saying that properly.

## What it does not prove

- **Constant time.** The key generator's count does not depend on the seed and
  the signer's depends only on the message, and both say so as theorems about
  counts. That is not a statement about which addresses are touched or how
  long anything takes on silicon; exp207 is.
- **Security.** Unforgeability is not here, and neither is any property of
  HASH; every theorem holds for any function.
- **The shell.** The copying between runs is assumed, as the theorem's
  hypotheses, and done by `endtoend.py` off the chip. Keeping the seed secret
  and never signing twice under one leaf are a shell's, and exp211's.
- **The chip.** Nothing here has run on a board.

## Running it

```sh
./check.sh       # the proof, the mutants, the binaries, the model and the RTL against Python
./compare.sh     # just the last of those
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy and python3. No board.

## Expected output

```text
(pending)
```
