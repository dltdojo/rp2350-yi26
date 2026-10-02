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
what one HASH costs. [`accounting/measure.sh`](./accounting/measure.sh)
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

See [`capture.txt`](./capture.txt), recorded by `./run.sh`; the summary lines
are:

```text
CAPTURE
```

There is no board half here: the RTL is the chip's core, simulated on this
machine. exp210 runs this kernel on silicon with the SHA-256 block as HASH.
