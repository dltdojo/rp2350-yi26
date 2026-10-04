# exp205 — the chain the checksum closes

<!-- SPDX-License-Identifier: Apache-2.0 -->

**432 bytes of RV32IM, proved in Lean to verify a Winternitz one-time
signature (WOTS, w = 16): 67 hash chains, 64 for the message's digits and 3
for their checksum's. It halts with 0 when every chain reaches the public key
and with 1 when any does not, for every base, every message, signature and
key, and every HASH. Unlike exp204's kernel, its instruction count depends on
the message, so the theorem states it as a formula: exactly 4142 + 3·S
instructions, where S = Σ(15 − dᵢ) is the number of HASH calls. The model, the
Hazard3 RTL and an independent Python check agree on eleven cases, from 45
HASH calls to 990. Eight wrong kernels and six wrong claims are each refused,
among them a kernel that never checks the last checksum chain and a claim
that the checksum chains need not be checked at all.**

This is the third kernel on the verified-kernel road (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md)),
after [exp204](../exp204-the-signature-the-kernel-checks/)'s Lamport. The
road's table asked two things of it: a loop invariant over a hash chain, and
the checksum.

## The scheme

| | |
| --- | --- |
| `F(x)` | the `HASH` call: SHA-256 of `x ‖ 32 zero bytes`, one step along a chain — exp204's padding |
| `F^k(x)` | `k` steps |
| digits | the 32-byte message as 64 base-16 digits, low nibble of each byte first; then `c = Σ(15 − aᵢ)` over those 64, at most 960, as 3 more digits, low first |
| keygen | `sk[i]` 32 random bytes for `i < 67`; `pk[i] = F^15(sk[i])` |
| sign `m` | `sig[i] = F^dᵢ(sk[i])` |
| verify | `F^(15 − dᵢ)(sig[i]) = pk[i]` for every `i` |

This is WOTS without WOTS+'s bitmasks and tweaks, the plainest Winternitz
there is. The checksum is the whole point. Anybody can walk a chain forward,
and raising a message digit by one and hashing its chain once more yields a
valid-looking chain for a different message. What stops that is the
checksum: raising a message digit lowers the checksum, and walking a checksum
chain backward means inverting `F`. The case `chain-walked-forward` is that
forgery, and every executor rejects it.

The image layout: the kernel at 0, the message at `0x1000`, the signature at
`0x2000` (67 × 32 bytes), the public key at `0x3000` (67 × 32), and 131 bytes
of scratch at `0x8000`: the 64-byte HASH buffer, then the 67 digits.

## The kernel

108 instructions in five parts:

- **setup** (18): pointers from `auipc`, and the buffer's zero half.
- **the digit pass** (4 + 32 × 11): writes the 64 message digits into scratch
  and sums the checksum as it goes.
- **the checksum's three digits** (7).
- **the chains' start** (6).
- **67 chains**, each one: copy the signature's value into the buffer, load
  the digit, walk `15 − d` steps, compare with the key, and advance.

The walk is the new part:

```text
  00f8  00074e03  lbu x28, 0(x14)       t3 = d, from the digits in scratch
  00fc  00f00393  addi x7, x0, 15
  0100  41c38e33  sub x28, x7, x28      t3 = 15 - d
  0104  000e0863  beq x28, x0, 16       d = 15: nothing to hash
  0108  00000073  ecall               ┐ HASH, in place: the buffer becomes F(buffer)
  010c  fffe0e13  addi x28, x28, -1   │
  0110  fe0e1ce3  bne x28, x0, -8     ┘
  0114  000aa383  lw x7, 0(x21)       ┐ the compare: eight words, no early exit,
  …                                   ┘ as exp204's
```

HASH is called with its output on top of its input. The model reads all 64
bytes before it writes 32, and so does the harness's C, which compresses the
whole input before it writes the digest. The arguments `a0`, `a1`, `a2` and
`t0 = 0` are set once, before the first chain, and never touched again.

## What is proved

[`proof/Wots.lean`](./proof/Wots.lean), against the model exp202 tested. `H` is
`env.hash`, and **nothing is assumed about it**.

| Theorem | Says |
| --- | --- |
| `verifies` | it halts after `4142 + 3 · steps` instructions with `if Verifies H m base then 0 else 1`, and every byte outside the 131 of scratch is what it was |
| `exactly` | after one fewer it is still running: the count is exact, not a bound |
| `steps_le` | `steps ≤ 1005`, so the count is at most 7157 whatever the input |
| `code_of_image`, `from_boot` | all of it from the state `rv32run` and the RTL harness build, for any image that begins with the 432 bytes |

`Verifies` is stated in Lean's own terms, independent of the kernel:
`chain H (sigAt i) (15 − digit i) = pkAt i` for every `i < 67`, where `digit`
reads the message's nibbles and, for `i ≥ 64`, the checksum's
`csumTo 64 / 16^(i−64) % 16`. `steps` is `Σ (15 − digit i)`, the same
definition the count is stated with.

The blocks, each a lemma:

| Block | Lemma | What it carries |
| --- | --- | --- |
| setup | `front` | the invariant `DInv` for the digit pass, at 0 |
| one byte of the message | `digit_iter` | `DInv k → DInv (k+1)`: two digits into scratch, `a3` the checksum of the first `2k + 2` |
| 32 bytes | `digits_loop` | induction |
| checksum digits, chain start | `middle` | `CInv 0`: all 67 digits in scratch, the zero half intact, HASH's arguments set |
| the walk | `walk_chain` | **the hash chain's loop invariant**, `WInv`: after `j` rounds the buffer holds `chain H x j`; `n` rounds are `3n` instructions |
| one chain | `chain_iter` | `CInv i → CInv (i+1)` in `56 + 3 (15 − dᵢ)` instructions; `good_iff` says the compare decided `Good i` |
| 67 chains | `chain_loop` | induction, with the count a sum that depends on the digits |
| the verdict | `halt` | `sltu`, HALT |

The proof rests on `propext`, `Classical.choice` and `Quot.sound`, and uses no
`native_decide`.

### What it changed in `lean/`

exp205 is the second caller of most of what exp204 wrote for itself. So that
moved, and exp204's proof now uses the library's copy, 300 lines shorter and
with the same theorems:

- **`Rv32/Kernel.lean`**: one instruction of any program at a time
  (`stepK`, `regStep`, `loadStep`, `lbuStep`, `storeStep`, and the new
  `sbStep`), `overlay`, and the word lemmas. The program-fits bound is an
  auto-parameter that `decide` discharges.
- **`Rv32/Blocks.lean`**: eight words zeroed, copied and compared, with the
  registers and offsets as parameters, plus `Keeps`: memory changed only
  inside one place.

Two things there are worth knowing before the next proof:

- **`decide` on the sign-extension of a negative immediate runs Lean out of
  memory**, and so does `omega` on a goal holding `2^32 − 1` as a literal.
  Both came up proving that `addi t3, t3, -1` subtracts one. `se_neg` and
  `dec_one` do it by hand.
- **A declaration with errors in it is not checked by Lean's kernel; one
  closed with `sorry` is.** So bisecting an out-of-memory crash by cutting a
  proof short gives contradictory answers until you notice that. It is the
  kernel that runs out.

`tools/hazard3/hash-cost.sh` is exp204's sweep of what one HASH costs on the
RTL, moved because exp205 reads the same number.

## The count

| | count |
| --- | --- |
| the proof | `4142 + 3 · S`, for every input |
| the model, run | the same, on all eleven cases, at `0x80010000` and at `0x20070000` |
| the Hazard3 RTL, `minstret` | `4142 + 3 · S + 3 + 4 · S`, on all eleven: the proof's count, exp203's harness constant, and exp204's measured 4 per HASH |

| case | S | proved | RTL |
| --- | --- | --- | --- |
| `valid-ones-message` | 45 | 4277 | 4460 |
| `valid` and seven broken ones | 480 | 5582 | 7505 |
| `valid-other-key`, `other-message-signature` | 600 | 5942 | 8345 |
| `valid-zero-message` | 990 | 7112 | 11075 |

S lies between 45 and 990 for every message. That follows from the checksum's
arithmetic and is not a theorem here; `steps_le` proves the looser 1005. The
all-ones message needs only the 45 steps of its three checksum chains, all of
whose digits are 0. The all-zero message needs 960 for the message and 30 for
a checksum of `0x3c0`.

This is the first kernel on the road whose running time depends on what it
is given. For verification that is harmless, since the message and signature
are public. **For signing it is not**: a signer walks `dᵢ` steps from secret
keys, so its count reveals the digits, which are the message's, and the
question of what else it reveals belongs to exp207's constant-time proof. The
RTL's `mcycle` here also moves with S (from 5232 to 14617 cycles), an
observation and not a theorem.

## What it does not prove

- **That HASH is SHA-256, or that WOTS is secure.** The theorem holds for
  every function; that a forger cannot satisfy `Verifies` is the scheme's
  claim, and rests on `F`.
- **WOTS+.** No bitmasks, no tweaks, no addresses. A multi-use scheme built
  on this (exp206) will need to decide whether it wants them.
- **That the model is the chip**, as in exp203 and exp204.
- **The shell**, as in exp203 and exp204: the theorems start from the state it
  is supposed to build.

## Running it

```sh
../../tools/lean/setup.sh      # once, needs the network: Lean 4.34.0, 580 MB
../../tools/hazard3/setup.sh   # once, needs the network: the Hazard3 RTL, built with Verilator
./check.sh                     # no board: the proof, fourteen mutants, kernel.bin, the RTL
./run.sh                       # records capture.txt
```

No board and nobody. `clang`, `lld` and `llvm-objcopy` for the HASH-cost
sweep, `python3` for the images. The proof checks in about 35 seconds; each
mutant checks it again, so `check.sh` takes about ten minutes.

## Expected output

CAPTURE

There is no board half here: the RTL is the chip's core, simulated on this
machine. exp210 runs this kernel on silicon with the SHA-256 block as HASH.
