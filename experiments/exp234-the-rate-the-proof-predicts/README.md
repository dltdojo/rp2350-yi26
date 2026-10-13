# exp234 — the rate the proof predicts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp232's world, proved. exp232 put a proved model of tissue, tumour and
drug beside a world it left something out of: a cell the tumour divides into
is, now and then, resistant. The model said every treated patient is cured;
the trial said some are not. That world was C, written again and unproved.
Here it is a 74-instruction kernel and a theorem, and the random draw is an
input — 64 masks, one a generation — so what is proved holds for every draw.
With every mask zero the world is exp232's model, so on the chip one kernel
is both. And the gap between proof and trial gets a number: Lean proves
exactly which cells must stay unhit for the treated to be cured, and from
that the treated fail 3276629119 / 25769803776 of the time — 12.715%.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once to copy `exp234.uf2` on, and a
**phone with Chrome** holding [exp233](../exp233-the-trial-on-the-phone/)'s
`trial.html`, build p3 or later, to read the trial. The page puts the
predicted rate beside the share the board has counted. The LED tells the
trial on its own, as exp232's does. A plain-language account is in
[WHY.zh-TW.md](./WHY.zh-TW.md).

## What changes from exp232

| | exp232 | exp234 |
| --- | --- | --- |
| the model | a proved kernel (M1) | the same proved kernel as the world, every mask zero (W0) |
| the world | C in the shell, unproved | a proved kernel (W1): every input, every mask |
| resistance | drawn in C | the masks, drawn in C — the only arithmetic left unproved |
| what the proof says about the trial | every treated patient is cured, in the model | which patients the world fails, and how often |
| the lines, the LED, the page | — | exp232's, unchanged: only the name and the serial differ |

The trial itself is exp232's to the bit: the same search, the same protocol
hash, the same patients from the same words. The world kernel computes exactly
what exp232's C did, so a word drawn on either board gives the same patient
and the same outcome, and exp232's `cure.py --board` checks both boards' logs.

## The world

`wnext m b` in [`proof/World.lean`](./proof/World.lean): exp232's generation,
with `r`, the resistant tumour cells, and `m`, this generation's mask.

- A dose kills what exp232's dose kills, **except resistant cells**.
- Every cell the tumour divides into is resistant **where `m` has a one**.
- A resistant cell's daughter, the cell above it, is resistant.

The shell draws `m` as exp232 did: four xorshift32 words from the patient's
word, ANDed, so each bit is one about 1 time in 16.

## The kernel

74 RV32I instructions, 296 bytes. It reads the tumour, tissue and schedule at
base + 0x200 and the 64 masks from 0x300, writes 64 generations — tumour,
tissue, resistant, 12 bytes each — from 0x400, and halts with 0.

```
0-7    t, h, s into a0, a1, a2; a4 = 0; a5 the masks; t1 the history; t2 64
8      lw a6, the mask
9-63   one generation, 55 register instructions
64-66  sw a0, a1, a4
67-70  t1 += 12, a5 += 4, t2 -= 1, bne t2, x0, 8
71-73  HALT 0
```

## The proof

On Lean's own axioms only, no `bv_decide`, no `native_decide`:

| | Theorem | Says |
| --- | --- | --- |
| W1 | `lives`, `from_boot` | after exactly 4043 instructions the kernel halts with 0 having written generations 1 to 64 of `wnext`, and changed nothing else — for every input and every mask |
| W0 | `still` | with every mask zero, the world is exp232's proved model |
| M6 | `resistance_stays` | one resistant cell inside the tumour, and whatever the schedule and the masks, the tumour never goes |
| M7 | `cured_iff` | cured at 64 exactly when the model's patient is and no mask hit a cell the model's tumour divided into |
| | `answer_world` | under exp232's answer, a lump of 1 to 6 cells anywhere on the ring leaves 0, 0, 1, 2, 3 or 8 such cells to chance |
| M8 | `zero_stays` | a corrected endpoint: no tumour cell at all — not "none a scan sees" — and none ever comes back, in the world as in the model |

**From M7 to a rate.** If each mask bit is one with probability q = 1/16,
independently, a lump that leaves D cells to chance is cured with probability
(15/16)^D. The widths are equally likely, so the treated fail

1 − (1 + 1 + (15/16) + (15/16)² + (15/16)³ + (15/16)⁸) / 6 =
3276629119 / 25769803776 ≈ **12.715%**.

That step is arithmetic, done in `world.py --check`. The assumption is the
one thing in it no theorem reaches: whether the bits of four xorshift32
words, seeded by the TRNG, are independent ones that come up 1 time in 16.

