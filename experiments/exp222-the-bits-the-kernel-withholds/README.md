# exp222 — the bits the kernel withholds

<!-- SPDX-License-Identifier: Apache-2.0 -->

**NIST SP 800-90B's two continuous health tests, as exp114 wrote them in
Rust, made into 48 RV32IM instructions and proved in Lean:
- **the Repetition Count Test:** 21 identical samples in a row fail;
- **the Adaptive Proportion Test:** 589 of 1024 equal to the first fail.

Over 1024 samples, the kernel copies them to its output only if both tests
pass. If either fails, it halts having written nothing. The proof covers
every input:
- **Fail:** after exactly 17427 instructions, memory is just as it was.
- **Pass:** after exactly 23574 instructions, the output is the samples
  word for word, and nothing else changed.

On the chip the kernel judges three sources: the RP2350's own TRNG, a
source stuck at 1, and exp114's "nine ones then a zero". On a Pico 2 it
blinked slowly. The TRNG's samples passed and came out as the output. Both
broken sources were withheld with memory untouched, every count as the
RTL's.**

exp114 put the two tests in a dependency-free crate and said why: *the
cutoffs are the part most likely to be wrong, and a wrong threshold still
produces confident output.* Here the tests are bytes with a theorem.
"Fail-closed", the property exp114 wrote as one `if`, is now a statement
about every input: a failing stream leaves memory untouched.

## The kernel

[`proof/Health.lean`](./proof/Health.lean): 48 instructions, 192 bytes,
[`kernel.bin`](./kernel.bin). The samples are 1024 words at `base +
0x1000`, one sample in bit 0 of each. The output is 1024 words at `base +
0x2000`.

```text
  0-11   pointers; the reference bit (sample 0); last = 2 (none yet); run, bad, agree = 0; count = 1024
  12-28  per sample, no branch but the loop's:
           t1 = bit; run = (t1 = last ? run : 0) + 1; last = t1
           bad |= run ≥ 21; agree += (t1 = ref)
  29-32  bad |= agree ≥ 589; if bad, to 45
  33-41  copy the 1024 words to the output
  42-44  HALT 0
  45-47  HALT 1
```

The tests' state is kept as exp114's `Health::push` keeps it, with one
difference: there is no early stop. Every sample costs the same seventeen
instructions, so the count does not depend on when a failure happened.

## What is proved

The specification is three Lean definitions, read off exp114's crate:
- `rctStep`: the run, reset to 1 when the bit changes;
- `agree`: how many of the 1024 equal the first;
- `Healthy`: no run reached 21, and `agree` < 589.

| Theorem | Says |
| --- | --- |
| `body_regs` | one sample's seventeen instructions leave the last bit, the run, the failure flag and the agreement count exactly as the specification advances them |
| `health_loop` | after `j` samples, the kernel's registers hold the specification's state after `j` bits |
| `verdict_run` | unhealthy: HALT 1 seven instructions on, memory untouched. Healthy: on to the copy |
| `copy_run` | the copy of 1024 words, then HALT 0 |
| **`withholds`** | the whole kernel: unhealthy means HALT 1 after exactly 17427 instructions with memory exactly as it was; healthy means HALT 0 after exactly 23574 with the samples copied to the output and nothing else changed |
| `output` | when healthy, output word `j` is sample `j` |
| `from_boot` | the same from any image that begins with the kernel's 192 bytes, which is what the shell builds |

All rest on Lean's own axioms. The proof is built from the library's
`run_line` and from `lean/Rv32/Copy.lean`, which this experiment added.
`Copy.lean` is exp203's copy-loop memory lemma with the source, the
destination and the count made parameters; exp203 itself is unchanged.

Eight wrong kernels in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused, every one by the theorem about the behaviour it breaks:
- the run's cutoff 22, or the proportion's 590;
- a change of bit that does not reset the run;
- counting the bits that differ from the reference;
- the reference taken from bit 1;
- the verdict's branch inverted;
- a failure halting with 0;
- the copy one word late.

## The differential

