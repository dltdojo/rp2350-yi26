# exp156-a-wall-you-can-measure — a boundary that refuses, watched from both sides

[exp154](../exp154-somewhere-to-put-a-key/) asked this chip whether it already
had somewhere to keep a secret, and the answer was clean: **no**. Not one of
4096 OTP rows refused to be read. So the boundary the
[signing road](../README.md#the-signing-road) needs has to be built, and this
builds the smallest one that can be shown to work.

**There is no cryptography in it at all.** That is the point. Prior work outside
this repository named a function `tfm_secure_ecdsa_sign`, gave it the
secure-gateway ABI, and never programmed a security boundary anywhere — so what
it demonstrated was that a function can be *called*, while the claim on the
label was that a key cannot be *read*. This experiment does only the second
half, and does it with a value nobody would want.

## The claim, and it is deliberately small

> **This firmware made an address unreadable from a place it had just been read
> from, and every step of that was watched.**

The controls are not decoration. A read that faults could be a broken core. A
read that works from somewhere else says nothing about anybody. And a read that
faults at an address which was *already* denied says nothing about the firmware
that claims to have denied it.

So the experiment passes only when **three** reads land, taken by one core at one
address, with core 0 changing exactly one thing between each pair. It took eight
rounds to arrive at that number, and the first version to run on hardware got a
true result for a wrong reason — the story is below, in the order it happened.

## How the wall is built, and why not the way the road said

The road said *program the SAU*. The SAU is the Cortex-M33's partitioning of the
address space, and it is one of two walls on this chip. The other is
**ACCESSCTRL**, which gates requests at the far end of the bus — per peripheral,
by who is asking and in what security state — and it is the one used here.

Three reasons, because the choice is not obvious:

1. **`embassy-rp` has no SAU support at all.** Asked before planning around it,
   as the road required: not one file in the HAL mentions SAU, TrustZone or
   Non-secure. `rp-pac` models ACCESSCTRL in full.
2. **ACCESSCTRL can put a whole core into Non-secure state** —
   `FORCE_CORE_NS.CORE1` — with no hand-written `SG` veneer and no `BXNS`. The
   veneer is still coming; it belongs to the experiment with code on both sides
   of the line, not to the one measuring whether the line exists.
3. **It puts the fault on a different core from the log.** That is the problem
   the road wrote down and left open: a firmware that proves its point by
   faulting takes USB with it and says nothing. Here core 1 faults and **core 0
   is still talking**.

```text
  core 0  Secure, privileged           core 1  the core being measured
  ---------------------------------    ------------------------------------
  owns USB, prints everything
                                       read 1  Secure,     open -> a value
  opens I2C1 to Non-secure    ---->
  FORCE_CORE_NS.CORE1         ---->
                                       read 2  Non-secure, open -> a value
  shuts I2C1 to Non-secure    ---->
                                       read 3  Non-secure, SHUT -> BusFault
  reports all three                    handler records it and parks
```

**One core, one address, one thing changed at a time.** Read 1 to read 2 changes
only the security state. Read 2 to read 3 changes only the ACCESSCTRL bits.

The peripheral is **I2C1**, chosen because nothing in this firmware uses it.
Denying Non-secure access to SRAM or XIP would take core 1's own stack and code
away before it reached the thing being tested; denying it to USB would take the
log.

## How to see the result

From a checkout, with a board attached:

```sh
yi26 log --json --seconds 20      # the whole thing, from a terminal
./check.sh                        # exit 0, and it prints the verdict
```

**[`wall.html`](./wall.html)** shows the same thing to somebody with a browser
and nothing else, which is what the page is for. On **Linux** it needs two
commands run first and the order is not negotiable —
[**Do this, in order**](#do-this-in-order) below is the whole procedure, and it
is the copy that ships in the zip.

The summary repeats every ten seconds and carries every value the run
established, so arriving late costs you the narrative and none of the findings.

The LED is the fallback when no page is open: **slow** while waiting for a
verdict, **fast** once there is one. It is not the result.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, and `yi26` only on Linux. `pack.sh` lifts this section verbatim into
that zip, so there is one copy of the procedure and it is this one.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A) and a USB data cable.
  * **A phone is enough.** Android with Chrome, and the board in its only port.
    A desktop with Chrome or Edge works the same way.
  * **On Linux only, two commands and a checkout to run them from.** They are
    two different gates, they fail at different moments, and the order is
    forced. A phone needs neither, which is the shortest description of why the
    browser track exists.

        yi26 udev --install    without it, Connect fails with "Access denied"
        yi26 detach            without it, Connect fails at claiming instead

    The first writes one udev rule and asks for your password once. The board's
    device node is root-only until it exists, so Chrome fails the instant it
    *opens* the device — before any interface is involved. **`yi26 detach` will
    not fix that**, and reaching for it is the mistake `wall.html` itself used to
    recommend, in its own warning box, until a run on Chrome under Ubuntu proved
    it wrong: detaching goes through the same node and fails with the same
    permission error. The second frees the interfaces from the kernel's
    `cdc_acm` driver, which is what `/dev/ttyACM0` is, because an interface has
    exactly one owner. `yi26 attach` gives them back, and so does replugging.

1. UNPACK IT. On a phone: the Files app will do it in place.

       unzip exp156-a-wall-you-can-measure.zip
       cd exp156-a-wall-you-can-measure

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold the BOOTSEL button
   down, plug the board in, then let go. A drive called `RP2350` appears, and
   you copy the firmware onto it.

       cp firmware/exp156-a-wall-you-can-measure.uf2 /media/$USER/RP2350/

   On a phone, do the copy in the Files app instead — or skip the button
   entirely if the board is already running exp105 or later: open
   `pages/bootsel.html`, then `pages/pflash.html`, and give it the `.uf2`. Do
   those two without a pause; a board left waiting in BOOTSEL may not still be
   waiting when you come back.

   **The drive vanishing as the copy finishes is success**, not an error. Some
   file managers report it as one.

3. WATCH THE LED FOR TEN SECONDS. It is not the result, but it is how you tell
   a board that is working from one that is not before opening anything.

       slow, about 1 Hz         running, no verdict yet
       fast, about 5 Hz         there is a verdict — go and read it
       dark                     the firmware never started
       N flashes, long pause    core 0 died on rung N, and this is all that is
                                left of the instrument

   It should blink slowly for about nine seconds and then go fast. **The last
   line is the one to report if you see it**: a repeating group of flashes means
   the core holding USB took a fault, the count says which step, and no page
   will connect because there is nothing left to connect to.

4. OPEN THE RESULT.

       pages/wall.html

   On Android: Files app, tap the file, *Open with* → Chrome. On a desktop,
   double-click it. On Linux run the two commands above first. Press
   **Connect**, and pick the board from the chooser Chrome puts up. That
   permission dialog is the one thing on this list nobody can automate for you.

   The page shows one address read three times by one core, and what changed
   between them:

       1 · Secure,     wall open     expected: a value
       2 · Non-secure, wall open     expected: the same value
       3 · Non-secure, wall shut     expected: FAULTED

   **All three panels have to fill in.** The first two are the controls and they
   are not decoration — a refusal on its own is one failed access, and a
   refusal at an address that was already denied says nothing about the firmware
   claiming to have denied it. Read 1 to read 2 changes only the security state.
   Read 2 to read 3 changes only the ACCESSCTRL bits. That is why the third one
   means anything.

   The verdict underneath is only allowed to say *the wall is there* when both
   controls arrived and the third read was refused.

5. IF THE PAGE SHOWS NOTHING. The summary repeats every ten seconds and carries
   every value the run produced, so arriving late is fine — wait fifteen seconds
   before concluding anything. If it is still empty, `pages/log.html` reads the
   same serial stream with no parsing in the way, and whatever it shows is the
   thing to report.

   A `(+N lines lost)` marker is not a fault. It means nobody was draining the
   log for a while — a backgrounded browser tab does it — and the firmware is
   telling you rather than pretending. Nothing is lost that matters: every
   finding is in the block that repeats.

WHAT THIS DOES NOT DO
  It never writes `ACCESSCTRL.LOCK`. That register makes a configuration
  survive until reset with no way for software to undo it, so a board left in a
  state you did not want is one power cycle from ordinary again. `check.sh`
  greps the source for that write rather than asking you to believe this
  paragraph.

  It writes no OTP and burns no fuse, and there is no cryptography in it at
  all. The address it protects is I2C1's hardware ID register, which is not a
  secret and is not worth protecting — that is the point. What is being shown
  is that an address can be made unreachable, not that a key kept there would
  be safe.

## What this does not do

**It never locks anything.** `ACCESSCTRL.LOCK` makes a configuration survive
until reset and cannot be undone by software; this never writes it, so a board
in a state you did not want is one power cycle from ordinary. `check.sh` greps
for that call rather than trusting this paragraph.

**It writes no OTP, and burns no fuse.** Nothing on this road does, yet.

## The first build went silent, and why

Flashed on 2026-08-20: no LED, no USB device to choose in the browser. Not one
byte of evidence — which is the outcome this repository spends the most effort
making impossible, and it was designed in.

Two causes, both found by reading rather than by another flash cycle:

**`spawn_core1` blocks.** It is not fire-and-forget. It hands core 1 a launch
sequence over the FIFO and waits on `fifo_read()` for each reply, with a
`fails > 16` escape that fires only on a *wrong* answer and never on silence. A
core 1 that cannot execute its own launch — because it has just been made
Non-secure, and the ROM, stack and FIFO it needs are not open to Non-secure —
never answers, so core 0 waits forever.

**And it was waiting before USB existed.** The first build did the ACCESSCTRL
write and `spawn_core1` in `main()`, three lines above `Driver::new`. So the
board hung at the one moment it had no way to say so.

Both are now structural rather than remembered. Everything risky lives in
`verdict_task`, which cannot start until the USB stack is up, and `check.sh`
greps `main()` and fails if any of it moves back — a guard that was checked by
moving one call back and watching it fire.

### And then it blinked three times and stopped

Second flash, 2026-08-20: the LED blinks about three times and goes dark, and
nothing enumerates. Three blinks is three seconds, and three seconds is the
`Timer::after` at the top of `verdict_task` — so the firmware boots fine and
dies on the ladder's **first rung**.

That rung reads I2C1 from core 0. **Peripherals on this chip come up held in
reset, and reading a register of one still in reset is a bus fault.** I2C1 was
chosen precisely because nothing here uses it, which is exactly the kind of
peripheral nobody remembers to un-reset.

And the fault landed on **core 0**, the core holding USB — so the log died with
it and the board looked like a firmware that never started. This experiment's
own README argued for putting the fault on a core that is not doing the
talking, and then core 0 was handed a read that could fault.

Both are fixed and both are guarded. `bring_i2c1_out_of_reset()` waits for
`RESET_DONE`, and `check.sh` fails if that wait disappears. And **core 0 never
touches the address again after the wall goes up**: the control is now core 1's
own first read, taken while it is still Secure — the same core and the same
address with only its security state changed between the two, which is a better
control than core 0 reading twice ever was. If the ACCESSCTRL bits are wrong —
and they come from a PAC whose documentation is shifted by one field — the read
that pays for it is not the one holding USB.

### Four blinks: the step that does three things at once

Third flash, 2026-08-20: **four blinks, then dark.** One more than last time,
which is one more second, which is the ladder getting one rung further — and
then stopping in step 5.

Step 5 did three things: write ACCESSCTRL, set `FORCE_CORE_NS.CORE1`, release
core 1 to read. All three inside a millisecond, so *four blinks* names all three
equally. The executor here is single-threaded, so a fault on core 0 stops the
heartbeat as well as the log, and the log is what died first.

**Three things inside one millisecond are three things the only working
instrument cannot tell apart.** So they are now two seconds apart, and the
blink count says which:

```text
~4 blinks then dark    the ACCESSCTRL write itself
~6 blinks then dark    demoting core 1
~8 blinks then dark    core 1's Non-secure read taking the system with it
keeps blinking         nothing killed core 0 — read the log for the verdict
```

That is a readout with no log, no page, no host and no toolchain, and it is the
third time this experiment has been debugged entirely through it.

**Splitting a step that already failed beats guessing which third of it failed.**
Each attempt costs somebody a walk to a bench, so the question a build asks
should be the narrowest one that still separates the candidates.

What is *not* known, and is worth saying before the next run: whether demoting a
core that is already executing from XIP can work at all. Once core 1 is
Non-secure, every instruction fetch it makes is a Non-secure access — including
the fetch of its own fault handler. If XIP is not open to Non-secure, core 1
cannot execute anything, which is a different outcome from being refused one
address, and only the ~6-versus-~8 distinction above can tell them apart.

### Dark and dead were the same signal, and now they are not

Three rounds were spent on a board that "stopped blinking", which could mean
the firmware never started or that it started and died. **The LED could not
tell those apart**, and every diagnosis had to work around that.

Embassy's executor drives every task **from a single stack** on one core — the
top-level README says so, and it is the reason the framework fits a
microcontroller at all: no per-task stacks, no preemption, concurrency known at
compile time. The consequence is the part that bit: a fault or a blocking call
in any task takes every other task on that core with it, including the
heartbeat that was the only instrument.

So the `HardFault` handler now drives the LED itself — bit-banged through SIO,
with no HAL, no executor and no interrupts, because those are exactly what is
no longer trustworthy at that point. **Two quick flashes and a long gap**, a
rate nothing else in this firmware produces.

| LED | Means |
| --- | --- |
| dark | the firmware never started |
| slow, 1 Hz | running, no verdict yet — the blink count says which rung |
| fast, 5 Hz | there is a verdict; read it on the page |
| **N flashes, long pause, repeat** | **core 0 faulted on rung N** — the executor is gone, this handler is all that is left |

A fixed pattern told us *that* core 0 died. It did not say *where*, so the
answer still had to come from somebody watching a clock. So the handler blinks
the rung instead, from a counter written **before** each step and never after —
the number it flashes is the step that did not come back:

| Flashes | Died in |
| --- | --- |
| 1 | taking I2C1 out of reset |
| 2 | core 0's baseline read |
| 3 | `spawn_core1` |
| 4 | checking core 1's Secure read |
| 5 | **reading** `ACCESSCTRL.LOCK` |
| 6 | **reading** `ACCESSCTRL.I2C1` |
| 7 | writing I2C1 back **unchanged** |
| 8 | **opening** the wall — NSU/NSP set |
| 9 | `FORCE_CORE_NS.CORE1` |
| 10 | releasing core 1 for read two |
| 11 | **shutting** the wall — NSU/NSP cleared |
| 12 | releasing core 1 for read three |

(Rungs 8 to 12 are the eighth round's shape; before it, rung 8 was the only
write and there was no read two. The table is what the handler blinks today.)

**A pattern that means "died" is worth much less than one that means "died
here".** The first version of this handler was the former, and it cost a round
to find that out.

The handler checks `SIO.CPUID` first: core 1 faulting is what this experiment is
*trying* to cause and core 0 is still there to report it, so core 1 parks
quietly. Only core 0's death needs announcing, because only core 0's death is
otherwise silent.

### Five flashes: the ACCESSCTRL write

Fourth flash, 2026-08-20: **five flashes, long pause, repeating.** Rung 5 — the
`ACCESSCTRL` write. Core 0 faults writing a register whose own documentation
says it is "writable only from a Secure, Privileged processor", which is exactly
what core 0 is.

That is surprising enough to be worth not guessing at. `rp-pac` models no
password for this block, the offsets are ordinary (LOCK at `0x00`, I2C1 at
`0x88`), and nothing in RESETS gates it.

So rung 5 becomes four rungs, and the first two **only read**:

```text
5   read ACCESSCTRL.LOCK          is this block readable at all?
6   read ACCESSCTRL.I2C1          and its power-on value
7   write I2C1 back unchanged     does ANY write fault?
8   write it with NSU/NSP cleared does THIS write fault?
```

One flash cycle separates *cannot reach the block*, *cannot write it*, and
*cannot write this value*.

**The reads earn their place twice over.** The register's documentation says it
"Defaults to Secure access from any master", so its power-on value is a fact
this experiment can print — and printing it settles, from silicon rather than
prose, which reading of the field layout is correct. `rp-pac`'s doc comments
here are shifted by one field: `su` carries NSP's sentence, `core1` carries
CORE0's. Either the names are right and the docs are misattached, or the docs
are right and the fields are misnamed. **A default value tells them apart**, and
until now this experiment has been writing bits it could not confirm the meaning
of.

### Seven flashes: reads work, and every write is refused

Fifth flash, 2026-08-20. Rungs five and six — reading `ACCESSCTRL.LOCK` and
reading `ACCESSCTRL.I2C1` — **passed**. Rung seven, writing that same value
straight back, **faulted**.

That is a clean split and it is a real finding:

> **The block is reachable. Reads work. Writes are refused, whatever the value.**

Not the wall bits, not this particular value — *any* write. A register whose own
documentation says it is "writable only from a Secure, Privileged processor",
refusing a Secure, Privileged processor writing back exactly what it just read.

The ordinary reason a peripheral behaves that way is a **write key** in the top
half of the word, and `rp-pac` models none — `Access` is a `u32` with fields
only in bits 0..7, so `modify()` reads a register whose top half is zero and
writes zero back there. That is exactly the write that gets refused.

So the next run tries `0xACCE` in bits 31:16, through a helper every ACCESSCTRL
write must go through, because `modify()` is a read-modify-write and would drop
the key every time. `check.sh` fails if a bare `write`/`modify` appears beside
it.

**This is a hypothesis, and it is stated as one.** If it is wrong, rung seven
faults again and one candidate is eliminated with certainty — which is worth a
flash cycle either way, and is a much better position than the four rounds
before it, where the board could only say that something, somewhere, had gone.

### Twenty seconds to read what already worked

Rungs five and six produce the two values this run was for, and rung seven is
the thing that killed the last one. So there was a **twenty-second wait between
them**: time to open the page and read `LOCK` and the power-on `I2C1` before
anything risks the log again.

Capturing what already succeeded costs twenty seconds. Losing it costs a flash
cycle, and somebody's walk to a bench.

**The wait is gone now**, and what replaced it is better than either. A board on
the machine makes `yi26 log` instant, so nobody has to be given time to open a
page — and the values are reprinted in the block that repeats every ten seconds,
so they cannot be missed by arriving late. A pause that protects a finding is a
worse instrument than a finding that repeats.

### What the rebuild buys, whatever happens

It is a **ladder**: every step announces itself before it runs, so the last line
in the log names the thing that did not come back. Each flash needs somebody at
a bench, so one attempt should answer *which rung broke* rather than *whether it
worked*.

```text
step 1  take I2C1 out of reset                     -> what the second build died on
step 2  read it from core 0, no wall yet            -> what unrestricted looks like
step 3  launch core 1, still Secure                 -> what the first build hung on
step 4  core 1 reads while Secure                   -> the control, on the core being tested
step 5  deny to Non-secure, demote core 1, read     -> the measurement
        core 0 never touches that address again
```

Core 1 now reads **twice**, and the first read is what separates *a core that
was refused* from *a core that never ran*. Those looked identical before.

**Demoting a core that is already running is now a question, not an
assumption.** If `FORCE_CORE_NS` only takes effect at launch, the second read
simply succeeds — and the log says that this build cannot tell that apart from
ACCESSCTRL failing to refuse, which is two findings in one outcome and worth
admitting rather than papering over.

That was the last build written without a board, and it is the one that ran.
Two reads were not enough, for a reason nothing above had spotted — everything
from here is what the bench said.

### Eighth round: a board on the same machine, and the key was real

2026-08-20, and this is the round where the economics changed. The board is
attached to the machine doing the work, so an observation costs a second instead
of somebody's walk to a bench. The first thing that bought was not a fix — it
was **reading the log that six rounds had been unable to read**.

`0xACCE` in bits 31:16 is the key. Step seven — the identity write that faulted
in round six — is accepted, and the register reads back what was written. The
hypothesis held, and the mechanism it implies is exactly what `rp-pac`'s own
prose for `LOCK` says about this block: writes it will not accept **raise a bus
error** rather than being quietly dropped. That is why a missing key looked like
a broken register instead of a no-op, and it is the whole of rounds five and six.

Everything the earlier rounds had produced and nobody had read:

```text
ACCESSCTRL.LOCK          0x00000004   bit 2, DMA — the bootrom set it, not us
ACCESSCTRL.I2C1          0x000000fc   nsu=0 nsp=0 su=1 sp=1 core0=1 core1=1 dma=1 dbg=1
I2C1 hardware ID         0x44570140   what an unrestricted read returns
```

`0x000000fc` settles the question this experiment had been working around since
it was written. `rp-pac`'s doc comments for `Access` are shifted by one field —
`su` carries NSP's sentence, `core1` carries CORE0's — so either the names were
wrong or the prose was. The register documents its default as *"Secure access
from any master"*, and `nsu=0 nsp=0 su=1 sp=1 core0=1 core1=1 dma=1 dbg=1` is
that default exactly. **The names and bit positions are right; the doc comments
are misattached.** Every bit this experiment had written before that was written
without knowing which.

### And the wall was already there

`0x000000fc` has NSU and NSP **clear**. The write this experiment called "the
wall" was `before & !0b11` — and the firmware said so itself, in the line it had
been carrying for two rounds against exactly this possibility:

```text
step 5d ok: I2C1 access is now 0x000000fc (was 0x000000fc).
  it did not change. The write was accepted and ignored, which is not a wall.
```

Then core 1 was demoted, read the address, and took a bus fault — and the build
printed **VERDICT: the wall is there**.

It was not wrong about the fault. It was wrong about whose wall it was. I2C1
denies Non-secure access at power-on, before this firmware runs at all; the
refusal would have happened had the experiment never been written. What the run
demonstrated was that the *bootrom's* configuration works.

> **A boundary you did not build is not a boundary you measured.** This is the
> defect the whole signing road was filed against, arriving from a direction
> nobody was watching. The prior work this experiment exists to correct claimed
> a key was protected by pointing at a function it had never gated. This build
> claimed a wall by pointing at one it had never raised.

And there was a second flaw underneath, which the first would have hidden
forever: reads 1 and 3 differ in **two** things at once — the security state and
(nominally) the ACCESSCTRL bits. So *ACCESSCTRL refused the read* and *a core
demoted while it was running cannot execute at all* produce the identical
outcome. That is [open question 4 of the handover](./HANDOVER.md), and the build
that was supposed to answer it could not.

### The fix is a third read, and it goes in the middle

One core, one address, three reads, and core 0 changes exactly one thing between
each pair:

| | state | wall | expected |
| --- | --- | --- | --- |
| read 1 | Secure | open | works — is this core alive at all? |
| read 2 | **Non-secure** | open | works — can a demoted core still read? |
| read 3 | Non-secure | **shut** | faults — and only ACCESSCTRL changed |

Read 2 is the one that was missing, and it does two jobs. It makes the firmware
**open** the wall before shutting it, so the value that refuses read 3 is one
this experiment wrote. And it answers the demotion question directly: a core
demoted by `FORCE_CORE_NS` while it is already running **still executes and
still reads** — `0x44570140`, the same value it read while Secure.

Read 3 is last because a faulted core 1 parks in the handler forever, so
anything after it would never happen.

That is the whole result:

```text
  read 1  Secure,     wall open: 0x44570140
  read 2  Non-secure, wall open: 0x44570140
  read 3  Non-secure, wall shut: bus fault at pc 0x1000088a
```

### The instrument ate the finding

The first successful run lost three lines, silently, and they were the three the
run existed to produce: the power-on value of `ACCESSCTRL.I2C1` and its bit
breakdown. They came back only when the log was read from the moment of boot.

`usb-log`'s outgoing queue is **sixteen lines deep**, it drops the newest when
full, and **nothing drains it until a host asserts DTR**. This firmware logged a
heartbeat every second and announced twelve ladder steps in six, so the queue
was full before anybody could open the port. Six rounds of building an
instrument that could survive a dead core, and it was defeated by a reader who
arrived eight seconds late.

Two fixes, and the second is the general one:

- the heartbeat logs every tenth beat, not every beat;
- **every finding is in the block that repeats.** `LOCK`, the power-on value,
  the opened and shut values, and all three reads are reprinted every ten
  seconds. Only the narrative is allowed to scroll away.

AGENTS.md already lists *the fact printed once that nobody sees* among the
mistakes this repository has paid for. It was paid for again here, by the
experiment whose entire subject is being able to see what a board did.

### The page had never been run against a board

`wall.html` looked for `core 0 (Secure) read` and `core 1 (Non-secure) faulted
at pc`. **No build of this firmware has ever printed either string.** Every one
of the page's patterns was written from what the log was expected to say, and
the page would have sat on *waiting* forever — indistinguishable, on a phone,
from a board that never spoke.

It now matches a real capture, and the patterns are checked against one rather
than against the source they were written from.

## The eight rounds, and what each one cost

**[`HANDOVER.md`](./HANDOVER.md)** is the record: what each round established,
which open questions the eighth round closed, and the decisions that were paid
for and should not be undone.

Seven of those rounds happened with no board on the machine, and the method they
produced is written up separately because it outlived this experiment:
[`docs/debugging-without-a-board.md`](../../docs/debugging-without-a-board.md).
The eighth had a board attached and took under an hour. That gap is the
argument for the document.

## Expected output

Pasted from a real run, `yi26 log --seconds 24` opened as the board came back
from a reflash. Pico 2, Ubuntu, 2026-08-20.

```console
$ yi26 log --seconds 24
[      37 ms] exp156 up. No cryptography here, only whether an address refuses.
[    3037 ms] step 1: taking I2C1 out of reset. One still in reset faults when read.
[    3037 ms] step 1 ok.
[    3037 ms] step 2: reading I2C1 from core 0, while no wall exists yet.
[    3037 ms] step 2 ok: 0x44570140. What an unrestricted read looks like.
[    3037 ms] step 3: launching core 1, still Secure.
[    3037 ms] step 3 ok: spawn_core1 returned; core 1 answered its handshake.
[    4037 ms] step 4 ok: core 1 read 0x44570140 while Secure. Same core, no wall yet.
[    4037 ms] step 5: reading accessctrl.LOCK — is this block readable at all?
[    4537 ms] step 5 ok: LOCK = 0x00000004. Bit 2 is DMA, set by the bootrom.
[    4537 ms] step 6: reading accessctrl.I2C1 — its power-on value.
[    5037 ms] step 6 ok: I2C1 access = 0x000000fc at power-on.
[    5037 ms]   bits: nsu=0 nsp=0 su=1 sp=1 core0=1 core1=1 dma=1 dbg=1
[    5037 ms]   Non-secure is ALREADY denied. We must OPEN the wall to prove we shut it.
[    5037 ms] step 7: identity write, with 0xacce0000 in the top half.
[    5537 ms] step 7 ok: a keyed write is accepted. Without the key it faulted.
[    5538 ms] step 8: OPENING the wall - setting NSU and NSP, so Non-secure may read.
[    6038 ms] step 8 ok: I2C1 access = 0x000000ff (was 0x000000fc).
[    6038 ms] step 9: FORCE_CORE_NS.CORE1 - demoting a core that is already running.
[    6538 ms] step 9 ok.
[    6538 ms] step 10: read two - Non-secure, wall OPEN. This one must work.
[    7538 ms] step 10 ok: read two = 0x44570140. A demoted core still executes and reads.
[    7538 ms] step 11: SHUTTING the wall - clearing NSU and NSP. Nothing else changes.
[    8038 ms] step 11 ok: I2C1 access = 0x000000fc (was 0x000000ff).
[    8038 ms] step 12: read three - Non-secure, wall SHUT. This one must fault.
[    9538 ms]   LOCK = 0x00000004, I2C1 at power-on = 0x000000fc
[    9538 ms]   I2C1 opened to 0x000000ff, then shut to 0x000000fc
[    9538 ms]   read 1  Secure,     wall open: 0x44570140
[    9538 ms]   read 2  Non-secure, wall open: 0x44570140
[    9538 ms]   read 3  Non-secure, wall shut: bus fault at pc 0x1000088a
[    9538 ms] VERDICT: the wall is there. Only ACCESSCTRL changed between reads 2 and 3.
[   19538 ms]   LOCK = 0x00000004, I2C1 at power-on = 0x000000fc
[   19538 ms]   I2C1 opened to 0x000000ff, then shut to 0x000000fc
[   19538 ms]   read 1  Secure,     wall open: 0x44570140
[   19538 ms]   read 2  Non-secure, wall open: 0x44570140
[   19538 ms]   read 3  Non-secure, wall shut: bus fault at pc 0x1000088a
[   19538 ms] VERDICT: the wall is there. Only ACCESSCTRL changed between reads 2 and 3.
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (152420 byte ELF)
PASS  converts to UF2 (52736 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the target address comes from the PAC
PASS  the target peripheral is taken out of reset before it is read
PASS  every ACCESSCTRL write goes through the keyed helper
PASS  nothing that can hang runs before USB
PASS  board enumerated as 1209:0001
PASS  control 1 ran —  Secure,     wall open: 0x44570140
PASS  control 2 ran —  Non-secure, wall open: 0x44570140
PASS  both controls read the same value (0x44570140)
PASS  a verdict was reached
      VERDICT: the wall is there. Only ACCESSCTRL changed between reads 2 and 3.
```

## What is verified, and what is not

Verified on one Pico 2, on Ubuntu, and nowhere else:

- **`ACCESSCTRL` writes need `0xACCE` in bits 31:16.** Without it a write faults;
  with it the same write is accepted and reads back.
- **`ACCESSCTRL.I2C1` is `0x000000fc` at power-on**, and `LOCK` is `0x00000004`.
  The PAC's field names and positions are right; its doc comments are shifted.
- **A core demoted by `FORCE_CORE_NS` while it is already running keeps
  running**, and reads what it is permitted to read.
- **Clearing NSU and NSP makes that same read fault**, with nothing else in the
  system changed.

Not verified, and worth saying:

- **Whether the fault is a BusFault escalated to HardFault, or something else.**
  The handler catches HardFault and the fault arrives there, which is all this
  build knows. It has never read `CFSR` to find out what kind it was.
- **That the wall holds against anything but a read.** Nothing here tries a
  write from Non-secure, a DMA transfer, or the debugger.
- **That any of this survives `LOCK`.** This experiment deliberately never
  writes it, so every configuration here is one power cycle from ordinary.
- **Anything about a key.** There is still no cryptography in this experiment,
  and I2C1's hardware ID register is not a secret. What has been shown is that
  an address can be made unreachable from one core, not that a key kept behind
  it would be safe.

## The ideas to take away

1. **A boundary is three measurements, not two.** Two is the version everybody
   publishes: it works here, it refuses there. But those two differ in more than
   one thing, and the reader cannot see which one did it. The third measurement
   is the one that changes *only the thing under test* — here, the same core in
   the same security state reading the same address with only the ACCESSCTRL
   bits different between them.

2. **A boundary you did not build is not a boundary you measured.** This
   experiment denied Non-secure access to a peripheral that already denied it,
   watched a Non-secure read fault, and reported a wall. Everything it printed
   was true. The conclusion was still somebody else's. **Open it before you shut
   it** — a control that costs one register write is the difference between
   measuring a mechanism and photographing a default.

3. **Put the fault where it can be reported.** A single-core version of this
   experiment goes silent at exactly the moment it succeeds. Choosing the
   mechanism that faults on a core which is not holding the USB stack is a
   design decision worth more than the code it saved.

4. **The chip's own gate came before the architecture's.** The obvious route was
   the SAU, because that is what TrustZone articles describe. Asking what this
   part actually offers found ACCESSCTRL, which is more specific, already
   modelled by the PAC, and answers the question with less hand-written
   assembly — the same shape of answer [exp138](../exp138-what-the-rom-already-knows/)
   got about A/B updates.

## Next

The signing road's third experiment: ECDSA P-256 behind this wall. A hash goes
in from the Non-secure side, 64 bytes come back, and something else checks them
— with the key sitting where this experiment measured that Non-secure code
cannot reach.
