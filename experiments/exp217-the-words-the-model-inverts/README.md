# exp217 — the words the model inverts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A model of one PIO state machine, an instruction at a time, in
[`lean/Pio/Machine.lean`](../../lean/Pio/Machine.lean), and exp214's `invert`
program proved on it. From the top of the loop, any list of words in TX that
fits the RX FIFO comes back through RX complemented and in order, three
steps a word. With TX empty, the machine waits. Six wrong models are refused
by the proof. Nine more pass it, because a proof about three instructions
says nothing about the rest. Each of the nine is refused by running the model
step by step against two emulators written by others, rp2040js and
rp2040-pio-emulator, on 700 seeded cases. Every disagreement with either
emulator is one of thirteen named deviations. Each deviation is the
emulator's, and each has the datasheet's reason.**

exp214 ran `invert` on a Pico 2 and saw eight words come back complemented.
exp215 proved that each of its three words has one reading. What was missing
is what those instructions *do*. This experiment adds that as a model, proves
the program against it, and holds the model to somebody else's reading of
the datasheet.

## The model

[`lean/Pio/Machine.lean`](../../lean/Pio/Machine.lean) models one state
machine of one PIO block, from the RP2350 datasheet's §11.4. Each step does
one of three things:
- completes an instruction;
- waits on one: a FIFO is empty or full, or a pin or flag is not yet at its
  level. The state is unchanged, and the same instruction is tried again;
- counts down the delay the last instruction asked for.

Time is counted, not modelled, so a theorem here says what a program does,
not how fast.

| In | |
| --- | --- |
| registers | X, Y; ISR and OSR with their shift counts, either direction, push and pull thresholds |
| FIFOs | TX and RX, four words each |
| pins | the values and directions this machine drives, through the OUT and SET mappings (wrapping from 31 to 0); what it reads is the pads, its own output where it drives and an outside input elsewhere |
| flags | the block's eight IRQ flags, as machine 0 sees them |
| the rest | `mov` from STATUS; `mov` and `out` to EXEC and PC; the RP2350's `mov pindirs` and `wait jmppin` |

`step` answers `none` rather than guess for:
- the IRQ index modes `prev` and `next`, which name other PIO blocks;
- `mov` to and from the RX FIFO, which needs a FIFO join mode the model does
  not have.

Autopush, autopull, side-set and the clock divider are not here. A program
that needs them is outside every theorem about this model.

## What is proved

