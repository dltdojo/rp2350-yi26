# exp225 — the life every beat proved

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Rule 30, a one-dimensional cellular automaton, on a ring of 32 cells. It is
the smallest thing that can be called artificial life. It runs as a
19-instruction RV32IM kernel, and Lean proves what the kernel does: from any
seed it halts with 0 after exactly 3079 instructions, having written
generations 1 to 256 and nothing else. The shell plays each generation's
centre cell on the Pico 2's LED, a beat at a time, and seeds the next life
with the last generation, so the LED beats forever. Every beat of it was
written by the proved bytes. Not yet run on a board.**

It was made in a gallery: Daito Manabe's *Relational Time — Life Beyond
Simulation*, at the Taichung Art Museum, with a Pico 2 in a pocket and a phone
to flash it. The exhibition is about artificial life that is generated, not
recorded. This is the same question asked at a smaller scale: a rhythm that
looks alive, where every beat can be checked, and has been.

## The rule

Each cell becomes **left XOR (centre OR right)**. That is Wolfram's Rule 30.
In one word, bit `i` is a cell; its left neighbour is bit `i+1` and its right
neighbour is bit `i-1`, round the ring. The kernel computes a whole generation
in eight register instructions:

```
life x = (x >>> 1 ||| x <<< 31) ^^^ ((x <<< 1 ||| x >>> 31) ||| x)
```

`rule30` proves that this formula is the rule, cell by cell.

From a single live cell the centre column looks like noise. Wolfram used it as
a random number generator. It is not noise: every bit of it is fixed by the
seed. On the LED, the first life begins like this, `█` a flash and `·` a dark
beat:

```
█·███··██···█·██··█··███·█·███·████···█·██████·█····████·····█·█
```

## What is proved

| Theorem | Says |
| --- | --- |
| `lives` | from `base`, the kernel's bytes there: it halts with 0 after exactly 3079 instructions, and memory is what it was but for the 1024 bytes from 0x200, which are generations 1 to 256 of `life` from the word at 0x100, little-endian |
| `not_before` | after 3078 it is still running, whatever the seed |
| `rule30` | `life` is Rule 30: cell `i` becomes cell `i+1` XOR (cell `i` OR cell `i-1`), mod 32 |
| `from_boot` | all of it, from `boot`, the state the shell builds, for any image beginning with `kernel.bin`'s 76 bytes |

All of these rest on Lean's own axioms only.

Eleven wrong versions are refused, each at the theorem about what it breaks:
- `body_x`, three wrong rules: Rule 90 instead of Rule 30, the right neighbour
  taken from the left, and a broken ring;
- `rule30`, a specification that forgets the centre;
- `iter`, a store a word too far on, and a history that skips words;
- `setup_run`, 255 generations, and the seed read a word late;
- `finish_run`, a halt with 1;
- `lives` and `not_before`, two wrong counts.

`proof/mutants.txt` lists them.

```
   0      auipc t1, 0
   1      lw    t0, 0x100(t1)        the seed
   2      addi  t1, t1, 0x200        where generation 1 goes
   3      addi  t2, x0, 256          generations to go
   4-11   t0 = life t0               eight register instructions
   12     sw    t0, 0(t1)
   13-14  t1 += 4, t2 -= 1
   15     bne   t2, x0, 4
   16-18  HALT 0
```

## The differential

`rule30.py` is Rule 30 written a cell at a time, the way the rule is usually
stated. It shares nothing with the kernel's shifts. On twenty seeds, the Lean
model (`rv32run`) and the Hazard3 RTL each run `kernel.bin`, and each leaves
exactly `rule30.py`'s 256 generations and nothing else. The seeds include one
live cell, none, all, the top bit alone, alternating cells, and fourteen
random ones. The model halts after exactly 3079 instructions on every seed;
the RTL counts 3082, the harness's three included.

## What runs on the chip

The shell (`shell/shell.c`), a round at a time:
1. It zeroes the 64 KiB region at 0x20070000, puts `kernel.bin` at its start,
   and puts the seed at 0x100.
2. It checks the kernel's bytes against `kernel.sha256`.
3. It runs the kernel in User mode under `tools/hazard3/harness`.
4. When the kernel halts, it checks what it can see:
   1. the kernel's bytes were `kernel.sha256`'s;
   2. it halted (`ecall`, t0 = 1) with 0;
   3. `minstret` is 3082, the RTL's count, which `lives` says does not depend
      on the seed;
   4. for the first life only, from one live cell at bit 16: SHA-256 of the
      1024 bytes is `rule30.py`'s.
5. It plays the life, then seeds the next round with the last generation.

The first life is the only one checked against Python: after it, the lives
are the chip's own, and nothing outside it knows them in advance. For those,
the proof is the check: each life is whatever 256 generations of Rule 30 from
its seed are, and the chip's `minstret` agrees with the count every round.

## Running it on the board

You need a Pico 2 and something that can copy a file onto a USB drive. A
phone's file manager is enough.

1. Hold **BOOTSEL**, plug the board in, then let go. A drive called `RP2350`
   appears. On a phone, do this right before step 2: a phone that sleeps
   power-cycles the port, and the board leaves BOOTSEL
   ([docs/debugging-on-a-phone.md](../../docs/debugging-on-a-phone.md)).
2. Copy `exp225.uf2` onto the drive. The board restarts as a RISC-V machine,
   and the drive goes away.
3. Watch the LED:

| The LED | Means |
| --- | --- |
| dark for a second and a half, then an **irregular beat** — a flash for a live centre cell, a dark beat for a dead one, about 0.36 s each | the checks held, and a life is playing: 256 beats, about 92 s, then a second and a half dark and the next life |
| **1 to 4 flashes**, a pause, repeated | check 1 to 4 failed: the kernel's bytes, no HALT 0, `minstret`, the first life |
| **on, steady** | the shell trapped |
| **dark** | the shell never ran |

The beat's length assumes the clock the bootrom leaves running, as
`tools/hazard3/shell/led.h` does; it is not measured here.

## On the board

Not yet run.

## What the RTL checks, and what it cannot

On the RTL the shell lives two lives and prints each, then stops. Both are
exactly `rule30.py`'s, the second seeded by the first's last generation.

Six wrong shells or expectations are caught:
- a wrong `kernel.sha256`: check 1;
- a halt held to 1: check 2;
- a count of one more: check 3;
- a wrong first-life hash: check 4;
- a first life from two cells instead of one: check 4;
- a trap in the shell itself.

What the RTL cannot show is the LED: whether a person sees the beat as it was
written.

## What it does not say

- **That the LED shows the life.** The shell reads each generation's centre
  bit and drives the pin. That is C, and not proved. A shell that played
  something else would not be caught by any check here; the first life's
  pattern above is what a person can hold it against.
- **That a later life is right, except by the proof.** No hash is held
  against lives after the first.
- **How long a beat is.** The beat is counted in `mcycle`, at whatever clock
  the bootrom left.
- **More than one board, or a long run.** Not run on a board yet.

## Running it

```sh
./check.sh     # under a minute
./run.sh       # the same, recorded to capture.txt, timed into build/capture-timing.txt
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.

## Expected output

To be pasted from a recording.
