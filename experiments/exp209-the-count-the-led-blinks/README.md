# exp209 — the count the LED blinks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The first RISC-V firmware in this repository: a shell, 3960 bytes in flash
sector 0 of a Pico 2, that runs exp203's proved 60-byte kernel in User mode
and blinks out on the LED how many instructions the chip counted. The proof
says 105, and the Hazard3 RTL counts 108 under the same shell. Whether the
RP2350's own core, an older Hazard3, counts 108 too is the question this
experiment exists to answer. Its board half needs a person to count flashes,
and has not been run yet.**

This is the board half of the verified-kernel road (see its
[briefing](../../docs/2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md)),
in its smallest form: one kernel, no HASH, and the LED as the only way
anything gets out.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W: its LED is on the wireless chip, which
this shell cannot reach), a USB cable, and a computer. A phone camera helps.

1. Check the file: its SHA-256 must be the one in
   [`exp209.uf2.sha256`](./exp209.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp209.uf2` onto it. The drive disappears and the board restarts,
   this time as a RISC-V machine.
4. Watch the LED, ideally **filming it with a phone**: you count flashes
   rather than time them, and a video can be counted at leisure. The pattern
   repeats forever, so there is no hurry.

To go back to anything else afterwards: hold BOOTSEL, plug in, and copy that
UF2. The shell writes nothing to flash.

### What the LED says

| You see | It means |
| --- | --- |
| dark from the start | the shell never ran, or failed before the LED came up (step 1) |
| on, and staying on for over a minute | the shell hung without trapping, somewhere in steps 1–4 |
| **one long glow**, then groups of short blinks | **PASS**: all six checks passed; the groups are minstret |
| **K long flashes**, then groups of short blinks | **FAIL**: check K failed; the groups are minstret, or mcause if K = 3 |
| fast flicker, then groups of short blinks | the shell itself trapped; the groups are the step it was in |

**Reading a number.** One group of short blinks per decimal digit, most
significant first, with a longer dark gap between groups. Ten blinks mean 0.
After the last digit comes a long dark gap, then the whole round starts again.
108 looks like this:

```text
▬▬▬▬▬▬▬▬▬▬   •   ••••••••••   ••••••••            (repeat)
  PASS       1       0            8
```

**The six checks**, in order; the first one that fails is the one reported:

| K | Check |
| --- | --- |
| 1 | the 60 bytes copied into SRAM hash to `kernel.sha256`: it is the proved kernel |
| 2 | PMP entry 0 reads back as the shell wrote it |
| 3 | the kernel halted: `ecall` with `t0 = 1` |
| 4 | its result, `a0`, is 0 |
| 5 | the 64 bytes at the destination are the 64 at the source |
| 6 | the whole 64 KiB region hashes to what the Lean model left there |

The steps, for a fault: 1 the LED, 2 placing the image, 3 hashing the kernel,
4 entering it, 5 checking what it left.

### What to send back

The verdict and the number, for example **"PASS, 1-0-8"**, and if you can,
**how long the glow lasted** (from the video). The glow is 60,000,000 cycles of
a clock the shell never touches, so its length gives the clock's speed:
about `60 / seconds` MHz. That is the one assumption in this experiment. One
blink unit is 2,000,000 cycles, which is about 0.18 s if the bootrom leaves
the ring oscillator at its usual ~11 MHz. If it left something much faster,
the blinks are short, and the video is how to count them.

## What the shell is

Plain assembly and C, 3960 bytes. It is not the Rust shell the briefing
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
| [`shell/board_chip.c`](./shell/board_chip.c) | GPIO25 through SIO, every address rp-pac's for the RP235x; nothing else on the chip is touched, the clock included |
| [`shell/blink.c`](./shell/blink.c) | the LED's language |
| [`gen.py`](./gen.py) | everything compared against, from exp203's own files: the image, `kernel.sha256`, and the hash of the region the Lean model leaves at `0x20070000` |

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
  of the LED: it passes all six checks, the region hashes to the model's, and
  it counts **minstret = 108**, what the RTL harness counts for exp203;
- seven wrong shells, each run on the RTL and each caught by the check it
  breaks, the last a shell that traps in step 2 and reports a fault;
- the LED's patterns, compiled for the host with a recorder in place of the
  LED and decoded the way a person counts: eight rounds, each read back as
  what was blinked.

## What only the board can say, and what it cannot

- **The count.** 108 means silicon counts as the RTL does under this shell.
  Any other number is the finding: the RP2350's Hazard3 is v1.0-rc1, the RTL a
  2026 v1.1 commit, and exp203 already found the count depends on what is in
  memory behind an `mret`.
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

The board half has **not been run**. What the LED shows is to be pasted here
once someone has counted it. The cloud half:

CAPTURE
