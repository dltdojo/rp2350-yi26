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
PATIENT n=… arm=treated|control width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
TRIAL treated=… cured=… relapsed=… missed=… predicted=… control=… control_missed=…
```

`model` and `world` are `cured`, `relapsed` or `missed`. SEARCH and PLAN go
out again before every patient, so a page opened late still sees what is
being tested. That SEARCH line is what the RTL prints. These lines have not
come from a board yet.

## Running it on a board

1. Hold BOOTSEL, plug the Pico 2 in, and copy `build/exp232.uf2` onto the
   `RP2350` drive. A phone's file manager is enough.
2. The LED comes on for about a second: the search. Then the trial begins,
   a patient every few seconds.
3. To read the lines, open `tools/pages/log.html` in Chrome, Connect, and
   choose the board.

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

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit: not yet
recorded.
