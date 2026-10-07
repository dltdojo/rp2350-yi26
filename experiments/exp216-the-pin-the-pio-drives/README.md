# exp216 — the pin the PIO drives

<!-- SPDX-License-Identifier: Apache-2.0 -->

**PIO0 drives the LED's pin, GPIO25, and the CPU reads it back. Eight
commands go in through the TX FIFO. For each one, the PIO program sets the
pin with `set pins` and answers through RX, and the shell reads the pin's
level at the pad through SIO's `GPIO_IN`. SIO's own output for the pin stays
high throughout, so a pin that reads 0 when told 0 is one that PIO is
driving. The program is written as exp215's Lean instructions, and its nine
words come out of the proved `encode`. They are the first words on the chip
made by the proved encoder: stated in a theorem, and the same as `pioasm`'s
reading of `drive.pio`. Not yet run on a board.**

exp214 showed PIO0 running a program and talking through its FIFOs, with no
pin involved. exp215 proved that a PIO word has one reading. This puts the
two together and adds one thing: a pin.

## The program

```text
  0  e081  set pindirs, 1      the pin is an output: once, before the wrap
  1  80a0  pull block          ← wrap target: wait for a command
  2  6020  out x, 32
  3  0026  jmp !x, 6
  4  e001  set pins, 1
  5  0007  jmp 7
  6  e000  set pins, 0
  7  a0c1  mov isr, x
  8  8020  push block          → wrap: the answer, once the pin is set
```

[`proof/Program.lean`](./proof/Program.lean) writes the program as
`Pio.Instr` values, and its theorems say three things:
- `words`: the nine words are what `encode` makes;
- `reads_back`: each word decodes back to the instruction it came from, by
  exp215's `decode_encode`;
- `jumps_inside`: every jump and the wrap are inside the program.

`lean --run` writes the words into [`shell/program.h`](./shell/program.h).
`check.sh` checks that file against Lean's output, and the words against what
`pioasm` makes of [`drive.pio`](./drive.pio), the same program written as
assembly.

Only `set pins` and `set pindirs` touch the pin. Side-set, the usual way PIO
drives a pin, is outside what exp215 proved, so it is left out here.

## The shell

`tools/hazard3/shell`, as exp209 to exp214 use it. The PIO registers, the
write checker and the stand-in loops came out of exp214 into
`tools/hazard3/shell/` for this one; exp214's UF2 is unchanged by that.

| Step | What the shell does |
| --- | --- |
| 1 | lets `mcycle` run, and turns the LED on through SIO: alive, and SIO's output for GPIO25 high |
| 2 | takes PIO0 out of reset |
| 3 | loads the nine words; wraps state machine 0 from 8 back to 1, so instruction 0 runs once; maps SET pins to GPIO25 (`SET_BASE` 25, `SET_COUNT` 1); hands GPIO25's function to PIO0; restarts, `jmp 0`, enables |
| 4 | for each of eight commands, `0 1 1 0 1 0 0 1`: writes it to TX, waits for the answer in RX, checks it is the command, then reads GPIO25 through `GPIO_IN` and checks it is the level commanded |
| 5 | checks both FIFOs are empty, stops the state machine, and gives GPIO25 back to SIO for the verdict |

## Running it on the board

You need a **Pico 2** (not a Pico 2 W), a USB cable, and a computer.

1. Check the file: its SHA-256 must be the one in
   [`exp216.uf2.sha256`](./exp216.uf2.sha256).
2. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears.
3. Copy `exp216.uf2` onto it. The board restarts as a RISC-V machine.
4. Look at the LED for a few seconds.

The commands take a fraction of a second, so the LED does not visibly follow
them; what you see is the verdict after.

### What the LED says

| The LED | Means |
| --- | --- |
| **slow blinking** | all eight commands were answered, the pin read back as commanded each time, and both FIFOs were empty at the end |
| **1 flash**, then dark, repeated | PIO0 never reported out of reset |
| **2 flashes** | a command went in and no answer came back |
| **3 flashes** | an answer was not the command |
| **4 flashes** | told 0, the pin read 1: SIO's level, so PIO was not driving the pin |
| **5 flashes** | told 1, the pin read 0 |
| **6 flashes** | a FIFO still held something at the end |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

4 flashes is the one this experiment exists to tell apart from slow
blinking. If the pin stayed SIO's, nothing would be wrong with the FIFOs or
the answers, and only the pin would say so.

## What the RTL checks, and what it cannot

The Hazard3 RTL has neither PIO nor GPIO. The RTL build prints each register
write instead of making it, and stand-ins answer its reads
([`shell/board_sim.c`](./shell/board_sim.c)). They are not a model of PIO or
of a pad.

- **The writes.** Against a PIO and pin that work, the writes must be exactly
  [`expected.txt`](./expected.txt), in order, each line saying why.
- **The verdicts.** Against six stand-ins that fail, each must get its own
  verdict:

  | Stand-in | Verdict |
  | --- | --- |
  | never leaves reset | 1 |
  | never answers | 2, on the first command |
  | answers the second command wrongly | 3, on it |
  | pin stays at SIO's 1 | 4, on the first command (told 0) |
  | pin stays at 0 | 5, on the second command (told 1) |
  | leaves a word in RX | 6 |

- **Wrong shells.** Six are each caught by those runs:
  - the pin never handed to PIO0;
  - SET mapped from GPIO24;
  - the wrap starting at 0;
  - the pin not read back;
  - the answer not looked at;
  - the pin not given back to SIO at the end.

What only the board can say:
- whether handing GPIO25 to PIO0 takes it away from SIO;
- whether `set pins` drives the pad;
- whether `GPIO_IN` reads the level PIO drives.

## What it does not do

- **Timing.** One level at a time, read back after the answer; nothing about
  how fast the pin moves.
- **Side-set, `out pins`, more than one pin.**
- **A proof of what the program does.** The words are proved to be these
  instructions; what the instructions do to the pin is a model of PIO, which
  is not here. The board is the evidence for that.
- **The chip.** **Not yet run on a board.**

## Running it

```sh
./check.sh       # the proof, its mutants, program.h, pioasm, the build, the UF2, the RTL
./build.sh       # build/exp216.uf2 and build/sim.bin
./run.sh         # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`), pioasm (`tools/pioasm/setup.sh`), the
Hazard3 testbench (`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy,
cargo and python3. About a minute.

## Expected output

CAPTURE
