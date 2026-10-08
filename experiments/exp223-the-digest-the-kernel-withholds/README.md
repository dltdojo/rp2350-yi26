# exp223 — the digest the kernel withholds

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp222's health tests and exp208's SHA-256, made into one kernel with one
theorem. The kernel runs NIST SP 800-90B's repetition count and adaptive
proportion tests over 1024 samples. If both pass, it goes on to SHA-256 over
those same samples. The proof covers every input:
- **Fail:** HALT 1 after exactly 17425 instructions. Memory is just as it
  was: no digest, not a byte written.
- **Pass:** HALT 0 after exactly 334284 instructions. The 32 bytes at 0x2140
  are SHA-256 of the samples' 4096 bytes, and nothing changed but the digest
  and SHA-256's own scratch.

So a digest exists only if the samples passed, and it is the digest of
exactly the samples the tests judged. That is the composition this
experiment adds; each half was proved before.

On the chip the kernel conditions or withholds three sources: the RP2350's
TRNG, a source stuck at 1, and exp114's "nine ones then a zero". The
kernel's digest is held against the chip's own SHA-256 block. Not yet run
on a board.**

## Why it is not part of exp222

The two halves prove different kinds of thing:
- **The health tests** make a decision, and fail closed. exp222's theorem is
  about control: which way the kernel halts, and that a failing stream
  writes nothing.
- **Conditioning** is a function. exp208's theorem is an equality: the
  bytes at the end are `sha256` of the bytes at the start.

SP 800-90B keeps them apart as well. The health tests are §4.4, and the
vetted conditioning components, SHA-256 among them, are §3.1.5. So exp222
stayed as it was. What is new here is only the join: "the digest exists if
and only if the tests passed, and it is the digest of what they judged".

## The kernel

One image, [`kernel.bin`](./kernel.bin), 8484 bytes, written by
[`proof/Condition.lean`](./proof/Condition.lean):

```text
  0x0000  the front, 34 instructions:
            0      auipc s0, 0
            1-2    s1 = base + 0x3000          the samples
            3-29   the tests: lean/Rv32/Health.lean's `front`
            30     beq s6, x0 → 0x1000         healthy: on to SHA-256
            31-33  HALT 1
  0x1000  exp208's SHA-256 kernel, its 1008 bytes unchanged
  0x2000  K, IV and the length (4096), as exp208's kernel reads them
  0x2140  the digest, written; 0x2200 to 0x2440 its scratch
  0x3000  the samples: 1024 words, one sample each in bit 0
```

Nothing is copied. The samples sit where SHA-256 reads its message, so the
bytes the tests judge are the bytes that are hashed, by where they are.
SHA-256 hashes the whole of each word, not only bit 0. The shell writes 0 or
1 into each word, so the 4096 bytes are an exact encoding of the 1024
samples. Packing them into 128 bytes first would need a third proved piece
of code, and buys nothing a theorem can see.

## What is proved

