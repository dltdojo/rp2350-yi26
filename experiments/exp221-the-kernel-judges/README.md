# exp221 — the kernel judges

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp220 again, with one thing moved: the comparison. PIO0 and PIO1 still
run `invert` and `reverse`, and every word still goes through them both
ways. The shell no longer decides whether the two orders agreed. It writes
the first order's 16 words and the second order's 16 into memory, and a new
RV32IM kernel, proved in Lean, compares them and halts with its verdict.
That gives one CPU and two PIO blocks, each running proved bytes, and the
proved CPU bytes have the last word. On a Pico 2 it blinked slowly: the
kernel judged the two orders the same.**

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

## On the board

| | |
| --- | --- |
| UF2 | `exp221.uf2`, SHA-256 `0e63a9b5e59eb7b19edaabce6700e4b9a9a6663540cc1c02c4ed436a2dc01109`, the committed one, built at 9003644 |
| Board | Pico 2 |
| How | BOOTSEL, the UF2 copied on, the LED watched |
| The LED | **slow blinking** |

The shell reaches slow blinking in only one way:
- **Both blocks started.** PIO0 and PIO1 came out of reset and ran their
  programs.
- **Each block answered as proved.** For each of the 16 words, PIO0 gave
  back the word complemented and PIO1 the word reversed.
- **Both lists went into memory.** Both orders' sixteen words were written
  where the kernel reads them, and all four FIFOs were empty.
- **The kernel's own conditions held.** The 292 bytes in SRAM were
  `kernel.bin`, by `kernel.sha256`. The kernel halted, and the region was
  byte for byte what it was before it ran, as `judges` says. `minstret` was
  76, the RTL's number.
- **The verdict.** The kernel halted with 0. By `judges` that means the two
  lists were the same, word by word.

So on one chip, three pieces of proved bytes did their parts, and the last
word was the proved CPU bytes':
- PIO0 ran `invert`;
- PIO1 ran `reverse`;
- the CPU ran the judge.

The two orders agreed, as `either_order` predicts. The shell carried every
word and is not proved. The LED is one bit, read after everything. One run;
nothing beyond it was recorded.

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
=== exp221 — the kernel judges ===
recorded at 2026-10-07T06:51:08Z from commit 9003644

>>> the kernel, as proof/Same.lean writes it
  0000  00000417  auipc x8, 0
  0004  00001337  lui x6, 1
  0008  006404b3  add x9, x8, x6
  000c  00002337  lui x6, 2
  0010  00640933  add x18, x8, x6
  0014  00000b13  addi x22, x0, 0
  0018  0004a383  lw x7, 0(x9)
  001c  00092e03  lw x28, 0(x18)
  0020  01c3c3b3  xor x7, x7, x28
  0024  007b6b33  or x22, x22, x7
  0028  0044a383  lw x7, 4(x9)
  002c  00492e03  lw x28, 4(x18)
  0030  01c3c3b3  xor x7, x7, x28
  0034  007b6b33  or x22, x22, x7
  0038  0084a383  lw x7, 8(x9)
  003c  00892e03  lw x28, 8(x18)
  0040  01c3c3b3  xor x7, x7, x28
  0044  007b6b33  or x22, x22, x7
  0048  00c4a383  lw x7, 12(x9)
  004c  00c92e03  lw x28, 12(x18)
  0050  01c3c3b3  xor x7, x7, x28
  0054  007b6b33  or x22, x22, x7
  0058  0104a383  lw x7, 16(x9)
  005c  01092e03  lw x28, 16(x18)
  0060  01c3c3b3  xor x7, x7, x28
  0064  007b6b33  or x22, x22, x7
  0068  0144a383  lw x7, 20(x9)
  006c  01492e03  lw x28, 20(x18)
  0070  01c3c3b3  xor x7, x7, x28
  0074  007b6b33  or x22, x22, x7
  0078  0184a383  lw x7, 24(x9)
  007c  01892e03  lw x28, 24(x18)
  0080  01c3c3b3  xor x7, x7, x28
  0084  007b6b33  or x22, x22, x7
  0088  01c4a383  lw x7, 28(x9)
  008c  01c92e03  lw x28, 28(x18)
  0090  01c3c3b3  xor x7, x7, x28
  0094  007b6b33  or x22, x22, x7
  0098  0204a383  lw x7, 32(x9)
  009c  02092e03  lw x28, 32(x18)
  00a0  01c3c3b3  xor x7, x7, x28
  00a4  007b6b33  or x22, x22, x7
  00a8  0244a383  lw x7, 36(x9)
  00ac  02492e03  lw x28, 36(x18)
  00b0  01c3c3b3  xor x7, x7, x28
  00b4  007b6b33  or x22, x22, x7
  00b8  0284a383  lw x7, 40(x9)
  00bc  02892e03  lw x28, 40(x18)
  00c0  01c3c3b3  xor x7, x7, x28
  00c4  007b6b33  or x22, x22, x7
  00c8  02c4a383  lw x7, 44(x9)
  00cc  02c92e03  lw x28, 44(x18)
  00d0  01c3c3b3  xor x7, x7, x28
  00d4  007b6b33  or x22, x22, x7
  00d8  0304a383  lw x7, 48(x9)
  00dc  03092e03  lw x28, 48(x18)
  00e0  01c3c3b3  xor x7, x7, x28
  00e4  007b6b33  or x22, x22, x7
  00e8  0344a383  lw x7, 52(x9)
  00ec  03492e03  lw x28, 52(x18)
  00f0  01c3c3b3  xor x7, x7, x28
  00f4  007b6b33  or x22, x22, x7
  00f8  0384a383  lw x7, 56(x9)
  00fc  03892e03  lw x28, 56(x18)
  0100  01c3c3b3  xor x7, x7, x28
  0104  007b6b33  or x22, x22, x7
  0108  03c4a383  lw x7, 60(x9)
  010c  03c92e03  lw x28, 60(x18)
  0110  01c3c3b3  xor x7, x7, x28
  0114  007b6b33  or x22, x22, x7
  0118  01603533  sltu x10, x0, x22
  011c  00100293  addi x5, x0, 1
  0120  00000073  ecall

