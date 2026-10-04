# exp204 — the signature the kernel checks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**352 bytes of RV32IM, proved in Lean to check a Lamport one-time signature:
it halts with 0 when all 256 preimages hash to the halves of the public key
the message's bits select, with 1 when any one does not. It always stops at
exactly instruction 16663, whatever the verdict, and writes nothing outside
its 96 bytes of scratch. That holds for every base, every message, signature
and key, and every HASH. The model, the Hazard3 RTL and an independent Python
check agree on ten cases. On the RTL, one HASH call costs 4 `minstret` that
the model does not count. The count also depends on the word in memory
behind the last `ecall`, a word that never runs.**

This is the second kernel on the verified-kernel road (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md)),
after [exp203](../exp203-the-count-the-proof-promised/)'s copy, and the first
one that calls `ecall` for HASH partway through its run.

## The scheme

| | |
| --- | --- |
| `H(x)` | the `HASH` call: SHA-256 of `x`, always 64 bytes |
| keygen | `sk[i][b]`, 32 random bytes for `i < 256`, `b ∈ {0, 1}`; `pk[i][b] = H(sk[i][b] ‖ 32 zero bytes)` |
| sign `m` | `sig[i] = sk[i][bit i of m]`, for a 32-byte `m` |
| verify | `H(sig[i] ‖ 32 zero bytes) = pk[i][bit i of m]` for every `i` |
| bit `i` of `m` | `(m[i / 8] >> (i % 8)) & 1`: low bit first |

The padding answers the briefing's open question 7. HASH takes whole
64-byte blocks only, and a Lamport preimage is 32 bytes, so each preimage gets
32 zero bytes after it. The kernel writes those zeros itself rather than
trusting scratch: the images start scratch as `0xee`.

The image layout: the kernel at 0, the message at `0x1000`, the signature at
`0x2000` (256 × 32 bytes), the public key at `0x4000` (`pk[i][b]` at
`0x4000 + 64i + 32b`), and 96 bytes of scratch at `0x8000`. That is the
64-byte HASH input, then its 32-byte output.

## The kernel

Eighty-eight instructions, in seven blocks: `setup` (20), then 256 iterations
of `copy` (16), `hash` (5), `pick` (8), `compare` (32) and `advance` (4), then
`finish` (3). The full listing is in `capture.txt`. The loop body, the part
that does the work:

```text
  0050  0004ae83  lw x29, 0(x9)       ┐ copy: preimage i into scratch,
  0054  01daa023  sw x29, 0(x21)      ┘ eight words
  …
  0090  00000293  addi x5, x0, 0        t0 = 0: HASH
  0094  000a8513  addi x10, x21, 0      a0 = scratch
  0098  04000593  addi x11, x0, 64      a1 = 64 bytes
  009c  040a8613  addi x12, x21, 64     a2 = scratch + 64
  00a0  00000073  ecall
  00a4  003a5313  srli x6, x20, 3     ┐
  00a8  00698333  add x6, x19, x6     │ pick: the byte of the message,
  00ac  00034303  lbu x6, 0(x6)       │ its bit i % 8, and from it
  00b0  007a7393  andi x7, x20, 7     │ pk[i][bit]
  00b4  00735333  srl x6, x6, x7      │
  00b8  00137313  andi x6, x6, 1      │
  00bc  00531313  slli x6, x6, 5      │
  00c0  00690333  add x6, x18, x6     ┘
  00c4  040aa383  lw x7, 64(x21)      ┐
  00c8  00032e03  lw x28, 0(x6)       │ compare: s6 |= out ^ pk,
  00cc  01c3c3b3  xor x7, x7, x28     │ eight words
  00d0  007b6b33  or x22, x22, x7     ┘
  …
  0144  02048493  addi x9, x9, 32       the next preimage
  0148  04090913  addi x18, x18, 64     the next key pair
  014c  001a0a13  addi x20, x20, 1
  0150  f17a10e3  bne x20, x23, -256
  0154  01603533  sltu x10, x0, x22     a0 = (s6 ≠ 0)
  0158  00100293  addi x5, x0, 1
  015c  00000073  ecall                 HALT
```

There is no early exit. A bad preimage only sets bits in `s6`, and the loop
runs all 256 times either way, so the count says nothing about where a
signature went wrong. That property is not constant time, which exp207 owns;
it is just the absence of a branch on the verdict.

## What is proved

[`proof/Lamport.lean`](./proof/Lamport.lean), against the same model as exp203.
`H` is `env.hash`, and **nothing is assumed about it**: not that it is
SHA-256, not that it is collision-resistant, nothing. The theorem says the
kernel computes the verification predicate for whatever function HASH is.
Whether that predicate means a forgery is hard is cryptography's question,
not this proof's.

