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
| the model, run | the same, on all 3 seeds, at `0x80010000` and at `0x20070000` | the same, on all 6 cases, at both |
| HASH calls | `16 · 67 · 16 + 16 + 15 = 17183` | `S + 67` |
| the Hazard3 RTL, `minstret` | `76456 + 3 + 4 · 17183` = 145191, on the first seed — the count is proved not to depend on it, and a run takes six minutes there | `2284 + 3 S + 3 + 4 (S + 67)` |

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
=== exp213 — the signer the verifier accepts ===
recorded at 2026-10-06T01:45:22Z from commit 21d73bb

>>> the kernels, as the proof states them and as keygen.bin and sign.bin hold them
keygen:
  0000  00000417  auipc x8, 0
  0004  00001337  lui x6, 1
  0008  006404b3  add x9, x8, x6
  000c  00002337  lui x6, 2
  0010  00640933  add x18, x8, x6
  0014  00003337  lui x6, 3
  0018  006409b3  add x19, x8, x6
  001c  04048a13  addi x20, x9, 64
  0020  08048a93  addi x21, x9, 128
  0024  7ff90b13  addi x22, x18, 2047
  0028  061b0b13  addi x22, x22, 97
  002c  0004ae83  lw x29, 0(x9)
  0030  01da2023  sw x29, 0(x20)
  0034  0044ae83  lw x29, 4(x9)
  0038  01da2223  sw x29, 4(x20)
  003c  0084ae83  lw x29, 8(x9)
  0040  01da2423  sw x29, 8(x20)
  0044  00c4ae83  lw x29, 12(x9)
  0048  01da2623  sw x29, 12(x20)
  004c  0104ae83  lw x29, 16(x9)
  0050  01da2823  sw x29, 16(x20)
  0054  0144ae83  lw x29, 20(x9)
  0058  01da2a23  sw x29, 20(x20)
  005c  0184ae83  lw x29, 24(x9)
  0060  01da2c23  sw x29, 24(x20)
  0064  01c4ae83  lw x29, 28(x9)
  0068  01da2e23  sw x29, 28(x20)
  006c  020a2023  sw x0, 32(x20)
  0070  020a2223  sw x0, 36(x20)
  0074  020a2423  sw x0, 40(x20)
  0078  020a2623  sw x0, 44(x20)
  007c  020a2823  sw x0, 48(x20)
  0080  020a2a23  sw x0, 52(x20)
  0084  020a2c23  sw x0, 56(x20)
  0088  020a2e23  sw x0, 60(x20)
  008c  020aa023  sw x0, 32(x21)
  0090  020aa223  sw x0, 36(x21)
  0094  020aa423  sw x0, 40(x21)
  0098  020aa623  sw x0, 44(x21)
  009c  020aa823  sw x0, 48(x21)
  00a0  020aaa23  sw x0, 52(x21)
  00a4  020aac23  sw x0, 56(x21)
  00a8  020aae23  sw x0, 60(x21)
  00ac  000b2023  sw x0, 0(x22)
  00b0  000b2223  sw x0, 4(x22)
  00b4  000b2423  sw x0, 8(x22)
  00b8  000b2623  sw x0, 12(x22)
  00bc  000b2823  sw x0, 16(x22)
  00c0  000b2a23  sw x0, 20(x22)
  00c4  000b2c23  sw x0, 24(x22)
  00c8  000b2e23  sw x0, 28(x22)
  00cc  00000293  addi x5, x0, 0
  00d0  04000593  addi x11, x0, 64
  00d4  00000b93  addi x23, x0, 0
  00d8  00000c13  addi x24, x0, 0
  00dc  00090c93  addi x25, x18, 0
  00e0  037a0023  sb x23, 32(x20)
  00e4  038a00a3  sb x24, 33(x20)
  00e8  000a0513  addi x10, x20, 0
  00ec  000a8613  addi x12, x21, 0
  00f0  00000073  ecall
  00f4  000a8513  addi x10, x21, 0
  00f8  00f00e13  addi x28, x0, 15
  00fc  00000073  ecall
  0100  fffe0e13  addi x28, x28, -1
  0104  fe0e1ce3  bne x28, x0, -8
  0108  000aae83  lw x29, 0(x21)
  010c  01dca023  sw x29, 0(x25)
  0110  004aae83  lw x29, 4(x21)
  0114  01dca223  sw x29, 4(x25)
  0118  008aae83  lw x29, 8(x21)
  011c  01dca423  sw x29, 8(x25)
  0120  00caae83  lw x29, 12(x21)
  0124  01dca623  sw x29, 12(x25)
  0128  010aae83  lw x29, 16(x21)
  012c  01dca823  sw x29, 16(x25)
  0130  014aae83  lw x29, 20(x21)
  0134  01dcaa23  sw x29, 20(x25)
  0138  018aae83  lw x29, 24(x21)
  013c  01dcac23  sw x29, 24(x25)
  0140  01caae83  lw x29, 28(x21)
  0144  01dcae23  sw x29, 28(x25)
  0148  020c8c93  addi x25, x25, 32
  014c  001c0c13  addi x24, x24, 1
  0150  04300393  addi x7, x0, 67
  0154  f87c18e3  bne x24, x7, -112
  0158  00090513  addi x10, x18, 0
  015c  44000593  addi x11, x0, 1088
  0160  00b585b3  add x11, x11, x11
  0164  00098613  addi x12, x19, 0
  0168  00000073  ecall
  016c  04000593  addi x11, x0, 64
  0170  02098993  addi x19, x19, 32
  0174  001b8b93  addi x23, x23, 1
  0178  01000393  addi x7, x0, 16
  017c  f47b9ee3  bne x23, x7, -164
  0180  00003337  lui x6, 3
  0184  00640533  add x10, x8, x6
  0188  00098613  addi x12, x19, 0
  018c  00f00c13  addi x24, x0, 15
  0190  00000073  ecall
  0194  04050513  addi x10, x10, 64
  0198  02060613  addi x12, x12, 32
  019c  fffc0c13  addi x24, x24, -1
  01a0  fe0c18e3  bne x24, x0, -16
  01a4  00000513  addi x10, x0, 0
  01a8  00100293  addi x5, x0, 1
  01ac  00000073  ecall
