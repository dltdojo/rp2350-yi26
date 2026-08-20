# The board is the loop

[`debugging-without-a-board.md`](./debugging-without-a-board.md) is what seven
rounds of exp156 taught about surviving the slow loop. This document asks the
next question, which is the one that matters for cloud development:

> **Why was it seven rounds and not two?**

The answer is not "the bug was hard". exp156's bug was one missing 16-bit
constant, and the finding that mattered — that the wall was already there — was
visible in the firmware's own output the first time it ran. Seven rounds went
somewhere else, and where they went is measurable.

**Nothing in the "what to build" section below has been verified.** It is a
design derived from evidence, and it says so where it stops being evidence.

---

## The arithmetic, from exp156's own record

Each round cost somebody a walk to a bench: flash a `.uf2`, hold BOOTSEL, plug,
watch an LED, report what they saw. Seven of them, and this is what each bought:

| # | What it cost a trip for | Category |
| --- | --- | --- |
| 1 | discovering `spawn_core1` blocks, and that it ran before USB existed | **scaffolding** |
| 2 | discovering a peripheral in reset faults when read | **scaffolding** |
| 3 | discovering that step 5 was three operations and the LED could not say which | **instrument** |
| 4 | discovering that "died" and "died *here*" are different signals | **instrument** |
| 5 | it is the `ACCESSCTRL` write | fact |
| 6 | reads work, **every** write faults | fact |
| 7 | nothing — the observation was ambiguous and was not recorded | **lost** |

**Two rounds out of seven produced a fact about the subject.** Two were spent
making the experiment run at all, two were spent making the instrument able to
say *where*, and one was lost. Round 8, with a board on the developer's machine,
produced more than all seven combined in under an hour.

That ratio is the thing to attack. It is not about being cleverer per round.

---

## Three bottlenecks, and only one of them is the LED

The existing document's Rule 2 says *the LED is the only channel, so design it
before you need it*. That was paid for and it is right. But it accepts a
premise that is worth challenging, because the premise is what costs the rounds:

**The LED is only the only channel because a fatal fault destroys every other
one.** That is a property of how the firmware was written, not a law of the
chip.

Separate the three things that actually went wrong:

1. **A dead run reports nothing.** Whatever the firmware knew at the moment it
   died — a register value it had already read, a step it had already passed —
   died with it. The LED could carry a number a human could count, and nothing
   else.
2. **One flash tests one hypothesis.** Rounds 5, 6 and 7 each proposed a single
   guess about `ACCESSCTRL` writes and spent a human trip on it. Three trips,
   three bits.
3. **A human is in the measurement path.** Round 7's report was "it kept
   blinking, and the page would not connect". Slow or fast? Nobody recorded it,
   and it changes the diagnosis completely. The observation was destroyed at the
   moment it was made.

Each has a fix, and none of the fixes is "try harder".

---

## Lever 1 — make the trace survive the death

A fault or a hang should not be the end of the report. It should be the
*beginning* of the next boot's report.

The RP2350 has the parts already, and this repository has verified half of them:

- **`WATCHDOG.REASON.TIMER` says the last reset was a watchdog timeout**, and it
  is readable at boot before anything else runs.
  [exp143](../experiments/exp143-the-image-that-is-never-bought/) does exactly
  that, by hand, because `embassy-rp` keeps its watchdog PAC private and its own
  driver only starts and feeds one.
- **`WATCHDOG.SCRATCH0`–`SCRATCH7` survive a watchdog reset.** That is not a
  trick; it is the documented mechanism the bootrom itself uses, and it is how
  `reset_usb_boot()` tells the ROM to come up in BOOTSEL.
- `rp-pac` models all eight (`WATCHDOG.scratch0()` … `scratch7()`).

**`SCRATCH4`–`SCRATCH7` belong to the bootrom.** It reads magic values there to
decide the boot outcome, so a breadcrumb must live in `SCRATCH0`–`SCRATCH3`.
That is four words — sixteen bytes — which is enough for a step number, an
attempt counter and two measured values.

