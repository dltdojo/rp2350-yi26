# exp227 — the life on the phone

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp225's proved Rule 30, drawn on a phone as the board plays it.
exp225's shell and kernel are compiled in unchanged, over exp226's USB port.
For every life, the board sends all 256 generations, one per beat of the LED.
`life.html` draws each generation as it arrives. It also checks each one,
cell by cell, against Rule 30 written again in the page, and draws any
generation that is not Rule 30's in red. The proof says what the kernel wrote;
the page says what reached the phone. Round 1, on a Pico 2 and a Pixel 9a:
the page and the LED kept the same beat, and every generation the phone
received was Rule 30's. Each was also exactly `rule30.py`'s at its place
counted from the boot seed.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once, and a **phone with Chrome**
holding `exp227.uf2` and `life.html`.

## What is new, and what is not

| | Where it comes from |
| --- | --- |
| the kernel, its proof, the four checks, the lives | exp225, unchanged: `shell/shell.c`, `gen.py`'s `expect.h`, `proof/Life.lean` |
| the USB device, the clocks, the status line, the LED's stage and error counts | exp226, moved into `tools/hazard3/shell/speak.h` for this experiment; exp226's UF2 still builds byte for byte |
| a line for every generation, and the LED playing the life again | **here**: `shell/board_chip.c` |
| a page that draws and checks them | **here**: `life.html` |

The test the repository asks of a new experiment's code applies to the move.
If this code changed, would this experiment's claim change? For the USB port,
no. So it is not this experiment's code, and exp227 includes it from `tools/`
instead of copying it.

## The lines

```
LIFE round minstret gen1 gen256 centre-column    before a life: exp226's line, as the RTL prints it
SEED round seed                                  what generation 0 grew from
GEN  round g word                                generation g, all 32 cells, one per beat
exp227 usb=… … lives=… minstret=…                exp226's status line, about once a second
```

The kernel writes all 256 generations in 3079 instructions, about 64 µs at
48 MHz, before the first beat. **What the phone shows is a replay**, at the
speed a person can watch: one generation per beat, as exp225's LED played
it. A cell that is alive flashes the LED for one unit (about 0.18 s), and a
dead cell leaves it dark for two units. A life takes about 92 s, with 1.5 s
dark before each one. The GEN line goes out at the start of its beat, so the
newest row on the page and the LED show the same generation.

The last generation of each life is the seed of the next, as in exp225. So
every life the board plays belongs to one unbroken Rule 30 sequence, and the
page checks the seams between lives too.

## What the page checks, and what it cannot

For each GEN line, `life.html` computes Rule 30 of what came before it. That
is the previous generation, or the seed for generation 0. It compares the
result with the line, cell by cell. The rule is written the way it is stated:
each cell becomes left XOR (centre OR right), and a cell's left neighbour is
the next bit up, round the ring. Nothing is shared with the kernel's shifts,
with the C code, or with `rule30.py`. Each generation gets one of three
verdicts:

- **ok**: it follows from the one before.
- **wrong**: it does not, and the page says against what. Its row is red.
- **unchecked**: nothing before it was seen. Either the page joined in the
  middle of a life, or a line was lost on the way.

The page also checks each generation against its LIFE line (generation 0,
generation 255 and the centre column), checks every seam between lives, and
checks that minstret is 3082.

So the page catches anything the C formatting, the USB code, the cable or the
phone got wrong. **It cannot catch the kernel being wrong.** A wrong kernel
would write a wrong first generation from a right seed, and that is caught.
But the page has no way to tell whether the generations it was sent are the
ones the kernel wrote. That gap is closed by the proof (`lives` in exp225)
and by the shell's own four checks.

The page shows the last 48 generations as cells, with bit 31 on the left. A
marker on the right of each row shows its verdict: green, red, or grey for
unchecked. The centre column, the cell the LED plays, is outlined. A dot
beside the canvas flashes with each live centre cell. The board's raw lines
appear below the canvas.

**Copy** puts the page's verdict, as one `#page` line, on the clipboard,
followed by every line it received. In exp226's round 4, Copy did nothing on a
Pixel 9a while the log was streaming, and nothing on the page said why. So
this Copy tries the Clipboard API first, then a selected text area, and the
status line names whichever one failed.

## Running it on a board, from a phone

Files on the phone: `exp227.uf2` and `life.html`, downloaded once and kept.