| Theorem | Says |
| --- | --- |
| `verifies` | it halts after 16663 instructions with `if Verifies H m base then 0 else 1`, and every byte outside the 96 of scratch is what it was |
| `exactly_16663` | after 16662 it is still running, for every input: a bad signature costs exactly as many instructions as a good one |
| `code_of_image` | any image that begins with the kernel's 352 bytes, loaded at `base`, holds the kernel |
| `from_boot` | all of it, from `boot`, the state `rv32run` and the RTL harness both start from |

`Verifies` is stated in Lean's own terms, independent of the kernel: for every
`i < 256`, `H (preimage i ++ 32 zeros)` equals, byte for byte, the 32 bytes at
`PK + 64i + 32·bitAt i`. The block contracts compose as in exp203. `start`
covers the twenty setup instructions. `iter` covers one iteration and carries
the invariant `Inv`, whose `acc` field says `s6 = 0` exactly when every
preimage so far was good. `loop` is induction over 256 iterations, and `halt`
covers the last three instructions. The pieces of `iter` are each their own
lemma: `copy_block`, `hash_block`, `pick_block`, `compare_block`, and
`good_iff`, which says comparing eight words is comparing 32 bytes. Everything
rests on `propext`, `Classical.choice` and `Quot.sound`, with no
`native_decide`.

Eleven wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused:

| | The wrong version |
| --- | --- |
| kernel | the loop stops after 255 preimages, so the last bit of the message is never checked |
| kernel | the zero padding starts one word late, so HASH reads four bytes left over from before |
| kernel | HASH is asked for 32 bytes, a length it refuses |
| kernel | the message byte is found with a shift of 4, not 3 |
| kernel | the words are folded together with `and`, so one matching word is enough |
| kernel | the verdict compares `s6` the wrong way round, so every signature is accepted |
| count | it is claimed to halt within 16662 instructions |
| count | it is claimed still to be running after 16663 |
| verdict | it is claimed to accept every signature |
| verdict | the message's bits are read high bit first |
| scratch | it is claimed to write only 64 bytes of scratch |

The second one is why the kernel writes its own zeros. A kernel that relied
on scratch being zero would pass every test that starts scratch as zero.

### What it changed in `lean/`

- **`Rv32/Place.lean` is new.** It holds the address arithmetic exp203 wrote
  first (`Placed`, `toNat_off`, `off_add`, …), the `lbu` and HASH steps, the
  `readBytes` lemmas, and `toBytes` and `code_of_image`, the bridge from a
  file to `CodeAt`. exp204 is the second caller, so exp203's copies moved
  there and exp203 now imports them.
- **`Sha256.lean` is new.** It is FIPS 180-4 for *running* the model only: no
  theorem mentions it, so a mistake in it could make `rv32run` disagree with
  the RTL, but it could not make a proof wrong. It agrees with `hashlib` at
  ten lengths around the padding boundaries.
- **`rv32run` keeps memory in an array.** It used to apply every store as
  another closure, so each load walked back through every store so far. A
  run of 5000 stores took 420 s, and this kernel makes 6000. It now holds
  the region in a `ByteArray` and, after each step, copies back only the bytes
  the instruction could have written, read from the machine `step` returned.
  The 5000-store run now takes 0.2 s. `step` itself is unchanged, so the
  runner still executes the definition the proofs are about.

## What the core counts

| | count |
| --- | --- |
| the proof | 16663, on every input |
| the model, run (`rv32run`) | 16663, on all ten cases, at `0x80010000` and at `0x20070000` |
| the Hazard3 RTL, `minstret` | 17690, on all ten |

17690 = 16663 + 3 + 256 × 4. The 3 is exp203's harness constant. The 4 is
what one HASH costs. [`tools/hazard3/hash-cost.sh`](../../tools/hazard3/hash-cost.sh)
measures both, without any of this kernel: payloads that make `k` HASH calls
in a row and then HALT, for `k` from 0 to 7. The model counts `k + 8`, and the
RTL counts `k + 8 + 3 + 4k`, every time. Three of the 4 are what exp203's table
predicts for one round trip through the harness: the write that stops
counting (1) and the `mret` back (2). The fourth is not attributed here.

Two things the sweep checks around that number:

- **The bytes hashed do not move it.** The same payloads hashing 64 bytes of
  `0xa5` instead of zeros count the same.
- **The word behind the HALT `ecall` does.** The same payloads with a `nop`
  placed right after the last `ecall`, a `nop` that never executes, count one
  more, at every `k`. Probed one word at a time behind a bare HALT,
  `0x00000000` and `0xffffffff` give 5, and the four others tried — `nop`,
  `ebreak`, `ret` and `0xa5a5a5a5` — give 6. That is exp203's
  "what lies behind an `mret`" again, this time behind an `ecall`. The
  kernel's images have zeros behind its last `ecall`, as the sweep's base case
  does, which is why 17690 is what the formula predicts. **On the chip it will
  depend on what the shell leaves after `kernel.bin` in SRAM.** That is for
  exp209 to fix in place, not discover.

