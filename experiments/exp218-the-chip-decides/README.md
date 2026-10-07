# exp218 — the chip decides

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Twenty short PIO programs run on PIO0 of a Pico 2, each built to land
where exp217's two emulators part from `lean/Pio/Machine.lean`, or on
something neither emulator checked. Each program runs until it stops. The
shell then reads, from the CPU, what the state machine holds:
- its pc;
- X, Y, ISR and OSR;
- the IRQ flags;
- the pins and directions it drives;
- the TX level;
- what RX gave up at each stop.

Each of these is compared with what the Lean model says, and the LED names
every case that differs. On a Pico 2 the LED flashed 18 times: case 18, the
IRQ flags, differed in something, and the other nineteen held what the model
says. Those nineteen include every place where an emulator parted from the
model. On each of them the chip sides with the model, and so with the
datasheet's prose.**

exp217 found thirteen places where an emulator and the model disagree. In
each one the model followed the datasheet's prose, and nothing had asked the
chip. This experiment asks it. The model is not changed here: if the chip
disagrees, that is recorded, and the model is fixed in an experiment of its
own.

## How a case runs

[`model/Cases.lean`](./model/Cases.lean) defines each case:
- a program, whose words come from lean/Pio's proved `encode`;
- where it starts;
- EXECCTRL, SHIFTCTRL and PINCTRL;
- two batches of TX words.

Every case ends by stopping. It either waits (`pull block` with TX empty, a
pin that stays low, `irq wait`) or jumps to itself. What it holds afterwards
therefore does not depend on how long the shell waited, and the model can
say it: `Cases.lean` steps the model until a step changes nothing. It then
writes [`shell/cases.h`](./shell/cases.h), with each case's words and what
the model says the chip holds.

The shell, [`shell/shell.c`](./shell/shell.c), is `tools/hazard3/shell`, as
in exp214 and exp216. For each case it runs these steps:

| Step | What the shell does |
| --- | --- |
| 1 | puts PIO0 through reset, so nothing carries over from the case before |
| 2 | loads the words, with the rest of instruction memory 0 (`jmp 0`, as the model reads an unloaded word); writes the three registers; restarts the state machine and executes a `jmp` to where the case starts |
| 3 | writes the first batch into TX, enables the machine for about 20 ms, disables it, and takes what RX holds |
| 4 | writes the second batch, then enables, waits and disables again |
| 5 | reads SM0_ADDR, IRQ, DBG_PADOUT, DBG_PADOE, the TX level, and what RX holds |
| 6 | reads ISR, X, Y and OSR. It executes `push noblock` through SM0_INSTR on the stopped machine, and before each of the last three a `mov isr, …` |
| 7 | compares each value with the model's |

The shift counts cannot be read from the CPU, so they are not compared.

Before the first case, GPIO2 to GPIO9 are set up once:
- **3, 6, 7 and 9** are pulled up by their pads;
- **2, 4, 5 and 8** are pulled down;
- input is enabled, output is disabled, and isolation is off;
- they are handed to PIO0.

Nothing drives these pins. A case that reads pins reads the pulls. The pads
are left like that after the run, which is harmless with nothing attached to
the header.

## The cases

| # | What it asks | Who parts from the model |
| --- | --- | --- |
| 1 | four words through OSR into X, Y, ISR and OSR, read back: the readout itself | — |
| 2 | `push iffull` at 4 bits of a threshold of 8, no autopush: nothing pushed | rp2040js pushes |
| 3 | the same at 8 of 8: pushed | — |
| 4 | `pull ifempty` at 4 bits of 8 out: no pull; at 8 of 8: pulled | rp2040js pulls; rp2040-pio-emulator compares with 32 |
| 5 | `out x, 32`: OSR shifted by 32 | rp2040js leaves OSR |
| 6 | `mov x, ::osr` and `mov y, ~osr` | rp2040-pio-emulator copies for `::` |
| 7 | `jmp !osre` after 8 bits of a threshold of 8: not taken | rp2040-pio-emulator compares with 32 |
| 8 | a wrap from 0 to 0 | rp2040-pio-emulator takes it as the program's end |
| 9 | a wrap from 5 to 3, round a `jmp x--` loop shifting X into ISR | — |
| 10 | `in pins, 8` from `IN_BASE` 2: GPIO2..9's pulls | rp2040-pio-emulator reads from GPIO0 |
| 11 | `wait pin`, `jmp pin`, `wait gpio`, and the RP2350's `wait jmppin`: pass where pulled up, stop where pulled down | — |
| 12 | `mov pins` and the RP2350's `mov pindirs` through the OUT mapping, 4 from GPIO4 | rp2040-pio-emulator writes 32 from GPIO0 |
| 13 | OUT pins from 31, three of them: they wrap to GPIO0 and 1 | both emulators stop at 31 |
| 14 | SET pins 30 and 31 | rp2040js keeps only 30 pins |
| 15 | `out exec`: a word from TX runs as an instruction | neither emulator checked |
| 16 | `mov exec`: X runs as an instruction | neither checked |
| 17 | `mov` from STATUS, TX level against N = 2 | neither checked |
| 18 | `irq set`, `irq clear`, `wait irq` clearing its flag, `irq wait`: flags 2 and 6 left | neither checked |
| 19 | `push block` on a full RX waits; after the shell takes four words, it pushes the fifth | rp2040js empties ISR while it waits |
| 20 | shifting left both ways, `jmp x--` past 0, `pull noblock` on an empty TX taking X | — |