[`proof/Invert.lean`](./proof/Invert.lean) loads exp214's words `80a0 a0cf
8020` at 0, wrapped from 2 back to 0, everything else at reset.

| Theorem | Says |
| --- | --- |
| `one_word` | from the top, with `w` first in TX and room in RX, three steps later `w` has left TX, `~w` is last in RX, and the machine is at the top again |
| `every_word` | from the top, with words `ws` in TX and `rx.length + ws.length ≤ 4`, `3·|ws|` steps later TX is empty and RX is what it was followed by `ws.map (~~~·)` |
| `waits` | at the top with TX empty, a step changes nothing: `pull block` stalls |

Room is written as 4, the chip's FIFO depth, not as the model's constant. A
model with another depth therefore does not prove it.

Each theorem rests on `propext` and `Quot.sound`. Each wrong model in
[`proof/mutants.txt`](./proof/mutants.txt) is refused by the proof:
- pull leaves the word in TX;
- push puts ISR at the front of RX;
- `mov`'s invert reverses the bits instead;
- the wrap goes past the top;
- the FIFO holds three;
- a blocking pull on an empty FIFO goes on as a non-blocking one does.

## The differential

No theorem can say the model is the datasheet's PIO, because the datasheet
is prose. Two emulators written by others each read that prose too.
[`tools/pio-emulators`](../../tools/pio-emulators/) pins both by hash:
- **rp2040js** 1.4.0: Wokwi's RP2040 emulator, its PIO stepped one
  instruction at a time;
- **rp2040-pio-emulator** 0.88.0: a Python generator of states.

[`differential/cases.py`](./differential/cases.py) draws 700 cases from a
fixed seed. Each case is a program of 2 to 8 words, a configuration, a
starting state, TX words, and the outside pin levels, run for 24 steps. The
cases come in four families:
- `core`: every register instruction, with every push and pull flag;
- `pinw`: pin writes;
- `pinr`: pin reads, with outside inputs;
- `irq`: IRQ flags and STATUS.

The cases leave out three things:
- the RP2350's additions, which are in neither emulator;
- delays, because both emulators count cycles where the model counts
  instructions;
- EXEC, because both emulators run an EXEC'd instruction in the same step.

[`Run.lean`](./differential/Run.lean),
[`rp2040js_run.js`](./differential/rp2040js_run.js) and
[`pioemu_run.py`](./differential/pioemu_run.py) each print the state after
every step. [`differential.py`](./differential/differential.py) follows each
case to the first step where an emulator and the model part, comparing only
the fields that emulator has. The instruction there, and the state before
it, must match one of that emulator's named deviations. Anything else fails,
and so does any named deviation that is never seen.

| Emulator | Deviation | The datasheet |
| --- | --- | --- |
| rp2040js | `push iffull` and `pull ifempty` ignored without autopush and autopull | IfFull and IfEmpty compare the count with the threshold either way |
| rp2040js | a `pull block` that waits empties OSR's count | a stalled instruction changes nothing |
| rp2040js | a `push block` that waits empties ISR | the same |
| rp2040js | `out` of 32 bits leaves OSR as it was | a bit count of 0 means 32 |
| rp2040js | pin writes past GPIO31 stop there | the pin ranges wrap from 31 to 0 |
| rp2040js | only GPIO0 to GPIO29 are kept | a state machine's pin state is 32 bits; how many reach a pad is the package's |
| rp2040-pio-emulator | `mov`'s bit-reverse is a plain copy | operation 2 reverses |
| rp2040-pio-emulator | `iffull` and `ifempty` compare with 32, not the threshold | they compare with the thresholds |
| rp2040-pio-emulator | `jmp !osre` compares with 32, not the threshold | `!OSRE` is the count below `PULL_THRESH` |
| rp2040-pio-emulator | a wrap top of 0 is the program's end | `WRAP_TOP` may be 0 |
| rp2040-pio-emulator | pins are read from GPIO0 whatever `IN_BASE` is | IN, MOV and WAIT PIN read from `IN_BASE` |
| rp2040-pio-emulator | pin writes past GPIO31 stop there | they wrap |
| rp2040-pio-emulator | `mov pins` writes 32 pins from GPIO0 | MOV to PINS uses the OUT mapping |

rp2040-pio-emulator also has no emulation for `irq` (set, clear or wait),
`wait irq`, or `mov` from STATUS. A case stops comparing with it there, at
the first one it reaches.

### What the proof cannot see, and the differential can

A theorem about one program is silent about the instructions it does not
use. [`differential/mutants.txt`](./differential/mutants.txt) holds nine
wrong models that still pass `Invert.lean`. The differential refuses each:
- `jmp x--` counts up;
- `out` leaves the count;
- a left `in` takes the source's top bits;
- a non-blocking pull on an empty FIFO loads 0;
- `set pins` writes from `OUT_BASE`;
- `jmp !osre` compares with 32;
- `wait irq 1` leaves the flag set;
- STATUS is inverted;
- pin writes stop at GPIO31.

Two of these refusals are weaker than the rest:
- **`jmp !osre` compares with 32.** This is rp2040-pio-emulator's own
  deviation, so that emulator now agrees with the model. Only rp2040js
  refuses this mutant, and the named deviation no longer being seen
  confirms it.
- **Pin writes stop at GPIO31.** Both emulators do this. The only sign is
  that a named deviation disappears. The model's wrapping is therefore held
  to the datasheet's prose alone; neither emulator agrees with it.

Some refusals rest on very few cases. `wait irq 1` leaving the flag set is
refused by a single case against rp2040js. The `irq` family biases its flag
indices toward 0 and 1 so that a wait finds a flag set earlier in the same
program; without that bias, no case reached one.

`tools/lean/gap.sh` runs them, as it does for exp201 and exp215. Two
additions came with this experiment:
- `GAP_PROOF`, a proof outside the library that each mutant must still
  pass;
- `GAP_INPUT`, the cases each wrong model runs.

## What it does not say

- **That the chip does this.** The model is held to two emulators, and the
  emulators are not the chip. exp214's board run is the only silicon here,
  and it agrees with `every_word` on its eight words.
- **That the deviation predicates are tight.** A deviation is recognized by
  the instruction and the state before it, not by the value the emulator
  produced. A model mistake on the same instruction in the same state would
  be excused with it. The mutants above are the evidence that most mistakes
  are not.
- **Delay, EXEC, side-set, autopush, autopull, the RP2350's additions.**
  Delay and EXEC are in the model, but no emulator checks them here.
  `prev`, `next` and the RX FIFO's `mov` are refused.

## Running it

```sh
./check.sh                      # the proof, its mutants, the differential, the gap
differential/gap.sh --show
./run.sh                        # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and the emulators
(`tools/pio-emulators/setup.sh`: node, npm and python3). No board. About a
minute and a half, most of it fifteen wrong models rebuilding the library.

## Expected output