sign:
  0000  00000417  auipc x8, 0
  0004  00001337  lui x6, 1
  0008  006409b3  add x19, x8, x6
  000c  00002337  lui x6, 2
  0010  006404b3  add x9, x8, x6
  0014  00003337  lui x6, 3
  0018  00640933  add x18, x8, x6
  001c  00008337  lui x6, 8
  0020  00640ab3  add x21, x8, x6
  0024  00000b13  addi x22, x0, 0
  0028  020aa023  sw x0, 32(x21)
  002c  020aa223  sw x0, 36(x21)
  0030  020aa423  sw x0, 40(x21)
  0034  020aa623  sw x0, 44(x21)
  0038  020aa823  sw x0, 48(x21)
  003c  020aaa23  sw x0, 52(x21)
  0040  020aac23  sw x0, 56(x21)
  0044  020aae23  sw x0, 60(x21)
  0048  00098713  addi x14, x19, 0
  004c  040a8793  addi x15, x21, 64
  0050  02098813  addi x16, x19, 32
  0054  00000693  addi x13, x0, 0
  0058  00074303  lbu x6, 0(x14)
  005c  00f37393  andi x7, x6, 15
  0060  00435313  srli x6, x6, 4
  0064  00778023  sb x7, 0(x15)
  0068  006780a3  sb x6, 1(x15)
  006c  407686b3  sub x13, x13, x7
  0070  406686b3  sub x13, x13, x6
  0074  01e68693  addi x13, x13, 30
  0078  00170713  addi x14, x14, 1
  007c  00278793  addi x15, x15, 2
  0080  fd071ce3  bne x14, x16, -40
  0084  00f6f313  andi x6, x13, 15
  0088  00678023  sb x6, 0(x15)
  008c  0046d313  srli x6, x13, 4
  0090  00f37313  andi x6, x6, 15
  0094  006780a3  sb x6, 1(x15)
  0098  0086d313  srli x6, x13, 8
  009c  00678123  sb x6, 2(x15)
  00a0  040a8713  addi x14, x21, 64
  00a4  083a8b93  addi x23, x21, 131
  00a8  00000293  addi x5, x0, 0
  00ac  000a8513  addi x10, x21, 0
  00b0  04000593  addi x11, x0, 64
  00b4  000a8613  addi x12, x21, 0
  00b8  04098c13  addi x24, x19, 64
  00bc  08098a13  addi x20, x19, 128
  00c0  000c2e83  lw x29, 0(x24)
  00c4  01da2023  sw x29, 0(x20)
  00c8  004c2e83  lw x29, 4(x24)
  00cc  01da2223  sw x29, 4(x20)
  00d0  008c2e83  lw x29, 8(x24)
  00d4  01da2423  sw x29, 8(x20)
  00d8  00cc2e83  lw x29, 12(x24)
  00dc  01da2623  sw x29, 12(x20)
  00e0  010c2e83  lw x29, 16(x24)
  00e4  01da2823  sw x29, 16(x20)
  00e8  014c2e83  lw x29, 20(x24)
  00ec  01da2a23  sw x29, 20(x20)
  00f0  018c2e83  lw x29, 24(x24)
  00f4  01da2c23  sw x29, 24(x20)
  00f8  01cc2e83  lw x29, 28(x24)
  00fc  01da2e23  sw x29, 28(x20)
  0100  020a2023  sw x0, 32(x20)
  0104  020a2223  sw x0, 36(x20)
  0108  020a2423  sw x0, 40(x20)
  010c  020a2623  sw x0, 44(x20)
  0110  020a2823  sw x0, 48(x20)
  0114  020a2a23  sw x0, 52(x20)
  0118  020a2c23  sw x0, 56(x20)
  011c  020a2e23  sw x0, 60(x20)
  0120  0209cc83  lbu x25, 32(x19)
  0124  039a0023  sb x25, 32(x20)
  0128  00000c13  addi x24, x0, 0
  012c  038a00a3  sb x24, 33(x20)
  0130  000a0513  addi x10, x20, 0
  0134  00000073  ecall
  0138  000a8513  addi x10, x21, 0
  013c  00074e03  lbu x28, 0(x14)
  0140  000e0863  beq x28, x0, 16
  0144  00000073  ecall
  0148  fffe0e13  addi x28, x28, -1
  014c  fe0e1ce3  bne x28, x0, -8
  0150  000aae83  lw x29, 0(x21)
  0154  01d4a023  sw x29, 0(x9)
  0158  004aae83  lw x29, 4(x21)
  015c  01d4a223  sw x29, 4(x9)
  0160  008aae83  lw x29, 8(x21)
  0164  01d4a423  sw x29, 8(x9)
  0168  00caae83  lw x29, 12(x21)
  016c  01d4a623  sw x29, 12(x9)
  0170  010aae83  lw x29, 16(x21)
  0174  01d4a823  sw x29, 16(x9)
  0178  014aae83  lw x29, 20(x21)
  017c  01d4aa23  sw x29, 20(x9)
  0180  018aae83  lw x29, 24(x21)
  0184  01d4ac23  sw x29, 24(x9)
  0188  01caae83  lw x29, 28(x21)
  018c  01d4ae23  sw x29, 28(x9)
  0190  02048493  addi x9, x9, 32
  0194  00170713  addi x14, x14, 1
  0198  001c0c13  addi x24, x24, 1
  019c  f97718e3  bne x14, x23, -112
  01a0  00005337  lui x6, 5
  01a4  00640d33  add x26, x8, x6
  01a8  00004337  lui x6, 4
  01ac  00640933  add x18, x8, x6
  01b0  20000d93  addi x27, x0, 512
  01b4  000c8693  addi x13, x25, 0
  01b8  00400813  addi x16, x0, 4
  01bc  0016c313  xori x6, x13, 1
  01c0  00531313  slli x6, x6, 5
  01c4  006d07b3  add x15, x26, x6
  01c8  0007ae83  lw x29, 0(x15)
  01cc  01d92023  sw x29, 0(x18)
  01d0  0047ae83  lw x29, 4(x15)
  01d4  01d92223  sw x29, 4(x18)
  01d8  0087ae83  lw x29, 8(x15)
  01dc  01d92423  sw x29, 8(x18)
  01e0  00c7ae83  lw x29, 12(x15)
  01e4  01d92623  sw x29, 12(x18)
  01e8  0107ae83  lw x29, 16(x15)
  01ec  01d92823  sw x29, 16(x18)
  01f0  0147ae83  lw x29, 20(x15)
  01f4  01d92a23  sw x29, 20(x18)
  01f8  0187ae83  lw x29, 24(x15)
  01fc  01d92c23  sw x29, 24(x18)
  0200  01c7ae83  lw x29, 28(x15)
  0204  01d92e23  sw x29, 28(x18)
  0208  02090913  addi x18, x18, 32
  020c  01bd0d33  add x26, x26, x27
  0210  001ddd93  srli x27, x27, 1
  0214  0016d693  srli x13, x13, 1
  0218  fff80813  addi x16, x16, -1
  021c  fa0810e3  bne x16, x0, -96
  0220  000d2e83  lw x29, 0(x26)
  0224  01d92023  sw x29, 0(x18)
  0228  004d2e83  lw x29, 4(x26)
  022c  01d92223  sw x29, 4(x18)
  0230  008d2e83  lw x29, 8(x26)
  0234  01d92423  sw x29, 8(x18)
  0238  00cd2e83  lw x29, 12(x26)
  023c  01d92623  sw x29, 12(x18)
  0240  010d2e83  lw x29, 16(x26)
  0244  01d92823  sw x29, 16(x18)
  0248  014d2e83  lw x29, 20(x26)
  024c  01d92a23  sw x29, 20(x18)
  0250  018d2e83  lw x29, 24(x26)
  0254  01d92c23  sw x29, 24(x18)
  0258  01cd2e83  lw x29, 28(x26)
  025c  01d92e23  sw x29, 28(x18)
  0260  00000513  addi x10, x0, 0
  0264  00100293  addi x5, x0, 1
  0268  00000073  ecall
    keygen.bin sha256 624925f64f5a7251789d7b6f2f3429b7b917e315af8a263de861d7dad8ded2b9  (432 bytes)
    byte for byte the committed keygen.bin
    sign.bin sha256 f392fecb427dacc0a22aecc7f80e6f4a7de6e0918ab0232f43cb684fd1a67fed  (620 bytes)
    byte for byte the committed sign.bin

