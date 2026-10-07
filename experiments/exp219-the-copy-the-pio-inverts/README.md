# exp219 — the copy the PIO inverts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Two pieces of proved bytes, running on one Pico 2 at the same time.**

| Side | Bytes | Proved by | What the theorem says |
| --- | --- | --- | --- |
| CPU | exp203's 60-byte RV32IM kernel | exp203 | it copies 64 bytes |
| PIO0 | exp214's three-word `invert` program | exp217 | it hands every word back complemented, and waits while TX is empty |

The kernel copies a fixed 64-byte message while PIO0 waits beside it. The
shell then carries the 16 copied words through PIO0. What comes back must
be the message, complemented word by word. That prediction comes from the
two theorems together; nothing new is proved here. Not yet run on a board.

exp209 ran exp203's kernel on silicon, and exp214 ran `invert` there, but
each ran alone. Here both run in one firmware, with the words from one
passing to the other. The shell (C, as in exp209 to exp218) carries those
words and is not proved. Only what each side does to them is.

## What runs, in order

| Step | What the shell does | Which theorem says what should happen |
| --- | --- | --- |
| 1 | takes PIO0 out of reset, loads `80a0 a0cf 8020` and starts state machine 0. TX is empty, so it waits at `pull block` | exp217 `waits` |
| 2 | puts exp203's image in the region, with the message as the 64 source bytes, and checks the kernel's bytes against `kernel.sha256` | exp203 `code_of_image`: any image starting with these bytes holds the kernel |
| 3 | checks that PIO0 is still waiting, with both FIFOs empty, and runs the kernel in User mode under `tools/hazard3/harness`, with PIO0 running beside it | — |
| 4 | when the kernel halts, runs exp209's checks: it halted, with 0; the destination equals the source; the whole region is what the Lean model left there; `minstret` is the RTL's 108 | exp203's theorems: copies the 64 bytes and halts with 0 after 105 instructions |
| 5 | sends the 16 words the kernel wrote through PIO0, one at a time. Each must come back as the copied word complemented, and both FIFOs must be empty at the end | exp217 `every_word` |

The message is

```text
exp219: Hazard3 copies these 64 bytes, then PIO0 inverts all 16.
```

[`gen.py`](./gen.py) computes everything the chip is held to:
- the image, from exp203's `images.py`;
- the region afterwards, from the Lean model running it where the chip will;
- `minstret`, from the Hazard3 RTL;
- the PIO words, read out of exp217's `proof/Invert.lean`, so that they are
  the ones its theorems are about;
- the 16 answers: the message's words, complemented.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp219.uf2.sha256`](./exp219.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp219.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for a few seconds.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | both sides did what their theorems say: the kernel copied the message and halted with 0, in 108 counted instructions, with the region as the model left it; then all 16 words came back complemented |
| **1 flash**, repeated | the CPU side: one of exp209's checks failed, or `minstret` was not 108 |
| **2 flashes** | PIO0 never came out of reset |
| **3 flashes** | PIO0 was not waiting, with both FIFOs empty, when the kernel was about to run |
| **4 flashes** | a word went into PIO0 and nothing came back |
| **5 flashes** | what came back was not the copied word complemented |
| **6 flashes** | a FIFO still held something at the end |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

## What the RTL checks, and what it cannot

On the Hazard3 RTL the kernel runs for real, exactly as in exp209: it halts
with 0 at `minstret` 108. The RTL has no PIO, so stand-ins
([`shell/board_sim.c`](./shell/board_sim.c)) answer PIO0's registers. They
are not a model of PIO.

| Stand-in | Verdict |
| --- | --- |
| a PIO that works | ok, after all 16 words |
| never leaves reset | 2, before the kernel runs |
| already holds a word while the kernel runs | 3 |
| never answers | 4, on the first word |
| hands each word back unchanged | 5, on the first word |
| leaves a word in RX | 6 |

Six wrong shells or expectations are each caught:
- the kernel's hash is not `kernel.sha256`;
- the model's region hash is wrong;
- the chip is asked to count 107;
- the answers are not complemented;
- the words are taken one word past where the kernel wrote them;
- the shell traps itself.