1. **Flash.** Hold BOOTSEL, plug the board into the phone, and let go. Copy
   `exp227.uf2` onto the `RP2350` drive with the file manager. Do it straight
   away: a phone whose screen sleeps takes the board out of BOOTSEL
   ([docs/debugging-on-a-phone.md](../../docs/debugging-on-a-phone.md)).
2. **The LED.**
   - **The life, or a count.** An irregular beat is the life: one flash for
     each generation whose centre cell is alive, as in exp225. A host that is
     part way through enumerating the device shows a count instead: 2 to 5
     flashes, then 3 s dark, repeated, which is how far it got (exp226's
     stages). With no host at all, on a USB charger, the life plays, because
     nothing is stuck.
   - **An error.** A 2-second light, then N flashes. 1 to 4 are exp225's
     checks; 5 to 9 are the clocks or the controller (exp226's table).
3. **`life.html`.** Open it with Chrome, tap **Connect**, and pick the board.
   Rows appear one per beat, in step with the LED. A new life starts about
   every 94 s.
4. **Bring it back.** Tap **Copy** and paste the result here. If the status
   line says Copy failed, tap **Disconnect** first, then **Copy**. Whatever
   the status line says about Copy is worth pasting too.

If the page says the board is not exp227, the board is still running another
firmware: flash again.

## What is checked without a board

`./check.sh`:

- **The page's checking block, under node.** It is fed in 64-byte packets,
  the way the endpoint delivers them.
  - Its Rule 30 agrees with `rule30.py` on 5005 words.
  - Two lives as `fixtures.py` writes them, from `rule30.py`, come out all
    Rule 30's.
  - Each of these is told apart: joining mid-life, a bit flipped in one
    generation, a lost line, a seam with the wrong seed, minstret 3083, and a
    LIFE line that disagrees with generation 255.
  - Four wrong versions of the page are caught.
- **The whole page in headless Chromium.** A stand-in USB device answers like
  exp227's and sends nothing until DTR is raised, as `usbdev.c` does. The
  check confirms that the page claims both interfaces, sets the line coding,
  raises DTR, draws, and gives the expected verdict, and that Copy puts the
  verdict and every line on the clipboard. `findCdc` is checked to be
  `tools/pages/log.html`'s, byte for byte.
- **The UF2.** The shell builds into 16 KiB of flash, its UF2 reads back as
  built, and it is byte for byte the committed one (`exp227.uf2.sha256`).
- **Logs from a phone.** Every log under `board/` is checked twice: by the
  page's own block, and against `rule30.py`'s lives from SEED0 at the same
  round and generation.

What none of it reaches: the board sending the lines, a phone drawing them,
and a person seeing the LED and the page keep the same beat.

## C or Rust

How this experiment's USB port, written in C for the RISC-V shell, differs
from the Rust + Embassy one the rest of the repository uses: the clocks
`embassy_rp::init` sets without saying, polling against interrupts, what is
in the repository and what is upstream, and what the board rounds cost. In
Traditional Chinese: [C-AND-RUST.zh-TW.md](./C-AND-RUST.zh-TW.md).

## On the board

| Round | Firmware | What came back |
| --- | --- | --- |
| 1 | revision 1 (`860a8329…`), page build p1 | A Pico 2 and a Pixel 9a. **The LED and the page flashed together, in step**, in the words of the person watching. **Copy** gave the report back. The page's own verdict, the `#page` line: **212 of 213 generations Rule 30's, 0 wrong, 1 unchecked** (the first one it saw, since it joined at generation 90 of life 0), no gaps, the one seam between lives right, minstret 3082. The paste ([board/round1-life.txt](./board/round1-life.txt)) holds 175 of those generations, from generation 90 of life 0 to generation 8 of life 1; it ends mid-line, so the text was cut somewhere between the clipboard and the chat. All 175 are Rule 30's by the page's block, and each is `rule30.py`'s at its round and generation from SEED0, both replayed by `check.sh`. Clocks from the status lines: clk_sys as left 10943 kHz, clk_usb 48002 kHz, clk_sys moved 48006 kHz, 47998-47999 kHz against the phone's frames; no bus errors, nothing dropped. |

The two lives are the first two after boot: life 0 grew from SEED0, one live
cell, and life 1 from life 0's last generation, `02bb07b0`, which the SEED
line carried and the page checked. Life 1's LIFE line, `06a28c28 27266abc
bd221e08`, is the second life exp225's RTL run prints.

This was a third boot of exp226's port. clk_sys as left was 10943 kHz here,
against 10966 and 10950 in exp226's rounds 4 and 5. That fits a ring
oscillator varying from boot to boot.

What the report does not say is whether Copy was pressed before or after
Disconnect, or which of its two ways worked: the status line that says so
was not part of the paste.

## What it does not say

- **That the kernel wrote what the page drew.** The proof and the shell's
  checks cover the kernel. The page covers everything after it (see above).
- **That the beat is exactly in step.** The GEN line leaves at the start of
  its beat, and to a person watching, the LED and the page flashed together.
  The delay between them has not been measured.
- **Recovery without a hand.** There is no 1200-baud reboot, so BOOTSEL by
  hand is the way back.
- **More than one phone.** The walkthrough is written for a Pixel 9a.

## Running it

```sh
./check.sh     # under a minute
./run.sh       # the same, recorded to capture.txt
```

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp227 — the life on the phone ===
recorded at 2026-10-10T11:13:31Z from commit 3f5f514

>>> what the board sends, as rule30.py writes it: the start of a life
LIFE 00000000 00000c0a 00038000 02bb07b0 bae4d19d
SEED 00000000 00010000
GEN 00000000 00000000 00038000
GEN 00000000 00000001 00064000
GEN 00000000 00000002 000de000

>>> the shell, for the chip
build/expect.h: kernel 559d70d93ee6242d…, model 3079, RTL minstret 3082, first life 8c3f6e7f0f4aa2dc…
build/exp227.bin  11456 bytes, the build allows 16384
build/exp227.uf2  23040 bytes  sha256 860a832994cecd16d499c961c6ce585893cb37af31525b11a72ef17f473b0d54

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  the page's script parses (node --check)
PASS  findCdc is tools/pages/log.html's, byte for byte
PASS  the page's Rule 30 is rule30.py's on all 5005 words tried
PASS  two lives as the board sends them, in 64-byte packets: all 512 generations Rule 30's, the seam between them too
PASS  joined at generation 100 of life 0: that one unchecked, the 411 after it checked
PASS  one bit of generation 37 flipped on the way: 37 is wrong, and 38, which does not follow from it
PASS  generation 120 lost: a gap, 121 unchecked, nothing called wrong
PASS  life 1 grown from a seed that is not life 0's last generation: the seam is wrong, the life itself is Rule 30's
PASS  a LIFE line with minstret 3083 is caught
PASS  a LIFE line that disagrees with generation 255: that generation is marked
PASS  the tests catch a page where Rule 30 is left XOR (centre AND right): the page's Rule 30 is rule30.py's on all 5005 words tried — word 3, 00010000 00038000: the page says 8000
PASS  the tests catch a page where a generation is taken as its own expectation: one bit of generation 37 flipped on the way: 37 is wrong, and 38, which does not follow from it — rows 512 o
PASS  the tests catch a page where the seam between lives is not checked: life 1 grown from a seed that is not life 0's last generation: the seam is wrong, the life itself is Rule 30's
PASS  the tests catch a page where the right neighbour is the cell itself: the page's Rule 30 is rule30.py's on all 5005 words tried — word 3, 00010000 00038000: the page says 18000
PASS  good.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  good.txt: the verdict line says "512 of 512 generations are Rule 30's"
PASS  good.txt: the canvas has the life on it (115074 pixels), and no script error
PASS  good.txt: Copy puts the verdict and every line received on the clipboard (50925 characters)
PASS  flipped.txt: the page claims interfaces 0 and 1, sets the line coding, then raises DTR
PASS  flipped.txt: the verdict line says "2 wrong"
PASS  flipped.txt: the canvas has the life on it (115074 pixels), and no script error
PASS  flipped.txt: Copy puts the verdict and every line received on the clipboard (51002 characters)
PASS  the shell builds for the chip from exp225's shell.c and expect.h over speak.h, in 11456 of the 16384 bytes it may use
PASS  all 45 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 11456-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 860a832994cecd16…
PASS  round1-life.txt: 174 of 175 generations from a board are Rule 30's, 1 unchecked, 1 seams between lives, 1 LIFE lines
PASS  round1-life.txt: all 175 generations are rule30.py's, at their round and generation from SEED0
```