On all ten cases the model and the RTL give the verdict Python expects (0 for
the three valid signatures, 1 for the seven broken ones). They leave the whole
64 KiB region byte for byte the same. Python, which does not use the model,
agrees that only the 96 bytes of scratch changed. The HASH under the model is
`Sha256.lean`, under the RTL the harness's C (`tools/hazard3/harness/handler.c`),
and in Python `hashlib`. Three implementations, and the dumps agree.

## What it does not prove

- **That HASH is SHA-256, or that SHA-256 is any good.** The theorem holds for
  every function. exp208 is where HASH may stop being an assumption.
- **That Lamport is secure.** The kernel computes the verification predicate;
  that a forger cannot satisfy it is the scheme's claim, and rests on `H`.
- **That the model is the chip.** As in exp203: exp202 is the evidence that
  `step` is RV32IM, and exp209 is where it meets silicon.
- **Anything about time.** The RTL takes 20508 cycles on every case here, valid
  or not. That is an observation, not a theorem, and the counter is held during
  the harness's software SHA-256, so it is not what HASH will cost on the chip.
- **The shell.** As in exp203, the theorems start from the state the shell is
  supposed to build.

## Running it

```sh
../../tools/lean/setup.sh      # once, needs the network: Lean 4.34.0, 580 MB
../../tools/hazard3/setup.sh   # once, needs the network: the Hazard3 RTL, built with Verilator
./check.sh                     # no board: the proof, eleven mutants, kernel.bin, the RTL
./run.sh                       # records capture.txt
```

No board and nobody. `clang`, `lld` and `llvm-objcopy` for the sweep's
payloads, `python3` for the images. The proof checks in about 40 seconds; each
mutant rebuilds against it, so `check.sh` takes a few minutes.

## Expected output

