# exp211 — the leaf signed once

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp213's signer on a Pico 2, one MSS leaf per boot, with the leaf counter
in the board's own flash: claimed before anything is signed, written so that
a power cut can waste a leaf but never hand one out twice, and kept where
flashing the firmware again does not reach. Each boot signs its leaf and
exp206's verifier accepts it on the chip; the boot after the sixteenth claim
refuses. A model says which designs lose a leaf to which attacker; a host
test cuts the power at every step of the real code; the RTL boots the shell
18 times over one flash. The board is asked to survive a person pulling the
power and flashing again in the middle of it.**

This is the verified-kernel road's last board step. exp213 proved a signer
that signs any leaf it is given; a one-time signature scheme is only safe if
it is never given the same leaf twice, and that is not a property of any
kernel. It is the shell's, and the flash's.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer — the
same as exp210. It takes about twenty boots and ten minutes.

1. Check the file: its SHA-256 must be the one in
   [`exp211.uf2.sha256`](./exp211.uf2.sha256).
2. **If the board has ever run exp139 to exp145**, or you are not sure, flash
   [exp209](../exp209-the-count-the-led-blinks/)'s UF2 first. A board that
   last ran exp209, exp210 or exp212 needs nothing.
3. Hold **BOOTSEL**, plug the board in, let go, and copy `exp211.uf2` onto
   the `RP2350` drive. The board restarts: that is **boot 1**.
4. Every boot goes the same way: the LED is **on** for a moment, then
   **blinks fast for about six seconds** — the window — then is on again for
   a moment, then **blinks slowly**: this boot signed its leaf, and the
   verifier accepted it.
5. For the next boot, **unplug the cable and plug it back in**. Do this, and
   watch each boot, until the LED does something other than blink slowly.
   On three of the boots, do something else:

   | Boot | Instead of waiting for the slow blinking |
   | --- | --- |
   | **3** | **pull the cable out while it blinks fast** (the window), then plug it back in |
   | **6** | the same: pull it out in the window |
   | after boot **9** blinks slowly | **flash the firmware again**: hold BOOTSEL, plug in, copy the same `exp211.uf2` — the board restarts and that is boot 10 |

6. Keep going until a boot shows **flashes with a pause** instead of slow
   blinking. **Count the flashes.**

### What the LED says

| You see | It means |
| --- | --- |
| **on**, then **fast for ~6 s**, then **on**, then **slow** | this boot claimed a leaf, signed it, and the verifier accepted |
| **N flashes, then about 2 s dark**, repeated | **refused: every leaf is used.** N is 1 + the leaves claimed and never signed |
| **fast**, and still fast after 15 s | refused or failed: the counter holds something this code never writes, a claim did not read back, or a kernel, the signer or the verifier failed |
| **on, steady**, for more than a minute | hung — most likely in a flash write, with the flash not back as memory |
| dark | the shell never ran |

**Say how many boots blinked slowly, and how many flashes the last one
showed.** With the two pulls above, the counter's answer is **14 boots
signed, and 3 flashes**: sixteen leaves, two of them claimed in a window and
never signed. Any other number is a finding, and so is any boot that
signed when you pulled the cable in its window.

### Starting over

The counter is in flash at 3.5 MiB and outlives every flash of this UF2, by
design. To run the experiment a second time on the same board, erase the
flash first (`picotool erase -a`, or flash a UF2 that covers that sector):
the next boot finds no marker and formats. That an erase starts it over is
the one door this design leaves open — see *What it does not stop*.

## The design