>>> the theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Rv32.Mss.Keygen.bytes_words' depends on axioms: [propext]
'Rv32.Mss.Keygen.code_of_image' depends on axioms: [propext, Quot.sound]
'Rv32.Mss.Keygen.chain_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Keygen.leaf_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Keygen.tree_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Keygen.generates' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Sign.bytes_words' depends on axioms: [propext]
'Rv32.Mss.Sign.code_of_image' depends on axioms: [propext, Quot.sound]
'Rv32.Mss.Sign.chain_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Sign.level_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Mss.Sign.signs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp213.flat_node' depends on axioms: [propext, Quot.sound]
'Exp213.hashes_add_up' depends on axioms: [propext, Quot.sound]
'Exp213.keygen_sign_verify' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp213.three_binaries' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
keygen  chain i's number goes into byte 34 of the PRF input, not 33                                           refused in chain_iter
keygen  each chain is walked 14 steps, not 15                                                                 refused in chain_iter
keygen  the ends are written 64 bytes apart                                                                   refused in chain_iter
keygen  a leaf has 66 chains                                                                                  refused in chain_iter
keygen  the leaf hashes 1088 bytes, not 2176                                                                  refused in leaf_end
keygen  there are 15 leaves                                                                                   refused in leaf_end
keygen  the tree stops one node short of the root                                                             refused in to_tree
keygen  a tree step's input moves 32 bytes, so it hashes each node with its neighbour                         refused in tree_iter
keygen  the zeros after the ends are seven words, so four bytes of each leaf's input are whatever was there   refused in kernel_length
keygen  it is claimed to halt one instruction sooner                                                          refused in generates
keygen  it is claimed to write only the PRF input, not the chain buffer after it                              refused in KMem.keeps
keygen  level 1 is claimed to start at node 17                                                                refused in flat_step
keygen  the secret is claimed to hash i before l                                                              refused in chain_iter
sign    the index is read one byte late                                                                       refused in to_chains
sign    chain i is walked by the next chain's digit                                                           refused in chain_iter
sign    a digit of 0 branches into the middle of the walk                                                     refused in chain_iter
sign    the signature's values are written 64 bytes apart                                                     refused in chain_iter
sign    the path takes the ancestor itself, not its sibling                                                   refused in level_iter
sign    each level is taken to be a quarter of the one below                                                  refused in level_iter
sign    the path has three nodes                                                                              refused in to_path
sign    each chain is claimed to cost two instructions per HASH, not three                                    refused in signs
sign    it is claimed still to be running one instruction later                                               refused in to_the_ecall
sign    it is claimed to write nothing past the path, so not the root                                         refused in SMem.keeps
sign    the path is claimed to take the ancestor, not its sibling                                             refused in level_iter
join    the verifier is claimed to accept a seventeenth leaf                                                  refused in keygen_sign_verify
join    the shell is taken to copy the signer's region only up to the root                                    refused in keygen_sign_verify
join    the shell is taken to copy the tree without its root                                                  refused in keygen_sign_verify