```text
=== exp204 — the signature the kernel checks ===
recorded at 2026-10-02T14:34:32Z from commit 04a5800

>>> the kernel, as the proof states it and as kernel.bin holds it
  0000  00000417  auipc x8, 0
  0004  00002337  lui x6, 2
  0008  006404b3  add x9, x8, x6
  000c  00004337  lui x6, 4
  0010  00640933  add x18, x8, x6
  0014  00001337  lui x6, 1
  0018  006409b3  add x19, x8, x6
  001c  00008337  lui x6, 8
  0020  00640ab3  add x21, x8, x6
  0024  00000a13  addi x20, x0, 0
  0028  00000b13  addi x22, x0, 0
  002c  10000b93  addi x23, x0, 256
  0030  020aa023  sw x0, 32(x21)
  0034  020aa223  sw x0, 36(x21)
  0038  020aa423  sw x0, 40(x21)
  003c  020aa623  sw x0, 44(x21)
  0040  020aa823  sw x0, 48(x21)
  0044  020aaa23  sw x0, 52(x21)
  0048  020aac23  sw x0, 56(x21)
  004c  020aae23  sw x0, 60(x21)
  0050  0004ae83  lw x29, 0(x9)
  0054  01daa023  sw x29, 0(x21)
  0058  0044ae83  lw x29, 4(x9)
  005c  01daa223  sw x29, 4(x21)
  0060  0084ae83  lw x29, 8(x9)
  0064  01daa423  sw x29, 8(x21)
  0068  00c4ae83  lw x29, 12(x9)
  006c  01daa623  sw x29, 12(x21)
  0070  0104ae83  lw x29, 16(x9)
  0074  01daa823  sw x29, 16(x21)
  0078  0144ae83  lw x29, 20(x9)
  007c  01daaa23  sw x29, 20(x21)
  0080  0184ae83  lw x29, 24(x9)
  0084  01daac23  sw x29, 24(x21)
  0088  01c4ae83  lw x29, 28(x9)
  008c  01daae23  sw x29, 28(x21)
  0090  00000293  addi x5, x0, 0
  0094  000a8513  addi x10, x21, 0
  0098  04000593  addi x11, x0, 64
  009c  040a8613  addi x12, x21, 64
  00a0  00000073  ecall
  00a4  003a5313  srli x6, x20, 3
  00a8  00698333  add x6, x19, x6
  00ac  00034303  lbu x6, 0(x6)
  00b0  007a7393  andi x7, x20, 7
  00b4  00735333  srl x6, x6, x7
  00b8  00137313  andi x6, x6, 1
  00bc  00531313  slli x6, x6, 5
  00c0  00690333  add x6, x18, x6
  00c4  040aa383  lw x7, 64(x21)
  00c8  00032e03  lw x28, 0(x6)
  00cc  01c3c3b3  xor x7, x7, x28
  00d0  007b6b33  or x22, x22, x7
  00d4  044aa383  lw x7, 68(x21)
  00d8  00432e03  lw x28, 4(x6)
  00dc  01c3c3b3  xor x7, x7, x28
  00e0  007b6b33  or x22, x22, x7
  00e4  048aa383  lw x7, 72(x21)
  00e8  00832e03  lw x28, 8(x6)
  00ec  01c3c3b3  xor x7, x7, x28
  00f0  007b6b33  or x22, x22, x7
  00f4  04caa383  lw x7, 76(x21)
  00f8  00c32e03  lw x28, 12(x6)
  00fc  01c3c3b3  xor x7, x7, x28
  0100  007b6b33  or x22, x22, x7
  0104  050aa383  lw x7, 80(x21)
  0108  01032e03  lw x28, 16(x6)
  010c  01c3c3b3  xor x7, x7, x28
  0110  007b6b33  or x22, x22, x7
  0114  054aa383  lw x7, 84(x21)
  0118  01432e03  lw x28, 20(x6)
  011c  01c3c3b3  xor x7, x7, x28
  0120  007b6b33  or x22, x22, x7
  0124  058aa383  lw x7, 88(x21)
  0128  01832e03  lw x28, 24(x6)
  012c  01c3c3b3  xor x7, x7, x28
  0130  007b6b33  or x22, x22, x7
  0134  05caa383  lw x7, 92(x21)
  0138  01c32e03  lw x28, 28(x6)
  013c  01c3c3b3  xor x7, x7, x28
  0140  007b6b33  or x22, x22, x7
  0144  02048493  addi x9, x9, 32
  0148  04090913  addi x18, x18, 64
  014c  001a0a13  addi x20, x20, 1
  0150  f17a10e3  bne x20, x23, -256
  0154  01603533  sltu x10, x0, x22
  0158  00100293  addi x5, x0, 1
  015c  00000073  ecall
    sha256 f078c2905bc937322cff2ba4a98e28eeb6c705c036174c64caff3e1b131fb104  (352 bytes)
    byte for byte the committed kernel.bin

>>> the theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Exp204.bytes_words' depends on axioms: [propext]
'Exp204.code_of_image' depends on axioms: [propext, Quot.sound]
'Exp204.copy_block' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.hash_block' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.pick_block' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.compare_block' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.good_iff' depends on axioms: [propext, Quot.sound]
'Exp204.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.verifies' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.exactly_16663' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp204.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
kernel   the loop stops after 255 preimages, so the last bit of the message is never checked     refused in setup_regs
kernel   the zero padding starts one word late, so HASH reads four bytes left over from before   refused in at_setup_zero
kernel   HASH is asked for 32 bytes, a length it refuses                                         refused in hash_block
kernel   the message byte is found with a shift of 4, not 3                                      refused in pick_block
kernel   the words are folded together with and, so one matching word is enough                  refused in at_cmp_or
kernel   the verdict compares s6 the wrong way round, so every signature is accepted             refused in halt
count    it is claimed to halt within 16662 instructions                                         refused in verifies
count    it is claimed still to be running after 16663                                           refused in exactly_16663
verdict  it is claimed to accept every signature                                                 refused in verifies
verdict  the message's bits are read high bit first                                              refused in pick_block
scratch  it is claimed to write only 64 bytes of scratch                                         refused in overlay_outside

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
case                     python model at 0x80010000        RTL                                model at 0x20070000
valid                    0      halt code=00000000 count=16663 halt code=00000000 instret=17690 cycles=20508 halt code=00000000 count=16663
valid-other-key          0      halt code=00000000 count=16663 halt code=00000000 instret=17690 cycles=20508 halt code=00000000 count=16663
all-ones-message         0      halt code=00000000 count=16663 halt code=00000000 instret=17690 cycles=20508 halt code=00000000 count=16663
first-preimage-flipped   1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
last-preimage-flipped    1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
message-bit-flipped      1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
other-half-revealed      1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
other-message-signature  1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
public-key-swapped       1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663
zero-signature           1      halt code=00000001 count=16663 halt code=00000001 instret=17690 cycles=20508 halt code=00000001 count=16663

PASS  the model gives Python's verdict after exactly 16663 instructions, the number proved, on all 10 cases
PASS  the RTL gives the same verdict and counts 17690 = 16663 proved + 3 for the harness + 256 HASH × 4, on all 10
PASS  the whole region is byte for byte the same on both, on all 10
PASS  Python agrees: only the 96 bytes of scratch changed, on all 10
PASS  at 0x20070000 the same bytes give the same verdict after 16663, on all 10
```

There is no board half here: the RTL is the chip's core, simulated on this
machine. exp210 runs this kernel on silicon with the SHA-256 block as HASH.