The shape:

```text
boot
  read SCRATCH0..3 and WATCHDOG.REASON      <- what the previous run got to
  LED up, then USB up                        <- still nothing risky
  PRINT THE PREVIOUS RUN'S TRACE             <- the report that survived
  arm the watchdog
  for each step:
      write step id (+ any value) to SCRATCH
      feed the watchdog
      run the step                           <- fault OR hang -> reboot
  disarm, and just report from here on
```

**This covers hangs, and the LED protocol does not.** Round 1 was a hang —
`spawn_core1` waiting forever on a core that could not answer — and no fault
handler fires for that. The board simply stopped, and the only signal was
darkness. A watchdog catches it and the breadcrumb names it.

Cost: the board reboots, so USB re-enumerates and any page has to reconnect. The
step numbers must be written *before* each step and never after, which exp156
already does for its LED rungs.

---

## Lever 2 — let the board run the matrix

Once a death is survivable and recorded, the next step follows: **the firmware
skips what killed it and tries the next candidate.**

Rounds 5, 6 and 7 asked three questions in sequence: *is it the write? is it any
write, or this value? is the key `0xACCE`?* Each cost a trip. A firmware that
reboots past its own failures asks all three in one flash:

```text
boot 1   identity write, no key      -> died   (breadcrumb: step 7, attempt 1)
boot 2   skip it; write with 0xACCE  -> lived  (breadcrumb: step 7, attempt 2, OK)
boot 3   continue the ladder
boot 4   nothing left to try; report everything
```

The human flashes once, waits, and reads one page. **Three rounds become one,
and the loop that used to contain a person now contains only the board.**

Two safety properties are not optional:

- **An attempt counter, and a hard stop.** After N attempts the firmware must
  stop arming the watchdog and do nothing but report. A harness that can put a
  board into a reboot loop it cannot be talked out of is worse than the slow
  loop it replaces — the 1200-baud reflash touch needs the device to stay
  enumerated long enough to hear it.
- **Report before risk, always.** The trace is printed while nothing dangerous
  has run yet, so it gets out even if this boot dies exactly like the last one.

---

## Lever 3 — ask for an artifact, never for a description

Round 7 is the cheapest round to have prevented, and it was lost to a sentence.

*"It kept blinking and the page would not connect"* is not data. Slow means no
verdict; fast means there is one. The person at the bench did nothing wrong —
they were asked for an impression, and an impression is what came back.

- **The last step of every walkthrough should produce a file, not a sentence.**
  `wall.html` and `log.html` both have a *Copy the log* button. The instruction
  is "press it and paste the result back", and it should be the step, not a
  suggestion.
- **The firmware should print one self-describing block that repeats**, carrying
  every value the run established, so any capture taken at any moment is a
  complete report. exp156 does this now; it did not when it mattered.
- **A returned capture must be replayable.** If the log is the deliverable, then
  a developer with no board can run every assertion against it. See lever 4.

The general rule: **the person at the bench should be a pair of hands and a
clipboard, never an instrument.** Every question of the form "what did it look
like" is a round you may have to spend again.

---

## Lever 4 — test everything that does not need a board, before spending a trip

Two of exp156's costs were pure waste in this sense.

**The `0xACCE` key was in OpenOCD.** Three rounds circled a register whose write
password is a named constant in a mature open-source implementation of this
silicon. This repository's existing rule is *search prior work*, and it is
scoped to this repository and the developer's own earlier projects. It needs
one more clause:

> **Before writing to any peripheral register you have not written before, read
> what an existing implementation of the same chip does with it** — pico-sdk,
> OpenOCD, embassy, the datasheet. A register that needs a key, a password, an
> unlock sequence or a specific reset order will say so there, and finding out
> from a bus fault costs a human trip per guess.

**`wall.html` had never been run against a board**, and every one of its
patterns was wrong — it looked for a string no build had printed. In cloud mode
that is a guaranteed wasted round: the board would have worked perfectly and the
page would have sat on *waiting*.

