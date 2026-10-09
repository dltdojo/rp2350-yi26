# exp225 — the life every beat proved

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Rule 30, a one-dimensional cellular automaton, on a ring of 32 cells. It is
the smallest thing that can be called artificial life. It runs as a
19-instruction RV32IM kernel, and Lean proves what the kernel does: from any
seed it halts with 0 after exactly 3079 instructions, having written
generations 1 to 256 and nothing else. The shell plays each generation's
centre cell on the Pico 2's LED, a beat at a time, and seeds the next life
with the last generation, so the LED beats forever. Every beat of it was
written by the proved bytes. On a Pico 2, flashed from an iPhone in the
gallery: an irregular beat.**

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

| | |
| --- | --- |
| UF2 | `exp225.uf2`, SHA-256 `f8d447b2bbd780582b8f5269c5118aea91ada85d4330d3cf6f30b0fd79f5f408`, the committed one, built at a5927c7 and unchanged since |
| Board | Pico 2 |
| How | in the gallery, BOOTSEL, the UF2 copied on from an iPhone, the LED watched |
| The LED | **an irregular beat** |

The shell reaches the beat in only one way: all four checks held on the first
life. The 76 bytes in SRAM were `kernel.bin`; the kernel halted in User mode
with 0; `minstret` was 3082, the RTL's count; and the 1024 bytes of the first
life hashed to `rule30.py`'s. So on silicon the first life is the one the
proof says and Python computes. Every life after it plays only if its
`minstret` is 3082 again.

This is also the first time a firmware from this repository was flashed from
an iPhone. Until now that had been done only from Ubuntu and Android.

What was not recorded: whether the opening beats matched the pattern above by
eye, and how long the board ran.

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
- **More than one board, or a long run.** One Pico 2, watched in a gallery for
  an unrecorded time.

## Running it

```sh
./check.sh     # under a minute
./run.sh       # the same, recorded to capture.txt, timed into build/capture-timing.txt: 40 s
```

Needs Lean (`tools/lean/setup.sh`), the Hazard3 testbench
(`tools/hazard3/setup.sh`), and clang, lld, llvm-objcopy, cargo and python3.

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp225 — the life every beat proved ===
recorded at 2026-10-09T08:01:03Z from commit f24df95

>>> the kernel, as proof/Life.lean writes it
  0000  00000317  auipc x6, 0
  0004  10032283  lw x5, 256(x6)
  0008  20030313  addi x6, x6, 512
  000c  10000393  addi x7, x0, 256
  0010  0012de13  srli x28, x5, 1
  0014  01f29e93  slli x29, x5, 31
  0018  01de6e33  or x28, x28, x29
  001c  00129e93  slli x29, x5, 1
  0020  01f2df13  srli x30, x5, 31
  0024  01eeeeb3  or x29, x29, x30
  0028  005eeeb3  or x29, x29, x5
  002c  01de42b3  xor x5, x28, x29
  0030  00532023  sw x5, 0(x6)
  0034  00430313  addi x6, x6, 4
  0038  fff38393  addi x7, x7, -1
  003c  fc039ae3  bne x7, x0, -44
  0040  00100293  addi x5, x0, 1
  0044  00000513  addi x10, x0, 0
  0048  00000073  ecall

>>> the theorems, and what they rest on
'Exp225.rule30' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp225.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp225.lives' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp225.not_before' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp225.bytes_words' depends on axioms: [propext]
'Exp225.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
body_x      the right neighbour is taken from the left                       refused in body_x
body_x      the centre is left out: Rule 90, not Rule 30                     refused in body_x
body_x      the ring is broken: the top cell's left is not the bottom cell   refused in body_x
rule30      the specification forgets the centre                             refused in rule30
iter        each generation is stored a word too far on                      refused in iter
iter        the history skips every other word                               refused in iter
setup_run   only 255 generations                                             refused in setup_run
setup_run   the seed is read a word late                                     refused in setup_run
finish_run  it halts with 1                                                  refused in finish_run
lives       it is claimed to halt one instruction sooner                     refused in lives
not_before  it is claimed still to be running after 3079                     refused in not_before

>>> the first life's centre column, from rule30.py: what the LED plays, a beat each
█·███··██···█·██··█··███·█·███·████···█·██████·█····████·····█·█
···███████·█·█··█████··██·█·██·███·█···█·█·█··█·█··█·██··██·██·█
··█····█·██····██··██·██·██···█·█████·██████···██··█████····██··
█·██·██·█····█████··███·█·██··█·██·██·██·······█·██······██·█·██

>>> the shell, for the chip and for the RTL
build/expect.h: kernel 559d70d93ee6242d…, model 3079, RTL minstret 3082, first life 8c3f6e7f0f4aa2dc…
build/exp225.bin  3272 bytes, the build allows 8192
build/exp225.uf2  6656 bytes  sha256 f8d447b2bbd780582b8f5269c5118aea91ada85d4330d3cf6f30b0fd79f5f408

>>> on the RTL, two lives: LIFE round minstret gen1 gen256 centre-column
4c494645 00000000 00000c0a 00038000 02bb07b0 bae4d19d 4c494645 00000001 00000c0a 06a28c28 27266abc bd221e08 exit=0 

>>> the checks
PASS  no lifeline, and it says why: no USB at all — the LED is the only channel, and BOOTSEL by hand is the way back
PASS  Life.lean checks, with no errors and no warnings
PASS  all 6 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  body_x: the proof refuses a version where the right neighbour is taken from the left
PASS  body_x: the proof refuses a version where the centre is left out: Rule 90, not Rule 30
PASS  body_x: the proof refuses a version where the ring is broken: the top cell's left is not the bottom cell
PASS  rule30: the proof refuses a version where the specification forgets the centre
PASS  iter: the proof refuses a version where each generation is stored a word too far on
PASS  iter: the proof refuses a version where the history skips every other word
PASS  setup_run: the proof refuses a version where only 255 generations
PASS  setup_run: the proof refuses a version where the seed is read a word late
PASS  finish_run: the proof refuses a version where it halts with 1
PASS  lives: the proof refuses a version where it is claimed to halt one instruction sooner
PASS  not_before: the proof refuses a version where it is claimed still to be running after 3079
PASS  kernel.bin is what proof/Life.lean writes, 76 bytes, and kernel.sha256 is its hash
PASS  on 20 seeds the Lean model halts with 0 after exactly 3079 and the RTL with 0, each leaving exactly rule30.py's 256 generations and nothing else
PASS  the shell builds for the chip and for the RTL, the chip's in 3272 of the 8192 bytes it may use
PASS  all 13 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 8 KiB of flash, 0x10000000..0x10002000
PASS  together they are exactly the 3272-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: f8d447b2bbd78058…
PASS  on the RTL the shell lives two lives, each exactly rule30.py's, the second seeded by the first's last generation
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — check 1
PASS  the shell catches a version where the halt is held to 1 instead of 0 — check 2
PASS  the shell catches a version where the chip is asked to count one more — check 3
PASS  the shell catches a version where the first life is held against a hash that is not rule30.py's — check 4
PASS  the shell catches a version where the first life starts from two live cells, not one — check 4
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a check
```
