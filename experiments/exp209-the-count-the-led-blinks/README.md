# exp209 — the count the LED blinks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The first RISC-V firmware in this repository: a shell, in flash sector 0 of a
Pico 2, that runs exp203's proved 60-byte kernel in User mode and checks what
it did. The proof says 105 instructions, and the Hazard3 RTL counts 108 under
the same shell. On a Pico 2, revision 1 blinked "2 long flashes, 1-0-8": the
kernel halted, and the RP2350's own core, an older Hazard3 than the RTL,
counted 108, the RTL's number. Revision 2 tried to blink four numbers, and a
person could not read them. So revision 3 answers one question with one bit:
slow blinking if everything matched (the kernel, its result, the copy, the
whole region against the Lean model, and 108), fast blinking if anything did
not. It has not been run yet.**

This is the board half of the verified-kernel road (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md)),
in its smallest form: one kernel, no HASH, and the LED as the only way
anything gets out.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W: its LED is on the wireless chip, which
this shell cannot reach), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp209.uf2.sha256`](./exp209.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp209.uf2` onto it. The drive disappears and the board restarts,
   this time as a RISC-V machine.
4. Look at the LED for a few seconds: is it blinking **slowly** or **fast**?
   Nothing needs counting, and it keeps going forever.

To go back to anything else afterwards: hold BOOTSEL, plug in, and copy that
UF2. The shell writes nothing to flash.

### What the LED says (revision 3)

| You see | It means |
| --- | --- |
| **slow blinking**, about 2 s on, 2 s off | **everything matched** |
| **fast blinking**, several times a second | something did not |
| on, steady | the shell hung, or trapped itself |
| dark | the shell never ran |

That is the whole report: **say "slow" or "fast"**. Slow and fast are 24 to 1
apart, so they cannot be mistaken for each other whatever the chip's clock
is. "Everything" is:

- **check 1:** the 60 bytes copied into SRAM hash to `kernel.sha256`, so it is
  the proved kernel;
- **check 3:** the kernel halted (`ecall` with `t0 = 1`);
- **check 4:** it halted with result `a0 = 0`;
- **check 5:** the 64 bytes at the destination are the 64 at the source;
- **check 6:** the whole 64 KiB region hashes to what the Lean model left
  there;
- **minstret = 108**, the count the Hazard3 RTL gives for the same image under
  the same shell. `gen.py` takes it from an RTL run, not from a person.

Check 2, PMP entry 0 reading back as written, is computed but left out of the
verdict. Run 1 already showed that it does not hold on silicon while the
kernel still ran confined and halted. That is a question of its own, for its
own one-bit build if it is ever asked.

**Why one bit.** Revision 1 blinked a verdict and one number, and was read.
Revision 2 blinked four numbers, each announced by long flashes, with decimal
digits as groups of up to ten short blinks, and the person at the board
reported: *"無法回報四個數字，這個驗證太複雜必須簡化，這種長度對於人眼識別計算太難"*
(the four numbers cannot be reported; this is too complicated; lengths like
these are too hard for a human eye to count). That is the finding about the
instrument: **a person reads one bit from an LED reliably, not a number**. So
the comparisons happen on the chip, against values computed here, and only
their verdict is blinked.

## What the board has said

| Run | UF2 (SHA-256) | Reported, as said | Read as |
| --- | --- | --- | --- |
| 1 | `09e9219984f37b21640f4e1b70990d7cb502131503af24c1f5e51bbbe0a0eddb` — revision 1, which blinked the first failed check and then minstret | **"2 次長閃，1-0-8"** — two long flashes, then 1, 0, 8 | check 1 passed, so SRAM held the proved kernel; check 2 failed, so PMP entry 0 did not read back as written; the number is minstret, because revision 1 blinked minstret only when the kernel had halted (otherwise mcause, never 108). So **the kernel halted, and the RP2350 counted 108, as the RTL does**. Checks 4, 5 and 6 were not reported |
| 2 | `4b3f3dff1983d6d34084561bdd8ba7236031f670862653e67dee52ae6068f2a2` — revision 2, four numbers | **"無法回報四個數字，這個驗證太複雜必須簡化，這種長度對於人眼識別計算太難"** | unreadable by design: the instrument, not the chip, failed. Nothing about the chip is learned from it |
| 3 | see `exp209.uf2.sha256` — revision 3, one bit | not yet run | |

Run 1 settles the question this experiment was built for, for this kernel and
this shell: silicon's `minstret` is the RTL's, so exp203's accounting (the
proved count plus 3) holds on the chip. It also raises one this repository had
not asked: what does the RP2350's Hazard3 do with PMP entry 0? The kernel
still ran in User mode inside the region, so User mode had the access it
needed, whatever entry 0 holds.

## What the shell is

Plain assembly and C, 3476 bytes. It is not the Rust shell the briefing
planned, and the reason is the count: the instructions around the kernel,
from the write that starts the counters to the trap that stops them, are
[`tools/hazard3/harness/harness.S`](../../tools/hazard3/harness/harness.S)
itself, included with `-DSHELL`. Those are the instructions whose counting
exp203 measured on the RTL, so a difference on silicon is the silicon's, not
a different shell's.

