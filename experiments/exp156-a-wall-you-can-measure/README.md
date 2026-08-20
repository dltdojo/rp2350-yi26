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

> **This address is readable from one place and not from another, and both
> halves were watched.**

The control is not decoration. A read that faults could be a broken core; a read
that works says nothing about anybody else. **The experiment passes only when
both happen**, which is the difference between a boundary and one failed access.

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
  core 0  Secure, privileged        core 1  Non-secure (FORCE_CORE_NS)
  -----------------------------     -----------------------------------
  owns USB, prints everything
  denies I2C1 to Non-secure   --->
  reads I2C1                        reads I2C1
    -> a value                        -> BusFault -> HardFault
  reports both                      handler records it and parks
```

The peripheral is **I2C1**, chosen because nothing in this firmware uses it.
Denying Non-secure access to SRAM or XIP would take core 1's own stack and code
away before it reached the thing being tested; denying it to USB would take the
log.

## How to see the result

**[`wall.html`](./wall.html)** — Chrome or Edge, press Connect, pick the board.
On Android: Files app → *Open with* → Chrome. It shows the two reads side by
side and will only say *the wall is there* when both arrived and disagreed in
the right direction.

The LED is the fallback when no page is open: **slow** while waiting for a
verdict, **fast** once there is one. It is not the result.

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
| 4 | checking core 1's first read |
| 5 | **reading** `ACCESSCTRL.LOCK` |
| 6 | **reading** `ACCESSCTRL.I2C1` |
| 7 | writing I2C1 back **unchanged** |
| 8 | writing it with NSU/NSP cleared — the wall |
| 9 | `FORCE_CORE_NS.CORE1` |
| 10 | releasing core 1 |

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
the thing that killed the last one. So there is a **twenty-second wait between
them**: time to open the page and read `LOCK` and the power-on `I2C1` before
anything risks the log again.

Capturing what already succeeded costs twenty seconds. Losing it costs a flash
cycle, and somebody's walk to a bench.

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

## Handed over, unverified

Seven flash cycles, each costing somebody a walk to a bench, and this is
blocked on a board rather than on an idea.
**[`HANDOVER.md`](./HANDOVER.md)** is what the next person needs: what each
round established, the one finding that is solid, the state nobody has explained
yet, and the six decisions that were paid for and should not be undone.

The method those rounds produced is written up separately, because it outlived
this experiment: [`docs/debugging-without-a-board.md`](../../docs/debugging-without-a-board.md).

## Expected output

**Not captured yet — this experiment has not run on a board.**

The [rule](../README.md#nothing-is-pushed-unverified) is that this section is a
paste of a real run, never written from what the code should do. The build half
is verified: it compiles, converts to a 45,056-byte UF2, and the family ID is
`e48bff59`.

## What is not verified here

- **Everything the board does.** No run, no capture, no verdict.
- **Whether `spawn_core1` and `FORCE_CORE_NS` compose.** Core 1 is launched
  through the ROM's protocol and then expected to be Non-secure. If the launch
  itself needs Secure access to something now denied it, core 1 dies before
  reaching the read — which is why it records a step number before each move
  and why `verdict_task` reports *which* step it stopped at rather than only
  whether it faulted.
- **Whether the fault arrives as a HardFault at all.** A Non-secure access to a
  denied peripheral could surface as a BusFault escalated to HardFault, and the
  handler here catches HardFault. If a run reports no fault and no value, that
  is the first thing to look at.

## The ideas to take away

1. **A boundary is two measurements.** The half everybody publishes is the one
   that refuses. The half that makes it mean something is the one that works,
   from the other side, on the same address in the same run.

2. **Put the fault where it can be reported.** A single-core version of this
   experiment goes silent at exactly the moment it succeeds. Choosing the
   mechanism that faults on a core which is not holding the USB stack is a
   design decision worth more than the code it saved.

3. **The chip's own gate came before the architecture's.** The obvious route was
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
