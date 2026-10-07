# exp214 — the words the PIO inverts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**The first PIO in this repository, from the RISC-V bare-metal C shell that
exp209 to exp212 run on: bring PIO0 out of reset, load a three-instruction
program into it, start state machine 0, and hand it eight words one at a
time. Each must come back through the RX FIFO as its bitwise complement.
Then both FIFOs must be empty. The program's bytes are checked against
Raspberry Pi's own assembler. On the Hazard3 RTL, which has no PIO, every
register the shell writes is checked in order against what the datasheet
asks for, and every way the PIO could fail gives its own verdict. On a
Pico 2 it blinked slowly: all eight words came back complemented, and both
FIFOs were empty at the end.**

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

What only the board could say, and on the board it did (below):
- whether PIO0 is reachable from Machine mode as the bootrom leaves it;
- whether the encodings and fields above are the chip's;
- whether the state machine runs at the clock the bootrom left.

The first RTL run caught one mistake that would have reached the board.
The timeouts are measured with `mcycle`, which Hazard3 holds at reset. The
"never answers" stand-in waited forever. On the chip that would have been a
steady LED where 2 flashes were meant. The shell now lets `mcycle` run
first.

## On the board

| | |
| --- | --- |
| UF2 | `exp214.uf2`, SHA-256 `0512ba5475593f5a53d92bbe20b4157ba4bb8c3485bc6da1bed2530a583f8cb4`, the committed one, built at d2ac4d1 |
| Board | Pico 2 |
| How | BOOTSEL, the UF2 copied on, the LED watched |
| The LED | **slow blinking** |

Slow blinking is verdict 0, and the shell reaches it in only one way. PIO0
came out of reset. The three words of `invert.pio` loaded and ran from
instruction 0. Each of the eight words came back through RX as its
complement, within the timeout, in order. Both FIFOs were then empty. So on
silicon:
- PIO0 is reachable from Machine mode as the bootrom leaves the chip;
- the addresses and fields in `shell/pio.h` are the chip's, and so are the
  three encodings `pioasm` agreed with;
- the state machine runs at whatever clock the bootrom left.

What the LED cannot say is how fast it ran: one bit, and the timeout is
about 0.1 s a word. One run; nothing beyond it was recorded.

## What it does not do

- **Pins.** No GPIO is given to PIO0. Driving a pin is the next thing, not
  this one.
- **More than one state machine, autopush, autopull, side-set, clock
  division.** All at their reset values.
- **Proofs.** Nothing here is proved; the program's bytes are compared with
  `pioasm`, and the shell's writes with a list written from the datasheet.
- **More than once.** One Pico 2, one run, read off the LED.

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

```text
=== exp214 — the words the PIO inverts ===
recorded at 2026-10-07T00:44:38Z from commit d2ac4d1

>>> invert.pio, as pioasm assembles it
pioasm version: 2.3.1
80a0
a0cf
8020

>>> the shell, for the chip and for the RTL
build/exp214.bin  1576 bytes, flash sector 0 holds 4096
build/exp214.uf2  3584 bytes  sha256 0512ba5475593f5a53d92bbe20b4157ba4bb8c3485bc6da1bed2530a583f8cb4

>>> on the RTL, against a stand-in PIO that works: every write, then the verdict

WRIT 40023000 00000800 
WRIT 50200048 000080a0 
WRIT 5020004c 0000a0cf 
WRIT 50200050 00008020 
WRIT 502000cc 00002000 
WRIT 50200000 00000110 
WRIT 502000d8 00000000 
WRIT 50200000 00000001 
WRIT 50200010 00000000 
WRIT 50200010 ffffffff 
WRIT 50200010 12345678 
WRIT 50200010 80000001 
WRIT 50200010 55555555 
WRIT 50200010 aaaaaaaa 
WRIT 50200010 0000ffff 
WRIT 50200010 deadbeef 
WRIT 50200000 00000000 
REPT 00000000 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  invert.pio is the words shell/pio.h encodes by hand: pioasm says 80a0 a0cf 8020
PASS  the shell builds for the chip and for the RTL, the chip's in 1576 of sector 0's 4096 bytes
PASS  all 7 blocks carry family 0xe48bff57, absolute
PASS  every block lies in flash sector 0, 0x10000000..0x10001000
PASS  together they are exactly the 1576-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 0512ba5475593f5a…
PASS  on the RTL, against a PIO that works: every register written as expected.txt says, in order, and ok
PASS  on the RTL, against one that never leaves reset: verdict 1, after the reset write and nothing more
PASS  on the RTL, against one that never answers: verdict 2 on the first word
PASS  on the RTL, against one that hands the word back unchanged: verdict 3 on the first word
PASS  on the RTL, against one that answers the last word wrongly: verdict 4 on deadbeef
PASS  on the RTL, against one that leaves a word in RX: verdict 5, FSTAT showing it
PASS  the RTL runs catch a shell where PIO1 is taken out of reset, not PIO0
PASS  the RTL runs catch a shell where the program wraps after its second instruction
PASS  the RTL runs catch a shell where SM0 is not sent to instruction 0 before it starts
PASS  the RTL runs catch a shell where mov isr, osr is loaded, without the complement
PASS  the RTL runs catch a shell where a wrong answer is not looked for
PASS  the RTL runs catch a shell where the FIFOs are not looked at at the end
```
