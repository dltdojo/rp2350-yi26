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

[`lean/Rv32/Mss.lean`](../../lean/Rv32/Mss.lean), with `lean/Rv32/Wots.lean`
for the first 69 instructions. The proof began here, in `proof/Mss.lean`, and
moved to the library when exp213 needed it: a proof file imports the library
and nothing else, and exp213's theorem joins this kernel to its key generator
and signer. `proof/Mss.lean` now prints what the theorems rest on and writes
`kernel.bin`, and the mutants edit the library file. `H` is `env.hash`, and
**nothing is assumed about it**.

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
sign binary, verify binary, accept. [exp213](../exp213-the-signer-the-verifier-accepts/)
is that experiment, and its `three_binaries` ends in this kernel's bytes.

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

- **That the signer is a binary.** See *Completeness*, above; exp213 proves
  it.
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
=== exp206 — the root the path climbs ===
recorded at 2026-10-05T06:07:26Z from commit 94e652f

>>> the kernel, as the proof states it and as kernel.bin holds it
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
  00b8  0004ae83  lw x29, 0(x9)
  00bc  01daa023  sw x29, 0(x21)
  00c0  0044ae83  lw x29, 4(x9)
  00c4  01daa223  sw x29, 4(x21)
  00c8  0084ae83  lw x29, 8(x9)
  00cc  01daa423  sw x29, 8(x21)
  00d0  00c4ae83  lw x29, 12(x9)
  00d4  01daa623  sw x29, 12(x21)
  00d8  0104ae83  lw x29, 16(x9)
  00dc  01daa823  sw x29, 16(x21)
  00e0  0144ae83  lw x29, 20(x9)
  00e4  01daaa23  sw x29, 20(x21)
  00e8  0184ae83  lw x29, 24(x9)
  00ec  01daac23  sw x29, 24(x21)
  00f0  01c4ae83  lw x29, 28(x9)
  00f4  01daae23  sw x29, 28(x21)
  00f8  00074e03  lbu x28, 0(x14)
  00fc  00f00393  addi x7, x0, 15
  0100  41c38e33  sub x28, x7, x28
  0104  000e0863  beq x28, x0, 16
  0108  00000073  ecall
  010c  fffe0e13  addi x28, x28, -1
  0110  fe0e1ce3  bne x28, x0, -8
  0114  000aae83  lw x29, 0(x21)
  0118  01d92023  sw x29, 0(x18)
  011c  004aae83  lw x29, 4(x21)
  0120  01d92223  sw x29, 4(x18)
  0124  008aae83  lw x29, 8(x21)
  0128  01d92423  sw x29, 8(x18)
  012c  00caae83  lw x29, 12(x21)
  0130  01d92623  sw x29, 12(x18)
  0134  010aae83  lw x29, 16(x21)
  0138  01d92823  sw x29, 16(x18)
  013c  014aae83  lw x29, 20(x21)
  0140  01d92a23  sw x29, 20(x18)
  0144  018aae83  lw x29, 24(x21)
  0148  01d92c23  sw x29, 24(x18)
  014c  01caae83  lw x29, 28(x21)
  0150  01d92e23  sw x29, 28(x18)
  0154  02048493  addi x9, x9, 32
  0158  02090913  addi x18, x18, 32
  015c  00170713  addi x14, x14, 1
  0160  f5771ce3  bne x14, x23, -168
  0164  00092023  sw x0, 0(x18)
  0168  00092223  sw x0, 4(x18)
  016c  00092423  sw x0, 8(x18)
  0170  00092623  sw x0, 12(x18)
  0174  00092823  sw x0, 16(x18)
  0178  00092a23  sw x0, 20(x18)
  017c  00092c23  sw x0, 24(x18)
  0180  00092e23  sw x0, 28(x18)
  0184  00003337  lui x6, 3
  0188  00640533  add x10, x8, x6
  018c  44000593  addi x11, x0, 1088
  0190  00b585b3  add x11, x11, x11
  0194  02090613  addi x12, x18, 32
  0198  00000073  ecall
  019c  06090513  addi x10, x18, 96
  01a0  08090893  addi x17, x18, 128
  01a4  04000593  addi x11, x0, 64
  01a8  00004337  lui x6, 4
  01ac  00640a33  add x20, x8, x6
  01b0  0209c683  lbu x13, 32(x19)
  01b4  00400813  addi x16, x0, 4
  01b8  0016f313  andi x6, x13, 1
  01bc  40600333  sub x6, x0, x6
  01c0  014643b3  xor x7, x12, x20
  01c4  0063f3b3  and x7, x7, x6
  01c8  00764733  xor x14, x12, x7
  01cc  007a47b3  xor x15, x20, x7
  01d0  00072e83  lw x29, 0(x14)
  01d4  01d52023  sw x29, 0(x10)
  01d8  00472e83  lw x29, 4(x14)
  01dc  01d52223  sw x29, 4(x10)
  01e0  00872e83  lw x29, 8(x14)
  01e4  01d52423  sw x29, 8(x10)
  01e8  00c72e83  lw x29, 12(x14)
  01ec  01d52623  sw x29, 12(x10)
  01f0  01072e83  lw x29, 16(x14)
  01f4  01d52823  sw x29, 16(x10)
  01f8  01472e83  lw x29, 20(x14)
  01fc  01d52a23  sw x29, 20(x10)
  0200  01872e83  lw x29, 24(x14)
  0204  01d52c23  sw x29, 24(x10)
  0208  01c72e83  lw x29, 28(x14)
  020c  01d52e23  sw x29, 28(x10)
  0210  0007ae83  lw x29, 0(x15)
  0214  01d8a023  sw x29, 0(x17)
  0218  0047ae83  lw x29, 4(x15)
  021c  01d8a223  sw x29, 4(x17)
  0220  0087ae83  lw x29, 8(x15)
  0224  01d8a423  sw x29, 8(x17)
  0228  00c7ae83  lw x29, 12(x15)
  022c  01d8a623  sw x29, 12(x17)
  0230  0107ae83  lw x29, 16(x15)
  0234  01d8a823  sw x29, 16(x17)
  0238  0147ae83  lw x29, 20(x15)
  023c  01d8aa23  sw x29, 20(x17)
  0240  0187ae83  lw x29, 24(x15)
  0244  01d8ac23  sw x29, 24(x17)
  0248  01c7ae83  lw x29, 28(x15)
  024c  01d8ae23  sw x29, 28(x17)
  0250  00000073  ecall
  0254  020a0a13  addi x20, x20, 32
  0258  0016d693  srli x13, x13, 1
  025c  fff80813  addi x16, x16, -1
  0260  f4081ce3  bne x16, x0, -168
  0264  00062383  lw x7, 0(x12)
  0268  000a2e03  lw x28, 0(x20)
  026c  01c3c3b3  xor x7, x7, x28
  0270  007b6b33  or x22, x22, x7
  0274  00462383  lw x7, 4(x12)
  0278  004a2e03  lw x28, 4(x20)
  027c  01c3c3b3  xor x7, x7, x28
  0280  007b6b33  or x22, x22, x7
  0284  00862383  lw x7, 8(x12)
  0288  008a2e03  lw x28, 8(x20)
  028c  01c3c3b3  xor x7, x7, x28
  0290  007b6b33  or x22, x22, x7
  0294  00c62383  lw x7, 12(x12)
  0298  00ca2e03  lw x28, 12(x20)
  029c  01c3c3b3  xor x7, x7, x28
  02a0  007b6b33  or x22, x22, x7
  02a4  01062383  lw x7, 16(x12)
  02a8  010a2e03  lw x28, 16(x20)
  02ac  01c3c3b3  xor x7, x7, x28
  02b0  007b6b33  or x22, x22, x7
  02b4  01462383  lw x7, 20(x12)
  02b8  014a2e03  lw x28, 20(x20)
  02bc  01c3c3b3  xor x7, x7, x28
  02c0  007b6b33  or x22, x22, x7
  02c4  01862383  lw x7, 24(x12)
  02c8  018a2e03  lw x28, 24(x20)
  02cc  01c3c3b3  xor x7, x7, x28
  02d0  007b6b33  or x22, x22, x7
  02d4  01c62383  lw x7, 28(x12)
  02d8  01ca2e03  lw x28, 28(x20)
  02dc  01c3c3b3  xor x7, x7, x28
  02e0  007b6b33  or x22, x22, x7
  02e4  01603533  sltu x10, x0, x22
  02e8  00100293  addi x5, x0, 1
  02ec  00000073  ecall
    sha256 67e649577b6c1e0147c25cc4173336851576fe77cfaddef72c334ad2790cd519  (752 bytes)
    byte for byte the committed kernel.bin