The programs and the model's values for each case are in the expected
output below.

Several outcomes would be informative rather than wrong. Case 14 asks
whether DBG_PADOUT has bits for GPIO30 and 31 on an RP2350A, which has no
such pads; the model assumes it has. Case 13 avoids that question: the bit
it writes to GPIO31 is 0, so only the wrap to 0 and 1 is compared there.

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer. Nothing
should be connected to GPIO2 to GPIO9.

1. Check the file: its SHA-256 must be the one in
   [`exp218.uf2.sha256`](./exp218.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp218.uf2` onto it. The board restarts as a RISC-V machine.
4. Watch the LED. The cases take under a second; then the verdict repeats
   forever.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | every case held what the model says |
| **groups of flashes** | each group is one case that did not: count the flashes in a group for the case number. A short dark separates groups, and a long dark ends the list before it repeats |
| **fast blinking** | PIO0 never came out of reset |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

With groups of flashes, the useful record is the list of case numbers, read
over two rounds to be sure. The LED says which cases, not which value in
them. The RTL build reports both, so a case that differs on the chip can be
taken apart afterwards.

## What the RTL checks, and what it cannot

The Hazard3 RTL has neither PIO nor GPIO. The RTL build prints every register
write instead of making it, and stand-ins answer its reads
([`shell/board_sim.c`](./shell/board_sim.c)). The stand-ins read their
answers out of `cases.h`, so they say nothing about PIO.

- **The writes.** The shell's 1033 writes must be exactly
  [`expected.txt`](./expected.txt), in order.
  [`expected.py`](./expected.py) makes that file from the cases and the
  registers' fields, without reading `shell.c`.
- **The verdicts.**

  | Stand-in | Verdict |
  | --- | --- |
  | holds what the model says | no case differs |
  | never leaves reset | reset, before case 1 |
  | pushes on case 2's `push iffull` | case 2 alone, on RX at the first stop |
  | pins stop at GPIO31 | case 13 alone, on the pins |
  | never hands a word out in case 18 | case 18 alone, on the words that never came |
  | X wrong everywhere | all 20, the first on X |

- **Wrong shells.** Eight are each caught:
  - PIO0 not reset between cases;
  - the pads pulled the other way;
  - RX not taken at the first stop;
  - the second batch never written;
  - Y read where X should be;
  - RX not compared word by word;
  - a word that never comes out not counted;
  - only the first case run.

What only the board can say:
- whether a stopped state machine executes what SM0_INSTR is given, so that
  its registers can be read this way (exp214 and exp216 relied on that for a
  `jmp`);
- whether DBG_PADOUT and DBG_PADOE are the pins the model writes;
- and then, case by case, whether the chip holds what the model says.

## On the board

| | |
| --- | --- |
| UF2 | `exp218.uf2`, SHA-256 `f24549c01b21ae55a89197eb1aaff70bda0c781313f2202a8bc47c9b2c9547d0`, the committed one, built at 10322fd |
| Board | Pico 2, nothing on GPIO2..9 |
| How | BOOTSEL, the UF2 copied on, the LED watched |
| The LED | **18 flashes** |

The shell flashes once per failing case, in a group whose length is the
case number. Eighteen flashes is therefore case 18 and no other.

**Nineteen cases held what the model says**, every value read: pc, X, Y,
ISR, OSR, IRQ, the pins, the directions, the TX level, and RX at both stops.
On silicon:
- `push iffull` and `pull ifempty` compare the count with the threshold
  without autopush or autopull (cases 2 to 4), against rp2040js;
- `out x, 32` shifts OSR by 32 (case 5), against rp2040js;
- `mov`'s bit-reverse reverses (case 6), against rp2040-pio-emulator;
- `jmp !osre` compares with the threshold (case 7), against
  rp2040-pio-emulator;
- a wrap from 0 to 0 stays at 0 (case 8), against rp2040-pio-emulator;
- `in pins` reads from `IN_BASE` (case 10), against rp2040-pio-emulator;
- `mov pins` and `mov pindirs` go through the OUT mapping (case 12),
  against rp2040-pio-emulator;
- OUT pins wrap from GPIO31 to GPIO0 (case 13), against both emulators;
- DBG_PADOUT and DBG_PADOE carry GPIO30 and 31 on this RP2350A (case 14),
  against rp2040js;
- a `push block` that waits keeps ISR (case 19), against rp2040js;
- `wait jmppin`, `mov pindirs`, `out exec`, `mov exec` and STATUS (cases
  11, 12, 15, 16, 17), which neither emulator checked, are as the model
  has them.

Every one of these also depends on the readout: a stopped state machine
executes `mov isr, …` and `push noblock` given through SM0_INSTR. Case 1,
and every case after it that agreed, shows that it does.

**Case 18 differed**, and the LED cannot say in what. The case runs `irq
set 3`, `irq clear 3`, `irq set 5`, `wait 1 irq 5`, `irq set 6`, `irq wait
2`. The model leaves flags 2 and 6 set, and the machine waiting at 9 with
everything else 0. The readings that would tell the explanations apart:

| If it is | The model is | What would show it |
| --- | --- | --- |
| the IRQ flags: `wait 1 irq 5` not clearing 5, or `irq wait 2` not leaving 2 set | wrong | IRQ ≠ 0x44, every word read out |
| the readout: a machine waiting in `irq wait` not executing what SM0_INSTR gives it | not in question; the measurement is | words that never come out (field 11), IRQ 0x44 |
| the pc: `irq wait` stopping somewhere other than its own address | wrong | pc ≠ 9 |

Which of them it is will be the next experiment's question. That
experiment splits case 18 and reports the field, not only the case. The
model is not changed here.

One run on one board; nothing beyond it was recorded.

## What it does not do

- **Shift counts.** Not readable; not compared.
- **Timing, delay, side-set, autopush, autopull.** No case uses them.
- **Pins driven onto pads.** The pads of GPIO2..9 have their output
  disabled, and DBG_PADOUT is read instead. That is what PIO0 drives, not
  what a pin does.
- **More than once.** One run, read off the LED.

## Running it

```sh
./check.sh       # cases.h against Lean, expected.txt, the build, the UF2, the RTL
./build.sh       # build/exp218.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.
About a quarter of an hour. Nearly all of it is the wrong shells: some of
them wait out every readout's timeout on the RTL.

## Expected output

```text
=== exp218 — the chip decides ===
recorded at 2026-10-07T04:18:29Z from commit 10322fd

>>> the cases, and what lean/Pio/Machine.lean says the chip holds when each stops
case 1: readout: four words through OSR into X, Y, ISR and OSR, read back
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x12345678, 0x9abcdef0, 0x0f1e2d3c, 0xa5a5c3c3} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   a027  mov x, osr
      6   80a0  pull block
      7   a047  mov y, osr
      8   80a0  pull block
      9   a0c7  mov isr, osr
      10   80a0  pull block
      11   80a0  pull block
    the model: pc 11  X 0x12345678  Y 0x9abcdef0  ISR 0x0f1e2d3c  OSR 0xa5a5c3c3  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 2: push iffull, 4 bits of 8, no autopush: nothing is pushed (rp2040js pushes)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x008c0000  PINCTRL 0x14000000  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e025  set x, 5
      5   4024  in x, 4
      6   8040  push iffull noblock
      7   80a0  pull block
    the model: pc 7  X 0x00000005  Y 0x00000000  ISR 0x50000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 3: push iffull, 8 bits of 8: pushed
    EXECCTRL 0x0001f000  SHIFTCTRL 0x008c0000  PINCTRL 0x14000000  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e025  set x, 5
      5   4024  in x, 4
      6   4024  in x, 4
      7   8040  push iffull noblock
      8   80a0  pull block
    the model: pc 8  X 0x00000005  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {0x55000000} then {}
case 4: pull ifempty, 4 bits of 8 out: no pull; 8 of 8: pulled (both emulators part)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x100c0000  PINCTRL 0x14000000  TX {0x87654321, 0xcafef00d} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   6024  out x, 4
      6   80c0  pull ifempty noblock
      7   a047  mov y, osr
      8   6064  out null, 4
      9   80c0  pull ifempty noblock
      10   80a0  pull block
    the model: pc 10  X 0x00000001  Y 0x08765432  ISR 0x00000000  OSR 0xcafef00d  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 5: out x, 32: OSR is shifted by 32 (rp2040js leaves it)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0xdeadbeef} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   6020  out x, 32
      6   80a0  pull block
    the model: pc 6  X 0xdeadbeef  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 6: mov's bit-reverse and invert (rp2040-pio-emulator copies)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x12345678} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   a037  mov x, ::osr
      6   a04f  mov y, ~osr
      7   80a0  pull block
    the model: pc 7  X 0x1e6a2c48  Y 0xedcba987  ISR 0x00000000  OSR 0x12345678  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 7: jmp !osre, 8 bits out of a threshold of 8: not taken (rp2040-pio-emulator takes it)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x100c0000  PINCTRL 0x14000000  TX {0x0000ffff} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   6068  out null, 8
      6   00e9  jmp !osre, 9
      7   e041  set y, 1
      8   000a  jmp 10
      9   e042  set y, 2
      10   80a0  pull block
    the model: pc 10  X 0x00000000  Y 0x00000001  ISR 0x00000000  OSR 0x000000ff  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 8: a wrap from 0 to 0: instruction 0, again and again (rp2040-pio-emulator goes on to 1)
    EXECCTRL 0x00000000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
      0   e045  set y, 5
      1   e047  set y, 7
      2 ← a0c3  mov isr, null
      3   a0e3  mov osr, null
      4   a023  mov x, null
      5   a043  mov y, null
      6   0000  jmp 0
    the model: pc 0  X 0x00000000  Y 0x00000005  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 9: a wrap from 5 to 3, round a jmp x-- loop that shifts X into ISR
    EXECCTRL 0x00005180  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
      0 ← e024  set x, 4
      1   a0c3  mov isr, null
      2   a043  mov y, null
      3   0026  jmp !x, 6
      4   0045  jmp x--, 5
      5   4024  in x, 4
      6   80a0  pull block
    the model: pc 6  X 0x00000000  Y 0x00000000  ISR 0x01230000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 10: in pins, 8 from IN_BASE 2: GPIO2..9 (rp2040-pio-emulator reads from GPIO0)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14010000  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   4008  in pins, 8
      5   80a0  pull block
    the model: pc 5  X 0x00000000  Y 0x00000000  ISR 0xb2000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 11: wait pin, jmp pin, wait gpio, wait jmppin: pass where high, wait where low
    EXECCTRL 0x0601f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14010000  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   20a1  wait 1 pin 1
      5   e041  set y, 1
      6   00c8  jmp pin, 8
      7   e042  set y, 2
      8   2087  wait 1 gpio 7
      9   20e1  wait 1 jmppin + 1
      10   e023  set x, 3
      11   20a0  wait 1 pin 0
    the model: pc 11  X 0x00000003  Y 0x00000001  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 12: mov pins and mov pindirs through the OUT mapping (rp2040-pio-emulator writes 32 from 0)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14400004  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e036  set x, 22
      5   a001  mov pins, x
      6   a061  mov pindirs, x
      7   80a0  pull block
    the model: pc 7  X 0x00000016  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000060  dirs 0x00000060  TX level 0  RX {} then {}
case 13: OUT pins from 31, three of them: they wrap to 0 (both emulators stop at 31)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x1430001f  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e026  set x, 6
      5   a001  mov pins, x
      6   a061  mov pindirs, x
      7   80a0  pull block
    the model: pc 7  X 0x00000006  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000003  dirs 0x00000003  TX level 0  RX {} then {}
case 14: SET pins 30 and 31: the machine drives 32 pins (rp2040js keeps 30)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x080003c0  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e003  set pins, 3
      5   e083  set pindirs, 3
      6   80a0  pull block
    the model: pc 6  X 0x00000000  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0xc0000000  dirs 0xc0000000  TX level 0  RX {} then {}
case 15: out exec: a word from TX runs as an instruction
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x0000e049} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   60f0  out exec, 16
      6   80a0  pull block
    the model: pc 6  X 0x00000000  Y 0x00000009  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 16: mov exec: X runs as an instruction
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x0000a04b} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   80a0  pull block
      5   a027  mov x, osr
      6   a081  mov exec, x
      7   80a0  pull block
    the model: pc 7  X 0x0000a04b  Y 0xffffffff  ISR 0x00000000  OSR 0x0000a04b  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 17: mov from STATUS, TX level against N = 2: 0 at 3 words, all ones at 1
    EXECCTRL 0x0001f002  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x00000001, 0x00000002, 0x00000003} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   a045  mov y, status
      5   80a0  pull block
      6   80a0  pull block
      7   a025  mov x, status
      8   80a0  pull block
      9   80a0  pull block
    the model: pc 9  X 0xffffffff  Y 0x00000000  ISR 0x00000000  OSR 0x00000003  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 18: irq set, clear, wait irq clearing its flag, and irq wait: flags 2 and 6 left
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   c003  irq set 3
      5   c043  irq clear 3
      6   c005  irq set 5
      7   20c5  wait 1 irq 5
      8   c006  irq set 6
      9   c022  irq wait 2
    the model: pc 9  X 0x00000000  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x44
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
case 19: push block on a full RX waits, then pushes when there is room (rp2040js empties ISR)
    EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {0x0000600d}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e021  set x, 1
      5   a0c1  mov isr, x
      6   8020  push block
      7   e022  set x, 2
      8   a0c1  mov isr, x
      9   8020  push block
      10   e023  set x, 3
      11   a0c1  mov isr, x
      12   8020  push block
      13   e024  set x, 4
      14   a0c1  mov isr, x
      15   8020  push block
      16   e025  set x, 5
      17   a0c1  mov isr, x
      18   8020  push block
      19   80a0  pull block
      20   a047  mov y, osr
      21   80a0  pull block
    the model: pc 21  X 0x00000005  Y 0x0000600d  ISR 0x00000000  OSR 0x0000600d  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {0x00000001, 0x00000002, 0x00000003, 0x00000004} then {0x00000005}
case 20: shifting left both ways, jmp x-- past 0, and pull noblock on an empty TX taking X
    EXECCTRL 0x0001f000  SHIFTCTRL 0x00000000  PINCTRL 0x14000000  TX {0xf0e1d2c3} then {}
      0 ← a0c3  mov isr, null
      1   a0e3  mov osr, null
      2   a023  mov x, null
      3   a043  mov y, null
      4   e023  set x, 3
      5   0045  jmp x--, 5
      6   80a0  pull block
      7   6048  out y, 8
      8   40ec  in osr, 12
      9   8080  pull noblock
      10   80a0  pull block
    the model: pc 10  X 0xffffffff  Y 0x000000f0  ISR 0x00000300  OSR 0xffffffff  IRQ 0x00
               pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}

>>> the shell, for the chip and for the RTL
build/exp218.bin  6956 bytes, the build allows 16384
build/exp218.uf2  14336 bytes  sha256 f24549c01b21ae55a89197eb1aaff70bda0c781313f2202a8bc47c9b2c9547d0

>>> on the RTL, against a stand-in that holds what the model says: the verdict
    (every one of the 1033 writes is in expected.txt, and check.sh holds the run to it)
REPT 00000000 00000000 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  shell/cases.h is what model/Cases.lean writes: 20 cases, each stopping in the model
PASS  expected.txt is what expected.py makes of shell/cases.h: 1033 writes
PASS  the shell builds for the chip and for the RTL, the chip's in 6956 of the 16384 bytes it may use
PASS  all 28 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 6956-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: f24549c01b21ae55…
PASS  on the RTL, against a PIO that holds what the model says: every register written as expected.txt says, in order, and no case differs
PASS  on the RTL, against a PIO that never leaves reset: said so before case 1, after the pads and the reset and nothing more
PASS  on the RTL, against one that pushes on case 2's push iffull: case 2 alone, on what RX held at the first stop
PASS  on the RTL, against one whose pins stop at GPIO31: case 13 alone, on the pins
PASS  on the RTL, against one that never hands a word out in case 18: case 18 alone, on the words that never came
PASS  on the RTL, against one whose X is wrong everywhere: all 20 cases, the first on X
PASS  the RTL runs catch a shell where PIO0 is not reset between cases
PASS  the RTL runs catch a shell where GPIO2..9 are pulled the other way
PASS  the RTL runs catch a shell where what RX holds at the first stop is not taken
PASS  the RTL runs catch a shell where the second batch is never written
PASS  the RTL runs catch a shell where Y is read where X should be
PASS  the RTL runs catch a shell where the RX lists are not compared word by word
PASS  the RTL runs catch a shell where a word that never comes out is not counted
PASS  the RTL runs catch a shell where only the first case is run
```
