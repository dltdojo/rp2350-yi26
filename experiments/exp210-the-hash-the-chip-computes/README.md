# exp210 — the hash the chip computes

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp204's Lamport verifier and exp205's WOTS verifier, both proved for every
function HASH might be, run on a Pico 2 with the RP2350's own SHA-256 block as
HASH: all 21 of their cases, each held on the chip against what the Lean model
and the Hazard3 RTL did with the same bytes — the verdict, every byte of the
64 KiB region, and minstret. On a Pico 2 it blinked slowly: every case
matched. The SHA-256 block answered 8,155 HASH calls as the model's SHA-256
does, the 21 regions came out byte for byte as the Lean model left them, and
the RP2350 counted each case's minstret as the RTL does — the trap into the
shell and the `mret` back included.**

This is the briefing's "three executors agree" step on the
[verified-kernel road](../README.md#the-verified-kernel-road), and the first
time a proved kernel's HASH is computed by something the repository did not
write. exp209 put a kernel with no HASH on silicon; this one puts the two
kernels that call it there, 256 calls for every Lamport case and 45 to 990 for
the WOTS ones, 8,155 in all.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer — the same
as exp209.

1. Check the file: its SHA-256 must be the one in
   [`exp210.uf2.sha256`](./exp210.uf2.sha256).
2. **If the board has ever run exp139 to exp145**, or you are not sure, flash
   [exp209](../exp209-the-count-the-led-blinks/)'s UF2 first, the same way.
   See *Why exp209 first* below; on a board that last ran exp209 there is
   nothing to do.
3. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
4. Copy `exp210.uf2` onto it. The drive disappears and the board restarts.
5. Wait a few seconds, then look at the LED: is it blinking **slowly** or
   **fast**?

### What the LED says

| You see | It means |
| --- | --- |
| **slow blinking**, about 2 s on, 2 s off | **every case matched** |
| **fast blinking**, several times a second | at least one did not |
| on, steady | the shell hung, or trapped itself — the SHA-256 block refusing to be touched would look like this |
| dark | the shell never ran |

**Say "slow" or "fast"**, as with exp209: a person reads one bit off an LED
reliably, and nothing more. For each of the 21 cases, "matched" is all six of:

1. the kernel's bytes in SRAM hash to its `kernel.sha256` — with the shell's
   software SHA-256, never the block under test;
2. the kernel halted (`ecall` with `t0 = 1`), not a fault;
3. with the verdict the Lean model gave: 0 for the valid signatures (three
   Lamport cases, four WOTS), 1 for the rest;
4. every one of the region's 65,536 bytes is the byte the Lean model left
   there;
5. `minstret` is what the RTL counted for the same image under the same
   harness — 17690 for every Lamport case, `4145 + 7·S` for a WOTS case with S
   HASH calls;
6. the SHA-256 block never said a word was written while it was not ready;

and the shell must have run all 21. Fast blinking says one of these failed
somewhere and nothing more; the next build would split the cases in half.

## What the board has said

| Run | UF2 (SHA-256) | Reported, as said | Read as |
| --- | --- | --- | --- |
| 1 | `bba43c353e4328793760c385ca1f86441129d810b503fc88967b02d4b9a557e5`, on a board that last ran exp209 | **"慢閃"** — slow blinking | **every case matched**: on all 21, the kernel in SRAM was the proved one, it halted with the model's verdict, all 65,536 bytes of the region were the model's, minstret was the RTL's, and the block never flagged a write while busy. So the driver in `sha_hw.h` gives the block what it wants, the block computes SHA-256 as `lean/Sha256.lean` and hashlib do, and a HASH call costs silicon the 4 counted instructions it costs the RTL |

One run, one board, as with exp209: what it settles is these 21 cases under
this shell on this Pico 2. It answers the road's open question about the
per-call cost for these two kernels — silicon's minstret is
`count + 3 + 4·S`, as the RTL's is — and it closes the briefing's
"three executors agree" step: model, RTL and chip, byte for byte. It says
nothing about time; `mcycle` was not read.

## The question

A proof about a kernel that calls HASH holds for every function HASH might
be — exp204's and exp205's theorems say so. That leaves the other half: is the
function the chip computes the one the model was run with? The model's HASH is
SHA-256 from `lean/Sha256.lean`, checked against hashlib; the RTL's is C,
checked the same way. The chip's is a hardware block whose padding, byte order
and handshake are the shell's to get right, and which nothing in the cloud can
run.

So the chip gets the cases with the answers attached, computed here from the
other two executors, and compares. Check 4 is the strong one: the kernels
write their verdict from what HASH returned, and exp205's also writes the
message's 67 digits to scratch, so a wrong hash, a hash written in the wrong
place, or a handshake that drops a word all leave a byte that differs.

## What the shell is

[exp209](../exp209-the-count-the-led-blinks/)'s shell, grown to many cases
and a HASH call. Everything the two share moved to
[`tools/hazard3/shell/`](../../tools/hazard3/shell/), and exp209's UF2 still
builds byte for byte to the file that ran on its board.

| | |
| --- | --- |
| [`gen.py`](./gen.py) | runs every case of exp204's and exp205's `images.py` on the Lean model at `0x20070000` and on the RTL harness, refuses to go on unless the model gives Python's verdict at the proved count and the RTL counts `count + 3 + 4·S`, and writes `expect.h`: the images and the regions the model left, as 64-byte blocks each stored once |
| [`shell/shell.c`](./shell/shell.c) | for each case: zero the region, write its blocks, hash the kernel, enter it under `harness.S`; answer HASH calls; at HALT run the six checks, then the next case |
| [`sha_hw.h`](../../tools/hazard3/shell/sha_hw.h), now in `tools/` | HASH on the SHA-256 block: `START`, the words with `BSWAP` on, one block of padding, wait for `SUM_VLD`, the sums out big-endian |
| [`shell/board_chip.c`](./shell/board_chip.c) | takes the block out of reset after the LED is up, and blinks the verdict |
| [`shell/board_sim.c`](./shell/board_sim.c) | the RTL's: HASH in software, as the RTL harness does it, and a line per case on the print port |

HASH's arguments are checked by
[`tools/hazard3/harness/hashcall.h`](../../tools/hazard3/harness/hashcall.h),
the same rule the RTL harness's `handler.c` applies, now one file for both.

**What the cases cost in flash.** The 21 images and 21 regions come to 1156
distinct 64-byte blocks — a Lamport public key appears in eight cases and is
stored once — plus two bytes of position and two of block number for each
placement: about 94 KiB, after the code. The image is linked into the first
128 KiB of flash, and the link refuses more.

**Why exp209 first.** exp209 confined itself to flash sector 0 because exp139
to exp145 leave a partition table there whose partition 0, sectors 1 onward,
accepts only Arm images; what the bootrom does with an `absolute` block
aimed into such a partition is not something this repository has measured.
This image cannot fit in sector 0. But the table lives in sector 0, so flashing
exp209 removes it, and on a board without a table every sector is
unpartitioned space, which exp138 measured accepting `absolute`.

## What is checked without the board

`check.sh`:

- the shell's own SHA-256 against hashlib;
- **`sha_hw.h` against a fake SHA-256 block** made from the datasheet's field
  descriptions as rp-pac carries them ([`host/shafake.c`](./host/shafake.c)):
  at five lengths, the block must be fed exactly SHA-256's padded message and
  the driver must return the digest the fake was handed. Four wrong drivers —
  one that does not wait for `WDATA_RDY`, one with `BSWAP` off, one that gives
  the length in bytes, one that reads the sums before `SUM_VLD` — are each
  caught. The fake is my reading of the datasheet, so this says the driver
  does what I think the block wants; only the board says the block wants it;
- `gen.py`: on all 21 cases the model's verdict and count and the RTL's
  outcome and minstret;
- the UF2, read back independently: family `absolute`, every block in the
  first 128 KiB, exactly the image, the jump and the IMAGE_DEF block; and,
  with the recorded toolchain, byte for byte the committed hash;
- **the same shell on the Hazard3 RTL**, HASH in software: all six checks pass
  on all 21 cases, and the verdict is ok;
- nine wrong shells, on two cases to be quick, each caught by the check it
  breaks — among them a hash block that answers one bit wrong (checks 3 and
  4: the valid signature is rejected, and the region is not the model's), one
  that reports an error (check 6), and a shell that stops after the first
  case.

## What only the board can say, and what it cannot

- **Whether the SHA-256 block computes HASH as the model does**, under the
  driver in `sha_hw.h`, for 8,155 calls.
- **Whether minstret on silicon is still the RTL's** with HASH calls in it:
  each one is a trap into the shell and an `mret` back, which is where exp203
  found Hazard3 counting in ways the specification does not describe. exp209
  settled it for a kernel with no HASH call.
- **Not the time.** `mcycle` is not reported, and the clock is the bootrom's.
- **Not the PMP readback** exp209 found: no check here reads PMP back.

## Running it

```sh
./build.sh       # build/exp210.uf2, and the RTL build; gen.py takes ~3 minutes the first time
./check.sh       # everything above; no board
./run.sh         # records capture.txt
```

Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
(`tools/lean/setup.sh`) and the Hazard3 testbench (`tools/hazard3/setup.sh`).

## Expected output

The board half is in **What the board has said** above, as reported. The
cloud half:

```text
=== exp210 — the hash the chip computes (cloud half) ===
recorded at 2026-10-05T03:19:23Z from commit 78b87bd (working tree dirty — this recording is not reproducible from the commit alone)

>>> every check
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  the harness's SHA-256 agrees with hashlib at 14 lengths, 0 to 65536
PASS  sha_hw feeds the fake block SHA-256's padded message and returns its digest, at 5 lengths from 64 to 65536 bytes
PASS  the fake catches a driver that does not wait for WDATA_RDY
PASS  the fake catches a driver that turns BSWAP off
PASS  the fake catches a driver that gives the length in bytes, not bits
PASS  the fake catches a driver that reads the sums before SUM_VLD
PASS  the shell builds for the chip and for the RTL, the chip's 97440 bytes in its 128 KiB
PASS  gen.py: on all 21 cases the model gives Python's verdict at the proved count, and the RTL agrees with minstret = count + 3 + 4 S
PASS  all 381 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 128 KiB of flash, 0x10000000..0x10020000
PASS  together they are exactly the 97440-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: bba43c353e432879…
PASS  on the RTL the shell passes all six checks on all 21 cases: the model's verdict and region, the RTL harness's minstret
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — check 1
PASS  the shell catches a version where HALT is looked for under t0 = 2 — checks 2 and 3
PASS  the shell catches a version where the model's verdict is taken to be 1 — check 3
PASS  the shell catches a version where the hash block answers one bit wrong — checks 3 and 4: the verdict turns, and the region is not the model's
PASS  the shell catches a version where a block the model changed is expected unchanged — check 4
PASS  the shell catches a version where the chip is asked to count one fewer — check 5
PASS  the shell catches a version where the hash block reports an error — check 6
PASS  the shell catches a version where the shell stops after the first case — not ok
PASS  the shell catches a version where the shell itself traps in step 2 — a fault, not a verdict

>>> every case, as gen.py found it on the Lean model and the RTL harness
valid                    kernel 0  verdict 0  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
valid-other-key          kernel 0  verdict 0  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
all-ones-message         kernel 0  verdict 0  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
first-preimage-flipped   kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
last-preimage-flipped    kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
message-bit-flipped      kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
other-half-revealed      kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
other-message-signature  kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
public-key-swapped       kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 393 blocks, 2 changed
zero-signature           kernel 0  verdict 1  S 256  count 16663  minstret 17690  in 265 blocks, 2 changed
valid                    kernel 1  verdict 0  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
valid-other-key          kernel 1  verdict 0  S 600  count  5942  minstret  8345  in  79 blocks, 3 changed
valid-zero-message       kernel 1  verdict 0  S 990  count  7112  minstret 11075  in  78 blocks, 3 changed
valid-ones-message       kernel 1  verdict 0  S  45  count  4277  minstret  4460  in  79 blocks, 3 changed
first-chain-wrong        kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
checksum-chain-wrong     kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
last-chain-wrong         kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
chain-walked-forward     kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
other-message-signature  kernel 1  verdict 1  S 600  count  5942  minstret  8345  in  79 blocks, 3 changed
public-key-swapped       kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  79 blocks, 3 changed
zero-signature           kernel 1  verdict 1  S 480  count  5582  minstret  7505  in  45 blocks, 3 changed
expect.h: 21 cases, 1156 distinct blocks (73984 bytes), 4636 placed, 53 changed

>>> the same cases under the shell on the Hazard3 RTL (HASH in software)
case                               ok  failed  a0  minstret
valid (Lamport)                    1   -       0   17690
valid-other-key (Lamport)          1   -       0   17690
all-ones-message (Lamport)         1   -       0   17690
first-preimage-flipped (Lamport)   1   -       1   17690
last-preimage-flipped (Lamport)    1   -       1   17690
message-bit-flipped (Lamport)      1   -       1   17690
other-half-revealed (Lamport)      1   -       1   17690
other-message-signature (Lamport)  1   -       1   17690
public-key-swapped (Lamport)       1   -       1   17690
zero-signature (Lamport)           1   -       1   17690
valid (WOTS)                       1   -       0   7505
valid-other-key (WOTS)             1   -       0   8345
valid-zero-message (WOTS)          1   -       0   11075
valid-ones-message (WOTS)          1   -       0   4460
first-chain-wrong (WOTS)           1   -       1   7505
checksum-chain-wrong (WOTS)        1   -       1   7505
last-chain-wrong (WOTS)            1   -       1   7505
chain-walked-forward (WOTS)        1   -       1   7505
other-message-signature (WOTS)     1   -       1   8345
public-key-swapped (WOTS)          1   -       1   7505
zero-signature (WOTS)              1   -       1   7505
52455054 00000001 00000000 exit=0
```