>>> what one HASH costs the RTL that the model does not count
  k   model   RTL: zeros   input   behind   RTL − model
  0       8           11      11       12             3
  1       9           16      16       17             7
  2      10           21      21       22            11
  3      11           26      26       27            15
  4      12           31      31       32            19
  5      13           36      36       37            23
  6      14           41      41       42            27
  7      15           46      46       47            31
PASS  RTL − model = 3 + 4 × HASH calls, for k = 0..7: the harness's constant is 3 and one HASH costs 4 more
PASS  the bytes hashed do not move the count; a nop behind the HALT ecall, never executed, adds one, at every k

>>> the kernels on the model and on the RTL, against Python; then the three in a row
>>> the key generator
case                     python S  model at 0x80010000        RTL                                model at 0x20070000
keygen-0                 0 0       halt code=00000000 count=76456 halt code=00000000 instret=145191 cycles=195653 halt code=00000000 count=76456
keygen-1                 0 0       halt code=00000000 count=76456 model only                         halt code=00000000 count=76456
keygen-2                 0 0       halt code=00000000 count=76456 model only                         halt code=00000000 count=76456

PASS  the model gives Python's verdict after exactly 76456 + 0 S instructions, the count proved, on all 3 cases
PASS  the RTL gives the same verdict and counts 76456 + 0 S proved + 3 for the harness + 4 (S + 17183) for HASH, on the 1 of 3 run on the RTL
PASS  the whole region is byte for byte the same on both, on the 1 of 3 run on the RTL
PASS  Python agrees: the tree is the one Python builds from the seed, on all 3
PASS  at 0x20070000 the same bytes give the same verdict after the same count, on all 3