[`differential/`](./differential/) runs `kernel.bin` on 14 streams:
- six random;
- stuck at 0, and stuck at 1;
- runs of 20, and runs of 21;
- a run of 21 at the very end;
- exactly 588 agreeing, and exactly 589;
- exp114's broken source.

Each stream runs on the Lean model and on the Hazard3 RTL, against exp114's
`Health::push` transcribed line for line into Python. All agree on the
verdict. The model's count and its region afterwards are also checked, and
are exactly the ones `withholds` gives.

## What runs on the chip

| Source | Samples | Must |
| --- | --- | --- |
| 0 | the TRNG: 32 words, each split into 32 samples, bit by bit | pass: HALT 0, the output the samples |
| 1 | stuck at 1 | be withheld: HALT 1, by the repetition count |
| 2 | nine ones then a zero | be withheld: HALT 1, by the adaptive proportion |

For each, the shell runs these steps:
1. **Set up.** It zeroes the region, puts the kernel at its start (checked
   against `kernel.sha256`) and the samples at 0x1000, and hashes the
   region.
2. **Run.** It runs the kernel in User mode.
3. **Check what `withholds` says.** The kernel halted with 0 or 1, and
   `minstret` is the RTL's count for that code: 23578 or 17430. Then, by
   code:
   - **HALT 1:** the region is byte for byte what it was.
   - **HALT 0:** the output is the samples. With the output cleared, the
     region is byte for byte what it was.

The TRNG driver is embassy-rp's blocking path in C, with exp109's sample
count of 1000. It is in [`shell/board_chip.c`](./shell/board_chip.c), and
like the rest of the shell it is not proved.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp222.uf2.sha256`](./exp222.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp222.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for a few seconds.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | the TRNG's samples passed and came out as the output; both broken sources were withheld, memory untouched; every count as the RTL's |
| **1 flash**, repeated | the kernel's side: its bytes, its halting, its count, or memory not as `withholds` says |
| **2 flashes** | the TRNG gave nothing within its timeout |
| **3 flashes** | the TRNG's own samples were withheld: HALT 1. A healthy source fails each test with probability about 2^-20, so this is most likely a real failure, and either way the kernel did what it should |
| **4 flashes** | a source built to fail was let through: HALT 0 |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## On the board

| | |
| --- | --- |
| UF2 | `exp222.uf2`, SHA-256 `ae820a7b32585ca44e22c6f0c27c351c68f13f0e68b79aebd1c86f0510ead3bf`, the committed one, built at 5063a73 |
| Board | Pico 2 |
| How | BOOTSEL, the UF2 copied on, the LED watched |
| The LED | **slow blinking** |

The shell reaches slow blinking in only one way. All of these held, for
each of the three sources in turn:
- **The kernel.** The 192 bytes in SRAM were `kernel.bin`, by
  `kernel.sha256`, and the kernel halted in User mode.
- **The TRNG.** It gave 32 words within its timeout. The kernel halted
  with 0 at `minstret` 23578, the RTL's count, and the output at 0x2000 was
  the 1024 samples word for word. With the output cleared, the region was
  byte for byte what it was before the run.
- **Stuck at 1.** The kernel halted with 1 at `minstret` 17430, the RTL's
  count, and the region was byte for byte what it was. The repetition count
  caught it, and nothing was written.
- **Nine ones then a zero.** The same: HALT 1 at 17430, the region
  untouched. The adaptive proportion caught it.

So on silicon:
- the RP2350's TRNG, read through the C driver at exp109's sample count,
  passed both tests on its 1024 samples;
- the proved kernel let them through, copied exactly;
- the two sources built to fail were withheld exactly as `withholds` says:
  HALT 1 after a fixed count, not a byte written.

`minstret` matched the RTL's numbers both ways. The proof's two counts
(17427 and 23574), plus the harness's own instructions, are what the chip
counts.

What this run cannot say is how often the TRNG fails these tests. One run,
1024 samples, read off the LED as one bit.

## What the RTL checks, and what it cannot

On the Hazard3 RTL the kernel runs for real. A stand-in gives the TRNG's
words ([`shell/board_sim.c`](./shell/board_sim.c)):

| Stand-in | Verdict |
| --- | --- |
| an LCG whose bits pass | ok: passed and copied, both broken sources withheld |
| all ones | 3: the kernel, run for real, withholds them at `minstret` 17430 |
| nothing | 2 |

Five wrong shells or expectations are caught:
- the kernel's hash is wrong;
- the healthy count is off by one;
- the broken source is made fair, and the kernel lets it through: 4;
- the output is not cleared before the region is hashed again;
- the shell traps itself.

## What it does not say

- **That the TRNG is random.** The tests catch a source that has stuck or
  has a strong preference, at the rate their cutoffs allow. A source can
  pass them and still be poor. SP 800-90B's entropy assessment is not here,
  and nor is a proof of the cutoffs' false-positive rates, which is
  probability, not program.
- **That the shell gathered the samples it claims.** The driver and the
  splitting into bits are C, not proved. What is proved is what the kernel
  does with whatever samples it is given.
- **Conditioning.** The output is the raw samples. Hashing them with
  exp208's proved SHA-256 kernel would be the next step.
- **More than one run.**

## Running it

```sh
./check.sh       # the proof and mutants, kernel.bin, the differential, the build, the UF2, the RTL
./build.sh       # build/exp222.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
A few minutes, most of it the mutants rebuilding.

