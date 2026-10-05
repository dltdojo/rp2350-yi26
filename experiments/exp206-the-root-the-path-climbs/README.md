# exp206 — the root the path climbs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**752 bytes of RV32IM proved to verify a Merkle signature scheme (MSS) of
height 4: WOTS (w = 16) under a tree of 16 one-time keys. The kernel halts with
0 exactly when the signature's 67 chain ends make a leaf that the
authentication path, ordered by the index's low four bits, lifts to the root,
and with 1 otherwise. It does so at exactly instruction `3295 + 3·S`, writing
nothing outside two scratch areas, for every input and every function HASH
might be. And completeness is proved down to the bytes: an image holding what a
signer produces under any of the 16 leaves makes the kernel halt with 0. The
model, the Hazard3 RTL and Python agree on 29 cases, all 16 leaves among them.**

This is stage 2 of the [verified-kernel road](../README.md#the-verified-kernel-road),
in its first half. The design asks for keygen, sign and verify, with
completeness "proved at the reference level and carried to the binary". This
experiment is the verifier and the carrying. Its kernel is the only binary,
and the completeness theorem ends in it. The signer and key generator as
kernels are the next experiment, and exp207's constant-time proofs need them
anyway.

## The scheme

As [`images.py`](./images.py) has it, independently of the Lean:

| | |
| --- | --- |
| WOTS | exp205's, unchanged: 67 chains, `F(x) = H(x ‖ 0³²)`, the message's 64 digits then the checksum's three |
| secret keys | `sk[l][i] = H(seed ‖ l ‖ i ‖ 0³⁰)` for leaf `l < 16`, chain `i < 67`: 32 secret bytes give all 16 one-time keys |
| leaf `l` | `H(e₀ ‖ … ‖ e₆₆ ‖ 0³²)`, `eᵢ = F¹⁵(sk[l][i])`: the 67 ends, 2176 bytes, hashed once |
| node | `H(left ‖ right)`; the root, four levels up, is the public key |
| signature | the WOTS signature under leaf `l`, the index `l` (one byte), and the four siblings on the way up |
| verify | walk each chain `15 − dᵢ` steps, hash the ends into a leaf, and at level `j` put the node left of the sibling when bit `j` of the index is 0 and right of it when it is 1; accept when that is the root |

The plainest tree there is: no bitmasks, no tweaks, no L-tree. Only the
index's low four bits are read, so an index of `16 + l` verifies as `l`; that is
a case below, and a property of this verifier, written down rather than
discovered. Which leaf a signer may use is the shell's business: MSS breaks if
a leaf signs twice, and the counter that prevents it is exp211's.

## The kernel

```text
  0000–0110  exp205's first 69 instructions: setup, the digits, the checksum,
             and for each chain the copy and the walk
  0114–0150  the chain's end, from the buffer to KEY + 32 i       (16)
  0154–0160  on to the next chain                                 (4)
  0164–0180  32 zeros after the 67 ends                           (8)
  0184–0198  the leaf: HASH of 2176 bytes into the node           (6)
  019c–01b4  the climb's registers: the input buffer, the path,
             the index, a count of four                           (7)
  01b8–0260  one level, four times: the two halves in order by
             the index bit with no branch, then HASH              (43)
  0264–02e0  the node against the root, eight words, no early exit (32)
  02e4–02ec  the verdict and HALT                                 (3)
```

The first 276 bytes are exp205's `kernel.bin`'s first 276. That made the
proof's first half free. exp205 writes `s2` as its public-key pointer, and
this kernel uses the same register to write each chain's end where exp205
compared it. The blocks for those 69 instructions moved to
[`lean/Rv32/Wots.lean`](../../lean/Rv32/Wots.lean), proved for any program
that starts with them. exp205 now stands on them too, with its `kernel.bin`
unchanged and its fourteen mutants still refused.

A tree level chooses the order of the two halves without a branch:
`t1 = 0 − bit`, `t2 = (cur ⊕ path) ∧ t1`, and `cur ⊕ t2`, `path ⊕ t2` are the
two pointers in one order or the other. The count is the same whichever leaf
signed. exp207 will want that, though nothing here proves it about time.

`kernel.bin` is the 752 bytes; its SHA-256 is in `kernel.sha256`. The layout:
the message at `0x1000` and the index at `0x1020`, the signature at `0x2000`,
the path at `0x4000` and the root at `0x4080`. The kernel writes in two places:
`0x3000` (the 67 ends, the padding, the node at `0x3880`, a level's HASH input
at `0x38c0`) and exp205's 131 bytes of scratch at `0x8000`.

## What is proved

[`proof/Mss.lean`](./proof/Mss.lean), with `lean/Rv32/Wots.lean` for the
first 69 instructions. `H` is `env.hash`, and **nothing is assumed about it**.

| Theorem | Says |
| --- | --- |
| `verifies` | it halts after `3295 + 3 · steps` instructions with `if Verifies H m base then 0 else 1`, and every byte outside the two scratch areas is what it was (`Writes`) |
| `exactly` | after one fewer it is still running: the count is exact |
| `code_of_image`, `from_boot` | all of it from the state `rv32run` and the RTL harness build, for any image that begins with the 752 bytes |
| `wots_complete` | what a signer reveals for digit `d`, walked `15 − d` more steps, is the chain's end |
| `path_climbs` | from leaf `l`, with `l`'s own path, the node after `j` levels is `l`'s ancestor at level `j` |
| `accepts_signed` | an image holding a signature of its own message under leaf `l < 16` of the key `seed` — chains, path, root and index as the reference signer makes them — satisfies `Verifies` |
| `signed_halts_with_zero` | so the kernel, from boot on such an image, halts with 0 after exactly `3295 + 3 · steps` |

`Verifies` is the scheme in Lean's own terms, written without the kernel:
`climbTo H m base 4 = rootAt m base`, where `climbTo 0` is the leaf of the 67
`chain H (sigAt i) (15 − digit i)` and each level is `up`, the order chosen by
`idx / 2^j % 2`. `chain_iter`, `to_tree`, `level_iter` and `halt` are the block
contracts; each states what its instructions leave and how many they take.

**Completeness, and how far it reaches.** The reference signer is a Lean
definition, `secret`, `leafRef`, `node`, `authRef`. `accepts_signed` says:
whatever `H` is, memory holding what that signer would put there verifies. Then
`signed_halts_with_zero` says the bytes accept it. What it does not say is
that a *kernel* produced the signature, because there is no signer kernel yet.
That is the next experiment, and with it the theorem becomes keygen binary,
sign binary, verify binary, accept.

Sixteen wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused:
- **nine wrong kernels:** among them, the signature stored instead of the walked end, padding one word short, the leaf over half its input, the mask not negated, and three levels instead of four;
- **seven wrong claims:** among them, a count that does not depend on the message, the root three levels up, the node on the wrong side of the bit, writing only exp205's scratch, completeness for a seventeenth leaf, and a sibling that is always the next node.

All of it rests on `propext`, `Classical.choice` and `Quot.sound`.

## The count

| | count |
| --- | --- |
| the proof | `3295 + 3 S` |
| the model, run | the same, on all 29 cases, at `0x80010000` and at `0x20070000` |
| the Hazard3 RTL, `minstret` | `3295 + 3 S + 3 + 4 (S + 5)` = `3318 + 7 S`, on all 29 |

`S` is the HASH calls the chains make, `Σ (15 − dᵢ)`. The leaf and the four
levels make five more, which is why the RTL's HASH cost is `4 (S + 5)`. That
cost is exp204's measurement, read again by `hash-cost.sh`. `S` is always a
multiple of 15 here, and in exp205: the checksum's three digits sum to the
checksum modulo 15, so the 67 digits sum to `960 ≡ 0`.

## What it does not prove

- **That the signer is a binary.** See *Completeness*, above.
- **Security.** Unforgeability is the design's optional item and is not here.
  Neither is any property of HASH; every theorem holds for any function.
- **The chip.** Nothing here has run on a board. The verifier would run under
  exp210's shell unchanged, being one more kernel that calls HASH, but no UF2
  has been built for it.

## Running it

```sh
./check.sh       # the proof, the mutants, kernel.bin, the model and the RTL against Python
./compare.sh     # just the last of those
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy and python3. No board.

## Expected output

```text
(recorded by run.sh)
```
