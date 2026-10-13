# exp232 — the cure the proof predicts

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A ring of 32 cells of tissue with a tumour in it, and a dose that kills
whatever cells are dividing, as chemotherapy does. One proved kernel runs it,
and Lean proves the kernel computes the model exactly (M1). On the chip, a
search plays the part of an AI asked to "find a schedule that passes the
trial". It runs that kernel over 1024 schedules and answers with the
passing one that has the fewest doses. Lean proves what the model predicts
for that answer: every enrolled tumour is gone (M4). Lean proves just as
readily that another schedule the search accepted meets the same endpoint and
comes back (M5). Then the chip runs a trial. Its patients are drawn from the
RP2350's TRNG, and they live in a world with one thing the model leaves out:
resistance. The proof says all the treated are cured, and the trial does not
agree.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once to copy `exp232.uf2` on, and
a **phone or computer with Chrome** to open `tools/pages/log.html` and read
the trial. The LED tells the same story on its own. A plain-language account,
written for students and for the debate this was built to ground, is in
[WHY.zh-TW.md](./WHY.zh-TW.md). The design is in
[exp231's NEXT.zh-TW.md](../exp231-the-fly-on-the-phone/NEXT.zh-TW.md). Two
of its three open questions were answered as recommended (tissue, tumour and
a dose; resistance drawn from the TRNG). The third went the other way: the
search runs on the chip, so the design's two experiments are one.

The trial on a phone is [exp233](../exp233-the-trial-on-the-phone/)'s
`trial.html`: it replays every patient from its word and draws the two lives
of each one the model and the world part on.

## Where it comes from

Terence Tao, in a talk at Caltech, asked: an AI is told to find a cancer
cure that passes a phase 3 trial. Its model's prediction is verified in Lean,
and the cure passes. Nobody knows how it was found. Could it still be
misaligned, passing by a loophole in the trial? Would you want someone to
understand it first? Researchers in drug development replied that this is
how medicine already works. Mechanisms are often unknown (paracetamol);
trials test what happens, not why; off-target effects are what drugs have.

Neither side is wrong about its own layer. This experiment builds every layer
of the thought experiment, small enough to hold, and says which layer each
piece of evidence comes from.

| In the thought experiment | Here | Who stands behind it |
| --- | --- | --- |
| the prompt: "passes phase 3" | the endpoint: no scan sees the tumour after generation 24, and the patient keeps half the tissue | nobody: it was written by a person, and it is not "cured" |
| the AI that found it | a search over 1024 schedules, keeping the fewest doses | nothing needs to: only what it returns is held to anything |
| "its prediction verified in Lean" | M4 | Lean |
| the mechanism | M2, and an argument a person can follow | Lean, and a person |
| a loophole | M5 | Lean, which proves it as readily as M4 |
| phase 3 | the trial on the chip: patients from the TRNG, two arms, the protocol hashed first | procedure, and a world the model does not hold |

## The model

Each cell is empty, tissue or tumour: two words, the tumour `t` and the
tissue `h`. Each generation:

1. **A dose**, if the schedule's bit for this generation is set. Every cell at
   the edge of its own kind dies: a tumour cell with a neighbour that is not
   tumour, and a tissue cell with a neighbour that is not tissue. Those are
   the cells that divide, and chemotherapy kills dividing cells.
2. **Growth.** A tumour cell invades the cell above it, whatever is there: it
   has lost contact inhibition. Tissue only grows into a gap beside it.

`cure.py` writes this cell by cell, and the kernel with shifts. Nothing is
shared between them, and the differential holds each to the other.

## The kernel

57 RV32IM instructions. It reads the tumour, tissue and schedule at 0x100,
0x104 and 0x108, writes 64 generations (tumour, then tissue, 8 bytes each)
from 0x200, and halts with 0. A generation is 43 register instructions,
branch-free: the dose is a mask, `0 - (s & 1)`.

```
0-5     the three inputs into a0, a1, a2; t1 the history; t2 64
6-48    one generation
49-50   sw a0, sw a1
51-53   t1 += 8, t2 -= 1, bne t2, x0, 6
54-56   HALT 0
```

## The proof

`proof/Cure.lean` uses Lean's own axioms only. `up1`, `dn1` and the
popcount came from exp230's `Fly.lean`. exp232 needed them second, so they
are now in [`lean/Rv32/Ring.lean`](../../lean/Rv32/Ring.lean), and exp230
imports them from there.

- **M1, `models` and `from_boot`.** For every input, after exactly 3081
  instructions the kernel halts with 0, the 512 bytes from 0x200 hold
  generations 1 to 64 of `next`, and nothing else has changed. `not_before`:
  after 3080 it is still running.
- **M2, the mechanism.**
  - A cell between two cells of its own kind survives a dose
    (`inside_survives`, `tissue_survives`). The drug reaches a lump only at
    its edges.
  - A healthy body loses nothing to a dose (`healthy_untouched`).
  - Tissue beside a tumour dies with it (`off_target`).
  - Tumour and tissue never share a cell (`apart`).
- **M3, `untreated_fills`.** Untreated, any tumour at all fills the ring by
  generation 31, whatever the tissue.
- **M4, `answer_cures`.** The search's answer, `0x51af` (nine doses), meets
  the endpoint for every lump of 1 to 6 cells, wherever it sits on the ring.
  The tumour is not merely unseen at generation 24: it is gone, from then on.
- **M5, `loophole_relapses`.** The first schedule the search accepted that
  relapses, `0xf917d1`, also meets the endpoint for every enrolled patient.
  Yet a lump of six is still there at generation 24, as two cells no scan
  sees, and it fills the ring by 64.

"Wherever it sits" is proved, not computed 32 times. `next` commutes with
moving the ring (`gen_up1`), and the count of cells does not change when it
moves (`pc_up1`). So the six lumps at cell 0 are computed by `decide`, and
the theorem covers the other 31 positions.

`proof/mutants.txt` holds eight wrong versions, each refused:

- three kernels: the tumour grows down, a dose every day, the halt one
  instruction sooner;
- five claims a reader might hope the proof makes:
  - a dose harms no tissue;
  - tissue with tissue on one side only survives a dose;
  - untreated, a tumour fills the ring by 30;
  - the answer also cures a lump of 7, one cell beyond the enrolment;
  - whatever meets the endpoint is cured.

## The search

1024 schedules come from xorshift32 seeded with 1, each cut to the trial's
24 generations. A schedule is accepted if the kernel's patient meets the
endpoint for every width from 1 to 6. Of those it keeps the one with the
fewest doses, the first on a tie. For every accepted schedule it also counts
whether, in the model, a tumour is still there at generation 64. That counts
nothing towards the goal.

On the RTL, and as `cure.py` has it: 367 accepted, **34 of them relapsing**
in the model, answer `0x51af`, first loophole `0xf917d1`. The answer is
checked against `cure.py`'s (check 4). Then the protocol is hashed: the
answer and every constant of the trial. The hash goes out before patient 1 is
drawn.

## The world, and the trial

Each patient comes from one random word:

- its low bit is the arm (treated with the answer, or a control given
  nothing);
- the lump is 1 to 6 cells wide, somewhere on the ring.

For each patient the kernel gives the model's outcome. Then the shell lives
the same patient in the world. The world is the same rule, written again in
C and not proved, with one addition: a cell the tumour divides into is
resistant with probability 1/16, and a dose never kills a resistant cell or
its daughters. If no cell ever became resistant, the world must have lived
exactly the proved model's 64 generations (check 10).

`cure.py` over 2000 patients:

- the model says every treated patient is cured;
- in the world, 142 of 1038 treated patients miss the endpoint;
- every control misses it, as M3 says they must.

On the RTL, patient 3 is treated with a lump of six. The model says cured.
In the world one cell became resistant, and the patient missed the endpoint,
with 20 tumour cells at generation 24.

## What the shell checks

| Check | What |
| --- | --- |
| 1 | the kernel's bytes are its hash's, once, when it is loaded |
| 2 | every run halted with 0 |
| 3 | every run's minstret is 3084, the RTL's, whatever the input |
| 4 | the search's answer, counts and first loophole are `cure.py`'s |
| 10 | a patient with no resistance lived exactly the proved model's generations |
| 11 | the TRNG gave words |

Every run reuses the loaded kernel. Nothing reloads it: `models` holds from
any memory that begins with its bytes, and the kernel changes nothing outside
its history.

## The LED

- **On, steady:** the search, about a second.
- **Then, for each patient:**
  - treated: one flash if the world cured it, two if it met the endpoint and
    came back, three if it missed;
  - control: dark.
  - Then 2 s dark before the next patient.
- And `speak.h`'s stage and error counts, as exp231 has them. An error starts
  with 2 s of light, then flashes its check's number.

## The lines

These go out over USB, and `tools/pages/log.html` shows them:

```
SEARCH tried=1024 accepted=367 relapsing=34 answer=000051af doses=9 loophole=00f917d1 minstret=3084
PLAN sha256=…
PATIENT n=… word=… arm=treated|control width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
TRIAL treated=… cured=… relapsed=… missed=… predicted=… control=… control_missed=…
```

`model` and `world` are `cured`, `relapsed` or `missed`. `word` is the TRNG's
word the patient was drawn from, so `cure.py` can replay that patient's world
exactly. It arrived with the second build, after round 1. SEARCH and PLAN go
out again before every patient, so a page opened late still sees what is
being tested.

## Running it on a board

1. Hold BOOTSEL, plug the Pico 2 in, and copy `build/exp232.uf2` onto the
   `RP2350` drive. A phone's file manager is enough.
2. The LED comes on for about a second: the search. Then the trial begins,
   a patient every few seconds.
3. To read the lines, open `tools/pages/log.html` in Chrome, Connect, and
   choose the board. Use page build b4 or later: b3's Copy can fail silently
   on a phone while the log streams (round 1 below).
4. To check what came back: save the lines as `board/<name>.txt` and run
   `python3 cure.py --board board/<name>.txt`. `check.sh` runs it on every
   saved log.

## On the board

**Round 1.** A Pico 2, the first build (UF2 `2e9f6811…`), and a phone with
`tools/pages/log.html` build b3. The log, pasted as the page showed it, is
[`board/round1.txt`](./board/round1.txt).

- **The search on silicon is `cure.py`'s.** 1024 tried, 367 accepted, 34 of
  them relapsing in the model, answer `0x51af` with 9 doses, first loophole
  `0xf917d1`. The PLAN hash is `cure.py`'s and the RTL's: `4cccf5ca…a112cd60`.
  Every run's minstret on silicon was 3084, the RTL's count, all 15 patients
  and the whole search.
- **The page joined at patient 7** and saw 7 to 15. `cure.py --board` holds
  every one:
  - each model outcome, recomputed from the arm, width and place;
  - each world to the number. These nine could not differ from the model:
    four controls, whose patients get no dose, so resistance changes
    nothing; and five treated patients with no resistant cell.
- **The trial at patient 15:**
  - 7 treated, and the model predicted all 7 cured. In the world 6 were
    cured and **1 missed the endpoint**.
  - 8 controls, all missed, as M3 says they must.

  The missed patient was one of 1 to 6, before the page joined, so its line
  is not in the log. But it is in TRIAL's count, and the board kept going,
  so check 10 held for every patient: no world without resistance left the
  proved model.
  **On silicon, the gap between the proof and the trial.**
- **Copy failed silently.** The page's Copy did nothing while the log
  streamed, and said nothing. The log came back only by pressing Disconnect
  and selecting the whole page. This is what exp226's round 4 met on a
  Pixel 9a, and what `life.html` and `fly.html` carry a fallback for;
  `log.html` never got it. Build b4 has it, and
  [`tools/pages/log_copy.mjs`](../../tools/pages/log_copy.mjs) holds it to
  the case: Clipboard API refusing, still streaming, every line out by the
  fallback. b3's handler, put back, fails the test.
- **The second build** puts `word=` in each PATIENT line, so a resistant
  treated patient, the one that matters, can be replayed too. Its UF2 is
  `exp232.uf2.sha256`'s. The trial is the same; only the line is longer.

**Round 2.** The same board, the second build (UF2 `dd5dbde3…`), every
PATIENT line carrying its TRNG word. The paste is
[`board/round2.txt`](./board/round2.txt).

- SEARCH, PLAN and minstret 3084 are as in round 1.
- **The page saw patients 5 to 20, and `cure.py` replays every one of the
  16 worlds from its word, to the number.** That includes the two that
  matter: patients 5 and 6, both treated.
  - Patient 5 had a lump of 6 at cell 10. The model said cured. In the
    world a resistant cell appeared, and at generation 24 there were 19
    tumour cells and 13 tissue: missed.
  - Patient 6 had a lump of 3 at cell 27. The model said cured. In the
    world: 24 tumour cells, 8 tissue, missed.

  Neither is a fault, an error or a guess. They are the TRNG's draw, lived
  out by the C world on silicon, and lived out the same way by Python.
- **The trial at patient 20:** 7 treated, all 7 predicted cured by the
  proved model; 5 cured in the world and **2 missed**. 13 controls, all
  missed.
- Across the two rounds, the board had treated 14 patients. The proof said
  all 14 would be cured; the world cured 11 and 3 missed. Round 2's 2 of 7 is
  above `cure.py`'s 13.7% over 2000 patients, which is what seven patients
  are: a small trial.

## What it does not say

- **Anything about medicine.** The world is a second model someone wrote,
  with randomness in it. It shows the shape of the argument, not a fact
  about bodies.
- **That trials beat proofs, or proofs beat trials.** M4 covers every
  enrolled patient in the model, which no finite trial does. The trial
  catches resistance, which the proof cannot see because it is not in the
  model. M5 is the endpoint's fault, and Lean finds it only if asked.
- **That the search is an AI.** It is a search. It shows only what an
  optimiser does with a goal.

## Running it

```sh
./check.sh     # about four minutes, most of it the RTL searching
./run.sh       # the same, recorded to capture.txt
```

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp232 — the cure the proof predicts ===
recorded at 2026-10-13T06:46:08Z from commit 0b63fba

>>> the theorems, and what they rest on
'Exp232.apart' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.inside_survives' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.healthy_untouched' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.off_target' depends on axioms: [propext, Quot.sound]
'Exp232.untreated_fills' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.answer_cures' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.loophole_relapses' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.body_t' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.models' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.not_before' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp232.bytes_words' depends on axioms: [propext]
'Exp232.from_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
grows_down      the kernel's tumour invades the cell below, where the model's invades the cell above            refused in body_t
every_day       the kernel doses every generation, whatever the schedule says                                   refused in body_t
count_short     the kernel is claimed to halt one instruction sooner than it does                               refused in models
harmless        the claim that a dose kills no tissue beside a tumour                                           refused in off_target
edge_tissue     the claim that tissue survives a dose with tissue on one side only                              refused in tissue_survives
sooner          the claim that untreated, a tumour fills the ring by generation 30: one cell takes 31           refused in untreated_fills
beyond          the claim that the answer cures a lump of seven too — one cell more than the trial enrolled   refused in answer_zero
loophole_cures  the claim that what meets the endpoint is cured: the loophole's lump of six gone by 64          refused in loophole_zero

>>> the search as the chip runs it, and 2000 patients in cure.py's world
search: 1024 schedules, 367 meet the endpoint, 34 of them relapse in the model
answer: 0051af, 9 doses; first loophole f917d1
  control  model 2 world 2: 962
  treated  model 0 world 0: 896
  treated  model 0 world 2: 142

>>> the shell, for the chip and the RTL
build/cure.h: kernel dad129edfd020594…, model 3081, RTL minstret 3084, search 367 accepted, 34 relapsing, answer 0051af
build/exp232.bin  15516 bytes, the build allows 16384
build/exp232.uf2  31232 bytes  sha256 dd5dbde39b7bf2959ef93a0bde626b971f96975543fe6c5512eb0a695bb7cfa6

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  Cure.lean checks, with no errors and no warnings
PASS  all 13 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  grows_down: the proof refuses a version where the kernel's tumour invades the cell below, where the model's invades the cell above
PASS  every_day: the proof refuses a version where the kernel doses every generation, whatever the schedule says
PASS  count_short: the proof refuses a version where the kernel is claimed to halt one instruction sooner than it does
PASS  harmless: the proof refuses a version where the claim that a dose kills no tissue beside a tumour
PASS  edge_tissue: the proof refuses a version where the claim that tissue survives a dose with tissue on one side only
PASS  sooner: the proof refuses a version where the claim that untreated, a tumour fills the ring by generation 30: one cell takes 31
PASS  beyond: the proof refuses a version where the claim that the answer cures a lump of seven too — one cell more than the trial enrolled
PASS  loophole_cures: the proof refuses a version where the claim that what meets the endpoint is cured: the loophole's lump of six gone by 64
PASS  kernel.bin is what proof/Cure.lean writes, 228 bytes, and kernel.sha256 is its hash
PASS  on 20 inputs the Lean model halts with 0 after exactly 3081 and the RTL with 0, each leaving exactly cure.py's 64 generations and nothing else; the RTL's instret=3084
PASS  the shell builds for the chip over speak.h and trng.h, in 15516 of the 16384 bytes it may use, and for the RTL
PASS  all 61 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 15516-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: dd5dbde39b7bf295…
PASS  on the RTL the shell's search finds cure.py's answer, 51af, and its counts — 367 accepted, 34 of them relapsing in the model — then hashes the protocol and treats six patients, model and world, exactly as cure.py does
PASS  the shell catches a version where the kernel is held to a hash that is not its own — check 1
PASS  the shell catches a version where a run's halt is held to 1 instead of 0 — check 2
PASS  the shell catches a version where the chip is asked to count one more — check 3
PASS  the shell catches a version where the search keeps the most doses, not the fewest — check 4
PASS  the shell catches a version where the world's tumour grows down while the proved model's grows up — check 10
PASS  the shell catches a version where the TRNG gives nothing — check 11
PASS  the shell catches a version where the shell itself traps entering the kernel — a fault, not a check
PASS  round1.txt: SEARCH and PLAN are cure.py's (9 times), minstret 3084 throughout; patients 7–15: every model outcome cure.py's, every world that could not differ from the model the model's to the number (9 of 9), every TRIAL count adding up, every treated patient predicted cured and every control missed
PASS  round2.txt: SEARCH and PLAN are cure.py's (16 times), minstret 3084 throughout; patients 5–20: every model outcome cure.py's, every world replayed by cure.py from its word, to the number (16 of 16), every TRIAL count adding up, every treated patient predicted cured and every control missed
PASS  a board log with one thing changed is refused: s/ tissue=26 t64=0$/ tissue=25 t64=0/
PASS  a board log with one thing changed is refused: s/sha256=4cccf5ca/sha256=4cccf5cb/
PASS  a board log with one thing changed is refused: s/control=8 control_missed=8/control=8 control_missed=7/
PASS  a board log with one thing changed is refused: s/n=8 arm=treated width=1 at=23 model=cured/n=8 arm=treated width=1 at=23 model=missed/
PASS  a board log with one thing changed is refused: s/resistant=1 t24=19 tissue=13/resistant=1 t24=18 tissue=13/
PASS  a board log with one thing changed is refused: s/word=2e8b3fbd/word=2e8b3fbc/
```