>>> the shell, for the chip and for the RTL
build/expect.h: kernel f23a0dd2a7923a3d…, RTL minstret 76, model 73 both ways
build/exp221.bin  4512 bytes, the build allows 8192
build/exp221.uf2  9216 bytes  sha256 0e63a9b5e59eb7b19edaabce6700e4b9a9a6663540cc1c02c4ed436a2dc01109

>>> what the chip is held to (build/expect.h, without the image)
// Generated by exp221/gen.py. Do not edit.
#define KERNEL_LEN 292
#define FIRST_OFF 0x1000
#define SECOND_OFF 0x2000
#define EXPECT_INSTRET 76u   // the RTL harness's minstret for this kernel
// words_invert: 80a0 a0cf 8020   (PIO0)
// words_reverse: 80a0 a0d7 8020   (PIO1)
#define PROGRAM_LEN 3
static const uint16_t INVERT[3] = {0x80a0, 0xa0cf, 0x8020};
static const uint16_t REVERSE[3] = {0x80a0, 0xa0d7, 0x8020};
// exp221: PIO0 and PIO1 answer, and a proved RV32IM kernel judges.
static const uint32_t WORDS[16] = {0x32707865u, 0x203a3132u, 0x304f4950u, 0x646e6120u, 0x4f495020u, 0x6e612031u, 0x72657773u, 0x6e61202cu, 0x20612064u, 0x766f7270u, 0x52206465u, 0x49323356u, 0x656b204du, 0x6c656e72u, 0x64756a20u, 0x2e736567u};
static const uint32_t INVERTED[16] = {0xcd8f879au, 0xdfc5cecdu, 0xcfb0b6afu, 0x9b919edfu, 0xb0b6afdfu, 0x919edfceu, 0x8d9a888cu, 0x919edfd3u, 0xdf9edf9bu, 0x89908d8fu, 0xaddf9b9au, 0xb6cdcca9u, 0x9a94dfb2u, 0x939a918du, 0x9b8a95dfu, 0xd18c9a98u};
static const uint32_t REVERSED[16] = {0xa61e0e4cu, 0x4c8c5c04u, 0x0a92f20cu, 0x04867626u, 0x040a92f2u, 0x8c048676u, 0xceeea64eu, 0x34048676u, 0x26048604u, 0x0e4ef66eu, 0xa626044au, 0x6acc4c92u, 0xb204d6a6u, 0x4e76a636u, 0x0456ae26u, 0xe6a6ce74u};

>>> on the RTL, stand-ins for PIO0 and PIO1 that work, and the kernel judging what they gave, for real: REPT verdict failed minstret a0 cause word block
52455054 00000000 00000000 0000004c 00000000 00000008 0000000f 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Same.lean checks, with no errors and no warnings
PASS  all 4 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  at_cmp: the proof refuses a version where the second block compares the first eight words again
PASS  setup_regs: the proof refuses a version where the second list is looked for 0x1000 bytes late
PASS  at_cmp: the proof refuses a version where differences are combined with and, so one matching word hides the rest
PASS  judges: the proof refuses a version where the verdict is tested the wrong way round
PASS  judges: the proof refuses a version where the ecall asks for HASH, not HALT
PASS  Through.lean checks, with no errors and no warnings
PASS  all 4 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  kernel.bin is what proof/Same.lean writes, 292 bytes, and kernel.sha256 is its hash
PASS  the shell builds for the chip and for the RTL, the chip's in 4512 of the 8192 bytes it may use; the model halts after 73 both ways
PASS  all 18 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 8 KiB of flash, 0x10000000..0x10002000
PASS  together they are exactly the 4512-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 0e63a9b5e59eb7b1…
PASS  on the RTL, against two blocks that work: the kernel, run for real, halts with 0 at minstret 76 — ok
PASS  on the RTL, against a PIO1 that never leaves reset: verdict 3, before anything is sent
PASS  on the RTL, against a PIO1 that hands words back unreversed: verdict 6, on the first word
PASS  on the RTL, against a PIO0 right on its own and wrong the second way round: the kernel, run for real, halts with 1 — verdict 7
PASS  on the RTL, against a PIO0 that never answers: verdict 4, on the first word
PASS  on the RTL, against a PIO1 that leaves a word in RX: verdict 8, before the kernel runs
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — verdict 1, check 1
PASS  the shell catches a version where the chip is asked to count 75 — verdict 1
PASS  the shell catches a version where the shell flips a bit of every word in the first list — the kernel, run for real, finds them different: verdict 7
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a verdict
```