What only the board can say:
- that PIO0 waits as `waits` says while the CPU runs the kernel;
- that the copy and the inversion together give what the two theorems give.

## What it does not say

- **That the two sides talk to each other.** They do not: the shell carries
  the words, and the shell is not proved. A theorem about the CPU and PIO0
  as one system is not here.
- **Anything about timing.** One bit, read after everything.
- **More than one message.** One fixed message, one run.

## Running it

```sh
./check.sh       # both proofs, the build, the UF2, the RTL against six stand-ins, wrong shells
./build.sh       # build/exp219.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
A few minutes.

## Expected output

```text
=== exp219 — the copy the PIO inverts ===
recorded at 2026-10-07T05:34:14Z from commit 86ab6b4

>>> the shell, for the chip and for the RTL
build/expect.h: kernel a23ae89b0c8e2eaa…, region 273c0c9c6cc954f2…, RTL minstret 108, PIO words 80a0 a0cf 8020
build/exp219.bin  4232 bytes, the build allows 8192
build/exp219.uf2  8704 bytes  sha256 79c319d2b2aaf494cd280e71d7da1b4c275cd123d951f58648367190bf40a70d

>>> what the chip is held to (build/expect.h, without the image)
// Generated by exp219/gen.py from exp203's and exp217's sources. Do not edit.
#define KERNEL_LEN 60
#define SRC_OFF 0x1000
#define DST_OFF 0x2000
#define EXPECT_INSTRET 108u   // the RTL harness's minstret for this image
// 273c0c9c6cc954f2d92dbef60cbcda15b071199b942afa0af43efd6b68cea937: the region, as the model left it
// exp217's `prog`: 80a0 a0cf 8020
#define PROGRAM_LEN 3
static const uint16_t PROGRAM[PROGRAM_LEN] = {0x80a0, 0xa0cf, 0x8020};
// exp219: Hazard3 copies these 64 bytes, then PIO0 inverts all 16.
// as 16 little-endian words, each complemented
static const uint32_t ANSWERS[16] = {0xcd8f879au, 0xdfc5c6ceu, 0x9e859eb7u, 0xdfcc9b8du, 0x968f909cu, 0x8bdf8c9au, 0x9a8c9a97u, 0xdfcbc9dfu, 0x9a8b869du, 0x8bdfd38cu, 0xdf919a97u, 0xcfb0b6afu, 0x899196dfu, 0x8c8b8d9au, 0x93939edfu, 0xd1c9cedfu};

>>> on the RTL, the kernel for real and a stand-in PIO that works: REPT verdict failed minstret a0 cause word
52455054 00000000 00000000 0000006c 00000000 00000008 0000000f exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Copy64.lean checks, with no errors and no warnings
PASS  all 8 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  Invert.lean checks, with no errors and no warnings
PASS  all 3 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  the shell builds for the chip and for the RTL, the chip's in 4232 of the 8192 bytes it may use
PASS  the PIO words are exp217's prog, the ones its theorems are about: 80a0 a0cf 8020
PASS  all 17 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 8 KiB of flash, 0x10000000..0x10002000
PASS  together they are exactly the 4232-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 79c319d2b2aaf494…
PASS  on the RTL, against a PIO that works: the kernel halts with 0 after minstret 108, then all 16 words come back complemented — ok
PASS  on the RTL, against a PIO that never leaves reset: verdict 2, before the kernel runs
PASS  on the RTL, against one already holding a word while the kernel runs: verdict 3, after it halts
PASS  on the RTL, against one that never answers: verdict 4 on the first word
PASS  on the RTL, against one that hands each word back as it was: verdict 5 on the first word
PASS  on the RTL, against one that leaves a word in RX: verdict 6, after all 16
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — verdict 1, check 1
PASS  the shell catches a version where the model's region hash is not the model's — verdict 1, check 6
PASS  the shell catches a version where the chip is asked to count 107 — verdict 1
PASS  the shell catches a version where the answers are the words themselves, not their complements — verdict 5
PASS  the shell catches a version where the words go to PIO0 one word past where the kernel wrote them — verdict 5
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
```
