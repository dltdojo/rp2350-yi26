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
source stuck at 1, and exp114's "nine ones then a zero". Not yet run on a
board.**

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
CAPTURE
```
