# exp208 — the hash the kernel computes

<!-- SPDX-License-Identifier: Apache-2.0 -->

**SHA-256 as a kernel, proved: 1008 bytes of RV32IM that hash a message of
whole 64-byte blocks — every block of it, then the padding block the kernel
builds itself — and halt with 0 after exactly `4990 + 4873·n` instructions
for `n` blocks, the 32 bytes they leave being `sha256` of the message. For
every base address and every message that fits in the region. The
specification it is proved against is written for proving, and is held to
`hashlib` by running it; the model and the Hazard3 RTL leave hashlib's digest
on ten messages, the model in the theorem's count and the RTL 3 more.**

This is the optional stage the [verified-kernel road](../README.md#the-verified-kernel-road)
left for last. Every kernel from exp204 to exp213 calls `HASH` through an
`ecall` and every theorem about them holds for any function `HASH` might be.
That is their strength and their gap: a theorem for every function says
nothing about SHA-256 in particular. Here is the other half — a kernel that
computes SHA-256 itself, and a theorem that says it does.

## The specification

[`lean/Rv32/Sha.lean`](../../lean/Rv32/Sha.lean), its first section, is
FIPS 180-4 written for proving rather than for running: words are
`BitVec 32`, rotation is the core library's `rotateRight`, and each sum is in
the order FIPS 180-4 writes it, so a line of register instructions reduces by
`simp` to the specification's expression. `round`, `rounds`, `expand` (the
message schedule), `compress`, `pad`, `blocks` and `sha256` are each a few
lines.

It is not [`lean/Sha256.lean`](../../lean/Sha256.lean). That one is for
`rv32run`, which needs to be fast; no theorem mentions it. This one is part
of what the theorem trusts, and **no theorem can say that a specification is
the standard**. So `compare.py` runs it — `lean.sh exec proof/Sha.lean digest`
— on every message it gives the kernel, and holds it to `hashlib`.

The same goes for the constants. The theorem takes K and IV from memory, as
the specification's lists: a wrong constant would move the specification and
the hypothesis together, and Lean could not object. hashlib does.

## The kernel

`sha.bin`, 252 instructions. The layout, from `R = base + 0x1000`:

| | |
| --- | --- |
| `R + 0x000` | K, 64 words, as data |
| `R + 0x100` | IV, 8 words, as data |
| `R + 0x120` | the message's length in bytes, a multiple of 64 |
| `R + 0x140` | the digest, 32 bytes, written |
| `R + 0x200` | H, 8 words |
| `R + 0x300` | W, the schedule, 64 words |
| `R + 0x400` | the padding block, 64 bytes, built |
| `base + 0x2000` | the message |

```text
  0000–00c0  R; the message; H from IV; the padding block zeroed, 0x80,
             the length in bits; s6 = blocks, s5 = 0                     (49)
  00c4–00c8  the message's next block, or the padding at the last        (2)
  00cc–010c  W[0..15]: the block's bytes, big-endian                     (2 + 15 · 16)
  0110–0184  W[16..63]: σ₁, σ₀ and the four words FIPS 180-4 names       (1 + 29 · 48)
  0188–01a4  a … h from H                                                (8)
  01a8–0278  64 rounds: Σ₁, Ch, K[t], W[t], Σ₀, Maj                      (3 + 50 · 64)
  027c–02d8  H += a … h                                                  (24)
  02dc–02e0  on to the next block while there is one                     (2)
  02e4–03ec  the digest, big-endian, at R + 0x140; HALT with 0           (64 + 3)
```

It hashes messages whose length is a multiple of 64 bytes, as `HASH` is only
ever asked to — the `ecall` refuses any other length — so the padding is
always one whole block, and the kernel builds it once, before the first
block, rather than finding where the message ends.

Its SHA-256 is in `sha.sha256`.

## What is proved