The fix costs nothing and needs no hardware:

> **Check a recorded capture into the experiment, and have `check.sh` replay it
> through whatever parses board output.** The page's own regexes, the verdict
> logic, the check's greps — all of it runs headless against a text file. A
> parser that has never seen real output is an unverified claim in a file that
> looks like a tool.

---

## What is verified here, and what is not

Verified on hardware, in this repository:

- Everything in [exp156's README](../experiments/exp156-a-wall-you-can-measure/README.md),
  including the round-by-round record this document does arithmetic on.
- [exp143](../experiments/exp143-the-image-that-is-never-bought/) reads
  `WATCHDOG.CTRL`, `LOAD` and `REASON` by hand at boot, before
  `embassy_rp::init`, and reports whether the last reset was a timeout.

Documented, and **not measured by this repository**:

- That `SCRATCH0`–`SCRATCH7` survive a watchdog reset, and that the bootrom
  claims `SCRATCH4`–`SCRATCH7`.

Not verified at all — this is a design, and it is the whole of levers 1 and 2:

- That a breadcrumb in `SCRATCH0`–`SCRATCH3` survives a watchdog reboot *on this
  part, from this firmware*, with `embassy-rp` and the bootrom in the picture.
- That a HardFault handler can arm-and-wait reliably enough to reboot rather
  than park.
- That a board rebooting every few seconds re-enumerates cleanly enough for a
  page to follow it, or for the 1200-baud reflash touch to still land.
- That the whole thing survives contact with a phone, which is the host this
  track exists for.

**None of it may be relied on until an experiment measures it.** Writing a
harness for board-less development and then trusting it without a board would be
the same defect the signing road was filed against: a mechanism whose label
claims more than anyone has watched it do.

---

## What to do about it, and when

Build it **now, while a board is on the desk.**

That is the whole recommendation, and it is not a scheduling preference. Every
lever above is instrumentation, and instrumentation is exactly the thing exp156
proved you cannot develop through the slow loop: rounds 3 and 4 were spent
improving an instrument, one notch per human trip, and they bought no facts at
all. A harness built in cloud mode would cost the rounds it exists to save.

The order that follows from the arithmetic:

1. **Lever 4 first.** It needs no hardware, no new firmware and no experiment —
   a recorded capture and a replay in `check.sh`. It removes a whole class of
   wasted round immediately, and exp156 has the capture already.
2. **Lever 3 next.** It is a change to walkthroughs and to what gets asked for.
   Also free.
3. **Levers 1 and 2 as one experiment, with a board attached.** The claim to
   measure is narrow and testable: *a firmware can record where it died, be
   rebooted by the watchdog, and report it after coming back* — and then,
   *it can skip what killed it and go on to the next candidate*. That is a
   two-measurement claim of exactly the shape exp156 ended up with, and it
   should be built the same way: the control is the boot that survives, not
   only the boot that dies.

## The checklist, for a firmware meant to be debugged from a cloud session

- [ ] **The previous run's trace is printed before anything risky runs.**
- [ ] **Progress is recorded before each step, never after**, so the number that
      survives names the step that did not come back.
- [ ] **A hang is covered, not only a fault.** The first thing that went wrong
      in exp156 was a hang, and no fault handler fires for one.
- [ ] **There is an attempt counter and a hard stop**, so the board can always
      be reflashed.
- [ ] **One repeating block carries every finding**, so any capture is complete
      and arriving late costs nothing.
- [ ] **Every log line fits the transport.** `usb-log` truncates at 96 bytes and
      drops the newest line when its 16-deep queue fills; exp156 lost its
      headline finding to the first and three findings to the second.
- [ ] **Every parser has been replayed against a recorded capture.**
- [ ] **The walkthrough's last step produces a file**, not an impression.
- [ ] **Any register being written for the first time has been looked up in
      someone else's implementation** of the same silicon.
- [ ] **The LED still works, as the fallback it should have been all along.**
