# Debugging without a board

[`debugging-on-a-phone.md`](./debugging-on-a-phone.md) is about verifying a
browser experiment on hardware you cannot see. This is about the layer under it:
**developing firmware from a machine with no board attached at all**, with a
person at the other end who flashes what you send and tells you what happened.

It is written from one experiment — [exp156](../experiments/exp156-a-wall-you-can-measure/)
— that took seven flash cycles and is still unfinished. Most of those seven were
avoidable, and the ones that were not are the reason the rest of this document
exists.

## The economics, which decide everything else

With a board on the same machine, an observation costs a second. Without one, it
costs **somebody walking to a bench, holding a button, plugging a cable, and
watching**. That is not a slower version of the same loop. It is a different
activity, and code written for the fast loop fails badly in the slow one.

Two consequences follow, and everything below is one of them:

- **A build must answer a question whatever the outcome.** "Try this and see" is
  a coin toss that costs a human trip.
- **The instrument matters more than the fix.** A round that produces an
  unreadable result costs the same as one that produces a finding.

---

## Rule 1 — search prior work before forming a hypothesis

**The first move when something breaks is not to think about causes. It is to
find out whether this has happened here before.**

This is not a nicety. In exp156 it was violated repeatedly, and every violation
cost a flash cycle that a `grep` would have saved:

| What broke | What the search would have found | Cost of not searching |
| --- | --- | --- |
| The device chooser was empty and the page looked broken | `exp117`'s troubleshooting table: *the picker lists nothing / the board is already in BOOTSEL / it is `2e8a:000f` now*. And `debugging-on-a-phone.md` recording the identical failure taking out exp146's step 0 **on a page that was working perfectly** | one round |
| A blocking call inside an async task froze everything | `exp110` is an entire experiment about awaiting versus blocking, and `exp113` yields inside its loop with a comment citing it | one round |
| A survey printed once and was never seen | `exp113`'s comment: *a fact printed once is a fact most readers never see* | one round, in exp154 |
| A hand-rolled OTP read disagreed with the HAL | `exp113` already reads OTP through `embassy_rp::otp` | would have been a wrong result, not just a delay |

The searches that pay are boring:

```sh
grep -rn "the symptom, in the words it appeared in" docs/ experiments/*/README.md
grep -rln "the register or API in question" experiments/*/src/
git log --all -S"a distinctive string from the thing you are about to write"
```

And one that is not a search of this repository at all, and paid best of any:
**read the source of the function you are calling.** `spawn_core1` looks like
fire-and-forget and contains two blocking `fifo_read()` calls with an escape
that fires only on a *wrong* answer, never on silence. No amount of reasoning
about the symptom would have produced that; thirty seconds of reading did.

**A hypothesis is what you form when the search comes back empty.** Forming one
first means you go looking for confirmation instead of for the answer, and on a
loop this slow you get one confirmation attempt per human trip.

---

## Rule 2 — the LED is the only channel, so prove it before you need it

When firmware fails on a board you cannot see, everything you would normally
read is downstream of the thing that broke. USB is gone. The log is gone. The
page cannot connect. **What is left is one GPIO and somebody's eyes.**

So the LED is not a nicety for a beginner's first blink. **It is the debug
channel**, and it has to be designed as one *before* the firmware needs it.

### It must run before anything that can fail

exp156's first build configured a peripheral and launched a second core **three
lines above `Driver::new`**, and the second of those blocked forever. The board
hung at the one moment it had no way to say so — no LED, no USB, nothing. It
looked exactly like a firmware that never started.

**Bring up the LED and the log first. Put everything that can hang after them.**
`check.sh` in exp156 now greps `main()` and fails if any risky call moves back
above the USB stack, because "we will remember" is not a property you can check.

### Dark and dead must not be the same signal

Three rounds were lost to a board that "stopped blinking", which could mean the
firmware never started **or** that it started and died. The LED could not tell
those apart, so every diagnosis had to work around its own instrument.

The fix is that a fault handler **drives the LED itself** — bit-banged through
SIO, with no HAL, no executor and no interrupts, because those are exactly what
is no longer trustworthy at that point:

```rust
#[exception]
unsafe fn HardFault(ef: &ExceptionFrame) -> ! {
    // ... record, then blink, forever, by hand
}
```

### One bit can say more than one thing

The instrument went through four revisions, each paid for by a round that could
not separate two outcomes:

1. **dark or blinking** — alive or not
2. **slow or fast** — running or finished
3. **a distinct fault pattern** — died, as opposed to never started
4. **a count** — died *here*

The last one is the one that mattered. **A pattern that means "died" is worth
much less than one that means "died at step five."** exp156 keeps a counter
written *before* each step and never after, and the fault handler flashes it, so
the number is the step that did not come back — with no log, no page, no host
and no clock.

> When the only channel is one bit, the design question is not whether it
> reports. It is **how many distinct things it can say**.

### Steps must be spread far enough apart to be told apart

A step that does three things inside a millisecond is three things the LED
cannot separate. exp156's step 5 was exactly that, and "four blinks" named all
three equally. Two seconds between them turned the blink count into an answer.

**Time is the cheapest thing to spend on this loop.** Twenty seconds of waiting
before a risky write, so a human can open a page and read the values that
already succeeded, costs nothing next to losing them and flashing again.

---

## The checklist, for the next firmware written this way

- [ ] **LED up first**, before any peripheral, any second core, any risky call.
- [ ] **Fault handler drives the LED by hand**, with a pattern nothing else
      produces, so *dark* and *died* are different signals.
- [ ] **The fault pattern carries a step number**, written before each step.
- [ ] **Risky steps are seconds apart**, not milliseconds.
- [ ] **The log repeats**, because a fact printed once is a fact most readers
      never see — and a person attaches late every time.
- [ ] **The page names the firmware it found** and says so loudly when it is the
      wrong one; a board running something else looks exactly like a broken
      experiment.
- [ ] **The device filter includes the bootrom**, so an empty chooser cannot be
      mistaken for a broken page.
- [ ] **Ship one zip, not loose files** — `pack.sh` carries the firmware, the
      pages, the walkthrough and the `check.sh` output, and refuses to build if
      the checks fail.

## What to ask the person at the other end

Ask for **what they can see**, never for a diagnosis, and ask for one thing:

- *How many flashes before it stopped?* — not "did it work"
- *Slow or fast?* — these mean different things and both look like "blinking"
- *Was the chooser empty, or did you close it?* — Chrome reports both as
  `No device selected`

And when a round produces data that survived — a log, a value, a count — **get
it out before anything else is tried.** exp156 produced two register values on
round five and nobody has read them yet, because round six went on to attempt
the thing that killed the log.

## When to stop and hand over

exp156 stopped after seven rounds, and stopping was right. The signal is not
frustration; it is **arithmetic**: when the remaining questions each cost a human
trip and a board on the developer's own desk answers all of them in minutes, the
loop is the problem, not the bug.

What to leave behind is in
[exp156's handover](../experiments/exp156-a-wall-you-can-measure/HANDOVER.md):
what was measured, in what order, what each round established, what is still
unexplained, and which decisions were paid for and should not be undone.
