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

`run.sh`'s recording, [`capture.txt`](./capture.txt), pasted:

```text
=== exp224 — the checks the kernel makes ===
recorded at 2026-10-09T03:34:11Z from commit a2160f1

>>> the judge, as proof/Judge.lean writes it
  0000  00000417  auipc x8, 0
  0004  00001337  lui x6, 1
  0008  006404b3  add x9, x8, x6
  000c  00000913  addi x18, x0, 0
  0010  00000a13  addi x20, x0, 0
  0014  0204a303  lw x6, 32(x9)
  0018  0404a383  lw x7, 64(x9)
  001c  00734333  xor x6, x6, x7
  0020  006a6a33  or x20, x20, x6
  0024  0244a303  lw x6, 36(x9)
  0028  0444a383  lw x7, 68(x9)
  002c  00734333  xor x6, x6, x7
  0030  006a6a33  or x20, x20, x6
  0034  0284a303  lw x6, 40(x9)
  0038  0484a383  lw x7, 72(x9)
  003c  00734333  xor x6, x6, x7
  0040  006a6a33  or x20, x20, x6
  0044  02c4a303  lw x6, 44(x9)
  0048  04c4a383  lw x7, 76(x9)
  004c  00734333  xor x6, x6, x7
  0050  006a6a33  or x20, x20, x6
  0054  0304a303  lw x6, 48(x9)
  0058  0504a383  lw x7, 80(x9)
  005c  00734333  xor x6, x6, x7
  0060  006a6a33  or x20, x20, x6
  0064  0344a303  lw x6, 52(x9)
  0068  0544a383  lw x7, 84(x9)
  006c  00734333  xor x6, x6, x7
  0070  006a6a33  or x20, x20, x6
  0074  0384a303  lw x6, 56(x9)
  0078  0584a383  lw x7, 88(x9)
  007c  00734333  xor x6, x6, x7
  0080  006a6a33  or x20, x20, x6
  0084  03c4a303  lw x6, 60(x9)
  0088  05c4a383  lw x7, 92(x9)
  008c  00734333  xor x6, x6, x7
  0090  006a6a33  or x20, x20, x6
  0094  00000a93  addi x21, x0, 0
  0098  0604a303  lw x6, 96(x9)
  009c  0804a383  lw x7, 128(x9)
  00a0  00734333  xor x6, x6, x7
  00a4  006aeab3  or x21, x21, x6
  00a8  0644a303  lw x6, 100(x9)
  00ac  0844a383  lw x7, 132(x9)
  00b0  00734333  xor x6, x6, x7
  00b4  006aeab3  or x21, x21, x6
  00b8  0684a303  lw x6, 104(x9)
  00bc  0884a383  lw x7, 136(x9)
  00c0  00734333  xor x6, x6, x7
  00c4  006aeab3  or x21, x21, x6
  00c8  06c4a303  lw x6, 108(x9)
  00cc  08c4a383  lw x7, 140(x9)
  00d0  00734333  xor x6, x6, x7
  00d4  006aeab3  or x21, x21, x6
  00d8  0704a303  lw x6, 112(x9)
  00dc  0904a383  lw x7, 144(x9)
  00e0  00734333  xor x6, x6, x7
  00e4  006aeab3  or x21, x21, x6
  00e8  0744a303  lw x6, 116(x9)
  00ec  0944a383  lw x7, 148(x9)
  00f0  00734333  xor x6, x6, x7
  00f4  006aeab3  or x21, x21, x6
  00f8  0784a303  lw x6, 120(x9)
  00fc  0984a383  lw x7, 152(x9)
  0100  00734333  xor x6, x6, x7
  0104  006aeab3  or x21, x21, x6
  0108  07c4a303  lw x6, 124(x9)
  010c  09c4a383  lw x7, 156(x9)
  0110  00734333  xor x6, x6, x7
  0114  006aeab3  or x21, x21, x6
  0118  00000b13  addi x22, x0, 0
  011c  0a04a303  lw x6, 160(x9)
  0120  0c04a383  lw x7, 192(x9)
  0124  00734333  xor x6, x6, x7
  0128  006b6b33  or x22, x22, x6
  012c  0a44a303  lw x6, 164(x9)
  0130  0c44a383  lw x7, 196(x9)
  0134  00734333  xor x6, x6, x7
  0138  006b6b33  or x22, x22, x6
  013c  0a84a303  lw x6, 168(x9)
  0140  0c84a383  lw x7, 200(x9)
  0144  00734333  xor x6, x6, x7
  0148  006b6b33  or x22, x22, x6
  014c  0ac4a303  lw x6, 172(x9)
  0150  0cc4a383  lw x7, 204(x9)
  0154  00734333  xor x6, x6, x7
  0158  006b6b33  or x22, x22, x6
  015c  0b04a303  lw x6, 176(x9)
  0160  0d04a383  lw x7, 208(x9)
  0164  00734333  xor x6, x6, x7
  0168  006b6b33  or x22, x22, x6
  016c  0b44a303  lw x6, 180(x9)
  0170  0d44a383  lw x7, 212(x9)
  0174  00734333  xor x6, x6, x7
  0178  006b6b33  or x22, x22, x6
  017c  0b84a303  lw x6, 184(x9)
  0180  0d84a383  lw x7, 216(x9)
  0184  00734333  xor x6, x6, x7
  0188  006b6b33  or x22, x22, x6
  018c  0bc4a303  lw x6, 188(x9)
  0190  0dc4a383  lw x7, 220(x9)
  0194  00734333  xor x6, x6, x7
  0198  006b6b33  or x22, x22, x6
  019c  0004ae03  lw x28, 0(x9)
  01a0  0044ae83  lw x29, 4(x9)
  01a4  0084af03  lw x30, 8(x9)
  01a8  00c4af83  lw x31, 12(x9)
  01ac  0104a583  lw x11, 16(x9)
  01b0  0144a603  lw x12, 20(x9)
  01b4  0184a683  lw x13, 24(x9)
  01b8  008e4713  xori x14, x28, 8
  01bc  00173713  sltiu x14, x14, 1
  01c0  001ec793  xori x15, x29, 1
  01c4  0017b793  sltiu x15, x15, 1
  01c8  00f77733  and x14, x14, x15
  01cc  001f3793  sltiu x15, x30, 1
  01d0  01403833  sltu x16, x0, x20
  01d4  0016b893  sltiu x17, x13, 1
  01d8  01186833  or x16, x16, x17
  01dc  002f3893  sltiu x17, x30, 2
  01e0  00e8f8b3  and x17, x17, x14
  01e4  0018c893  xori x17, x17, 1
  01e8  00bfc333  xor x6, x31, x11
  01ec  00603333  sltu x6, x0, x6
  01f0  00f37333  and x6, x6, x15
  01f4  00cfc3b3  xor x7, x31, x12
  01f8  007033b3  sltu x7, x0, x7
  01fc  0017ce13  xori x28, x15, 1
  0200  01c3f3b3  and x7, x7, x28
  0204  00736333  or x6, x6, x7
  0208  015033b3  sltu x7, x0, x21
  020c  00e3f3b3  and x7, x7, x14
  0210  00f3f3b3  and x7, x7, x15
  0214  01603e33  sltu x28, x0, x22
  0218  00189893  slli x17, x17, 1
  021c  00231313  slli x6, x6, 2
  0220  00339393  slli x7, x7, 3
  0224  004e1e13  slli x28, x28, 4
  0228  01186833  or x16, x16, x17
  022c  00686833  or x16, x16, x6
  0230  00786833  or x16, x16, x7
  0234  01c86833  or x16, x16, x28
  0238  00080e63  beq x16, x0, 28
  023c  00681513  slli x10, x16, 6
  0240  00391313  slli x6, x18, 3
  0244  00656533  or x10, x10, x6
  0248  00156513  ori x10, x10, 1
  024c  00100293  addi x5, x0, 1
  0250  00000073  ecall
  0254  00091a63  bne x18, x0, 20
  0258  020f0463  beq x30, x0, 40
  025c  00300513  addi x10, x0, 3
  0260  00100293  addi x5, x0, 1
  0264  00000073  ecall
  0268  ffff0313  addi x6, x30, -1
  026c  00030a63  beq x6, x0, 20
  0270  00391513  slli x10, x18, 3
  0274  00456513  ori x10, x10, 4
  0278  00100293  addi x5, x0, 1
  027c  00000073  ecall
  0280  10048493  addi x9, x9, 256
  0284  00190913  addi x18, x18, 1
  0288  00300313  addi x6, x0, 3
  028c  d86912e3  bne x18, x6, -636
  0290  00000513  addi x10, x0, 0
  0294  00100293  addi x5, x0, 1
  0298  00000073  ecall

>>> the theorems, and what they rest on
'Exp224.checks_spec' depends on axioms: [propext, Quot.sound]
'Exp224.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp224.judges' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp224.bytes_words' depends on axioms: [propext]
'Exp224.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
checks_spec  check 1 forgets the SHA-256 block's error flag             refused in checks_spec
checks_spec  t0 = 3 counts as HALT                                      refused in checks_spec
checks_spec  halting with 2 passes check 2                              refused in checks_spec
checks_spec  minstret is held to the HALT 0 count whatever the code     refused in checks_spec
checks_spec  the digest is checked after HALT 1 too                     refused in checks_spec
body_run     the digest is compared with itself                         refused in body_run
body_run     the region's hash after is compared with itself            refused in body_run
iter         a failure's code puts the source one bit too high          refused in iter
iter         the TRNG withheld is reported as 4                         refused in iter
iter         a broken source counts as withheld when it halted with 0   refused in iter
next_run     only two records are judged                                refused in next_run
setup_run    the records are said to start at 0x1100                    refused in setup_run
judges       a later record's verdict is said to come first             refused in judges

>>> the differential: the Lean model and the Hazard3 RTL against the specification in Python
PASS  as on the chip: the TRNG passed, both broken sources withheld: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  source 0: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  source 0: the SHA-256 block reported an error: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  source 0: it faulted, mcause 5: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  source 0: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  source 0: it halted with 2: the model and the RTL halt with 0x181 (verdict 1, source 0, failures 00110), the model's region untouched
PASS  source 0: one instruction more than the RTL's: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  source 0: the region's hash changed: the model and the RTL halt with 0x401 (verdict 1, source 0, failures 10000), the model's region untouched
PASS  source 1: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  source 1: the SHA-256 block reported an error: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  source 1: it faulted, mcause 5: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: it halted with 2: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: one instruction more than the RTL's: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  source 1: the region's hash changed: the model and the RTL halt with 0x409 (verdict 1, source 1, failures 10000), the model's region untouched
PASS  source 2: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  source 2: the SHA-256 block reported an error: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  source 2: it faulted, mcause 5: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: it halted with 2: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: one instruction more than the RTL's: the model and the RTL halt with 0x111 (verdict 1, source 2, failures 00100), the model's region untouched
PASS  source 2: the region's hash changed: the model and the RTL halt with 0x411 (verdict 1, source 2, failures 10000), the model's region untouched
PASS  source 0: the digest is not the samples' SHA-256: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  source 1: a wrong digest, but it halted with 1, so check 4 does not apply: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  source 0: the TRNG's samples withheld, HALT 1: the model and the RTL halt with 0x3 (verdict 3, source 0, failures 00000), the model's region untouched
PASS  source 1: let through, HALT 0: the model and the RTL halt with 0xc (verdict 4, source 1, failures 00000), the model's region untouched
PASS  source 2: let through, HALT 0: the model and the RTL halt with 0x14 (verdict 4, source 2, failures 00000), the model's region untouched
PASS  source 0: withheld and a wrong count: the failure wins: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  source 1 let through, source 2 faulted: the first one wins: the model and the RTL halt with 0xc (verdict 4, source 1, failures 00000), the model's region untouched
PASS  source 0: every check fails: the model and the RTL halt with 0x741 (verdict 1, source 0, failures 11101), the model's region untouched
PASS  random 0: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 1: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 2: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 3: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 4: the model and the RTL halt with 0x241 (verdict 1, source 0, failures 01001), the model's region untouched
PASS  random 5: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 6: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 7: the model and the RTL halt with 0x401 (verdict 1, source 0, failures 10000), the model's region untouched
PASS  random 8: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  random 9: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 10: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 11: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 12: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 13: the model and the RTL halt with 0x411 (verdict 1, source 2, failures 10000), the model's region untouched
PASS  random 14: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  random 15: the model and the RTL halt with 0x491 (verdict 1, source 2, failures 10010), the model's region untouched
PASS  random 16: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 17: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  random 18: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 19: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 20: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 21: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 22: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  random 23: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 24: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 25: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 26: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 27: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 28: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  random 29: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched

>>> the shell, for the chip and for the RTL
build/expect.h: exp223's kernel 8995effdbd2aba7a…, RTL minstret 334287 conditioned, 17428 withheld; judge cf2b695c8d26a562…
build/exp224.bin  13508 bytes, the build allows 16384
build/exp224.uf2  27136 bytes  sha256 2ae0e1cf75d240be498a3bae453680870135dad44b9a71e1b30b00af791eed89

>>> on the RTL, exp223's kernel and the judge for real: REPT verdict source failed code minstret cause
52455054 00000000 00000000 00000000 00000000 000001bf 00000008 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Judge.lean checks, with no errors and no warnings
PASS  all 5 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  checks_spec: the proof refuses a version where check 1 forgets the SHA-256 block's error flag
PASS  checks_spec: the proof refuses a version where t0 = 3 counts as HALT
PASS  checks_spec: the proof refuses a version where halting with 2 passes check 2
PASS  checks_spec: the proof refuses a version where minstret is held to the HALT 0 count whatever the code
PASS  checks_spec: the proof refuses a version where the digest is checked after HALT 1 too
PASS  body_run: the proof refuses a version where the digest is compared with itself
PASS  body_run: the proof refuses a version where the region's hash after is compared with itself
PASS  iter: the proof refuses a version where a failure's code puts the source one bit too high
PASS  iter: the proof refuses a version where the TRNG withheld is reported as 4
PASS  iter: the proof refuses a version where a broken source counts as withheld when it halted with 0
PASS  next_run: the proof refuses a version where only two records are judged
PASS  setup_run: the proof refuses a version where the records are said to start at 0x1100
PASS  judges: the proof refuses a version where a later record's verdict is said to come first
PASS  judge.bin is what proof/Judge.lean writes, 668 bytes, and judge.sha256 is its hash
PASS  as on the chip: the TRNG passed, both broken sources withheld: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  source 0: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  source 0: the SHA-256 block reported an error: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  source 0: it faulted, mcause 5: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  source 0: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  source 0: it halted with 2: the model and the RTL halt with 0x181 (verdict 1, source 0, failures 00110), the model's region untouched
PASS  source 0: one instruction more than the RTL's: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  source 0: the region's hash changed: the model and the RTL halt with 0x401 (verdict 1, source 0, failures 10000), the model's region untouched
PASS  source 1: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  source 1: the SHA-256 block reported an error: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  source 1: it faulted, mcause 5: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: it halted with 2: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  source 1: one instruction more than the RTL's: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  source 1: the region's hash changed: the model and the RTL halt with 0x409 (verdict 1, source 1, failures 10000), the model's region untouched
PASS  source 2: the kernel's hash is not kernel.sha256's: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  source 2: the SHA-256 block reported an error: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  source 2: it faulted, mcause 5: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: an ecall that was not HALT, t0 0: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: it halted with 2: the model and the RTL halt with 0x91 (verdict 1, source 2, failures 00010), the model's region untouched
PASS  source 2: one instruction more than the RTL's: the model and the RTL halt with 0x111 (verdict 1, source 2, failures 00100), the model's region untouched
PASS  source 2: the region's hash changed: the model and the RTL halt with 0x411 (verdict 1, source 2, failures 10000), the model's region untouched
PASS  source 0: the digest is not the samples' SHA-256: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  source 1: a wrong digest, but it halted with 1, so check 4 does not apply: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  source 0: the TRNG's samples withheld, HALT 1: the model and the RTL halt with 0x3 (verdict 3, source 0, failures 00000), the model's region untouched
PASS  source 1: let through, HALT 0: the model and the RTL halt with 0xc (verdict 4, source 1, failures 00000), the model's region untouched
PASS  source 2: let through, HALT 0: the model and the RTL halt with 0x14 (verdict 4, source 2, failures 00000), the model's region untouched
PASS  source 0: withheld and a wrong count: the failure wins: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  source 1 let through, source 2 faulted: the first one wins: the model and the RTL halt with 0xc (verdict 4, source 1, failures 00000), the model's region untouched
PASS  source 0: every check fails: the model and the RTL halt with 0x741 (verdict 1, source 0, failures 11101), the model's region untouched
PASS  random 0: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 1: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 2: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 3: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 4: the model and the RTL halt with 0x241 (verdict 1, source 0, failures 01001), the model's region untouched
PASS  random 5: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 6: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 7: the model and the RTL halt with 0x401 (verdict 1, source 0, failures 10000), the model's region untouched
PASS  random 8: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  random 9: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 10: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 11: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 12: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 13: the model and the RTL halt with 0x411 (verdict 1, source 2, failures 10000), the model's region untouched
PASS  random 14: the model and the RTL halt with 0x41 (verdict 1, source 0, failures 00001), the model's region untouched
PASS  random 15: the model and the RTL halt with 0x491 (verdict 1, source 2, failures 10010), the model's region untouched
PASS  random 16: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 17: the model and the RTL halt with 0x89 (verdict 1, source 1, failures 00010), the model's region untouched
PASS  random 18: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 19: the model and the RTL halt with 0x51 (verdict 1, source 2, failures 00001), the model's region untouched
PASS  random 20: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 21: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  random 22: the model and the RTL halt with 0x49 (verdict 1, source 1, failures 00001), the model's region untouched
PASS  random 23: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 24: the model and the RTL halt with 0x109 (verdict 1, source 1, failures 00100), the model's region untouched
PASS  random 25: the model and the RTL halt with 0x201 (verdict 1, source 0, failures 01000), the model's region untouched
PASS  random 26: the model and the RTL halt with 0x81 (verdict 1, source 0, failures 00010), the model's region untouched
PASS  random 27: the model and the RTL halt with 0x0 (verdict 0, source 0, failures 00000), the model's region untouched
PASS  random 28: the model and the RTL halt with 0x101 (verdict 1, source 0, failures 00100), the model's region untouched
PASS  random 29: the model and the RTL halt with 0xc1 (verdict 1, source 0, failures 00011), the model's region untouched
PASS  the shell builds for the chip and for the RTL, the chip's in 13508 of the 16384 bytes it may use
PASS  all 53 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 13508-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20060000
PASS  the UF2 is byte for byte the committed one: 2ae0e1cf75d240be…
PASS  on the RTL, against a stand-in TRNG that works: the judge halts with 0 — ok
PASS  on the RTL, against a stand-in TRNG giving all ones: exp223's kernel withholds, and the judge says so — verdict 3, source 0
PASS  on the RTL, against a stand-in TRNG giving nothing: verdict 2, from the shell, before anything runs
PASS  the shell catches a version where kernel.sha256 is not exp223's kernel's hash — the judge: source 0, check 1 (code 0x41)
PASS  the shell catches a version where the chip is asked to count one more when healthy — the judge: source 0, check 3 (code 0x101)
PASS  the shell catches a version where the broken source is made fair, and exp223's kernel lets it through — the judge: verdict 4, source 2 (code 0x14)
PASS  the shell catches a version where the digest is held against SHA-256 of one block fewer — the judge: source 0, check 4 (code 0x201)
PASS  the shell catches a version where the digest and its scratch are not cleared before the region is hashed again — the judge: source 0, check 5 (code 0x401)
PASS  the shell catches a version where judge.sha256 is not judge.bin's hash — verdict 5, the one check left in the shell
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
PASS  a shell that lies — scribbles on the region, then hands the judge the hash from before — is NOT caught: verdict 0. The judge can only judge the facts it is given
```