| | |
| --- | --- |
| [`shell/start_chip.S`](./shell/start_chip.S) | `j _start`, then the IMAGE_DEF block, its words those of embassy-rp's `block.rs`: RISC-V EXE for RP2350, with an ENTRY_POINT that also names `_start` — whichever the bootrom goes by, it lands there |
| [`shell/shell.c`](./shell/shell.c) | zero the region at `0x20070000`, write exp203's `counting` image, hash the kernel, enter it, then the six checks |
| [`shell/board_chip.c`](./shell/board_chip.c) | GPIO25 through SIO, every address rp-pac's for the RP235x; slow or fast blinking for the verdict; nothing else on the chip is touched, the clock included |
| [`gen.py`](./gen.py) | everything compared against, from exp203's own files and two runs: the image, `kernel.sha256`, the hash of the region the Lean model leaves at `0x20070000`, and the RTL harness's minstret for the same image |

**Why the UF2 family is `absolute`, and why the image must fit in sector 0.**
Experiments exp139 to exp145 wrote partition tables, and exp139's
partition 0 accepts only `rp2350-arm-s`. An `rp2350-riscv` UF2 dragged onto a
board that still has one could be refused or placed elsewhere. But exp138
measured that a stock board's unpartitioned space accepts the `absolute`
family, and exp139's table keeps that same word. So an absolute image confined
to sector 0, which no partition covers, lands at `0x10000000` either way, and
the table it overwrites in sector 0 is no longer there to redirect the boot.
`link_chip.ld` refuses an image over 4096 bytes. `tools/partimg` gained a
`bin` mode to write it, and `host/uf2check.py` reads the UF2 back without it.
`yi26` refuses RISC-V UF2s (the briefing noted it) but is not needed here: the
drag goes straight to the bootrom.

## What is checked without the board

`check.sh`:

- the shared SHA-256 against hashlib, and `partimg`'s tests;
- the UF2, read back independently: family `absolute`, every block in sector
  0, exactly the image, a jump to `_start` first and the IMAGE_DEF block right
  after;
- with the recorded toolchain (`build-toolchain.txt`), the UF2 byte for byte
  the committed hash;
- **the same shell built for the Hazard3 RTL**, with the print port in place
  of the LED: it passes all six checks, PMP entry 0 reads back as written
  (`0x1f`, XOR 0), the region hashes to the model's, and it counts
  **minstret = 108**, what the RTL harness counts for exp203; its verdict is
  ok. So the RTL does not show the PMP readback the board showed in run 1;
- seven wrong shells, each run on the RTL and each caught by the check it
  breaks, the last a shell that traps in step 2 and reports a fault;
- the LED's patterns, compiled for the host with a recorder in place of the
  LED and decoded the way a person counts: eight rounds, each read back as
  what was blinked.

## What only the board can say, and what it cannot

- **The count.** Run 1 says 108: silicon counts as the RTL does under this
  shell, though the RP2350's Hazard3 is v1.0-rc1 and the RTL a 2026 v1.1
  commit. exp203 found the count depends on what lies in memory behind an
  `mret`; here that is the same `harness.S`, in flash rather than RAM.
- **Whether everything around the count holds on silicon**: PMP, `mret` into
  User mode, the trap, the region the model predicted.
- **Not the time.** `mcycle` is not reported, because the clock is not set up.
  Constant time is exp207's and exp212's.
- **Not the hardware SHA-256.** HASH is not used; exp210 does that.

## Running it

```sh
./build.sh       # build/exp209.uf2, and the RTL build
./check.sh       # everything above; no board
./run.sh         # records capture.txt
```

Needs clang, lld, llvm-objcopy, cargo, a host C compiler, Lean
(`tools/lean/setup.sh`) and the Hazard3 testbench (`tools/hazard3/setup.sh`).

## Expected output

The board half is in **What the board has said** above, as reported. The
cloud half:

```text
=== exp209 — the count the LED blinks (cloud half) ===
recorded at 2026-10-05T02:00:10Z from commit b0d183e

>>> the build
build/expect.h: 5 image blocks, kernel a23ae89b0c8e2eaa…, region 76c6dc347213530b…, RTL minstret 108
build/exp209.bin  3476 bytes, flash sector 0 holds 4096
build/exp209.uf2  7168 bytes  sha256 35f7e1d932bddac2485bba0ada9689c679a109e1cbbed2457f8e41c92e6f016e

>>> the shell on the Hazard3 RTL: REPT failed number instret cycles a0 cause
52455054 00000001 00000000 0000006c 0000001f 00000000 00000000 00000008 exit=0 

>>> every check
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  the harness's SHA-256 agrees with hashlib at 14 lengths, 0 to 65536
PASS  partimg's tests pass, its bin mode among them
PASS  the shell builds for the chip and for the RTL, the chip's in 3476 of sector 0's 4096 bytes
PASS  all 14 blocks carry family 0xe48bff57, absolute
PASS  every block lies in flash sector 0, 0x10000000..0x10001000
PASS  together they are exactly the 3476-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 35f7e1d932bddac2…
PASS  on the RTL the shell's verdict is ok: all six checks pass, PMP reads back as written, minstret = 108
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — not ok
PASS  the shell catches a version where HALT is looked for under t0 = 2 — not ok
PASS  the shell catches a version where the result is expected to be 1 — not ok
PASS  the shell catches a version where the source is looked for 64 bytes late — not ok
PASS  the shell catches a version where the model's region hash is not the model's — not ok
PASS  the shell catches a version where the chip is asked to count 107 — not ok
PASS  the shell catches a version where PMP entry 0 is expected to say something else — reported as check 2, still ok
PASS  the shell catches a version where the shell itself traps in step 2 — a fault, not a verdict
```