Why the position does not matter: `born_rot` proves that rotating the patient
rotates the cells it divides into, so the count `answer_zero` checks at cell 0
is the count everywhere. 32 positions were never tried.

Six wrong versions are refused (`proof/mutants.txt`):

- a kernel whose dose kills resistant cells too;
- a kernel whose resistant cells have no resistant daughters;
- the claim that the kernel halts one instruction sooner;
- the claim that a patient the model cures is cured in the world, whatever
  the masks;
- the claim that a lump of six leaves seven divisions to chance, not eight;
- the claim for a lump of seven, one cell beyond the enrolment.

The tissue rule exp232 proved its model with — `spread`, `dose`, `edge`,
`next`, `gen`, the patients and rotation — moved to
[`lean/Rv32/Tissue.lean`](../../lean/Rv32/Tissue.lean), where both proofs
stand on it. exp232's `kernel.bin` is unchanged.

## How close the world comes

`world.py` runs exp232's `cure.py` world — written cell by cell, sharing
nothing with the kernel — over 40000 treated patients:

| Width | Divisions | Predicted | cure.py's world |
| --- | --- | --- | --- |
| 1 | 0 | 0 | 0 of 6530 |
| 2 | 0 | 0 | 0 of 6849 |
| 3 | 1 | 6.25% | 5.77% |
| 4 | 2 | 12.11% | 12.20% |
| 5 | 3 | 17.60% | 16.44% |
| 6 | 8 | 40.33% | 39.57% |
| all | | **12.715%** | **12.43%** (4971 of 40000) |

12.43% is 1.7 standard errors below the prediction, which 40000 patients
leave room for (one standard error is 0.17%). exp232's own 2000-patient
figure, 13.7% of 1038 treated, was 1 standard error above it.

exp232's board treated 30 patients, each boot counting from patient 1: 7 in
round 1 (1 missed, [its log](../exp232-the-cure-the-proof-predicts/board/round1.txt)),
7 in round 2 (2 missed, [its log](../exp232-the-cure-the-proof-predicts/board/round2.txt)),
and 16 by patient 40 in exp233's round 1 (1 missed, as the page's summary line
records the board's TRIAL line, [its log](../exp233-the-trial-on-the-phone/board/round1.txt)).
4 of 30 were not cured: 13.3%, with a 95% interval of 5.3%–29.7%. exp234's own
board, round 1 below, treated 27 by patient 44 and 4 were not cured: 14.8%,
interval 5.9%–32.5%. Together, 8 of 57: 14.0%, interval 7.3%–25.3%, against
7.2 expected. The prediction is inside every one of them. Those intervals are
what trials of thirty and sixty can say, and they are wide.

## The shell

exp232's shell, with every generation left to the kernel. The C in
[`shell/shell.c`](./shell/shell.c) draws the masks and counts; it computes no
generation of anything.

- **The search** runs the kernel with every mask zero: by W0, that is exp232's
  model, and the search finds what exp232's did.
- **Each patient** is two runs: every mask zero (the model), then the masks
  drawn from the patient's word (the world).
- **Two theorems are checked again on every patient**, as what the chip must
  show if it runs what was proved:
  - a world in which no cell became resistant is the model's 64 generations
    (W0, check 10);
  - a world in which one did never loses its tumour after (M6, check 12).

| Check | What |
| --- | --- |
| 1 | the kernel's bytes are its hash's, once, when it is loaded |
| 2 | every run halted with 0 |
| 3 | every run's minstret is 4046, the RTL's, whatever the input and the masks |
| 4 | the search's answer, counts and first loophole are `cure.py`'s |
| 10 | a patient with no resistance lived exactly the model's generations (W0) |
| 11 | the TRNG gave words |
| 12 | a patient with resistance kept a tumour from then on (M6) |

What exp232 and exp234 share moved to `tools/hazard3/shell`: the ring
arithmetic and the trial's endpoint (`ring.h`), and the board layer on the
chip and the RTL (`trial_chip.h`, `trial_sim.h`). exp232's UF2 is byte for
byte what it was, `dd5dbde3…`, and so is its RTL build.

## The LED

exp232's:

- **On, steady:** the search, about a second.
- **Then, for each patient:** treated, one flash if the world cured it, two if
  it met the endpoint and came back, three if it missed; control, dark. Then
  2 s dark before the next.
- An error starts with 2 s of light, then flashes its check's number. **10 or
  12 flashes is a theorem the chip did not hold.**

