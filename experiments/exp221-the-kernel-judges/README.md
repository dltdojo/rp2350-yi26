# exp221 — the kernel judges

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp220 again, with one thing moved: the comparison. PIO0 and PIO1 still
run `invert` and `reverse`, and every word still goes through them both
ways. The shell no longer decides whether the two orders agreed. It writes
the first order's 16 words and the second order's 16 into memory, and a new
RV32IM kernel, proved in Lean, compares them and halts with its verdict.
That gives one CPU and two PIO blocks, each running proved bytes, and the
proved CPU bytes have the last word. Not yet run on a board.**

## The kernel

[`proof/Same.lean`](./proof/Same.lean): 73 instructions, 292 bytes,
[`kernel.bin`](./kernel.bin).

```text
  0     auipc s0, 0                  s0 = base
  1-2   s1 = base + 0x1000           the first list
  3-4   s2 = base + 0x2000           the second
  5     s6 = 0                       the accumulator
  6-37  words 0..7:  lw t2; lw t3; xor t2, t2, t3; or s6, s6, t2
  38-69 words 8..15: the same, 32 bytes on
  70    sltu a0, x0, s6              a0 = (s6 ≠ 0)
  71    addi t0, x0, 1
  72    ecall                        HALT a0
```

The two compare blocks are `lean/Rv32/Blocks.lean`'s `compare_words`,
which exp204 and exp205 already stand on. No new library code was needed.

| Theorem | Says |
| --- | --- |
| `compared` | after setup and both blocks, the accumulator is zero exactly when the two lists of sixteen words are the same, and memory is untouched |
| `judges` | from `base`, it halts after exactly 73 instructions, whatever the lists hold: with 0 if they are the same and 1 if they are not, and memory just as it was |
| `from_boot` | the same from any image that begins with the kernel's 292 bytes, which is what the shell builds |
| `bytes_words` | `kernel.bin`'s words are the encodings of those instructions |

All rest on Lean's own axioms. Five wrong kernels in
[`proof/mutants.txt`](./proof/mutants.txt) are each refused:
- the second block compares the first eight words again;
- the second list is looked for 0x1000 bytes late;
- differences are combined with `and`;
- the verdict is tested the wrong way round;
- the `ecall` asks for HASH.

`gen.py` also runs the Lean model on the bytes before anything is built:
- on two equal lists it halts with 0 after 73 instructions;
- on lists one bit apart it halts with 1, also after 73.

## What runs, in order

| Step | What the shell does | Which theorem says what should happen |
| --- | --- | --- |
| 1 | takes PIO0 and PIO1 out of reset, loads `invert` and `reverse`, and starts both | exp220 `waits` |
| 2 | sends each of the message's 16 words both ways. It checks what each block gives back alone, but never what the two orders end with: those go to `base + 0x1000` and `base + 0x2000`. Then all four FIFOs must be empty | exp220 `every_word`; by `either_order` the two lists should be the same |
| 3 | puts the kernel's 292 bytes at `base`, checks them against `kernel.sha256`, and hashes the whole region | `code_of_image` |
| 4 | runs the kernel in User mode | — |
| 5 | checks that the kernel halted with 0 or 1, that the region is unchanged, and that `minstret` is the RTL's 76. The kernel's code is then the verdict | `judges` |

The message is

```text
exp221: PIO0 and PIO1 answer, and a proved RV32IM kernel judges.
```

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp221.uf2.sha256`](./exp221.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp221.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for a few seconds.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | the kernel judged the two orders the same: HALT 0 |
| **1 flash**, repeated | the kernel's side: its bytes, its halting, the memory it left, or `minstret` |
| **2 flashes** | PIO0 never came out of reset |
| **3 flashes** | PIO1 never came out of reset |
| **4 flashes** | a word went into a block and nothing came back |
| **5 flashes** | PIO0 gave back something other than the word complemented |
| **6 flashes** | PIO1 gave back something other than the word reversed |
| **7 flashes** | the kernel judged the two orders different: HALT 1 |
| **8 flashes** | a FIFO still held something before the kernel ran |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## What the RTL checks, and what it cannot

On the Hazard3 RTL the kernel runs for real on whatever the stand-in blocks
gave back ([`shell/board_sim.c`](./shell/board_sim.c)). The stand-ins are
not a model of PIO.

| Stand-in | Verdict |
| --- | --- |
| two blocks that work | ok: the kernel halts with 0 at `minstret` 76 |
| PIO1 never leaves reset | 3 |
| PIO1 hands words back unreversed | 6, on the first word |
| PIO0 right on its own, wrong the second way round | **7: the kernel, run for real, halts with 1** |
| PIO0 never answers | 4, on the first word |
| PIO1 leaves a word in RX | 8 |

The fourth row is the one this experiment is about. Each block passed the
shell's own checks, and only the proved kernel saw that the two orders
disagreed.

Four wrong shells or expectations are caught:
- the kernel's hash is wrong;
- the chip is asked to count 75;
- the shell flips a bit in the first list, which the kernel finds;
- the shell traps itself.

## What it does not say

- **That the blocks and the kernel talk to each other.** The shell carries
  every word and is not proved. What is proved is what each of the three
  does to the words it is given.
- **That the two lists are the right words.** The kernel judges whether
  they are the same, which is what `either_order` predicts. The shell checks
  each block's single answers on the way.
- **Timing.** One bit, read after everything; one run.

## Running it

```sh
./check.sh       # the proofs and mutants, kernel.bin, the build, the UF2, the RTL against six stand-ins
./build.sh       # build/exp221.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
A few minutes, most of it the mutants.

## Expected output

```text
CAPTURE
```