| Theorem | Says |
| --- | --- |
| `round_step` | fifty instructions from the top of the round loop take a … h in `a0`–`a7` to `round` of them with K[t] and W[t] as memory holds them, step the three counters, and go back — or on, after the 64th |
| `rounds_loop` | by induction on rounds done: `50 j` instructions do `j` rounds |
| `load_loop` | `15 j` instructions write the block's first `j` words, big-endian, at W |
| `expand_loop` | `29 n` instructions write schedule words 16 to `16 + n`, each from the four FIPS 180-4 names |
| `block_step` | from the top of the load, 4870 instructions later H is `compress H` of the 64 bytes at the block pointer, the pointer has moved on 64, and nothing outside H and W changed |
| `setup_run` | 49 instructions: `s1` at R, H from IV, the padding block built — `0x80`, 59 zeros, the length in bits big-endian — and the block count in `s6` |
| `block_loop` | by induction on blocks: `4873 i` instructions compress the message's first `i` blocks, each block's bytes the specification's |
| `output_run` | 64 instructions write word `j` of H big-endian at `R + 0x140 + 4j` |
| `sha256_whole` | for a message of whole blocks, `sha256` is its blocks, then the padding block, compressed from IV |
| `computes` | **the kernel**: from `base`, it halts with 0 after exactly `4990 + 4873·n` instructions, the 32 bytes at `R + 0x140` are `sha256` of the message, and nothing outside `R + 0x140` to `R + 0x440` changed |

The rounds are the bulk of it, and they are proved as three straight lines of
register instructions and two loads: `lean/Rv32/Line.lean` folds a line of
`op`, `opi` and `sh` over the machine once, in `run_line`, instead of one
step lemma each, and the registers afterwards are `simp` over the fold.

The hypotheses of `computes` are the kernel's bytes at `base`, K and IV as
words at `R` and `R + 0x100`, the length `64 n` at `R + 0x120`, and
`0x2000 + 64 n ≤ 0x10000`. Nothing else: not the registers, not the rest of
memory.

Seventeen wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are
each refused:
- **thirteen wrong kernels:** Σ₁ rotating by 26, Ch taking ¬f, Maj's last term
  `a ∧ c`, 63 rounds, σ₀ shifting by 4, W[t−15] for W[t−16], each word's first
  byte taken from the second, H starting one word into IV, padding starting
  with `0x01`, the length in bytes rather than bits, H gaining the wrong
  working variable, the loop leaving before the padding block, and the
  digest's bytes swapped;
- **two wrong claims:** one instruction fewer per block, and a frame that
  leaves out the padding block;
- **two wrong specifications:** Σ₁ rotating by 26, and the length padded in
  bytes.

All of it rests on `propext`, `Classical.choice` and `Quot.sound`.

## The count

| | `n` blocks |
| --- | --- |
| setup | 49 |
| a block of the message | `1 + 4870 + 2` = 4873 |
| the padding block | `2 + 4870 + 2` = 4874 |
| the digest and HALT | `64 + 3` = 67 |
| **the proof** | **`4990 + 4873 n`** |
| the model, run | the same, on all ten messages |
| the Hazard3 RTL, `minstret` | `4990 + 4873 n + 3`, on all ten |

A block is `2 + 15 · 16 + 1 + 29 · 48 + 8 + 3 + 50 · 64 + 24` = 4870. No
`ecall` HASH is made, so the RTL's `4 · S` of exp204–exp213 is 0 here; the 3
is the harness's, as since exp203. `compare.py` reads 4990 and 4873 out of
the theorem's statement in `lean/Rv32/Sha.lean`, so the count it checks is
the one proved, not a copy.

## What it does not prove

- **That the other kernels hash with it.** exp204 to exp213 still call
  `HASH` through an `ecall`, proved for every function. Putting this kernel
  behind that `ecall` — or calling it as a subroutine — and carrying `computes`
  into their theorems is a further step. What is here is the half that had to
  come first: one function HASH might be, proved to be SHA-256.
- **That the specification is FIPS 180-4.** It is held to hashlib by running
  it on ten messages, not proved; and so are K and IV.
- **Messages that are not whole blocks.** The kernel is for `HASH`'s inputs,
  which always are.
- **Time.** The count is a function of the length alone, and the kernel never
  branches on a message byte; a statement about the trace, as exp207 makes for
  exp213's kernels, is not made here.
- **The chip.** Nothing here has run on a board.

## Running it

```sh
./check.sh       # the proof, the mutants, sha.bin, the model, the RTL and the specification against hashlib
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and the Hazard3 testbench
(`tools/hazard3/setup.sh`), and python3. No board.

## Expected output

CAPTURE
