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
=== exp220 — either order ===
recorded at 2026-10-07T06:31:41Z from commit b1ef8fa

>>> the shell, for the chip and for the RTL
build/expect.h: kernel a23ae89b0c8e2eaa…, RTL minstret 108, PIO0 80a0 a0cf 8020, PIO1 80a0 a0d7 8020
build/exp220.bin  4772 bytes, the build allows 8192
build/exp220.uf2  9728 bytes  sha256 b52032400a7ce553237989f8e256e8e4dc10b88ff94a1000d64ee3a482831cce

>>> what the chip is held to (build/expect.h, without the image)
// Generated by exp220/gen.py from exp203's sources and proof/Through.lean. Do not edit.
#define KERNEL_LEN 60
#define SRC_OFF 0x1000
#define DST_OFF 0x2000
#define EXPECT_INSTRET 108u   // the RTL harness's minstret for this image
// d13d1596665a40c6bdd81e294ad3b0e53f729d08e83ae734b9baf1f9e7fc3d27: the region, as the model left it
// words_invert: 80a0 a0cf 8020   (PIO0)
// words_reverse: 80a0 a0d7 8020   (PIO1)
#define PROGRAM_LEN 3
static const uint16_t INVERT[3] = {0x80a0, 0xa0cf, 0x8020};
static const uint16_t REVERSE[3] = {0x80a0, 0xa0d7, 0x8020};
// exp220: Hazard3 copies. PIO0 inverts, PIO1 reverses, either way.
// as 16 little-endian words: complemented, reversed, and both
static const uint32_t INVERTED[16] = {0xcd8f879au, 0xdfc5cfcdu, 0x9e859eb7u, 0xdfcc9b8du, 0x968f909cu, 0xdfd18c9au, 0xcfb0b6afu, 0x899196dfu, 0x8c8b8d9au, 0xb6afdfd3u, 0x8ddfceb0u, 0x8d9a899au, 0xd38c9a8cu, 0x8b969adfu, 0xdf8d9a97u, 0xd1869e88u};
static const uint32_t REVERSED[16] = {0xa61e0e4cu, 0x4c0c5c04u, 0x12865e86u, 0x4e26cc04u, 0xc6f60e96u, 0xa6ce7404u, 0x0a92f20cu, 0x0496766eu, 0xa64e2eceu, 0x34040a92u, 0xf28c044eu, 0xa66ea64eu, 0xcea6ce34u, 0x04a6962eu, 0x16a64e04u, 0xee869e74u};
static const uint32_t ANSWERS[16] = {0x59e1f1b3u, 0xb3f3a3fbu, 0xed79a179u, 0xb1d933fbu, 0x3909f169u, 0x59318bfbu, 0xf56d0df3u, 0xfb698991u, 0x59b1d131u, 0xcbfbf56du, 0x0d73fbb1u, 0x599159b1u, 0x315931cbu, 0xfb5969d1u, 0xe959b1fbu, 0x1179618bu};

>>> on the RTL, the kernel for real and stand-ins for PIO0 and PIO1 that work: REPT verdict failed minstret a0 cause word block
52455054 00000000 00000000 0000006c 00000000 00000008 0000000f 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Through.lean checks, with no errors and no warnings
PASS  all 4 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  words_invert: the proof refuses a version where the middle instruction moves from X, not from OSR
PASS  words_reverse: the proof refuses a version where PIO1's words are claimed to be the invert program's
PASS  step1: the proof refuses a version where mov's bit-reverse is a plain copy, as rp2040-pio-emulator has it
PASS  commute: the proof refuses a version where the bit-reverse also shifts by one, so that it no longer commutes with the complement
PASS  waits: the proof refuses a version where a blocking pull on an empty FIFO goes on with X
PASS  Copy64.lean checks, with no errors and no warnings
PASS  all 8 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  the shell builds for the chip and for the RTL, the chip's in 4772 of the 8192 bytes it may use
PASS  PIO0 gets words_invert, exp217's prog, and PIO1 words_reverse: 80a0 a0cf 8020 and 80a0 a0d7 8020
PASS  all 19 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 8 KiB of flash, 0x10000000..0x10002000
PASS  together they are exactly the 4772-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: b52032400a7ce553…
PASS  on the RTL, against two blocks that work: the kernel halts with 0 at minstret 108, then all 16 words agree both ways — ok
PASS  on the RTL, against a PIO1 that never leaves reset: verdict 3, before the kernel runs
PASS  on the RTL, against a PIO1 that hands words back unreversed: verdict 7, on the first word
PASS  on the RTL, against a PIO0 right on its own and wrong the second way round: verdict 8, the orders disagreeing on the first word
PASS  on the RTL, against a PIO0 that never answers: verdict 5, on the first word, block 0
PASS  on the RTL, against a PIO1 that leaves a word in RX: verdict 9, block 1
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — verdict 1, check 1
PASS  the shell catches a version where the answers are only reversed, not complemented — verdict 8
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
```