## The lines

exp232's, so `trial.html` and `cure.py --board` read them unchanged:

```
SEARCH tried=1024 accepted=367 relapsing=34 answer=000051af doses=9 loophole=00f917d1 minstret=4046
PLAN sha256=4cccf5ca…
PATIENT n=… word=… arm=treated|control width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
TRIAL treated=… cured=… relapsed=… missed=… predicted=… control=… control_missed=…
```

The status line says `exp234` and the USB serial is `234`. minstret is 4046,
not exp232's 3084: the world's kernel is longer.

## Running it on a board

1. Hold BOOTSEL, plug the Pico 2 in, and copy `build/exp234.uf2` onto the
   `RP2350` drive.
2. The LED comes on for about a second: the search. Then a patient every few
   seconds.
3. Open exp233's `trial.html` (p3 or later) in Chrome, Connect, and choose the
   board. The rate panel shows 12.7% beside the board's share.
4. Copy, save the text as `board/<name>.txt`, and run
   `python3 world.py --board board/<name>.txt`. `check.sh` runs it on every
   saved log.

## On the board

**Round 1.** A Pico 2 running `exp234.uf2` (`636f96ab…`), and an Android phone
with exp233's `trial.html` build p3. Copy gave back the page's summary and
the lines from patient 7; the paste ends partway through patient 25's status
lines, so [`board/round1.txt`](./board/round1.txt) holds patients 7–25 whole
and the page's verdict on 7–44.

- **The proved world on silicon is `cure.py`'s.** `world.py --board` replays
  every one of the 19 patients in the file from its TRNG word, model and world,
  to the number. The search on silicon is exp232's, answer `0x51af`, the PLAN
  hash `4cccf5ca…a112cd60`, and minstret is 4046 on every run, the RTL's count.
- **The page agreed with all 38 it saw**, patients 7–44: search, plan, every
  TRIAL count, every patient replayed in the phone's own JavaScript. It said
  `"board":"exp234"`.
- **No theorem check failed.** Checks 10 (W0) and 12 (M6) run on every
  patient, and a failure stops the trial; the board was still treating at
  patient 44 and sent no FAIL line.
- **The trial at 44:** 27 treated, the model predicting all 27 cured; the
  world cured 23 and 4 missed the endpoint. 17 controls, all missed. The rate
  panel's prediction is 12.7%; the board's share was 14.8%, with 3.4 expected.
- **What M7 says about the four**, for the two in the file: patient 7, a lump
  of 6 (8 divisions to chance), and patient 16, a lump of 5 (3), each became
  resistant and missed. Every width-1 and width-2 treated patient in the file
  (8, 12, 17, 21) was cured, as the theorem says they must be whatever the
  masks: their lumps leave nothing to chance.

## What it does not say

- **Anything about medicine.** The world is still a model. It now has a proof,
  which makes it a better-understood model, not a body.
- **That the TRNG's bits are what M7's rate assumes.** The rate is exact only
  if each mask bit is an independent one-in-sixteen. The masks come from
  xorshift32 seeded by one TRNG word. The trial is where that assumption meets
  a board.
- **That a proof replaces the trial.** M7 says which patients fail. It cannot
  say how often unless something says how the masks fall, and that is the
  world's business, not the proof's.

## Running it

```sh
./check.sh     # about eight minutes, most of it the RTL searching
./run.sh       # the same, recorded to capture.txt
```

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp234 — the rate the proof predicts ===
recorded at 2026-10-13T00:30:38Z from commit 17d6407 (working tree dirty — this recording is not reproducible from the commit alone)

>>> the theorems, and what they rest on
'Exp234.lives' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.still' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.resistance_stays' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.cured_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.zero_stays' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp234.answer_world' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
kills_resistant  the kernel's dose kills resistant cells too                                          refused in body_t
not_inherited    the kernel's resistant cells have no resistant daughters                             refused in body_r
count_short      the kernel is claimed to halt one instruction sooner than it does                    refused in lives
masks_free       the claim that a patient the model cures is cured in the world, whatever the masks   refused in cured_iff
seven            the claim that a lump of six leaves seven divisions to chance, not eight             refused in answer_zero
lump_seven       the claim for a lump of seven too, one cell beyond the trial's enrolment             refused in answer_world

