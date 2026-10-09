# exp224 — the checks the kernel makes

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp223 again, with its checks moved out of C. exp223's shell checked, in C,
what the theorem `conditions` says about each of its three sources. Here the
shell checks nothing. For each source it only gathers the facts the checks
are made on, into a record. Then a new RV32IM kernel, proved in Lean, reads
the three records and halts with the verdict:
- exp223's five checks, made on each record;
- the first record with a failure;
- the TRNG's samples withheld, or a broken source let through.

The theorem `judges` covers every input: whatever the records hold, the judge
halts with exactly the verdict its specification gives, and writes nothing.
Thirteen wrong judges and wrong claims are refused. Not yet run on a board.**

Why this direction, and what it costs, is written up for students in
Taiwanese Mandarin: [WHY.zh-TW.md](./WHY.zh-TW.md).

## What moved, and what did not

| In exp223's shell | Kind | In exp224 |
| --- | --- | --- |
| reading the trap (HALT? a0) and `minstret` | CSRs, the trap | the shell: a fact |
| SHA-256 of the samples, and of the 128 KiB region | the SHA-256 block | the shell: a fact |
| SHA-256 of the kernel's bytes | computation, by `sha256.c` | the shell: a fact |
| three 32-byte comparisons: the kernel's hash, the digest, the region before and after | pure computation | **the judge** |
| halted with 0 or 1; `minstret` the one for that code | pure computation | **the judge** |
| the verdict, by source | pure computation | **the judge** |

Two decisions stay in C, and are named here because the line is not perfectly
clean:
- **The judge's own bytes.** They are compared with `judge.sha256`. Nothing
  can judge its own bytes; something outside it has to.
- **SHA-256's scratch.** When exp223's kernel halts with 0, the shell clears
  0x2140 to 0x2440 before hashing the region again, as exp223's shell did.
  That is a decision on a0.

## The judge

[`proof/Judge.lean`](./proof/Judge.lean): 167 instructions, 668 bytes,
[`judge.bin`](./judge.bin). It runs in exp223's 128 KiB region, after
exp223's kernel has run three times.

```text
  records   three of 0x100 bytes from base + 0x1000, one per source:
    0x00 mcause   0x04 t0   0x08 a0   0x0c minstret       what the trap said
    0x10 the RTL's minstret for HALT 0, 0x14 for HALT 1     what it should say
    0x18 nonzero if the SHA-256 block reported no error
    0x20 SHA-256 of the kernel's bytes    0x40 kernel.sha256
    0x60 the 32 bytes at 0x2140           0x80 SHA-256 of the samples
    0xa0 the region's hash after          0xc0 and before

   0      auipc s0, 0
   1-2    s1 = base + 0x1000        the first record
   3      s2 = 0                    the source
   4-102  three 32-byte comparisons into s4, s5, s6
   103-109 the seven words
   110-141 the five checks, without a branch; the failures in a6
   142-148 failures: HALT 1 | s << 3 | failures << 6
   149-159 the TRNG withheld: HALT 3; a broken source passed: HALT 4 | s << 3
   160-163 the next record, round to 4 while s < 3
   164-166 HALT 0
```

The halt code is:

| Bits | Meaning |
| --- | --- |
| 0–2 | the verdict: 0 ok, 1 a check failed, 3 the TRNG withheld, 4 a broken source let through |
| 3–5 | the source |
| 6–10 | the failed checks: check `k` is bit `k − 1` |

The five checks, on each record, are exp223's:
1. the kernel's bytes are `kernel.sha256`'s, and the SHA-256 block reported
   no error;
2. it halted (mcause 8, t0 1) with 0 or 1;
3. `minstret` is the one for the code it halted with;
4. halting with 0, the digest is the samples' SHA-256;
5. the region is as it was.

## What is proved

The specification is a few Lean definitions:
- `Check1` to `Check5`;
- `failures`, the five failures as bits;
- `verdictOf`, one record's verdict, if it gives one;
- `verdict`, the first record that gives one, or 0.

