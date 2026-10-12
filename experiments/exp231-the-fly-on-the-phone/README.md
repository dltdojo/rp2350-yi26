# exp231 — the fly on the phone

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp230's proved fly, on the chip, watching exp225's proved Rule 30, drawn on
a phone as the board plays it. Each round the shell runs two proved kernels
one after the other in the same region. The first is the life: 256 generations
from a seed. The second is the fly, on the seed and those 256 generations: what
it saw move up and down at each step. The shell checks what it can see of both
proofs, among them `watches_life` itself: no step is seen moving down. Then it
plays the fly on the LED, a flash for each step seen moving. It sends each step
to `fly.html`, which draws the generation beside a meter of what moved, and
checks each step again, with Rule 30 and the fly both written cell by cell in
the page.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once, and a **phone with Chrome**
holding `exp231.uf2` and `fly.html`. **Not yet run on a board**: everything
below that says so was run on the Hazard3 RTL and in headless Chromium.

exp230 was planned with the board and the phone left to a next experiment, on
exp227's USB; this is it. A plain-language account is in
[WHY.zh-TW.md](./WHY.zh-TW.md).

## What is new, and what is not

| | Where it comes from |
| --- | --- |
| the life's kernel, its proof, its four checks | exp225, unchanged: `kernel.bin`, `gen.py`'s `expect.h`, `proof/Life.lean` |
| the fly's kernel and its proof | exp230, unchanged: `kernel.bin`, `proof/Fly.lean` |
| the USB device, the clocks, the status line, the LED's stage and error counts | exp226's, in `tools/hazard3/shell/speak.h`, as exp227 uses it |
| the RTL's FAIL and FAUL lines | `tools/hazard3/shell/fail_sim.h`, out of exp225's `board_sim.c` |
| two kernels a round, and the fly's five checks | **here**: `shell/shell.c`, `gen.py`'s `fly.h` |
| a SEES line and a beat for every step | **here**: `shell/board_chip.c` |
| a page that draws and checks them | **here**: `fly.html` |

The shell is new rather than exp225's because exp225's runs one kernel a round
and this one runs two. `fly.html` is a page of its own, not `life.html` with a
column added: it is an appliance (see
[`tools/pages/README.md`](../../tools/pages/README.md)) for exp231's lines.
Its Rule 30 is three lines, written again. The rest of its checking is the fly,
which `life.html` does not have.

## A round

```
the life   region zeroed; exp225's kernel at 0, the seed at 0x100
           -> halts with 0 after 3079; generations at 0x200          checks 1-4, exp225's
the fly    region zeroed; exp230's kernel at 0; at 0x200 the seed,
           then the 256 generations: 257 frames
           -> halts with 0 after 70924; each step's up and down at
              0x800 + 8t, the totals at 0x100 and 0x104                checks 10-14
```

Every frame the fly is shown is Rule 30 of the one before, which is exactly the
hypothesis of exp230's `watches_life`. So the theorem says what the shell
should find. The shell checks:

| Check | What | Which proof it watches |
| --- | --- | --- |
| 10 | the fly's kernel bytes are exp230's `kernel.sha256` | — |
| 11 | it halted (ecall, t0 = 1) with 0 | `detects` |
| 12 | minstret is 70927, the RTL's count | `detects`: 70924, whatever the frames, and the harness's 3 |
| 13 | round 0's 256 steps and two totals are `fly.py`'s, by SHA-256 | `detects` |
| 14 | no step is seen moving down more than up, every round | `watches_life` |

The last generation is the next round's seed, as in exp225. Both kernels
together take about 74,000 instructions, about 1.6 ms at 48 MHz, before the
first beat. **What the LED and the phone show is a replay**, one step a beat.

## The lines

```
LIFE round minstret gen1 gen256 centre-column    exp227's line: the life's kernel
FLY  round minstret up down                      the fly's kernel: its count and totals
SEED round seed                                  frame 0, what generation 0 grew from
SEES round g word up down                        generation g, and what the fly saw move
                                                 from the frame before to it
exp231 usb=… … lives=… minstret=…                exp226's status line, about once a second
```

