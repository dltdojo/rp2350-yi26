# exp214 — the words the PIO inverts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The first PIO in this repository, from the RISC-V bare-metal C shell that
exp209 to exp212 run on: bring PIO0 out of reset, load a three-instruction
program into it, start state machine 0, and hand it eight words one at a
time. Each must come back through the RX FIFO as its bitwise complement.
Then both FIFOs must be empty. The program's bytes are checked against
Raspberry Pi's own assembler. On the Hazard3 RTL, which has no PIO, every
register the shell writes is checked in order against what the datasheet
asks for, and every way the PIO could fail gives its own verdict. Not yet run
on a board.**

This is a foundation, and it is deliberately one thing. Nothing here has
driven a PIO before. Later work on PIO, including anything that proves
properties of the bytes a PIO program is made of, should stand on a shell
that has already been seen to load a program, start a state machine and
talk to it through its FIFOs. If that later work fails on a board, this
experiment is how to tell a wrong proof from a wrong register.

## Why a complement, and why FIFOs

The two FIFOs are the one way in and out of a state machine that needs no
wiring and no instrument: C writes `TXF0`, the program runs, and C reads
`RXF0`. Nothing about pins, clocks for the outside world or timing is in
it.

The program does not just echo, because an echo cannot be told apart from a
broken one. If the shell reads back the word it wrote, the state machine
might have run, or the read might have returned something that never moved.
The complement can only come from `mov isr, ~osr` having run.

```text
.program invert
.wrap_target
    pull block          ; OSR <- TX FIFO, waiting while it is empty
    mov isr, ~osr       ; ISR <- ~OSR
    push block          ; RX FIFO <- ISR, waiting while it is full
.wrap
```

[`invert.pio`](./invert.pio). [`shell/pio.h`](./shell/pio.h) encodes the
three instructions by hand from the datasheet's instruction table, field by
field. `check.sh` holds them to what `pioasm` assembles from `invert.pio`:
`80a0 a0cf 8020`. `pioasm` comes from [`tools/pioasm/`](../../tools/pioasm/),
built from pico-sdk 2.3.1, pinned by tag and commit.

## The shell

`tools/hazard3/shell`, as exp209 to exp212 use it: flash sector 0, RISC-V,
Machine mode, the LED through `led.h`. No payload runs. The harness is
linked only because the start code sends every trap to `handle`, and here
every trap is the shell's own.

| Step | What the shell does |
| --- | --- |
| 1 | lets `mcycle` run (Hazard3 comes out of reset with it held), and turns the LED on: alive |
| 2 | takes PIO0 out of reset (RESETS bit 11) and waits for `RESET_DONE` |
| 3 | loads the program into `INSTR_MEM0..2`; wraps state machine 0 from instruction 2 back to 0; restarts it and its clock divider; executes `jmp 0` on it; enables it |
| 4 | for each of eight words: waits for room in TX, writes it, waits for something in RX, reads it, and checks it is the complement |
| 5 | checks both FIFOs are empty, and stops the state machine |

Every wait gives up after about 0.1 s of `mcycle`, so a PIO that never
answers gives a verdict, not a hang. Every address and field is rp-pac
7.0.0's for the RP235x, written out in `shell/pio.h` as `led.h` writes out
the LED's.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp214.uf2.sha256`](./exp214.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp214.uf2` onto it. The drive disappears and the board restarts as
   a RISC-V machine.
4. Look at the LED for a few seconds.

To go back to anything else: hold BOOTSEL, plug in, copy that UF2. The shell
writes nothing to flash.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | all eight words came back complemented, and both FIFOs were empty at the end |
| **1 flash**, then dark, repeated | PIO0 never reported out of reset |
| **2 flashes** | a word went in and nothing came back: the state machine did not run, or not this program |
| **3 flashes** | a word came back unchanged: something answered, but not `mov isr, ~osr` |
| **4 flashes** | a word came back as something else |
| **5 flashes** | a FIFO still held something at the end |
| **on, steady** | the shell trapped. Most likely an access to PIO0 itself faulted |
| **dark** | the shell never ran |

Slow blinking and counted flashes are `led.h`'s two shapes, the ones exp212
was read with.

## What the RTL checks, and what it cannot

The Hazard3 RTL is a core and nothing else, so the RTL build of the shell
prints each register write instead of making it, and its reads are answered
by a stand-in chosen at build time ([`shell/board_sim.c`](./shell/board_sim.c)).
The stand-in is not a model of PIO, and nothing here simulates one.

- **The writes.** Against a stand-in that works, the shell's writes must be
  exactly [`expected.txt`](./expected.txt), every address and value in
  order, each line saying why: reset, program, wrap, restart, `jmp 0`,
  enable, the eight words, stop.
- **The verdicts.** Against five stand-ins that fail, it must say how they
  fail:

  | Stand-in | Verdict |
  | --- | --- |
  | never leaves reset | 1, after the reset write and nothing more |
  | never answers | 2, on the first word |
  | hands the word back | 3, on the first word |
  | answers the last word wrongly | 4, on `deadbeef` |
  | leaves a word in RX | 5, with FSTAT |

- **Wrong shells.** Six are each caught by those runs: PIO1's reset bit
  instead of PIO0's, the wrap one instruction early, no `jmp 0` before the
  start, `mov isr, osr` without the complement, no check for a wrong
  answer, and no check of the FIFOs at the end.

What only the board can say:
- whether PIO0 is reachable from Machine mode as the bootrom leaves it;
- whether the encodings and fields above are the chip's;
- whether the state machine runs at the clock the bootrom left.

The first RTL run caught one mistake that would have reached the board.
The timeouts are measured with `mcycle`, which Hazard3 holds at reset. The
"never answers" stand-in waited forever. On the chip that would have been a
steady LED where 2 flashes were meant. The shell now lets `mcycle` run
first.

## What it does not do

- **Pins.** No GPIO is given to PIO0. Driving a pin is the next thing, not
  this one.
- **More than one state machine, autopush, autopull, side-set, clock
  division.** All at their reset values.
- **Proofs.** Nothing here is proved; the program's bytes are compared with
  `pioasm`, and the shell's writes with a list written from the datasheet.
- **The chip.** **Not yet run on a board.**

## Running it

```sh
./check.sh       # pioasm, the build, the UF2, the RTL against six stand-ins, six wrong shells
./build.sh       # build/exp214.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs the pioasm build (`tools/pioasm/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
Under a minute.

## Expected output

CAPTURE