| Theorem | Says |
| --- | --- |
| `checks_spec` | the 32 branch-free instructions of `checks` leave in a6 the record's `failures`, given the record's words in the registers and the three comparisons' accumulators zero exactly when their 32 bytes agree |
| `compare_run` | a cleared accumulator, then `compare_words` (lean/Rv32/Blocks.lean) over two fields of the record: zero exactly when they agree |
| `body_run` | from the top of a record, 138 instructions on: a6 the failures, t5 the record's a0, memory untouched |
| `iter` | one record: the kernel halts with `verdictOf` if it gives a verdict, memory untouched; if not, it goes on to the next record |
| **`judges`** | the whole judge: from `base`, whatever the three records hold, it halts with `verdict`, and memory is just as it was |
| `from_boot` | the same from any image beginning with `judge.bin`, in a 128 KiB region (`Wide`, now lean/Rv32/Within.lean's) |

All rest on Lean's own axioms. Unlike exp221's and exp223's theorems, `judges`
gives no exact instruction count. How many instructions run depends on where
the first verdict is.

Thirteen wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused, each by the theorem about the part it breaks. The five that break a
check change `checks` and, in the same sed, `checksOf`, the formula
`checks_a6` reads the instructions into. So `checks_a6` still holds, and it
is `checks_spec`, the comparison with the specification, that refuses them.
- **Eleven wrong judges:**
  - check 1 forgets the SHA-256 block's error flag;
  - t0 = 3 counts as HALT;
  - halting with 2 passes check 2;
  - `minstret` held to the HALT 0 count whatever the code;
  - the digest checked after HALT 1 too;
  - the digest compared with itself;
  - the region's hash compared with itself;
  - a failure's code with the source one bit too high;
  - the TRNG withheld reported as 4;
  - a broken source that halted with 0 counted as withheld;
  - only two records judged.
- **Two wrong claims:**
  - the records at 0x1100;
  - a later record's verdict coming first.

## The differential

[`differential/`](./differential/) runs `judge.bin` on 60 sets of three
records ([`facts.py`](./differential/facts.py)), on the Lean model and on the
Hazard3 RTL. They are checked against the specification transcribed into
Python. The sets are:
- the chip's own case;
- each check made to fail alone, in each source;
- the TRNG withheld, and a broken source let through;
- two in which more than one record gives a verdict and the first must win;
- thirty random sets.

All 60 agree, and the model's region is untouched after every one.

## What runs on the chip

For each of exp223's three sources the shell runs these steps:
1. **Set up.** It zeroes the region, puts exp223's `kernel.bin` at its start
   and the samples at 0x3000.
2. **Gather facts before the run.** It takes:
   - the kernel's hash, with `sha256.c`;
   - the samples' SHA-256 and the region's hash, with `board_sha`.
3. **Run** exp223's kernel.
4. **Gather facts after the run.** It records:
   - mcause, t0, a0 and `minstret`;
   - the 32 bytes at 0x2140;
   - the region's hash after.

None of this is checked. Then the judge runs on the three records, and its
code goes to the LED.

`board_sha` differs by build:
- on the chip, it is the RP2350's SHA-256 block;
- on the RTL, it is `sha256.c`.

The board pieces are exp223's, now shared as
[`tools/hazard3/shell/health_chip.c`](../../tools/hazard3/shell/health_chip.c)
and [`health_sim.c`](../../tools/hazard3/shell/health_sim.c). exp223's UF2 is
byte for byte what it was.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp224.uf2.sha256`](./exp224.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp224.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for about ten seconds.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | the judge halted with 0: every check on every source held, the TRNG's samples were conditioned, both broken sources withheld |
| **1 flash**, repeated | the judge found a failed check |
| **2 flashes** | the TRNG gave nothing within its timeout (the shell's) |
| **3 flashes** | the judge: the TRNG's own samples were withheld |
| **4 flashes** | the judge: a source built to fail was let through |
| **5 flashes** | the judge's bytes were not `judge.sha256`'s, or it did not HALT (the shell's) |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## On the board

Not yet run.

## What the RTL checks, and what it cannot

On the Hazard3 RTL both kernels run for real:

| Stand-in TRNG | Verdict |
| --- | --- |
| an LCG whose bits pass | ok: the judge halts with 0 |
| all ones | 3: exp223's kernel withholds them, and the judge says so |
| nothing | 2, before anything runs |

Seven wrong shells or expectations are caught. Five of them are caught by the
judge, whose code names the source and the check:
- the kernel's hash is wrong: source 0, check 1;
- the healthy count is off by one: source 0, check 3;
- the broken source is made fair: verdict 4, source 2;
- the digest is held against the wrong SHA-256: source 0, check 4;
- the scratch is not cleared: source 0, check 5.

The last two are caught by the shell, which is what is left of it:
- the judge's own hash is wrong: 5;
- the shell traps.

**And one is not caught, on purpose.** A shell that writes a byte into the
region after the run, and then hands the judge the hash from before instead of
the hash after, comes out ok. The judge can only judge the facts it is given.
The trust that was in the shell's checks is now in its gathering, and this
experiment draws that line rather than hiding it.

## What it does not say

- **That the facts are true.** The shell gathers them, in C, and is not
  proved. See above.
- **That the hashes are right.** `sha256.c` and the SHA-256 block compute
  them. The judge only compares them.
- **That the harness and the trap are as the model has them.** The Lean
  model has no Machine mode, no CSRs and no PMP.
  [WHY.zh-TW.md](./WHY.zh-TW.md) §3 says what extending it would take.
- **How long the judge runs.** There is no exact count, because it depends
  on the records.
- **More than one run.**

## Running it

```sh
./check.sh       # the proof and mutants, judge.bin, the differential, the build, the UF2, the RTL
./build.sh       # build/exp224.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
Half an hour, most of it the RTL hashing the 128 KiB region for each wrong
shell.

## Expected output

To be pasted from `capture.txt` once `run.sh` has recorded it.
