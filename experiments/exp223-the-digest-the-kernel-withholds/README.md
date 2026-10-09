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
kernel's digest is held against the chip's own SHA-256 block. On a Pico 2
it blinked slowly:
- the TRNG's samples passed, and the proved kernel's digest of them was the
  SHA-256 block's;
- both broken sources were withheld with memory untouched;
- every count was the RTL's.**

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

| | |
| --- | --- |
| UF2 | `exp223.uf2`, SHA-256 `5c1c1a1e16816e4717eea9ed3c8e41ca14073acb7d059eac253891f1c5fd68ba`, the committed one, built at 012a8c3 and unchanged since |
| Board | Pico 2 |
| How | BOOTSEL, the UF2 copied on, the LED watched |
| The LED | **slow blinking** |

The shell reaches slow blinking in only one way. All of these held, for
each of the three sources in turn:
- **The kernel.** The 8484 bytes in SRAM were `kernel.bin`, by
  `kernel.sha256`, and the kernel halted in User mode, in the 128 KiB
  region at 0x20060000.
- **The TRNG.** It gave 32 words within its timeout. The kernel halted with
  0 at `minstret` 334287, the RTL's count. The 32 bytes at 0x2140 were the
  digest the RP2350's SHA-256 block gave for the same 4096 bytes. With the
  digest and SHA-256's scratch cleared, the region was byte for byte what
  it was before the run.
- **Stuck at 1.** The kernel halted with 1 at `minstret` 17428, the RTL's
  count, and the region was byte for byte what it was. No digest was
  written.
- **Nine ones then a zero.** The same: HALT 1 at 17428, the region
  untouched.

So on silicon, three SHA-256s agreed:
- the specification the kernel is proved against, through the theorem;
- the kernel's 1008 bytes, run in User mode;
- the chip's own SHA-256 block.

The digest came out only for the source that passed both tests. It was the
digest of exactly the samples the tests judged.

`minstret` matched the RTL's numbers both ways. The proof's two counts,
17425 and 334284, plus the harness's 3, are what the chip counts.

What this run cannot say:
- how often the TRNG fails the tests;
- how much entropy the digest carries.

It was one run, read off the LED as one bit.

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

`run.sh`'s recording, [`capture.txt`](./capture.txt), pasted:

```text
=== exp223 — the digest the kernel withholds ===
recorded at 2026-10-09T02:28:40Z from commit d973c53

>>> the front, as proof/Condition.lean writes it (exp208's SHA-256 follows at 0x1000)
  0000  00000417  auipc x8, 0
  0004  00003337  lui x6, 3
  0008  006404b3  add x9, x8, x6
  000c  0004ab83  lw x23, 0(x9)
  0010  001bfb93  andi x23, x23, 1
  0014  00200a13  addi x20, x0, 2
  0018  00000a93  addi x21, x0, 0
  001c  00000b13  addi x22, x0, 0
  0020  00000c13  addi x24, x0, 0
  0024  40000993  addi x19, x0, 1024
  0028  0004a303  lw x6, 0(x9)
  002c  00137313  andi x6, x6, 1
  0030  014343b3  xor x7, x6, x20
  0034  0013b393  sltiu x7, x7, 1
  0038  407003b3  sub x7, x0, x7
  003c  007afab3  and x21, x21, x7
  0040  001a8a93  addi x21, x21, 1
  0044  00030a13  addi x20, x6, 0
  0048  015ab393  sltiu x7, x21, 21
  004c  0013c393  xori x7, x7, 1
  0050  007b6b33  or x22, x22, x7
  0054  017343b3  xor x7, x6, x23
  0058  0013c393  xori x7, x7, 1
  005c  007c0c33  add x24, x24, x7
  0060  00448493  addi x9, x9, 4
  0064  fff98993  addi x19, x19, -1
  0068  fc0990e3  bne x19, x0, -64
  006c  24dc3393  sltiu x7, x24, 589
  0070  0013c393  xori x7, x7, 1
  0074  007b6b33  or x22, x22, x7
  0078  780b04e3  beq x22, x0, 3976
  007c  00100513  addi x10, x0, 1
  0080  00100293  addi x5, x0, 1
  0084  00000073  ecall

>>> the theorems, and what they rest on
'Exp223.front_decides' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp223.conditions' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp223.bytes_words' depends on axioms: [propext]
'Exp223.sha_words' depends on axioms: [propext]
'Exp223.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
setup_run         the tests read 0x2000, the data, not the samples SHA-256 hashes         refused in setup_run
front_decides     the branch is inverted: a failure goes on to SHA-256                    refused in front_decides
front_decides     a pass lands one instruction into SHA-256, past its auipc               refused in front_decides
front_decides     a failure halts with 0                                                  refused in front_decides
from_boot         the length SHA-256 is given is 4032, one block short                    refused in data_len
conditions        the count when healthy is one short                                     refused in conditions
conditions        the digest is of the samples' first 4092 bytes                          refused in conditions
conditions        nothing but the digest's 32 bytes changed, SHA-256's scratch left out   refused in conditions
Wide.within       the region is 64 KiB, as every kernel before it had                     refused in within1
Region.ok_within  a region inside another is one that starts no later                     refused in Region.ok_within

>>> the differential: the Lean model and the Hazard3 RTL against exp114's tests and hashlib
PASS  random 0: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 16f4a129e8c494a2…
PASS  random 1: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 8e7512dca87142b8…
PASS  random 2: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 18ee5926ccd3fbdb…
PASS  random 3: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 426a52747a09e302…
PASS  random 4: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, b79e08f3e9dc3633…
PASS  random 5: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 4cdfa162b7cf60cf…
PASS  stuck at 1: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  stuck at 0: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  runs of 20: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, f897635874145497…
PASS  runs of 21: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  a run of 21 at the end: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  588 agree: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 089372c1cc190e2b…
PASS  589 agree: exp114 says withheld: adaptive proportion 589; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  nine ones then a zero: exp114 says withheld: adaptive proportion 922; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched

>>> the shell, for the chip and for the RTL
build/expect.h: kernel 8995effdbd2aba7a…, RTL minstret 334287 conditioned, 17428 withheld
build/exp223.bin  12852 bytes, the build allows 16384
build/exp223.uf2  26112 bytes  sha256 5c1c1a1e16816e4717eea9ed3c8e41ca14073acb7d059eac253891f1c5fd68ba

>>> on the RTL, the kernel for real on three sources: REPT verdict source failed a0 minstret cause
52455054 00000000 00000003 00000000 00000000 00000000 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Condition.lean checks, with no errors and no warnings
PASS  all 5 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  setup_run: the proof refuses a version where the tests read 0x2000, the data, not the samples SHA-256 hashes
PASS  front_decides: the proof refuses a version where the branch is inverted: a failure goes on to SHA-256
PASS  front_decides: the proof refuses a version where a pass lands one instruction into SHA-256, past its auipc
PASS  front_decides: the proof refuses a version where a failure halts with 0
PASS  from_boot: the proof refuses a version where the length SHA-256 is given is 4032, one block short
PASS  conditions: the proof refuses a version where the count when healthy is one short
PASS  conditions: the proof refuses a version where the digest is of the samples' first 4092 bytes
PASS  conditions: the proof refuses a version where nothing but the digest's 32 bytes changed, SHA-256's scratch left out
PASS  Wide.within: the proof refuses a version where the region is 64 KiB, as every kernel before it had
PASS  Region.ok_within: the proof refuses a version where a region inside another is one that starts no later
PASS  kernel.bin is what proof/Condition.lean writes, 8484 bytes, and kernel.sha256 is its hash
PASS  kernel.bin holds exp208's sha.bin, byte for byte, at 0x1000, and zeros between the pieces
PASS  random 0: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 16f4a129e8c494a2…
PASS  random 1: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 8e7512dca87142b8…
PASS  random 2: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 18ee5926ccd3fbdb…
PASS  random 3: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 426a52747a09e302…
PASS  random 4: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, b79e08f3e9dc3633…
PASS  random 5: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 4cdfa162b7cf60cf…
PASS  stuck at 1: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  stuck at 0: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  runs of 20: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, f897635874145497…
PASS  runs of 21: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  a run of 21 at the end: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  588 agree: exp114 says healthy; the model and the RTL halt with 0, the model after 334284; both digests hashlib's, 089372c1cc190e2b…
PASS  589 agree: exp114 says withheld: adaptive proportion 589; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  nine ones then a zero: exp114 says withheld: adaptive proportion 922; the model and the RTL halt with 1, the model after 17425; no digest, the model's region untouched
PASS  the shell builds for the chip and for the RTL, the chip's in 12852 of the 16384 bytes it may use
PASS  all 51 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 12852-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20060000
PASS  the UF2 is byte for byte the committed one: 5c1c1a1e16816e47…
PASS  on the RTL, against a stand-in TRNG that works: its samples pass and their digest is sha256.c's, both broken sources are withheld, each check as conditions says — ok
PASS  on the RTL, against a stand-in TRNG giving all ones: the kernel, run for real, withholds its digest at minstret 17428 — verdict 3
PASS  on the RTL, against a stand-in TRNG giving nothing: verdict 2, before the kernel runs
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — verdict 1, check 1
PASS  the shell catches a version where the chip is asked to count one more when healthy — verdict 1, check 3
PASS  the shell catches a version where the broken source is nine ones then a zero no longer, but a fair alternation — it passes: verdict 4
PASS  the shell catches a version where the digest is held against SHA-256 of one block fewer — verdict 1, check 4
PASS  the shell catches a version where the digest and its scratch are not cleared before the region is hashed again — verdict 1, check 5
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
```