>>> the theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Exp206.bytes_words' depends on axioms: [propext]
'Exp206.code_of_image' depends on axioms: [propext, Quot.sound]
'Exp206.chain_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.chain_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.to_tree' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.level_iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.level_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.root_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.verifies' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.exactly' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp206.wots_complete' depends on axioms: [propext, Quot.sound]
'Exp206.path_climbs' depends on axioms: [propext, Quot.sound]
'Exp206.accepts_signed' depends on axioms: [propext, Quot.sound]
'Exp206.signed_halts_with_zero' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
kernel    the signature's value is stored as the chain's end, not the walked value               refused in at_store
kernel    the ends are written 64 bytes apart                                                    refused in chain_iter
kernel    the padding is seven words, so four bytes of the leaf's input are whatever was there   refused in kernel_length
kernel    the leaf hashes 1088 bytes, not 2176                                                   refused in to_tree
kernel    the index is read one byte late                                                        refused in to_tree
kernel    the mask is the bit itself, not its negation                                           refused in level_iter
kernel    the right half is copied from the same side as the left                                refused in at_right
kernel    the index is shifted two bits per level                                                refused in level_iter
kernel    the tree is climbed three levels, not four                                             refused in to_tree
count     the count is claimed not to depend on the message                                      refused in verifies
count     it is claimed still to be running one instruction later                                refused in verifies
verdict   the root is claimed to be three levels up                                              refused in root_iff
verdict   the node is claimed to go on the left when the index bit is 1                          refused in level_iter
scratch   it is claimed to write only exp205's 131 bytes of scratch                              refused in verifies
complete  completeness is claimed for a seventeenth leaf                                         refused in accepts_signed
complete  the path's sibling is claimed always to be the next node                               refused in path_climbs

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

