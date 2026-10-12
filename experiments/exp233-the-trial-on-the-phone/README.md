# exp233 — the trial on the phone

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp232's trial, on a phone, every line checked again in the page:
`trial.html`. exp232's board searches for a dosing schedule over a proved
model of tissue and tumour, hashes the protocol, then treats patients drawn
from its TRNG. It lives each patient twice: in the model, by the proved
kernel, and in a world with resistance in it. The page runs the same search
itself and hashes the same protocol itself. It replays every patient, cell by
cell, from the random word the board drew it from. Where the proved model
said a treated patient would be cured and the world did not, the page draws
both lives side by side, a row a generation, the trial's endpoint marked.**

Needs: exp232's board, a **Pico 2** running `exp232.uf2` (the second build,
whose lines carry each patient's word), and a **phone with Chrome** holding
`trial.html`. Or nothing at all: **Demo** plays the same page with patients
drawn in the page, and says it checks nothing. exp233 has no firmware of its
own. A plain-language account is in [WHY.zh-TW.md](./WHY.zh-TW.md).

## What is new, and what is not

| | Where it comes from |
| --- | --- |
| the board, its lines, the search, the trial | exp232, unchanged: `shell/board_chip.c`'s formats |
| the proof the page quotes | exp232's `proof/Cure.lean`; the page runs none of it |
| what Copy, the connection and the tests are made of | exp231's `fly.html`, `tools/pages/headless.mjs` and `pagecheck.sh` |
| the model, the world, the search and SHA-256, written a third time | **here**: `trial.html`, between `BEGIN trial-check` and `END trial-check` |
| the two lives drawn side by side | **here** |

## The page

From the top:

- **The trial**, as the board counts it, every patient since boot, the ones
  before the page joined too. For example: "Treated 7: the proof predicts 7
  cured · the world cured 5, 2 missed". Then the controls, all missed, as M3
  says they must be.
- **The search and the protocol.** The page runs the search itself, about
  0.1 s in node: 1024 schedules, 367 accepted, 34 relapsing, answer `0x51af`.
  It also hashes the protocol itself, with its own SHA-256. A page opened from
  a phone's files may have no `crypto.subtle`, so it carries its own. Both
  marks are ✓ when the board's lines agree.
- **Where the proof and the world part.** Each such patient gets two
  canvases of 65 rows by 32 cells. On the left is the proved model, on the
  right the world.
  - Tissue is green, tumour dark red, resistant tumour orange.
  - A blue square in the margin is a dose, and the line under generation 24 is
    the endpoint.
  - The resistant cell's daughters are all resistant, so a relapse in the
    world is an orange wedge, while the model's tumour is gone within the
    first dozen rows.
- **What Lean proved, and what it refused**, quoted, with the page saying it
  checks none of it.
- **The verdict line** and the last 40 lines received, a wrong one marked
  with why.

What the page checks, line by line:

| Line | Against |
| --- | --- |
| `SEARCH` | the page's own search: tried, accepted, relapsing, answer, loophole; doses against the answer; minstret 3084 |
| `PLAN` | the page's own SHA-256 of the same eight words |
| `PATIENT` with a word | the patient replayed from it: arm, lump, the model's outcome, the world's outcome, resistance, tumour at 24, least tissue, tumour at 64 |
| `PATIENT` without one (exp232's first build) | the model's outcome; the world's numbers where the world cannot differ from the model, which is a control or no resistant cell; otherwise "partial" |
| `TRIAL` | its counts adding up; every control missed (M3); every treated patient predicted cured (M4); and against the one before it, moved by exactly the patient in between |

## What is checked without a board

`check.sh`, under a minute:

1. **The page's block under node**, fed in 64-byte packets, against what
   `fixtures.py` writes from exp232's `cure.py`, which shares nothing with
   the page:
   - its search, its protocol hash, and its model and world on 3003 random
     words, every number;
   - 40 patients as the board sends them, and the same without words;
   - a late join, and ten wrong streams, each told apart.
2. **Six wrong pages** are caught: no resistance in the world; a dose killing
   resistant cells; the tumour invading downward; the search keeping the most
   doses; SHA-256 padding with 0x81; a TRIAL never held to the patient before
   it.
3. **The whole page in headless Chromium**, against a stand-in for exp232's
   USB device:
   - claims, line coding, DTR;
   - the panels, the charts, the verdict and Copy;
   - with no WebUSB, Demo.

   A page that draws the patients the model and the world agree on is
   caught.
4. **Every log exp232's board gave back** (its `board/*.txt`), through the
   page's block and through the page in the browser:
   - **round 1**: 9 of 9 patients agree;
   - **round 2**: 16 of 16 agree, and patients 5 and 6 are drawn — both
     treated, both predicted cured, both missed with a resistant cell.

## Running it

```sh
./check.sh     # under a minute
./run.sh       # the same, recorded to capture.txt
```

On a phone: copy `trial.html` to it, open it from Files with Chrome, plug in
exp232's board, press Connect and choose it. A patient arrives every few
seconds, with the LED's flashes. **Copy** gives the verdict and every line
received.

## What it does not say

- **Anything Lean proved.** The page quotes the theorems; it cannot run
  them. What it checks is the board's lines, against a third writing of the
  same rule.
- **Anything about medicine**, as exp232 says: the world is a second model,
  with randomness in it.

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp233 — the trial on the phone ===
recorded at 2026-10-12T08:20:32Z from commit 537979a

>>> what exp232's board sends, as cure.py writes it: the first patient
build/fixtures: 40 patients, the model and the world part on 2 treated: [3, 4]; patient 2 is the first the world cured
SEARCH tried=1024 accepted=367 relapsing=34 answer=000051af doses=9 loophole=00f917d1 minstret=3084
PLAN sha256=4cccf5ca251d8259a4f0d16052d0ba2e14c3e66203d1c60c7f579a6ca112cd60
PATIENT n=1 word=aeb6ce87 arm=treated width=4 at=8 model=cured world=cured resistant=0 t24=0 tissue=28 t64=0
TRIAL treated=1 cured=1 relapsed=0 missed=0 predicted=1 control=0 control_missed=0

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  the page's script parses (node --check)
PASS  findCdc is tools/pages/log.html's, byte for byte
PASS  the page's own search is cure.py's: 1024 tried, 367 accepted, 34 relapsing, answer 000051af, loophole 00f917d1
PASS  the page's own SHA-256 of the protocol is cure.py's, 4cccf5ca251d8259…
PASS  the page's model and world are cure.py's, every number, for all 3003 random words
PASS  40 patients as exp232's board sends them, in 64-byte packets: all replayed and agreeing, every SEARCH, PLAN and TRIAL; the model and the world part on 2
PASS  the same with no word on the lines, as exp232's first build: 38 checked whole, 2 treated with resistance checked as far as the model
PASS  joined at patient 9: 32 seen, the board's TRIAL still counting all 40
PASS  a parted patient's tumour at 24 changed: that patient is wrong, and says t24
PASS  a parted patient's word changed by one bit: its replay no longer agrees
PASS  a cured patient sent as missed: the patient is wrong, and the TRIAL after it moved the wrong way
PASS  a PLAN line one digit off is caught
PASS  a SEARCH line saying no schedule relapses is caught
PASS  a TRIAL line with one cured too many is caught
PASS  a TRIAL line with a control that met the endpoint is caught, by M3
PASS  patient 12's line lost: a gap, nothing called wrong
PASS  a status line with minstret 3085 is caught
PASS  round1.txt: 9 of 9 patients from a board agree with the page; search, plan and every TRIAL count agree; the model and the world part on 0
PASS  round2.txt: 16 of 16 patients from a board agree with the page; search, plan and every TRIAL count agree; the model and the world part on 2
PASS  the tests catch a page where the world has no resistance in it: the page's model and world are cure.py's, every number, for all 5 random words — word 2654496c: cure.py 0 1 
PASS  the tests catch a page where a dose kills resistant cells too: the page's model and world are cure.py's, every number, for all 8 random words — word b4b95461: cure.py 1 5 
PASS  the tests catch a page where the tumour invades the cell below: the page's model and world are cure.py's, every number, for all 0 random words — word 00000000: cure.py 0 1 
PASS  the tests catch a page where the search keeps the most doses: the page's own search is cure.py's: 1024 tried, 367 accepted, 34 relapsing, answer 000051af, loophole 00f917d1
PASS  the tests catch a page where SHA-256 pads with 0x81: the page's own SHA-256 of the protocol is cure.py's, 4cccf5ca251d8259… — 87ac43ca356dfcb27f5fdc142bfce8a90
PASS  the tests catch a page where a TRIAL line is never held to the patient before it: a cured patient sent as missed: the patient is wrong, and the TRIAL after it moved the wrong way — patients 
PASS  good.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  good.txt: the verdict line says "40 of 40 patients agree"
PASS  good.txt: the trial panel says "Treated 28: the proof predicts 28 cured · the world cured 26, 2 missed", and the search and the protocol agree with the page's own
PASS  good.txt: 2 patients drawn where the model said cured and the world did not (149352, 149352 pixels), no script error
PASS  good.txt: Copy puts the verdict and every line received on the clipboard (39488 characters)
PASS  with no WebUSB the page says so, and offers Demo
PASS  Demo draws patients at about the board's pace and says it checks nothing: "Demo: 3 patients computed in this page, so nothing here is check…"
PASS  Copy during Demo says DEMO, no board, on its first line
PASS  t24.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  t24.txt: the verdict line says "1 wrong"
PASS  t24.txt: the trial panel says "Treated 28: the proof predicts 28 cured · the world cured 26, 2 missed", and the search and the protocol agree with the page's own
PASS  t24.txt: 2 patients drawn where the model said cured and the world did not (149352, 149352 pixels), no script error
PASS  t24.txt: Copy puts the verdict and every line received on the clipboard (39539 characters)
PASS  round1.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  round1.txt: the verdict line says "9 of 9 patients agree"
PASS  round1.txt: the trial panel says "Treated 7: the proof predicts 7 cured · the world cured 6, 1 missed", and the search and the protocol agree with the page's own
PASS  round1.txt: 0 patients drawn where the model said cured and the world did not ( pixels), no script error
PASS  round1.txt: Copy puts the verdict and every line received on the clipboard (10033 characters)
PASS  round2.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  round2.txt: the verdict line says "16 of 16 patients agree"
PASS  round2.txt: the trial panel says "Treated 7: the proof predicts 7 cured · the world cured 5, 2 missed", and the search and the protocol agree with the page's own
PASS  round2.txt: 2 patients drawn where the model said cured and the world did not (149352, 147552 pixels), no script error
PASS  round2.txt: Copy puts the verdict and every line received on the clipboard (16304 characters)
PASS  the tests catch a page where the page draws the patients the model and the world agree on: good.txt: 6 patients drawn where the model said cured and the world did not (149244, 149532, 149244, 149820, 1
```