```text
=== exp217 — the words the model inverts ===
recorded at 2026-10-07T03:09:03Z from commit cfe13fa (working tree dirty — this recording is not reproducible from the commit alone)

>>> the theorems, and what they rest on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'Exp217.one_word' depends on axioms: [propext, Quot.sound]
'Exp217.every_word' depends on axioms: [propext, Quot.sound]
'Exp217.waits' depends on axioms: [propext, Quot.sound]
exit 0

>>> wrong models: each must be refused by the proof
every_word  pull reads the TX FIFO's front word but leaves it there                       refused in step0
every_word  push puts ISR at the front of the RX FIFO, not the back                       refused in step2
every_word  mov's invert reverses the bits instead                                        refused in step1
every_word  the wrap goes to the instruction after the top, not to the bottom             refused in step2
every_word  push has room for three words, not four                                       refused in one_word
waits       a blocking pull on an empty FIFO goes on with X, as a non-blocking one does   refused in waits

>>> rp2040js 1.4.0: 700 cases, 24 steps each (core 300, pinw 150, pinr 150, irq 100)
   492  agree with the model on every step
   146  part at a deviation: push iffull and pull ifempty are ignored without autopush and autopull
        the datasheet: IfFull and IfEmpty compare the shift count with the threshold whatever autopush and autopull are; e.g. case 1
    22  part at a deviation: a pull block that waits empties OSR's count
        the datasheet: a blocking pull on an empty FIFO stalls, and a stalled instruction changes nothing; e.g. case 25
     5  part at a deviation: a push block that waits empties ISR
        the datasheet: a blocking push on a full FIFO stalls, and a stalled instruction changes nothing; e.g. case 103
     7  part at a deviation: out of 32 bits leaves OSR as it was
        the datasheet: a bit count of 0 means 32, and OSR shifts by it like any other; e.g. case 209
    26  part at a deviation: pin writes past GPIO31 stop there
        the datasheet: the OUT and SET pin ranges wrap from 31 to 0; e.g. case 316
     2  part at a deviation: only GPIO0 to GPIO29 are kept
        the datasheet: a state machine's pin state is 32 bits on either chip; how many of them reach a pad is the package's (30 on an RP2040 or an RP2350A); e.g. case 346
PASS  every disagreement with rp2040js 1.4.0 is one of its named deviations, and 492 of 700 cases agree on every step

>>> rp2040-pio-emulator 0.88.0: 700 cases, 24 steps each (core 300, pinw 150, pinr 150, irq 100)
   428  agree with the model on every step
    71  part at a deviation: mov's bit-reverse is a plain copy
        the datasheet: operation 2 reverses the bit order; e.g. case 0
    37  part at a deviation: push iffull and pull ifempty compare the count with 32, not the threshold
        the datasheet: IfFull and IfEmpty compare the shift count with PUSH_THRESH and PULL_THRESH; e.g. case 1
     8  part at a deviation: jmp !osre compares the count with 32, not the threshold
        the datasheet: !OSRE is the output shift count below PULL_THRESH; e.g. case 11
    34  part at a deviation: a wrap top of 0 is taken as the end of the program
        the datasheet: WRAP_TOP is any instruction, 0 included; e.g. case 44
    24  part at a deviation: in, mov and wait read pins from GPIO0 whatever IN_BASE is
        the datasheet: IN, MOV and WAIT PIN read from IN_BASE; e.g. case 457
    10  part at a deviation: pin writes past GPIO31 stop there
        the datasheet: the OUT and SET pin ranges wrap from 31 to 0; e.g. case 313
    28  part at a deviation: mov pins writes 32 pins from GPIO0
        the datasheet: MOV to PINS uses the OUT pin mapping; e.g. case 316
    60  stop comparing where the emulator has no emulation for an instruction
PASS  every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations, and 428 of 700 cases agree on every step

>>> wrong models the proof cannot see: each must pass it and be refused by the emulators
PASS  differential: a version where jmp x-- counts X up passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 32 of 700 cases are not
      the two emulators: every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations — 32 of 700 cases are not
PASS  differential: a version where out leaves OSR's shift count where it was passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 174 of 700 cases are not
      the two emulators: every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations — 165 of 700 cases are not
PASS  differential: a version where in, shifting left, takes the top bits of the source passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 59 of 700 cases are not
      the two emulators: every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations — 48 of 700 cases are not
PASS  differential: a version where a non-blocking pull on an empty FIFO loads 0, not X passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 32 of 700 cases are not
      the two emulators: every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations — 31 of 700 cases are not
PASS  differential: a version where set pins writes from OUT_BASE passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 16 of 700 cases are not
      the two emulators: every disagreement with rp2040-pio-emulator 0.88.0 is one of its named deviations — 14 of 700 cases are not
PASS  differential: a version where jmp !osre compares with 32, as one of the emulators does passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 7 of 700 cases are not
      the two emulators: every deviation named for rp2040-pio-emulator 0.88.0 is seen — not: jmp !osre compares the count with 32, not the threshold
PASS  differential: a version where wait irq 1 leaves the flag set passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 1 of 700 cases are not
PASS  differential: a version where mov from STATUS is all ones when the TX level is at or above N passes Invert.lean and fails against the two emulators
      the two emulators: every disagreement with rp2040js 1.4.0 is one of its named deviations — 33 of 700 cases are not
PASS  differential: a version where pin writes past GPIO31 stop there, as in both emulators, passes Invert.lean and fails against the two emulators
      the two emulators: every deviation named for rp2040-pio-emulator 0.88.0 is seen — not: pin writes past GPIO31 stop there
```
