# exp201 — one word, one reading

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The first experiment of the [verified-kernel road](../README.md#the-verified-kernel-road):
a Lean encoder and decoder for the forty-six RV32IM instruction forms a kernel
may use, two theorems that say they agree in both directions, and LLVM — an
assembler nobody here wrote — agreeing with all 3,450 instructions and 5,572
words it was shown. Two wrong versions of the encoding pass both theorems and
fail against LLVM, which is the reason the comparison is here at all.**

The road this starts proves things about the *bytes* a RISC-V core executes, not
about a program that a compiler later turns into bytes. Every later proof says
"this word is this instruction", and this experiment is where that sentence is
earned. The library lives in [`lean/Rv32/`](../../lean/Rv32/), because every
experiment after this one stands on it; what exp201 claims about it, and the one
thing it shows on top, is in [`proof/Roundtrip.lean`](./proof/Roundtrip.lean).

## The two sentences

| Theorem | Says |
| --- | --- |
| `decode_encode` | every instruction survives a round trip: `decode (encode i) = some i` |
| `encode_decode` | the decoder accepts no word that is not exactly the encoding of what it returns: `decode w = some i → encode i = w` |

From those, in the experiment's own file: `encode_injective` (two instructions
never share a word) and **`one_reading`** — two words that decode to the same
instruction are the same word.

The first theorem is the one anybody writes down, and it is not enough.
`a_round_trip_allows_a_second_reading` is a decoder that passes it for every
instruction and also reads `0x40001013` — an `slli` with the reserved bit 30 set
— as `slli x0, x0, 0`. That decoder has two words for one instruction. A
theorem about the instruction would then be about two binaries, and only one of
them is the one whose hash the shell checks before running it
([design §5](../../docs/2026-10-02-0800-verified-kernel-road-briefing-zh-tw.md)).
`encode_decode` is what rules it out.

## What only somebody else's reading can check

Both theorems compare this file with itself. Neither can say that the encoding
is the one in the RISC-V specification, because the specification is prose. So
the experiment hands the same instructions to LLVM, in both directions:

| | Shown | Result |
| --- | --- | --- |
| `llvm-mc` assembles the text Lean prints | 3,450 instructions: every edge register in every position, every edge immediate in every field, and a fixed pseudo-random sample | the same word, every one |
| `llvm-objdump` disassembles words Lean decodes | 6,000 words drawn over the ten opcodes the model knows, three it refuses on purpose, and anything at all | 2,453 the same instruction; 2,784 refused by both; 335 real instructions this model refuses on purpose; 428 of another length, refused |

And then the point of it. [`differential/mutants.txt`](./differential/mutants.txt)
holds two wrong versions of `Isa.lean` whose mistake is **the same in the encoder
and the decoder** — `sub` given funct7 `0x30`, `lw` and `lh` trading funct3. The
library still builds, both theorems still hold, and LLVM refuses each at once:

```text
FAIL  every encoding is LLVM's — 75 of 3450 differ; first: `sub x0, x31, x7` Lean 607f8033, LLVM 407f8033
```

That is the shape of this whole road: a proof is exactly as good as the model it
is about, and a model can only be held against something outside it. Here that
is LLVM; for the semantics it is the `riscv-tests` suite and the Hazard3 RTL
(exp202); for the kernel, the chip.

## The subset, and what it leaves out

Forty-six forms: RV32I's computational, control-transfer, load and store
instructions, the eight of M, and `ecall`. Everything else Hazard3 implements —
C, A, Zb*, Zbk*, CSR access, `fence`, `ebreak`, `mret` — has no constructor, so
`decode` answers `none` and the machine model faults. The 335 "refused on
purpose" above are LLVM naming exactly those: `fence`, `csrrw`, `ebreak` and the
rest.

`fence` is RV32I and is left out anyway: on one hart with nothing cached between
the kernel and its SRAM it is a no-op, and a no-op the kernel never needs is one
more line of model to get wrong.

## What the proof cost

The design document asked for Lean 4 and Mathlib. Mathlib was not needed: every
field is a `BitVec` of the width the specification gives it, the encoding is
arithmetic on `Nat`, and core Lean's `omega` knows every bound. What *was*
needed is worth knowing before the next proof, because it will need it too:

- **`omega` is not complete.** It does not implement the "dark shadow" step, so a
  goal with several divisions of one number can defeat it although it is true.
  The B-type immediate, scattered over four places in the word, was the first
  goal it could not do. The fix is `field`: state the word as
  `(q * m + f) * p + r`, which turns one hard goal into three linear ones.
- **`omega` hits Lean's recursion limit** on a sum multiplied by a large power
  of two — `(c * 32 + x) * 2^20` — and the error cannot be caught by `first`.
  Distributing the product first (`simp only [Nat.add_mul, Nat.mul_assoc]`)
  makes it go away.
- **`simp` must not unfold a name inside an `if`'s decision.** Writing the
  opcodes as `OP_LUI` and unfolding them left the decision procedure typed
  against the old term, and every later `split` failed silently. The decoder
  writes its opcodes as numbers.