>>> the rate M7 predicts, and 40000 treated patients in cure.py's world
PASS  the divisions answer_world proves, {1: 0, 2: 0, 3: 1, 4: 2, 5: 3, 6: 8}, are cure.py's cell by cell, lump by lump; with each mask bit one 1 time in 16 the treated fail 3276629119/25769803776 = 12.7150%
the treated, by lump width: M7's prediction beside cure.py's world, 40000 patients
  width 1: 0 divisions, predicted 0.0000, cure.py 0.0000 (0 of 6530)
  width 2: 0 divisions, predicted 0.0000, cure.py 0.0000 (0 of 6849)
  width 3: 1 divisions, predicted 0.0625, cure.py 0.0577 (378 of 6553)
  width 4: 2 divisions, predicted 0.1211, cure.py 0.1220 (814 of 6671)
  width 5: 3 divisions, predicted 0.1760, cure.py 0.1644 (1082 of 6582)
  width 6: 8 divisions, predicted 0.4033, cure.py 0.3957 (2697 of 6815)
  all: predicted 3276629119/25769803776 = 12.7150%, cure.py 4971 of 40000 = 12.4275%

>>> the shell, for the chip and the RTL
build/world.h: kernel ec5eb7147ee2bfd0…, model 4043, RTL minstret 4046, search 367 accepted, 34 relapsing, answer 0051af
build/exp234.bin  15532 bytes, the build allows 16384
build/exp234.uf2  31232 bytes  sha256 636f96ab96299091df6d8cc3b321c13cb686728ad4da6da10c5b9b9a79386982

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  World.lean checks, with no errors and no warnings
PASS  all 7 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  kills_resistant: the proof refuses a version where the kernel's dose kills resistant cells too
PASS  not_inherited: the proof refuses a version where the kernel's resistant cells have no resistant daughters
PASS  count_short: the proof refuses a version where the kernel is claimed to halt one instruction sooner than it does
PASS  masks_free: the proof refuses a version where the claim that a patient the model cures is cured in the world, whatever the masks
PASS  seven: the proof refuses a version where the claim that a lump of six leaves seven divisions to chance, not eight
PASS  lump_seven: the proof refuses a version where the claim for a lump of seven too, one cell beyond the trial's enrolment
PASS  the divisions answer_world proves, {1: 0, 2: 0, 3: 1, 4: 2, 5: 3, 6: 8}, are cure.py's cell by cell, lump by lump; with each mask bit one 1 time in 16 the treated fail 3276629119/25769803776 = 12.7150%
PASS  kernel.bin is what proof/World.lean writes, 296 bytes, and kernel.sha256 is its hash
PASS  on 15 bodies and mask sets the Lean model halts with 0 after exactly 4043 and the RTL with 0, each leaving exactly cure.py's world, 64 generations, and nothing else; the RTL's instret=4046
PASS  the shell builds for the chip over trial_chip.h, in 15532 of the 16384 bytes it may use, and for the RTL
PASS  all 61 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 15532-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 636f96ab96299091…
PASS  on the RTL the shell's search, every run the world's kernel with every mask zero, finds cure.py's answer, 51af, and its counts; then it treats six patients, the model and the world each a run of the same kernel, exactly as cure.py does — minstret 4046 on every run
PASS  the shell catches a version where the kernel is held to a hash that is not its own — check 1
PASS  the shell catches a version where a run's halt is held to 1 instead of 0 — check 2
PASS  the shell catches a version where the chip is asked to count one more — check 3
PASS  the shell catches a version where the search keeps the most doses, not the fewest — check 4
PASS  the shell catches a version where a patient's model run keeps the last patient's masks — check 10, W0
PASS  the shell catches a version where the shell reads resistance from the tissue's word — check 12, M6
PASS  the shell catches a version where the TRNG gives nothing — check 11
PASS  the shell catches a version where the shell itself traps entering the kernel — a fault, not a check
PASS  round1.txt: SEARCH and PLAN are cure.py's (19 times), minstret 4046 throughout; patients 7–25: every model outcome cure.py's, every world replayed by cure.py from its word, to the number (19 of 19), every TRIAL count adding up, every treated patient predicted cured and every control missed
PASS  a board log with one thing changed is refused: s/word=8fd5a26f/word=8fd5a26e/
PASS  a board log with one thing changed is refused: s/resistant=1 t24=22 tissue=10/resistant=1 t24=21 tissue=10/
PASS  a board log with one thing changed is refused: s/n=16 word=4b29cb4d arm=treated width=5 at=20 model=cured world=missed/n=16 word=4b29cb4d arm=treated width=5 at=20 model=cured world=cured/
PASS  a board log with one thing changed is refused: s/lives=10 minstret=4046/lives=10 minstret=3084/
```