## Expected output

```text
=== exp222 — the bits the kernel withholds ===
recorded at 2026-10-07T09:27:37Z from commit 5063a73

>>> the kernel, as proof/Health.lean writes it
  0000  00000417  auipc x8, 0
  0004  00001337  lui x6, 1
  0008  006404b3  add x9, x8, x6
  000c  00002337  lui x6, 2
  0010  00640933  add x18, x8, x6
  0014  0004ab83  lw x23, 0(x9)
  0018  001bfb93  andi x23, x23, 1
  001c  00200a13  addi x20, x0, 2
  0020  00000a93  addi x21, x0, 0
  0024  00000b13  addi x22, x0, 0
  0028  00000c13  addi x24, x0, 0
  002c  40000993  addi x19, x0, 1024
  0030  0004a303  lw x6, 0(x9)
  0034  00137313  andi x6, x6, 1
  0038  014343b3  xor x7, x6, x20
  003c  0013b393  sltiu x7, x7, 1
  0040  407003b3  sub x7, x0, x7
  0044  007afab3  and x21, x21, x7
  0048  001a8a93  addi x21, x21, 1
  004c  00030a13  addi x20, x6, 0
  0050  015ab393  sltiu x7, x21, 21
  0054  0013c393  xori x7, x7, 1
  0058  007b6b33  or x22, x22, x7
  005c  017343b3  xor x7, x6, x23
  0060  0013c393  xori x7, x7, 1
  0064  007c0c33  add x24, x24, x7
  0068  00448493  addi x9, x9, 4
  006c  fff98993  addi x19, x19, -1
  0070  fc0990e3  bne x19, x0, -64
  0074  24dc3393  sltiu x7, x24, 589
  0078  0013c393  xori x7, x7, 1
  007c  007b6b33  or x22, x22, x7
  0080  020b1a63  bne x22, x0, 52
  0084  00001337  lui x6, 1
  0088  006404b3  add x9, x8, x6
  008c  40000993  addi x19, x0, 1024
  0090  0004a383  lw x7, 0(x9)
  0094  00792023  sw x7, 0(x18)
  0098  00448493  addi x9, x9, 4
  009c  00490913  addi x18, x18, 4
  00a0  fff98993  addi x19, x19, -1
  00a4  fe0996e3  bne x19, x0, -20
  00a8  00000513  addi x10, x0, 0
  00ac  00100293  addi x5, x0, 1
  00b0  00000073  ecall
  00b4  00100513  addi x10, x0, 1
  00b8  00100293  addi x5, x0, 1
  00bc  00000073  ecall

>>> the theorems, and what they rest on
'Exp222.body_regs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp222.health_loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp222.verdict_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp222.copy_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp222.withholds' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp222.output' depends on axioms: [propext, Quot.sound]
'Exp222.bytes_words' depends on axioms: [propext]
'Exp222.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels: each must be refused
body_regs    the repetition count fails at 22, not 21                          refused in body_regs
verdict_run  the adaptive proportion fails at 590, not 589                     refused in verdict_run
body_regs    a change of bit does not reset the run                            refused in body_regs
body_regs    the proportion counts the bits that differ from the reference     refused in body_regs
setup_run    the reference is bit 1 of the first sample, not bit 0             refused in setup_run
verdict_run  a sample that fails goes to the copy, one that passes to HALT 1   refused in verdict_run
verdict_run  a failure halts with 0                                            refused in verdict_run
copy_iter    the copy writes each word to the output one word late             refused in copy_iter

>>> the differential: the Lean model and the Hazard3 RTL against exp114's tests
PASS  random 0: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 1: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 2: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 3: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 4: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 5: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  stuck at 1: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  stuck at 0: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  runs of 20: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  runs of 21: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  a run of 21 at the end: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  588 agree: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  589 agree: exp114 says withheld: adaptive proportion 589; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  nine ones then a zero: exp114 says withheld: adaptive proportion 922; the model and the RTL halt with 1, the model after 17427, its region as said

>>> the shell, for the chip and for the RTL
build/expect.h: kernel 39587b4ec6bd48b2…, RTL minstret 23578 healthy, 17430 withheld
build/exp222.bin  4116 bytes, the build allows 8192
build/exp222.uf2  8704 bytes  sha256 ae820a7b32585ca44e22c6f0c27c351c68f13f0e68b79aebd1c86f0510ead3bf

>>> on the RTL, the kernel for real on three sources: REPT verdict source failed a0 minstret cause
52455054 00000000 00000003 00000000 00000000 00000000 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Health.lean checks, with no errors and no warnings
PASS  all 8 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  body_regs: the proof refuses a version where the repetition count fails at 22, not 21
PASS  verdict_run: the proof refuses a version where the adaptive proportion fails at 590, not 589
PASS  body_regs: the proof refuses a version where a change of bit does not reset the run
PASS  body_regs: the proof refuses a version where the proportion counts the bits that differ from the reference
PASS  setup_run: the proof refuses a version where the reference is bit 1 of the first sample, not bit 0
PASS  verdict_run: the proof refuses a version where a sample that fails goes to the copy, one that passes to HALT 1
PASS  verdict_run: the proof refuses a version where a failure halts with 0
PASS  copy_iter: the proof refuses a version where the copy writes each word to the output one word late
PASS  kernel.bin is what proof/Health.lean writes, 192 bytes, and kernel.sha256 is its hash
PASS  random 0: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 1: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 2: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 3: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 4: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  random 5: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  stuck at 1: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  stuck at 0: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  runs of 20: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  runs of 21: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  a run of 21 at the end: exp114 says withheld: repetition count 21; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  588 agree: exp114 says healthy; the model and the RTL halt with 0, the model after 23574, its region as said
PASS  589 agree: exp114 says withheld: adaptive proportion 589; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  nine ones then a zero: exp114 says withheld: adaptive proportion 922; the model and the RTL halt with 1, the model after 17427, its region as said
PASS  the shell builds for the chip and for the RTL, the chip's in 4116 of the 8192 bytes it may use
PASS  all 17 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 8 KiB of flash, 0x10000000..0x10002000
PASS  together they are exactly the 4116-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: ae820a7b32585ca4…
PASS  on the RTL, against a stand-in TRNG that works: its samples pass and are copied, both broken sources are withheld, each check as withholds says — ok
PASS  on the RTL, against a stand-in TRNG giving all ones: the kernel, run for real, withholds its samples at minstret 17430 — verdict 3
PASS  on the RTL, against a stand-in TRNG giving nothing: verdict 2, before the kernel runs
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — verdict 1, check 1
PASS  the shell catches a version where the chip is asked to count one more when healthy — verdict 1, check 3
PASS  the shell catches a version where the broken source is nine ones then a zero no longer, but a fair alternation — it passes: verdict 4
PASS  the shell catches a version where the output is not cleared before the region is hashed again — the region differs: verdict 1, check 5
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
```
