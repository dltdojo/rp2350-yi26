# exp220 — either order

<!-- SPDX-License-Identifier: Apache-2.0 -->

**One CPU and two PIO blocks on a Pico 2, each running bytes a Lean theorem
is about:**
- **CPU:** exp203's copy kernel.
- **PIO0:** `invert`.
- **PIO1:** `reverse`.

The kernel copies a fixed 64-byte message. Each of the 16 copied words then
goes through PIO0 and PIO1 in both orders. Both orders must give the same
word, because complementing a word and reversing its bits commute. That
fact is new here, proved as `either_order`. Not yet run on a board.

exp219 put proved bytes on the CPU and on one PIO block. This one adds a
second block, and with it a question about how the two compose. The answer
comes from a new theorem rather than from running both.

## What is proved

[`proof/Through.lean`](./proof/Through.lean) proves one PIO program once,
with its middle instruction as a parameter `o`, one of `mov`'s three
operations:

```text
  0  pull block          OSR <- TX, waiting while it is empty
  1  mov isr, o osr      ISR <- o(OSR)
  2  push block          RX <- ISR       → wrap to 0
```

Two instances of it run on the chip:
- **PIO0:** `invert` (`o` = `~`): `80a0 a0cf 8020`, exp214's words. The
  theorem `words_invert` says so, and `gen.py` checks them against exp217's
  `prog`.
- **PIO1:** `reverse` (`o` = `::`): `80a0 a0d7 8020`, by `words_reverse`.

| Theorem | Says |
| --- | --- |
| `every_word` | for either instance, from the top, any words in TX that fit come back through RX with `o` applied, in order, three steps each |
| `waits` | for either, with TX empty a step changes nothing |
| `commute` | `reverse (~w) = ~(reverse w)` for every 32-bit `w` |
| `either_order` | a list of words through `invert` then `reverse` is the same list as through `reverse` then `invert` |

`commute` takes one line because `lean/Pio/Machine.lean`'s `reverse32` is
now Lean's own `BitVec.reverse`, so `BitVec.getElem_reverse` applies to it.
exp217's differential traces and exp218's `cases.h` came out byte for byte
the same after the change. Every theorem rests on Lean's own axioms.

Five wrong versions in [`proof/mutants.txt`](./proof/mutants.txt) are each
refused:
- the middle instruction reads X;
- PIO1's words are claimed to be `invert`'s;
- `mov`'s bit-reverse is a plain copy, as rp2040-pio-emulator has it;
- the bit-reverse also shifts by one, so that it no longer commutes;
- a blocking pull on an empty FIFO goes on with X.

## What runs, in order

| Step | What the shell does | Which theorem says what should happen |
| --- | --- | --- |
| 1 | takes PIO0 and PIO1 out of reset, loads each one's program, and starts each. Both wait at `pull block` | `waits` |
| 2 | puts exp203's image in the region with the message as its source, and checks the kernel's bytes against `kernel.sha256` | exp203 `code_of_image` |
| 3 | checks that both blocks are waiting with their FIFOs empty, then runs the kernel in User mode | — |
| 4 | runs exp209's checks: halted with 0, the destination is the source, the region is the model's, `minstret` is 108 | exp203's theorems |
| 5 | sends each of the 16 copied words both ways: PIO0 then PIO1, and PIO1 then PIO0. PIO0's answer must be the word complemented and PIO1's the word reversed, and both orders must end at the word reversed and complemented | `every_word` for each block, then `either_order` |
| 6 | checks that all four FIFOs are empty | — |

The message is

```text
exp220: Hazard3 copies. PIO0 inverts, PIO1 reverses, either way.
```

[`gen.py`](./gen.py) reads the two programs' words out of the theorems and
computes everything else the chip is held to:
- the image, the region and `minstret`, as exp219's does;
- the 16 words complemented, reversed, and both, in Python rather than by
  the model.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp220.uf2.sha256`](./exp220.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp220.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for a few seconds.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | all three did what their theorems say, and every word came back the same both ways |
| **1 flash**, repeated | the CPU side: one of exp209's checks failed, or `minstret` was not 108 |
| **2 flashes** | PIO0 never came out of reset |
| **3 flashes** | PIO1 never came out of reset |
| **4 flashes** | a block was not waiting, with its FIFOs empty, before the kernel ran |
| **5 flashes** | a word went into a block and nothing came back |
| **6 flashes** | PIO0 gave back something other than the word complemented |
| **7 flashes** | PIO1 gave back something other than the word reversed |
| **8 flashes** | each block was right on its own, but the two orders did not both give the word reversed and complemented |
| **9 flashes** | a FIFO still held something at the end |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## What the RTL checks, and what it cannot

The kernel runs for real on the Hazard3 RTL and halts with 0 at `minstret`
108. The RTL has no PIO, so stand-ins answer both blocks' registers
([`shell/board_sim.c`](./shell/board_sim.c)):

| Stand-in | Verdict |
| --- | --- |
| two blocks that work | ok, after all 16 words |
| PIO1 never leaves reset | 3, before the kernel runs |
| PIO1 hands words back unreversed | 7, on the first word |
| PIO0 right on its own, wrong the second way round | 8, on the first word |
| PIO0 never answers | 5, on the first word |
| PIO1 leaves a word in RX | 9 |

Three wrong shells or expectations are caught on the RTL:
- the kernel's hash is wrong;
- the answers are only reversed;
- the shell traps itself.

Two are not caught there, and are said here rather than counted:
- **The two blocks given each other's programs.** The stand-ins do not run
  programs, so only the board would show it, as 6 flashes.
- **A shell that never takes the second order.** It would still check the
  first, so the RTL's verdict stays ok.

## What it does not say

- **That the blocks talk to each other, or to the CPU.** The shell carries
  every word, and is not proved.
- **That every pair of operations commutes.** `commute` is about these two.
  The mutant that adds a shift to the reverse shows the theorem can tell.
- **Timing.** One bit, read after everything; one run.

## Running it

```sh
./check.sh       # the proofs and mutants, the build, the UF2, the RTL against six stand-ins
./build.sh       # build/exp220.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
A few minutes, most of it the mutants rebuilding the library.

## Expected output

```text
CAPTURE
```