## The LED is the fly

One step a beat, as exp225's beat (about 0.36 s):

| The LED | What the fly saw |
| --- | --- |
| a flash, one unit on and one off | the step moved up, more than down |
| dark for the beat | nothing moved: up and down the same |
| — | down more than up never reaches the LED: check 14 stops the shell first |

So a round is an even beat, with a gap where the fly saw nothing move. From
the boot seed, one live cell, the first step is the only gap: generation 0
grows from one cell to three, and the fly sees one cell move each way. In the
first twelve rounds there is no other (`fly.py`, with exp225's `rule30.py`).
A round takes about 92 s, with 1.5 s dark before each.

The rest is exp227's, unchanged:

- **A count.** 2 to 5 flashes, then 3 s dark, repeated: a host part way
  through enumerating the device.
- **An error.** A 2-second light, then N flashes:
  - 1 to 4: exp225's checks.
  - 5 to 9: the clocks or the controller (exp226's table).
  - 10 to 14: the fly's checks, above.

## The page

`fly.html`, opened from the phone's files with Chrome:

- **Rows.** Each row is one generation, the newest at the bottom, bit 31 on the
  left.
- **The meter.** Beside each row is what the fly saw from the row above. A bar
  to the left counts the cells that moved left, toward bit 31: exp230's up and
  Rule 30's left. A bar to the right counts the cells that moved right.
- **The mark.** At the end of each row is the page's own verdict.
- **Above the rows.** A copy of the LED, the current step in words, and the
  round's totals so far.

It checks each SEES line against the line before it, or for step 0 against the
round's seed, and gives one of three verdicts:

- **ok**: its generation is Rule 30 of that frame, and its two counts are what
  the page's own fly counts between them.
- **wrong**: one of those is not so, and the page says which.
- **unchecked**: no frame before it was seen.

It also checks the FLY line's totals against every step of a round it saw
whole, both minstrets, generation 0 and 255 against the LIFE line, and the
seams between rounds. It counts what the board said the fly saw: moving up,
not moving, moving down.

The page's Rule 30 and fly are written cell by cell, as each is stated. The fly
is "a cell lit now, whose neighbour below was lit a frame ago, moved up". None
of it is shared with the kernels' shifts, with C, or with the Python.

So the page catches anything the C, the USB code, the cable or the phone got
wrong. **It cannot catch a kernel being wrong.** The proofs and the shell's
checks cover the kernels. The page covers everything after them.

**Demo** plays the same thing with no board: computed in the page from one
live cell, at the board's pace. Its rows are checked against the page's own
functions, so it checks nothing, and the verdict line, the status line and Copy
all say so (`#page exp231 fly.html p1 DEMO, no board`). It is there so the
page can be shown where there is no board. It is not evidence.

**Copy** works as exp227's does: the Clipboard API, then a selected text area,
and the status line names whichever one failed.

## Running it on a board, from a phone

Files on the phone: `exp231.uf2` and `fly.html`, downloaded once and kept.

1. **Flash.** Hold BOOTSEL, plug the board into the phone, and let go. Copy
   `exp231.uf2` onto the `RP2350` drive with the file manager straight away. A
   phone whose screen sleeps takes the board out of BOOTSEL
   ([docs/debugging-on-a-phone.md](../../docs/debugging-on-a-phone.md)).
2. **The LED.**
   - **An even beat**: the fly, seeing every step move. The first round's
     dark pause is one beat longer than the others, because its first step
     is the one the fly sees not moving.
   - **2 to 5 flashes, 3 s dark**: a host stuck enumerating. With no host at
     all, on a USB charger, the beat plays.
   - **A 2-second light, then N flashes**: an error, numbered as above.
3. **`fly.html`.** Open it with Chrome, tap **Connect**, and pick the board.
   Rows appear one per beat, in step with the LED. The bars point left.
4. **Bring it back.** Tap **Copy** and paste the result here. If the status
   line says Copy failed, tap **Disconnect** first, then **Copy**.

If the page says the board is not exp231, the board is running another
firmware: flash again.

## What is checked without a board

`./check.sh`:

- **The page's checking block, under node.** It is fed in 64-byte packets.
  - Its Rule 30 and fly agree with `rule30.py` and `fly.py` on 5007 pairs of
    words.
  - Two rounds as `fixtures.py` writes them all agree.
  - Each of these is told apart: joining mid-round, a bit flipped in one
    generation, an up count one too many, a step crossed to look like down, a
    lost line, a FLY line whose totals do not add up, and a minstret of 70928.
  - Five wrong versions of the page are caught: Rule 30 with AND for OR, the
    fly looking the wrong way, the counts never compared, the totals never
    compared, and the minstret never compared.
- **The whole page in headless Chromium**, against a stand-in USB device that
  sends nothing until DTR. The check confirms that the page claims the
  interfaces, sets the line coding, raises DTR, draws, gives the expected
  verdict, and that Copy works. With no WebUSB, Demo plays and says it checks
  nothing.
- **The shell on the RTL.** It runs two rounds, printing LIFE and FLY words,
  each exactly what `rule30.py` and `fly.py` say:
  - round 0 counts 2053 up and 1030 down, 255 steps seen moving and 1 not;
  - round 1 counts 2004 and 992, all 256 moving.

  Seven wrong shells are caught, each by the check it breaks. Among them is the
  fly shown the generations without the seed before them, which check 13
  catches.
- **The UF2.** 12400 bytes of the 16 KiB it may use, it reads back as built,
  and it is byte for byte the committed one (`exp231.uf2.sha256`).
- **Logs from a phone** (`board/*.txt`, none yet). Each is checked by the
  page's own block, and against `rule30.py` and `fly.py` from SEED0 at its
  round and step.

What none of it reaches: the board running two kernels a round, the beat on
its LED, a phone drawing the steps, and a person seeing the two keep time.

## On the board

| Round | Firmware | What came back |
| --- | --- | --- |
| — | revision 1 (`0346f697…`), page build p1 | not yet run |

## What it does not say

- **That the kernels wrote what the page drew.** The proofs and the shell's
  checks cover the kernels; the page covers everything after them.
- **That `watches_life` holds on silicon for every round.** Check 14 holds it
  for every round the board runs, and only those.
- **Recovery without a hand.** There is no 1200-baud reboot, so BOOTSEL by
  hand is the way back.
- **More than one phone.** The walkthrough is written for a Pixel 9a, which
  exp227 used.

## Running it

```sh
./check.sh     # under two minutes
./run.sh       # the same, recorded to capture.txt
```

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp231 — the fly on the phone ===
recorded at 2026-10-12T02:46:24Z from commit fd2daed

>>> what the board sends, as rule30.py and fly.py write it: the start of a round
LIFE 00000000 00000c0a 00038000 02bb07b0 bae4d19d
FLY 00000000 0001150f 00000805 00000406
SEED 00000000 00010000
SEES 00000000 00000000 00038000 00000001 00000001
SEES 00000000 00000001 00064000 00000002 00000001
SEES 00000000 00000002 000de000 00000003 00000002
SEES 00000000 00000003 00191000 00000003 00000001

>>> the shell, for the chip and the RTL
build/expect.h: kernel 559d70d93ee6242d…, model 3079, RTL minstret 3082, first life 8c3f6e7f0f4aa2dc…
build/fly.h: fly 0361bd0d0b52e6f3…, model 70924, RTL minstret 70927, first round up 2053 down 1030, steps ff41a6963da90979…
build/exp231.bin  12400 bytes, the build allows 16384
build/exp231.uf2  25088 bytes  sha256 0346f697a56f99108cfcfce6dc8fd5eb3e7ec87820e1d6cbff84dae50095745e

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  the page's script parses (node --check)
PASS  findCdc is tools/pages/log.html's, byte for byte
PASS  the page's Rule 30 is rule30.py's, and its fly counts fly.py's, on all 5007 pairs tried
PASS  two rounds as the board sends them, in 64-byte packets: all 512 steps agree, 511 seen moving up, 1 not, none down; both FLY lines' totals add up
PASS  joined at step 100 of round 0: that one unchecked, the 411 after it checked; only round 1's totals checked
PASS  one bit of generation 37 flipped on the way: 37 is wrong, frame and counts, and 38, which does not follow from it
PASS  step 50's up count one more than the fly saw: that step is wrong, its generation is not, and round 0's total is off
PASS  step 60 sent as if seen moving down, up and down crossed: it is wrong, and counted as seen down
PASS  step 120 lost: a gap, 121 unchecked, nothing called wrong, round 0's totals not checked
PASS  a FLY line whose down total is one more than its steps add up to is caught
PASS  a FLY line with minstret 70928 is caught
PASS  the tests catch a page where Rule 30 is left XOR (centre AND right): the page's Rule 30 is rule30.py's, and its fly counts fly.py's, on all 5007 pairs tried — pair 3, 00010000 0
PASS  the tests catch a page where the fly looks the wrong way: up from the cell above: the page's Rule 30 is rule30.py's, and its fly counts fly.py's, on all 5007 pairs tried — pair 3, 00010000 0
PASS  the tests catch a page where the counts are never compared: one bit of generation 37 flipped on the way: 37 is wrong, frame and counts, and 38, which does not follow from
PASS  the tests catch a page where the FLY line's totals are not checked: step 50's up count one more than the fly saw: that step is wrong, its generation is not, and round 0's total i
PASS  the tests catch a page where the fly's minstret is not checked: a FLY line with minstret 70928 is caught — rows 256 ok 256 wrong 0 [] unchecked 0 gaps 0 seen 255/1/0 totals
PASS  good.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  good.txt: the verdict line says "512 of 512 steps agree"
PASS  good.txt: the rows and the fly's meter are drawn (254456 pixels), the last step said "← moving left", no script error
PASS  good.txt: Copy puts the verdict and every line received on the clipboard (60974 characters)
PASS  with no WebUSB the page says so, and offers Demo
PASS  Demo plays from one live cell at the board's pace, drawn (2349 pixels), and says it checks nothing: "Demo: 3 steps computed in this page, so nothing here is chec…"
PASS  Copy during Demo says DEMO, no board, on its first line
PASS  crossed.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  crossed.txt: the verdict line says "1 wrong"
PASS  crossed.txt: the rows and the fly's meter are drawn (254456 pixels), the last step said "← moving left", no script error
PASS  crossed.txt: Copy puts the verdict and every line received on the clipboard (61066 characters)
PASS  the shell builds for the chip from exp225's and exp230's kernels over speak.h, in 12400 of the 16384 bytes it may use, and for the RTL
PASS  all 49 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 12400-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 0346f697a56f9910…
PASS  on the RTL the shell runs two rounds: each life rule30.py's, each fly's totals and steps fly.py's — 255 steps seen moving up and 1 not, then 256 and 0
PASS  the shell catches a version where the fly's kernel is held to a hash that is not its own — check 10
PASS  the shell catches a version where the fly's halt is held to 1 instead of 0 — check 11
PASS  the shell catches a version where the chip is asked to count one more for the fly — check 12
PASS  the shell catches a version where the first round's steps are held against a hash that is not fly.py's — check 13
PASS  the shell catches a version where the fly is shown the generations without the seed before them — check 13
PASS  the shell catches a version where the shell calls a step moving down when it moved up — check 14
PASS  the shell catches a version where the shell itself traps setting the fly up — a fault, not a check
SKIP  checking a phone's log: none recorded yet (board/*.txt)
```
