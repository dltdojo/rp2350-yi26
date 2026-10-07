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
every case that differs. No board run is recorded yet.**

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
CAPTURE
```
