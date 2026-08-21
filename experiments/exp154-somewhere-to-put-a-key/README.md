# exp154-somewhere-to-put-a-key — does this chip have anywhere to keep a secret?

The [signing road](../README.md#the-signing-road) needs a place to keep a
private key that code on the other side of a security boundary cannot read.
Before building any boundary, this asks the part what it already has.

That is the move [exp138](../exp138-what-the-rom-already-knows/) made for A/B
updates, and it is here for the same reason: the standard advice is to assume
the chip has nothing and build the missing thing, and on this chip that advice
has already been wrong once.

**It reads. It writes nothing.** OTP is one-time programmable, so a firmware
that gets a write wrong does not fail — it ruins the board, permanently, for
every experiment after this one. `check.sh` greps for the HAL's write functions
and fails if any of them appears, because "we did not mean to" is not a
property you can check later.

## The code IS the walkthrough

Read [`src/main.rs`](./src/main.rs). The module comment carries the arithmetic
that made this experiment worth running, and every decision is explained beside
the line that makes it.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, and read the survey with the argument around it
./check.sh    # quick verdict, and it passes with or without a board attached
```

## What it prints, and why each part is there

**Every row, classified.** All 4096, collapsed into runs of like answers so the
shape fits on a screen. Three answers are possible and all three matter:
*programmed*, *blank*, and **REFUSED** — the hardware declining to hand a row
over, which is the one this road came looking for. A count of zero refusals is
a real answer, and the one that decides what the next experiment has to build.

**The identity rows.** [exp113](../exp113-enumerable-seed/) folds rows 0–3 into
a public chip identity and prints it. The same rows are printed here so the two
can be laid side by side on one board.

**The rows a signing experiment elsewhere called a key.** Prior work outside
this repository reads what it calls an ECDSA private key from rows
`0xE80`–`0xE8F`, and falls back to a compiled-in test key when they read zero.
Whether those rows hold anything is a question with an answer.

## The arithmetic that made this worth checking

That prior work addresses OTP by hand:

```rust
let row_addr = (0x4013_0000 + (0xE80 + i) * 8) as *const u32;
```

on the stated belief that a row is two bytes of payload spaced eight bytes
apart. `embassy_rp::otp` disagrees, in a comment on the constant itself:

> OTP read address, using automatic Error Correction. A 32-bit read returns the
> ECC-corrected data for **two neighbouring rows** … Only the first 8 KiB is
> populated.

So a row is **two** bytes apart, not eight, and there are 4096 of them. Take
the first at its word and `0xE80 * 8` is byte 29,696 — outside an 8 KiB window
entirely. Read as a row number, `0xE80` is 3,712 and lands comfortably inside
it.

This firmware reads it the second way, which is the way the HAL means, and
prints what is there. It deliberately does **not** try the first way: an access
outside the populated window is how you get a HardFault, and a HardFault here
takes USB with it, leaving a board that says nothing at all. A firmware that
proves its point by going silent has proved nothing a reader can tell from a
crash — [exp134](../exp134-the-log-nobody-reads/) is the record of how many
ways silence reads.

## How to see the result

**[`otp-map.html`](./otp-map.html)** — open it in Chrome or Edge, press Connect,
pick the board. One file, no build step, no server; on Android it is Files app →
*Open with Chrome*.

It claims the CDC interfaces the same way
[`tools/pages/log.html`](../../tools/pages/log.html) does and then draws what
the firmware says: 4096 rows as a grid, one cell each, coloured by what the
chip answered. The question this experiment exists to ask — *is there anywhere
on this part the core cannot read* — becomes **is any of it red**, which is a
thing you can see rather than a thing you count. The raw log is on the page too,
underneath.

A grid rather than the log viewer that already works, because the answer here is
a map of 4096 rows, and a map read as lines of text is not read at all.

This experiment has **no drive and serves no page of its own** — it declares one
CDC interface and nothing else, so a boot drive that vanishes after the copy is
the flash succeeding, not a fault. Putting the page on the board is
[exp131](../exp131-the-volume-is-the-app-drawer/)'s trick and belongs to a later
experiment on this road.

### And the LED, when you have no page at all

The LED is a fallback for telling a stuck board from a dead one, not a way to
read the result:

| LED | Means |
| --- | --- |
| **fast, 5 Hz** | running, sweep not finished |
| **slow, 1 Hz** | sweep finished — the answer is on the page |
| **dark** | the firmware is not running |

The middle state is the one worth having. Reading OTP is the only operation here
that could fault, and a fault takes USB and the page with it — but a board stuck
on fast blink says *started and did not finish*, which is a different diagnosis
from one that never started.

The summary also **repeats every ten seconds**, because
[exp113](../exp113-enumerable-seed/) already wrote down what printing once
costs: a fact printed once is a fact most readers never see, and anyone
attaching afterwards finds heartbeats and no way to tell a finished run from a
stuck one.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. `pack.sh` lifts this section verbatim into that zip, so
there is one copy of the procedure and it is this one.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A) and a USB data cable.
  * **A phone is enough.** Android with Chrome, and the board in its only port.
    A desktop with Chrome or Edge works the same way.
  * Nothing installed. No compiler, no driver, no root.
  * On Linux only: the kernel's `cdc_acm` driver claims the board's serial
    interfaces, and an interface has exactly one owner. `yi26 detach` frees
    them, and that one command does need the repository. **A phone has no such
    driver and needs no such step** — which is the shortest description of why
    the browser track exists.

1. UNPACK IT. On a phone: the Files app will do it in place.

       unzip exp154-somewhere-to-put-a-key.zip
       cd exp154-somewhere-to-put-a-key

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold the BOOTSEL button
   down, plug the board in, then let go. A drive called `RP2350` appears, and
   you copy the firmware onto it.

       cp firmware/exp154-somewhere-to-put-a-key.uf2 /media/$USER/RP2350/

   On a phone, do the copy in the Files app instead — or skip the button
   entirely if the board is already running exp105 or later: open
   `pages/bootsel.html`, then `pages/pflash.html`, and give it the `.uf2`. Do
   those two without a pause; a board left waiting in BOOTSEL may not still be
   waiting when you come back.

   **The drive vanishing as the copy finishes is success**, not an error. Some
   file managers report it as one.

3. WATCH THE LED FOR A MOMENT. It is not the result — it is how you tell a
   board that is working from one that is not, before opening anything.

       fast, about 5 Hz    running, sweep not finished
       slow, about 1 Hz    sweep finished, the answer is ready
       dark                the firmware is not running

   It should be fast for a few seconds and then slow. **If it stays fast, stop
   and say so**: that means the sweep started and did not finish, which is a
   real finding and not a mistake you made.

4. OPEN THE RESULT.

       pages/otp-map.html

   On Android: Files app, tap the file, *Open with* → Chrome. On a desktop,
   double-click it. Press **Connect**, and pick the board from the chooser
   Chrome puts up. That permission dialog is the one thing on this list nobody
   can automate for you.

   The page draws all 4096 OTP rows as a grid, one cell each:

       blue    programmed — something is in that row
       grey    blank — nothing has been written there
       RED     REFUSED — the hardware declined to hand it over

   **The whole experiment is the question "is any of it red".** A red cell is a
   place this chip already will not let the core read, which is what the
   signing road went looking for. No red is an equally real answer, and the
   page says which of the two it is reading.

   Underneath the grid: the totals, the rows a signing experiment elsewhere
   assumed held a private key, the identity rows exp113 uses, and the raw log.

5. IF THE PAGE SHOWS NOTHING. The summary repeats every ten seconds, so
   arriving late is fine — wait fifteen seconds before concluding anything. If
   it is still empty, `pages/log.html` reads the same serial stream without any
   parsing in the way, and whatever it shows is the thing to report.

WHAT THIS DOES NOT DO
  It never writes to OTP. Not once, not optionally, not behind a flag. OTP is
  one-time programmable, so a wrong write does not fail a test — it ruins the
  board for every experiment after this one. `check.sh` greps the source for
  the write functions and fails if any of them appears, because "we did not
  mean to" is not something you can check afterwards.

## Expected output

Captured on a Raspberry Pi Pico 2 (non-W), read on an Android phone through
[`otp-map.html`](./otp-map.html), 2026-08-18.

```console
[      37 ms] exp154 up. Asking the chip what it already has, and writing nothing.
[    3037 ms] sweeping 4096 OTP rows. Nothing here writes.
[    3037 ms] rows 0000-000b (  12): programmed
[    3037 ms] rows 000c-000f (   4): blank
[    3037 ms] rows 0010-0011 (   2): programmed
[    3038 ms] rows 0012-0017 (   6): blank
[    3038 ms] rows 0018-0018 (   1): programmed
[    3038 ms] rows 0019-0035 (  29): blank
[    3038 ms] rows 0036-0037 (   2): programmed
[    3039 ms]   ... reached row 0400
[    3040 ms]   ... reached row 0800
[    3041 ms]   ... reached row 0c00
[    3042 ms] rows 0038-0f7f (3912): blank
[    3042 ms] rows 0f80-0f81 (   2): programmed
[    3042 ms] rows 0f82-0f82 (   1): blank
[    3042 ms] rows 0f83-0f83 (   1): programmed
[    3042 ms] rows 0f84-0f84 (   1): blank
[   36288 ms] (+73 lines lost) heartbeat #34
[   43042 ms] survey: 23 programmed, 4073 blank, 0 refused, of 4096 rows
[   43042 ms] survey: nothing on this part is hidden from this core by OTP alone.
[   43042 ms] survey: rows 0e80+ hold no key on this part.
```

**23 programmed, 4073 blank, 0 refused.** The map is almost entirely grey with
a dozen blue cells at the top and a couple more at `0f80`, and **no red at
all**.

### The answer, and what it costs the road that asked

**Nothing on a stock part refuses to be read.** OTP here is a place to *store*
a key; it is not a place that *hides* one from the core doing the reading. Every
one of the 4096 rows handed its contents over to ordinary firmware with no
privilege of any kind.

So the boundary the [signing road](../README.md#the-signing-road) needs does not
come free with the chip, the way [exp138](../exp138-what-the-rom-already-knows/)
found the A/B machinery did. It has to be built, which is what the next
experiment goes and does — and that is a useful thing to have learned by asking
for ten seconds rather than by discovering it underneath a working signature.

**Rows `0xE80`–`0xE8F` hold nothing.** The prior work that reads an ECDSA
private key from them, and falls back to a compiled-in test key when they read
zero, would fall back on this part — every time, on every board, since 4073 of
4096 rows are blank.

### The capture is missing 73 lines, and that is the log working

`(+73 lines lost)` is `crates/log-ring` saying what it dropped rather than
quietly dropping it — [exp134](../exp134-the-log-nobody-reads/)'s subject
exactly. The board printed the identity rows and the sixteen key rows into a
ring nobody was draining yet, because the phone had not attached, and by the
time it did those lines were gone. The verdict survived only because it repeats.

That is a finding about this experiment's own design, not about the chip, and it
has been fixed the way exp134 would: **the two tables now repeat too**, one
compact line each, so a reader who attaches at any moment gets the whole answer
rather than the summary and two empty tables. What is above is the run that
found it.

## What is not verified here

- **The capture predates two lines.** It was taken before the identity and key
  rows were made to repeat, so a run of the current firmware prints two
  `survey:` lines the block above does not show. The rule here is that an aged
  capture is [recorded, not repaired](../README.md#a-capture-ages-and-where-that-is-written-down)
  — editing it to match would be inventing a run.
- **One board.** 23 programmed rows is this part's number. Which rows a factory
  programs is not something one Pico 2 can establish for every Pico 2.
- **Nothing about what a lock would look like.** `read_raw_word` reports
  `InvalidPermissions` when a raw read comes back all-ones, and no row on this
  board did — so the code path that would report a refusal has never been seen
  to run. A board with OTP locks set would be needed to exercise it, and this
  experiment cannot make one without writing, which it will not do.

## The ideas to take away

1. **Ask the part before building the missing piece.** exp138 found the RP2350's
   ROM already holds the A/B machinery everybody hand-rolls. Whether OTP holds
   anything comparable for keys is the same question, and it has the same two
   possible answers, and only one way to find out.

2. **"Refused" is an answer, not an error.** A row the hardware declines to read
   is a row already beyond this core's reach — which is the property the whole
   signing road is shopping for. Code that treats every `Err` as a failure
   throws that away.

3. **A permanent operation deserves a check, not an intention.** Nothing here
   writes OTP, and `check.sh` proves it by grepping rather than trusting the
   author. The cost of being wrong is not a failed test.

## Next

The signing road's second experiment: **a wall you can measure**. No
cryptography — a known pattern in a Secure region, the SAU programmed, and a
read from Non-Secure that has to fault for the experiment to pass. Whatever
this one finds, that is where an enforced boundary comes from.
