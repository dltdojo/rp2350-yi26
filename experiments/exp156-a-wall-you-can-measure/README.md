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

### What the rebuild buys, whatever happens

It is a **ladder**: every step announces itself before it runs, so the last line
in the log names the thing that did not come back. Each flash needs somebody at
a bench, so one attempt should answer *which rung broke* rather than *whether it
worked*.

```text
step 1  read I2C1 from core 0, no wall yet          -> what unrestricted looks like
step 2  deny I2C1 to Non-secure in ACCESSCTRL
step 3  read it again from core 0                   -> the control: Secure is unaffected
step 4  launch core 1, still Secure                 -> where the first build hung
step 5  core 1 reads while Secure                   -> it is running and can reach the address
step 6  demote core 1, let it read again            -> the measurement
```

Core 1 now reads **twice**, and the first read is what separates *a core that
was refused* from *a core that never ran*. Those looked identical before.

**Demoting a core that is already running is now a question, not an
assumption.** If `FORCE_CORE_NS` only takes effect at launch, the second read
simply succeeds — and the log says that this build cannot tell that apart from
ACCESSCTRL failing to refuse, which is two findings in one outcome and worth
admitting rather than papering over.

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
