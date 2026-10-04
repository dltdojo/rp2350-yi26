# exp203 — the count the proof promised

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Sixty bytes of RV32IM, proved in Lean to copy 64 bytes and halt with 0 at
exactly instruction 105 — for every base address, every input and every
register. The model runs the same bytes in 105; the Hazard3 RTL retires 108.
The 3 is the harness's, measured, constant, and spent in a way the RISC-V
privileged specification says it should not be: Hazard3 counts `ecall`, counts
`mret` twice, and counts them differently depending on what lies in memory
behind them.**

This is phase 0 of the design this road follows (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md)), in its cloud half: one minimal program all the way through — written in Lean,
proved, emitted as bytes, run, and its instruction count checked. Everything
after it is the same path with a bigger program.

## The kernel

```text
  0000  00000517  auipc x10, 0          a0 = base, wherever that is
  0004  00001337  lui x6, 1
  0008  00650333  add x6, x10, x6       t1 = base + 0x1000   the source
  000c  000023b7  lui x7, 2
  0010  007503b3  add x7, x10, x7       t2 = base + 0x2000   the destination
  0014  01000e13  addi x28, x0, 16      t3 = 16 words
  0018  00032e83  lw x29, 0(x6)     ┐
  001c  01d3a023  sw x29, 0(x7)     │
  0020  00430313  addi x6, x6, 4    │   sixteen times
  0024  00438393  addi x7, x7, 4    │
  0028  fffe0e13  addi x28, x28, -1 │
  002c  fe0e16e3  bne x28, x0, -20  ┘
  0030  00100293  addi x5, x0, 1        t0 = 1: HALT
  0034  00000513  addi x10, x0, 0       a0 = 0: the result
  0038  00000073  ecall
```

`kernel.bin` is exactly these sixty bytes; its SHA-256 is in `kernel.sha256`,
and that number is what the chip's shell will compare against before it runs
anything. `check.sh` has Lean write the bytes again and requires them to be the
committed file, so the file cannot drift from the proof.

It finds its own address with `auipc` instead of being linked to one. That is
not style: the RTL testbench puts the region at `0x80010000`, the chip's shell
will put it in SRAM at `0x20070000`, and a kernel linked to one address would
be two binaries. This one is one, and the theorems are stated for every base.

## What is proved

[`proof/Copy64.lean`](./proof/Copy64.lean), against the model exp202 tested:

| Theorem | Says |
| --- | --- |
| `copies` | it halts with 0 within 105 instructions; the 64 bytes at `base + 0x2000` are then those at `base + 0x1000`; every other byte is what it was |
| `exactly_105` | after 104 instructions it is still running — no halt, no fault — so it is exactly 105 |
| `code_of_image` | any image that begins with the kernel's sixty bytes, loaded at `base`, holds the kernel |
| `from_boot` | all of it, from `boot` — the state `rv32run` and the RTL harness both start from |

The design asked for block contracts, so that changing one part means re-proving
that part: `setup` (six instructions), `iter` (one turn of the loop, carrying the
invariant `Inv`), `halt` (three), and `loop` and `to_the_ecall` only compose
them. All of it rests on `propext`, `Classical.choice` and `Quot.sound`, and no
`native_decide`.

`exactly_105` is what makes the number mean something. A bound alone — "halts
within 105" — would be true of a kernel that halts after 3. Seven wrong versions
in [`proof/mutants.txt`](./proof/mutants.txt) are each refused: three wrong
kernels (60 bytes copied, the source written back to itself, a branch one
instruction too far) and four wrong claims about the right one (halts within
104, still running at 105, copies 65 bytes, a base that is only even).

## What the core counts

| | count |
| --- | --- |
| the proof | 105 |
| the model, run (`rv32run`) | 105, on all four data sets, at `0x80010000` and at `0x20070000` |
| the Hazard3 RTL, `minstret` | 108, on all four |

The model and the RTL leave the whole 64 KiB region byte for byte the same, and
a Python check that does not use the model agrees that the destination is the
source and the canaries either side of it are untouched.

The 3 is the harness. [`accounting/measure.sh`](./accounting/measure.sh) runs
payloads of `k` `nop`s and a HALT through the same harness, for `k` from 0 to 7:
the model counts `k + 2`, the RTL `k + 5`, every time. So each instruction the
proof counts, the core counts once, and a proof's count plus 3 is the RTL's
count — for this harness.

Where the 3 goes is the finding. [`accounting/counts.S`](./accounting/counts.S)
measures it one instruction at a time, with nothing else running:

| measured | counted |
| --- | --- |
| the write that starts counting (`mcountinhibit = 0`) | 0 |
| the write that stops it | 1 |
| one `mret` | 2 |
| `mret` into User mode, then `ecall` | 4 |
| `mret` into User mode, then an illegal instruction | 3 |
| `mret` into User mode, `nop`, `ecall` | **5 — or 4**, when the trap handler happens to sit in memory right behind the `mret` |

The RISC-V privileged specification says of `ecall` that, causing an exception,
it is "not considered to retire, and should not increment the `minstret` CSR".
Hazard3 increments it. And the last row is not a property of any instruction at
all: the same four instructions are counted 5 or 4 depending only on what the
frontend has fetched behind the `mret`. The RTL's own expression says why —
`x_instr_ret = |df_cir_use && (x_except == EXCEPT_NONE || x_except_counts_as_retire)`
counts an instruction when *decode* hands it on, gated by whether the
instruction then in execute is one of the exceptions it lists as retiring (`mret`
and `ecall` are), so an instruction fetched behind an `mret` and then flushed
can be counted.