>>> the signer
case                     python S  model at 0x80010000        RTL                                model at 0x20070000
sign-leaf-00             0 510     halt code=00000000 count=3814 halt code=00000000 instret=6125 cycles=7908 halt code=00000000 count=3814
sign-leaf-05             0 495     halt code=00000000 count=3769 halt code=00000000 instret=6020 cycles=7756 halt code=00000000 count=3769
sign-leaf-10             0 480     halt code=00000000 count=3724 halt code=00000000 instret=5915 cycles=7604 halt code=00000000 count=3724
sign-leaf-15             0 525     halt code=00000000 count=3859 halt code=00000000 instret=6230 cycles=8054 halt code=00000000 count=3859
sign-zero-message        0 15      halt code=00000000 count=2329 halt code=00000000 instret=2660 cycles=3074 halt code=00000000 count=2329
sign-ones-message        0 960     halt code=00000000 count=5164 halt code=00000000 instret=9275 cycles=12400 halt code=00000000 count=5164

PASS  the model gives Python's verdict after exactly 2284 + 3 S instructions, the count proved, on all 6 cases
PASS  the RTL gives the same verdict and counts 2284 + 3 S proved + 3 for the harness + 4 (S + 67) for HASH, on all 6
PASS  the whole region is byte for byte the same on both, on all 6
PASS  Python agrees: the signature, the path and the root are the ones Python signs, on all 6
PASS  at 0x20070000 the same bytes give the same verdict after the same count, on all 6

>>> the three in a row
keygen         halt code=00000000 count=76456  tree is Python's
leaf  0  sign halt code=00000000 count=4309  verify halt code=00000000 count=4285
leaf  5  sign halt code=00000000 count=4624  verify halt code=00000000 count=3970
leaf 10  sign halt code=00000000 count=3364  verify halt code=00000000 count=5230
leaf 15  sign halt code=00000000 count=4399  verify halt code=00000000 count=4195
PASS  keygen, sign and exp206's verify in a row on the model: the verifier accepts leaves 0, 5, 10, 15
keygen         (its region from keygen-0.sig)  tree is Python's
leaf  0  sign halt code=00000000 instret=7280 cycles=9546  verify halt code=00000000 instret=5628 cycles=6675
leaf 15  sign halt code=00000000 instret=7490 cycles=9848  verify halt code=00000000 instret=5418 cycles=6407
PASS  keygen, sign and exp206's verify in a row on the rtl: the verifier accepts leaves 0, 15
```