Three 4 KiB sectors at 3.5 MiB into flash —
[`shell/counter.h`](./shell/counter.h) — far past every firmware image here
(exp181's record is at 3 MiB):

| Sector | Holds |
| --- | --- |
| marker | `0x4d535302` once formatted; written last when formatting |
| claims | leaf *i*'s word in page *i*: cleared **before** leaf *i* is signed |
| confirmations | leaf *i*'s word in page *i*: cleared after its signature verified |

NOR flash sets bits to 1 only by erasing a whole sector, and a program only
clears bits. So each word is written once, only ever loses bits, and is read
one of two ways: all ones (free) or anything else (used). Four rules:

1. **Claim first.** The claim is written and read back before the signer
   starts. A cut after the claim wastes the leaf; there is no point at which
   a signature exists for a leaf the flash still shows as free.
2. **Any cleared bit means used** — in the count and in the read-back alike.
   A write cut short, or one a worn cell takes only part of, reads as used
   both times.
3. **Never erased after formatting.** Formatting erases the three sectors
   and writes the marker last; it runs only when the marker is not whole, so
   a cut in it formats again with nothing yet claimed.
4. **Outside the image.** A UF2 writes only its own sectors, so flashing this
   one again — or exp209, exp210 or exp212 — leaves the counter as it was.

The boot itself is [`shell/shell.c`](./shell/shell.c): read and claim, the
window, exp213's signer in User mode under the RTL harness's `harness.S`, then
exp206's verifier on the region the signer left with only the code replaced
(exp213's `three_binaries`), then the confirmation. The flash is written
through the bootrom's own functions, called from SRAM
([`shell/flash_rom.S`](./shell/flash_rom.S)): once flash stops being memory,
nothing may be fetched from it until it is memory again.

## What the model says

[`model/MssCounter.tla`](./model/MssCounter.tla), with 3 leaves of 2-bit
words — enough for every way a word can tear — and the property **no leaf is
signed twice**:

| Design | Power cuts, mid-write too | And flashing again | And erasing all flash |
| --- | --- | --- | --- |
| **this one**: claim first, one word a leaf, outside the image | holds | holds | **violated** |
| sign, then claim | **violated** | | |
| claim first, but one number, erased and rewritten | **violated** | | |
| this one, but inside the image | holds | **violated** | |

Each violation is a few steps: sign then claim loses to a cut between the
two, exactly the order exp197 found its PIN counter had; the rewritten number
loses to a cut after its erase; the counter inside the image loses to the
next flash. The last column is the open row, as exp197 left one: whoever
holds the board can erase everything through BOOTSEL, and this design does
not stop them. `tools/tlc/tlc.sh cited` holds ten lines of the C to the
model's steps.

## What is checked without the board

`check.sh`:

- the model, against [`model/expected.txt`](./model/expected.txt), and its
  citations;
- **`counter.h` on the host** ([`host/countertest.c`](./host/countertest.c)),
  over a fake NOR flash: a power cut at each of the 52 steps of a run and at
  every pair of them, each write torn three ways, from a flash of all ones,
  all zeros or random bytes — 8,652 runs, no leaf twice, every run reaching
  the end; a flash that silently takes no program signs nothing; one that
  takes only part of each program signs no leaf twice; a flash already
  holding a claim after a free slot signs nothing. Six wrong counters are
  each caught — among them one that reads a part-written claim as free,
  which only the part-taking flash exposes;
- `gen.py`: on the Lean model, exp213's key generator writes `mss.py`'s tree
  for the seed, and all 16 leaves sign and are accepted by exp206's verifier;
- the UF2, read back independently, and against its committed hash;
- **the same shell on the Hazard3 RTL**, booted 18 times in one simulation
  over a flash that outlives each boot: the power cut in the middle of the
  first erase, in a window, and in the middle of writing a claim; 14 leaves
  signed once and each accepted on the RTL, the 2 cut ones wasted, the
  17th claim refused.

## What only the board can say

- **That the bootrom's flash functions work from this shell** — called from
  RISC-V, from SRAM, by C that has never written flash before. Every earlier
  flash write in this repository was Arm and Embassy.
- **That the counter outlives a pulled cable and a second flash** on the
  real part, and that the signer and verifier run on silicon after the flash
  has been written and XIP restored.

And what it cannot:

- **A write torn by hand.** A program takes microseconds; nobody's hand lands
  in one. The model and the host test are where a cut lands mid-write.

## What it does not stop

- **Erasing the flash.** Anybody with the board and the BOOTSEL button can
  erase it and start the counter over. Stopping that needs storage a flash
  erase cannot reach — the RP2350's OTP, which this repository has decided
  not to write (exp154).
- **Reading the seed.** It is in the firmware image, in flash, in the clear.
  This experiment is about the counter, not about keeping the key.
- **A signature leaving the board.** The shell has no channel out; a
  signature is made, verified on the chip, and stays there. A real signer
  would send it after the confirmation — which the model's ordering already
  allows.

## Running it

```sh
./build.sh       # build/exp211.uf2, and the RTL build; gen.py takes ~15 s the first time
./check.sh       # everything above; no board
./run.sh         # records capture.txt
```

Needs clang, lld, llvm-objcopy, cargo, a host C compiler, java
(`tools/tlc/setup.sh`), Lean (`tools/lean/setup.sh`) and the Hazard3
testbench (`tools/hazard3/setup.sh`).

## What the board has said

**Nothing yet: this experiment has not been run on a board.** It was merged
with its cloud half complete — the model, the host test, the Lean model's
16 leaves and the RTL's 18 boots — and the board run deferred, because it
takes a person about twenty boots and two well-timed pulls of the cable.
Everything under *What only the board can say* is still open, the first of
it most of all: this shell's flash writes through the bootrom have never
run on silicon.

## Expected output

The board half is in **What the board has said** above, as reported. The
cloud half:

```text
=== exp211 — the leaf signed once (cloud half) ===
recorded at 2026-10-06T06:44:35Z from commit 787611f (working tree dirty — this recording is not reproducible from the commit alone)

>>> every check
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  MssCounter.tla parses
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:54 is still: if (flash_word(CTR_MARK) == CTR_MAGIC) return;
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:58 is still: flash_program_word(CTR_MARK, CTR_MAGIC);
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:70 is still: uint32_t claimed = flash_word(ctr_claim_at(i)) != CTR_FREE;
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:73 is still: if (gap) return CTR_CORRUPT;
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:88 is still: flash_program_word(ctr_claim_at(c->used), 0);
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:89 is still: != CTR_FREE ? CTR_SIGN : CTR_UNWRITTEN
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/counter.h:33 is still: #define CTR_MARK   0x00380000u
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/shell.c:58 is still: uint32_t s = ctr_begin(&c);
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/shell.c:65 is still: board_window(leaf);
PASS  the citation experiments/exp211-the-leaf-signed-once/shell/shell.c:70 is still: put(0, SIGN_BIN, SIGN_LEN);
PASS  unary-power-NoLeafTwice: holds
PASS  unary-reflash-NoLeafTwice: holds
PASS  unary-eraser-NoLeafTwice: violated
PASS  signfirst-power-NoLeafTwice: violated
PASS  number-power-NoLeafTwice: violated
PASS  inimage-power-NoLeafTwice: holds
PASS  inimage-reflash-NoLeafTwice: violated
PASS  no cut: every leaf signed once, 52 steps
PASS  from flash all ones: a cut at each of 60 steps, three ways a write tears — 180 runs, no leaf twice, every run exhausts
PASS  from flash all zeros: a cut at each of 60 steps, three ways a write tears — 180 runs, no leaf twice, every run exhausts
PASS  from flash random: a cut at each of 60 steps, three ways a write tears — 180 runs, no leaf twice, every run exhausts
PASS  two cuts at every pair of steps, three ways a write tears — 8112 runs, no leaf twice, every run exhausts
PASS  a flash that silently takes no program: four boots, 0 signatures — a claim the flash does not show is never signed under
PASS  a flash that silently takes only part of each program: 200 runs, no leaf twice
PASS  a flash holding a claim after a free slot: four boots, 0 signatures — what this code never writes, it never signs under
PASS  the host test catches a counter where a part-written claim reads as free
PASS  the host test catches a counter where the claim is not read back
PASS  the host test catches a counter where the marker is written before the claims are erased
PASS  the host test catches a counter where formatting does not erase the claims
PASS  the host test catches a counter where the claims need not be a prefix
PASS  the host test catches a counter where the leaf claimed is not the next one
PASS  the shell builds for the chip and for the RTL, the chip's 7984 bytes in its 32 KiB
PASS  gen.py: on the Lean model keygen writes mss.py's tree, and all 16 leaves sign and are accepted by exp206's verifier
PASS  all 32 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 32 KiB of flash, 0x10000000..0x10008000
PASS  together they are exactly the 7984-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 65ddb23249c387cf…
PASS  on the RTL, 18 boots over one flash: cut in the first erase, in a window and mid-claim, 14 leaves signed once and each accepted, 2 wasted, the 17th claim refused

>>> the model, design by attacker
MssCounter unary-power-NoLeafTwice                  holds       236 states  
MssCounter unary-reflash-NoLeafTwice                holds       236 states  
MssCounter unary-eraser-NoLeafTwice                 violated    204 states  Next -> Cut -> Next -> Next -> Next -> EraseAll -> Next -> Cut -> Next -> Next -> Next
MssCounter signfirst-power-NoLeafTwice              violated     17 states  Next -> Cut -> Next -> Next -> Cut -> Next -> Next
MssCounter number-power-NoLeafTwice                 violated     76 states  Next -> Next -> Next -> Cut -> Next -> TornClaim -> Next -> Next -> Next
MssCounter inimage-power-NoLeafTwice                holds       236 states  
MssCounter inimage-reflash-NoLeafTwice              violated    204 states  Next -> Cut -> Next -> Next -> Next -> Reflash -> Next -> Cut -> Next -> Next -> Next

>>> every leaf on the Lean model, as gen.py found it
keygen     halt code=00000000 count=76456  tree is mss.py's
leaf  0    sign halt code=00000000 count=3859     verify halt code=00000000 count=4735
leaf  1    sign halt code=00000000 count=3499     verify halt code=00000000 count=5095
leaf  2    sign halt code=00000000 count=4039     verify halt code=00000000 count=4555
leaf  3    sign halt code=00000000 count=3634     verify halt code=00000000 count=4960
leaf  4    sign halt code=00000000 count=3634     verify halt code=00000000 count=4960
leaf  5    sign halt code=00000000 count=3724     verify halt code=00000000 count=4870
leaf  6    sign halt code=00000000 count=3589     verify halt code=00000000 count=5005
leaf  7    sign halt code=00000000 count=3859     verify halt code=00000000 count=4735
leaf  8    sign halt code=00000000 count=3589     verify halt code=00000000 count=5005
leaf  9    sign halt code=00000000 count=3814     verify halt code=00000000 count=4780
leaf 10    sign halt code=00000000 count=3769     verify halt code=00000000 count=4825
leaf 11    sign halt code=00000000 count=3814     verify halt code=00000000 count=4780
leaf 12    sign halt code=00000000 count=3724     verify halt code=00000000 count=4870
leaf 13    sign halt code=00000000 count=3814     verify halt code=00000000 count=4780
leaf 14    sign halt code=00000000 count=3724     verify halt code=00000000 count=4870
leaf 15    sign halt code=00000000 count=3544     verify halt code=00000000 count=5050
expect.h: 16 leaves, each signed and accepted on the model

>>> the shell on the Hazard3 RTL, booted 18 times over one flash
boot  what happened                leaf  used  done  wasted
0     power cut in a flash write  
1     signed                       0     0     0     0
2     power cut in the window     
3     power cut in a flash write  
4     signed                       3     3     1     2
5     signed                       4     4     2     2
6     signed                       5     5     3     2
7     signed                       6     6     4     2
8     signed                       7     7     5     2
9     signed                       8     8     6     2
10    signed                       9     9     7     2
11    signed                       10    10    8     2
12    signed                       11    11    9     2
13    signed                       12    12    10    2
14    signed                       13    13    11    2
15    signed                       14    14    12    2
16    signed                       15    15    13    2
17    exhausted                    -     16    14    2
52455054 00000001 exit=0
```