What this means for the road: **an instruction count read from `minstret` is a
proof's count plus a constant that belongs to the shell, and that constant has
to be measured for the exact shell code, not derived from the specification.**
Every kernel after this one calls `ecall` for HASH in the middle of its run, and
each such call will carry a cost of its own to measure. And the RP2350 runs an
earlier Hazard3 than the one simulated here — v1.0-rc1, whose `mimpid` the
Hazard3 documentation gives as `86fc4e3f`, against a 2026 commit of the v1.1
line — so whether the chip counts the same way is the first question this
road's board half asks.

## What it does not prove

- **That the model is the chip.** The theorems are about `Rv32.step`; exp202 is
  the evidence that `step` is RV32IM, on 53 programs, and the board half of this
  road is where it meets silicon.
- **Anything about time.** The RTL takes 113 cycles on every data set here, and
  that is an observation, not a theorem: constant time is a later experiment's
  claim, with a relational proof.
- **Overlapping source and destination.** They are fixed, 4 KiB apart. A copy
  that may overlap is a different program.
- **The shell.** Loading `kernel.bin`, checking its hash, setting PMP and
  entering User mode are the harness's here and the Rust shell's on the chip.
  The theorems start from the state they are supposed to build.

## Running it

```sh
../../tools/lean/setup.sh      # once, needs the network: Lean 4.34.0, 580 MB
../../tools/hazard3/setup.sh   # once, needs the network: the Hazard3 RTL, built with Verilator
./check.sh                     # no board: the proof, seven mutants, kernel.bin, the count on the RTL
./run.sh                       # records capture.txt
```

No board and nobody. `clang`, `lld` and `llvm-objcopy` for the images. The proof
checks in a few seconds; the mutants take about a minute.

## Expected output

```text
=== exp203 — the count the proof promised ===
recorded at 2026-10-02T09:33:49Z from commit 559e7b0

>>> the kernel, as the proof states it and as kernel.bin holds it
  0000  00000517  auipc x10, 0
  0004  00001337  lui x6, 1
  0008  00650333  add x6, x10, x6
  000c  000023b7  lui x7, 2
  0010  007503b3  add x7, x10, x7
  0014  01000e13  addi x28, x0, 16
  0018  00032e83  lw x29, 0(x6)
  001c  01d3a023  sw x29, 0(x7)
  0020  00430313  addi x6, x6, 4
  0024  00438393  addi x7, x7, 4
  0028  fffe0e13  addi x28, x28, -1
  002c  fe0e16e3  bne x28, x0, -20
  0030  00100293  addi x5, x0, 1
  0034  00000513  addi x10, x0, 0
  0038  00000073  ecall
    sha256 a23ae89b0c8e2eaa9e74b07b6ff3cd92e860f189feee101739d5f89ac09abd3e  (60 bytes)
    byte for byte the committed kernel.bin

>>> the theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Exp203.bytes_words' depends on axioms: [propext]
'Exp203.code_of_image' depends on axioms: [propext, Quot.sound]
'Exp203.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp203.loop' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp203.halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp203.copies' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp203.exactly_105' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp203.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
kernel  the loop counter starts at 15, so 60 bytes are copied                          refused in setup
kernel  the store goes through the source pointer, writing the source back to itself   refused in iter
kernel  the branch goes back one instruction too far                                   refused in iter
count   it is claimed to halt within 104 instructions                                  refused in copies
count   it is claimed still to be running after 105                                    refused in exactly_105
copy    it is claimed to copy 65 bytes                                                 refused in copies
place   the base is only required to be even, not a multiple of four                   refused in stepK

>>> what the RTL counts that the model does not
  k   model   RTL minstret   RTL − model
  0       2              5             3
  1       3              6             3
  2       4              7             3
  3       5              8             3
  4       6              9             3
  5       7             10             3
  6       8             11             3
  7       9             12             3
PASS  every instruction the model counts, the RTL counts once: RTL − model = 3 for k = 0..7

  measurement                                    apart  adjacent
  1  enable; read                                    0         0
  2  enable; disable; read                           1         1
  3  enable; nop; disable; read                      2         2
  4  enable; mret to Machine                         2         2
  5  enable; mret to User; ecall                     4         4
  6  enable; mret to User; illegal instruction       3         3
  7  enable; mret to User; nop; ecall                5         4
PASS  the write that starts counting is not counted, the write that stops it is
PASS  one mret is counted as two
PASS  an ecall is counted at all — the privileged specification says it should not be
PASS  the same instructions count differently when only what lies behind an mret changes (5 and 4)

>>> the kernel on the model and on the RTL
data         model at 0x80010000        RTL                              model at 0x20070000
alternating  halt code=00000000 count=105 halt code=00000000 instret=108 cycles=113 halt code=00000000 count=105
counting     halt code=00000000 count=105 halt code=00000000 instret=108 cycles=113 halt code=00000000 count=105
ones         halt code=00000000 count=105 halt code=00000000 instret=108 cycles=113 halt code=00000000 count=105
random       halt code=00000000 count=105 halt code=00000000 instret=108 cycles=113 halt code=00000000 count=105

PASS  the model halts with 0 after exactly 105 instructions, the number proved, on all 4 data sets
PASS  the RTL halts with 0 and counts 108 = 105 proved + 3 for the harness, on all 4
PASS  the whole region is byte for byte the same on both, on all 4
PASS  Python agrees: the destination is the source and nothing else changed, on all 4
PASS  at 0x20070000 the same bytes halt with 0 after 105, on all 4
```

There is no board half here: the RTL is the chip's core, simulated on this
machine. Whether silicon counts 108 is exp209's question.