- **One theorem per format.** The round trip as one proof ran out of Lean's
  per-declaration budget; eleven lemmas, one per constructor, each fit.

The library takes about forty seconds to check. That is the cost of every mutant
below, since each is a rebuilt copy of it.

## The mutants

[`proof/mutants.txt`](./proof/mutants.txt) holds four wrong versions of
`lean/Rv32/Isa.lean`, one per kind of mistake an encoder makes. Each must be
refused, and the table says by which step:

| Mutant | Refused in |
| --- | --- |
| `bge` given `blt`'s funct3 — two branches share a code | `BrOp.ofF3_f3` |
| `jal`'s immediate put back with bit 11 read from bit 9 | `dec_jal` |
| `slli` read whatever funct7 holds, the reserved bit 30 included | `ShOp.f_ofF` |
| every SYSTEM opcode read as `ecall`, so `csrrw` is an `ecall` | `encodeNat_decodeNat` |

The first two break `decode_encode`, the last two `encode_decode`: each theorem
refuses something the other accepts.

## What it does not prove

- **That the semantics are right.** This is the instruction *encoding* only. What
  an `add` does is [exp202](../exp202-the-tests-the-chip-passes/)'s question.
- **The specification itself.** LLVM is one reading of it, not the text. Two
  assemblers sharing a mistake would both pass; the RTL in exp202 is a second,
  independent reading of the same encodings.
- **Every word.** 6,000 of 2³² words were shown to LLVM. The theorems cover all
  2³²; the sample only covers what the theorems cannot see.

## Try it

In `lean/Rv32/Isa.lean`, change `ROp.ofF`'s `| 1, 7 => some .remu` to
`| 1, 7 => some .rem`, and run `../../tools/lean/lean.sh check proof/Roundtrip.lean`.
Which theorem stops checking, and why does `decode_encode` notice before
`encode_decode` gets the chance? Put it back before running anything else.

## Running it

```sh
../../tools/lean/setup.sh   # once, needs the network: Lean 4.34.0 by sha256, 580 MB
./check.sh                  # no board: the theorems, their axioms, six mutants, the LLVM differential
./run.sh                    # records capture.txt
```

No board and nobody. `llvm-mc` and `llvm-objdump` with the RISC-V target, and
`python3`. Each library mutant rebuilds `Isa.lean` in a copy, so `check.sh`
takes four or five minutes.

## Expected output

```text
=== exp201 — one word, one reading ===
recorded at 2026-10-02T08:10:09Z from commit 1f06707

>>> the two theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Exp201.round_trip' depends on axioms: [propext, Quot.sound]
'Exp201.no_alias' depends on axioms: [propext, Quot.sound]
'Exp201.encode_injective' depends on axioms: [propext, Quot.sound]
'Exp201.one_reading' depends on axioms: [propext, Quot.sound]
'Exp201.sloppy_round_trips' depends on axioms: [propext, Quot.sound]
'Exp201.a_round_trip_allows_a_second_reading' does not depend on any axioms
exit 0

>>> wrong versions of the library: each must be refused
decode_encode  bge is given blt's funct3, so two branches share a code            refused in BrOp.ofF3_f3
decode_encode  jal's immediate is put back with bit 11 read from bit 9            refused in dec_jal
encode_decode  slli is read whatever funct7 holds, the reserved bit 30 included   refused in ShOp.f_ofF
encode_decode  every SYSTEM opcode reads as ecall, so csrrw is an ecall           refused in encodeNat_decodeNat

>>> LLVM's reading against Lean's
    Ubuntu LLVM version 18.1.3
PASS  every encoding is LLVM's: 3450 instructions, all 46 forms
PASS  no word of another length is read as a 32-bit instruction: 428 refused
PASS  every word is read as LLVM reads it: 5572 words — 2453 the same instruction, 2784 refused by both, 335 real instructions this model refuses on purpose

>>> wrong versions Lean cannot see: each must be accepted by Lean and refused by LLVM
PASS  differential: a version where sub is given funct7 0x30 instead of 0x20, in both tables passes both theorems and fails against LLVM
      LLVM: every encoding is LLVM's — 75 of 3450 differ; first: `sub x0, x31, x7` Lean 607f8033, LLVM 407f8033
      LLVM: every word is read as LLVM reads it — 2 of 5572 differ; first: 61ef0cb3: Lean reads `sub x25, x30, x30`, LLVM `<unknown>`
PASS  differential: a version where lw and lh trade funct3, in both tables passes both theorems and fails against LLVM
      LLVM: every encoding is LLVM's — 150 of 3450 differ; first: `lh x0, 0(x31)` Lean 000fa003, LLVM 000f9003
      LLVM: every word is read as LLVM reads it — 122 of 5572 differ; first: 89cd1f83: Lean reads `lw x31, -1892(x26)`, LLVM `lh x31, -0x764(x26)`
```

There is no board half: nothing in this claim is on silicon.