>>> the kernel on the model and on the RTL, against Python
case                     python S  model at 0x80010000        RTL                                model at 0x20070000
leaf-00                  0 480     halt code=00000000 count=4735 halt code=00000000 instret=6678 cycles=8179 halt code=00000000 count=4735
leaf-01                  0 480     halt code=00000000 count=4735 halt code=00000000 instret=6678 cycles=8179 halt code=00000000 count=4735
leaf-02                  0 555     halt code=00000000 count=4960 halt code=00000000 instret=7203 cycles=8928 halt code=00000000 count=4960
leaf-03                  0 495     halt code=00000000 count=4780 halt code=00000000 instret=6783 cycles=8332 halt code=00000000 count=4780
leaf-04                  0 600     halt code=00000000 count=5095 halt code=00000000 instret=7518 cycles=9377 halt code=00000000 count=5095
leaf-05                  0 450     halt code=00000000 count=4645 halt code=00000000 instret=6468 cycles=7880 halt code=00000000 count=4645
leaf-06                  0 480     halt code=00000000 count=4735 halt code=00000000 instret=6678 cycles=8178 halt code=00000000 count=4735
leaf-07                  0 510     halt code=00000000 count=4825 halt code=00000000 instret=6888 cycles=8480 halt code=00000000 count=4825
leaf-08                  0 525     halt code=00000000 count=4870 halt code=00000000 instret=6993 cycles=8629 halt code=00000000 count=4870
leaf-09                  0 525     halt code=00000000 count=4870 halt code=00000000 instret=6993 cycles=8628 halt code=00000000 count=4870
leaf-10                  0 510     halt code=00000000 count=4825 halt code=00000000 instret=6888 cycles=8477 halt code=00000000 count=4825
leaf-11                  0 420     halt code=00000000 count=4555 halt code=00000000 instret=6258 cycles=7578 halt code=00000000 count=4555
leaf-12                  0 555     halt code=00000000 count=4960 halt code=00000000 instret=7203 cycles=8929 halt code=00000000 count=4960
leaf-13                  0 525     halt code=00000000 count=4870 halt code=00000000 instret=6993 cycles=8631 halt code=00000000 count=4870
leaf-14                  0 600     halt code=00000000 count=5095 halt code=00000000 instret=7518 cycles=9377 halt code=00000000 count=5095
leaf-15                  0 495     halt code=00000000 count=4780 halt code=00000000 instret=6783 cycles=8331 halt code=00000000 count=4780
auth-0-wrong             1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
auth-1-wrong             1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
auth-2-wrong             1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
auth-3-wrong             1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
index-bit-0-flipped      1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
index-bit-3-flipped      1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
index-plus-16            0 450     halt code=00000000 count=4645 halt code=00000000 instret=6468 cycles=7880 halt code=00000000 count=4645
other-root               1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
message-changed          1 480     halt code=00000001 count=4735 halt code=00000001 instret=6678 cycles=8178 halt code=00000001 count=4735
first-chain-wrong        1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
checksum-chain-wrong     1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
other-leafs-signature    1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645
zero-signature           1 450     halt code=00000001 count=4645 halt code=00000001 instret=6468 cycles=7880 halt code=00000001 count=4645

PASS  the model gives Python's verdict after exactly 3295 + 3 S instructions, the count proved, on all 29 cases
PASS  the RTL gives the same verdict and counts 3295 + 3 S proved + 3 for the harness + 4 (S + 5) for HASH, on all 29
PASS  the whole region is byte for byte the same on both, on all 29
PASS  Python agrees: only the two scratch areas changed, and the digits and the chain ends there are right, on all 29
PASS  at 0x20070000 the same bytes give the same verdict after the same count, on all 29
```