| Theorem | Says |
| --- | --- |
| `Health.front_run` | (lean/Rv32/Health.lean) the tests, anywhere in a kernel, over samples anywhere: `s6` is zero exactly when they are healthy, nothing is written |
| `front_decides` | the front: unhealthy, HALT 1 after 17425 with memory untouched; healthy, 17422 instructions on, the run is at 0x1000 with memory untouched |
| `Sha.computes` | (lean/Rv32/Sha.lean, exp208's) from its first instruction, SHA-256 of `64 n` bytes in `4990 + 4873 n` instructions |
| `run_within` | (lean/Rv32/Within.lean) a run that went on, or halted, in a region does the same in any region holding it |
| **`conditions`** | the whole kernel, as stated at the top |
| `from_boot` | the same from any image holding the front at 0, exp208's bytes at 0x1000 and the data at 0x2000, which is what the shell builds |

All rest on Lean's own axioms.

### Why the region is 128 KiB

Every kernel theorem here assumes `Placed`: the kernel's first instruction
at the start of a 64 KiB region. exp208's `computes` is no exception. Its
first instruction is at 0x1000 here, so its region runs to 0x11000, past
the 64 KiB every earlier kernel had. The run itself touches nothing above
0x4000, and on a 64 KiB region the RTL halts the same way. But the theorem
would not apply there, so the region is 128 KiB:
- 0x80040000 on the RTL;
- 0x20060000 on the chip.

NAPOT wants it aligned to its size, which is why the addresses move.

`run_within` is the join: each half is proved in its own 64 KiB, and both
are carried into the 128 KiB. It holds because the region only ever says
no. A fetch, load, store or `HASH` outside it is a fault, and nothing inside
it depends on where its edges are.

One of the mutants claims a 64 KiB region. Lean refuses it.

Ten wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused.
- **Four wrong kernels:**
  - the tests read the data, not the samples;
  - the branch inverted;
  - a pass landing one instruction into SHA-256, past its `auipc`;
  - a failure halting with 0.
- **Six wrong claims:**
  - SHA-256 given a length one block short;
  - the count one short;
  - the digest of 4092 bytes, not 4096;
  - a frame that leaves out SHA-256's scratch;
  - a 64 KiB region;
  - "inside" meaning only "starts no earlier".

The tests' own mutants are exp222's, and SHA-256's are exp208's. Both still
edit the library this kernel stands on.

## The differential

[`differential/`](./differential/) runs `kernel.bin` on exp222's 14 streams
([`streams.py`](../../tools/hazard3/shell/streams.py)), on the Lean model
and on the Hazard3 RTL, both in the 128 KiB region. They are checked
against exp114's tests in Python and against hashlib.

Every one agrees:
- **The 7 healthy streams:** HALT 0. The model counts 334284, and both
  digests are hashlib's.
- **The 7 unhealthy streams:** HALT 1. The model counts 17425, and its
  region is untouched.

## What runs on the chip

| Source | Samples | Must |
| --- | --- | --- |
| 0 | the TRNG: 32 words, each split into 32 samples | pass: HALT 0, the digest the chip's SHA-256 block's |
| 1 | stuck at 1 | be withheld: HALT 1, by the repetition count |
| 2 | nine ones then a zero | be withheld: HALT 1, by the adaptive proportion |

For each, the shell runs these steps:
1. **Set up.** It zeroes the 128 KiB region and puts `kernel.bin` at its
   start, checked against `kernel.sha256`. It puts the samples at 0x3000.
   It takes SHA-256 of the samples with `board_sha` and hashes the region.
2. **Run.** It runs the kernel in User mode.
3. **Check what `conditions` says.** The kernel halted with 0 or 1, and
   `minstret` is the RTL's count for that code: 334287 or 17428. Then, by
   code:
   - **HALT 1:** the region is byte for byte what it was.
   - **HALT 0:** the 32 bytes at 0x2140 are `board_sha`'s digest. With
     0x2140 to 0x2440 cleared, the region is byte for byte what it was.

`board_sha` is the chip's SHA-256 block on the chip. That is exp210's
driver, [`sha_chip.h`](../../tools/hazard3/shell/sha_chip.h). On the RTL,
which has no such block, it is
[`sha256.c`](../../tools/hazard3/harness/sha256.c).

On the chip, then, three different SHA-256s have to agree:
- the specification the kernel is proved against;
- the kernel itself, run on silicon;
- the RP2350's own hardware.

The TRNG driver, the three sources, the RTL's stand-in TRNG and the LED
reports are exp222's, in [`tools/hazard3/shell/`](../../tools/hazard3/shell/).
None of the shell is proved.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp223.uf2.sha256`](./exp223.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp223.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for about ten seconds. Hashing the 128 KiB region seven
   times takes a moment.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | the TRNG's samples passed and their digest was the chip's SHA-256 block's; both broken sources were withheld, memory untouched; every count as the RTL's |
| **1 flash**, repeated | the kernel's side: its bytes, its halting, its count, its digest, or memory not as `conditions` says |
| **2 flashes** | the TRNG gave nothing within its timeout |
| **3 flashes** | the TRNG's own samples were withheld: HALT 1. A healthy source fails each test with probability about 2^-20, so this is most likely a real failure, and either way the kernel did what it should |
| **4 flashes** | a source built to fail was let through: HALT 0 |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## On the board

Not yet run.

## What the RTL checks, and what it cannot

On the Hazard3 RTL the kernel runs for real, in the 128 KiB region. A
stand-in gives the TRNG's words
([`trng_sim.h`](../../tools/hazard3/shell/trng_sim.h)):

| Stand-in | Verdict |
| --- | --- |
| an LCG whose bits pass | ok: conditioned, the digest `sha256.c`'s, both broken sources withheld |
| all ones | 3: the kernel, run for real, withholds them at `minstret` 17428 |
| nothing | 2 |

Six wrong shells or expectations are caught:
- the kernel's hash is wrong;
- the healthy count is off by one;
- the broken source is made fair, and the kernel lets it through: 4;
- the digest is held against SHA-256 of one block fewer;
- the digest and its scratch are not cleared before the region is hashed
  again;
- the shell traps itself.

The RTL cannot run the chip's SHA-256 block. exp210 holds `sha_hw.h`
against the datasheet's description on the host, and against the chip on
the board.

## What it does not say

- **That the output has full entropy.** SP 800-90B credits a vetted
  conditioning component with at most the entropy that went into it. That
  is an assessment of the noise source, and none was made here. What is
  proved is the program: which samples go in, and that the output is their
  SHA-256 or nothing.
- **That the TRNG is random.** As exp222 says, the tests catch a source
  that has stuck or has a strong preference, at the rate their cutoffs
  allow.
- **That the specification is FIPS 180-4.** exp208 holds it to hashlib by
  running it. Here the model's and the RTL's digests are held to hashlib
  again, and on the chip to the SHA-256 block.
- **That the shell gathered the samples it claims.** The driver and the
  splitting into bits are C, not proved.
- **More than one run.**

## Running it

```sh
./check.sh       # the proof and mutants, kernel.bin, the differential, the build, the UF2, the RTL
./build.sh       # build/exp223.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
Half an hour, most of it the mutants and the RTL hashing its region.

## Expected output

To be pasted from `capture.txt` once `run.sh` has recorded it.
