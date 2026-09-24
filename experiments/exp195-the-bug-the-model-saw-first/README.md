# exp195 — the bug the model saw first

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A model checker, given four crates and three sentences from their own
documentation, finds in under a second the bug a board found on 2026-08-30 —
and then finds the one that fix left open, which exp190's own capture had been
printing since that same morning.**

This experiment has no firmware of its own. Its subject is a method, and it is
calibrated the only honest way a method can be: on a question whose answer was
already paid for.

## The method, in four steps

| | Step | Here |
| --- | --- | --- |
| 1 | **Model** only the hard part: the state that outlives a reboot, the order events can come in | [`model/Breadcrumb.tla`](./model/Breadcrumb.tla), 97 lines; [`model/UsbLog.tla`](./model/UsbLog.tla), 118 |
| 2 | **Find counterexamples**: let a tool search every order of events for one that breaks a stated property | TLC, fetched and pinned by [`tools/tlc/setup.sh`](../../tools/tlc/setup.sh); [`tools/tlc/tlc.sh`](../../tools/tlc/tlc.sh) runs all 15 configurations |
| 3 | **Reproduce**: go back to the real code and make it happen | a test in `crates/breadcrumb`; exp190 flashed twice ([`run.sh`](./run.sh)) |
| 4 | **Fix** it in the code, and ask the model again | `crates/usb-reboot`, and the `fixed` configurations |

A counterexample from step 2 is a **hypothesis**. Step 3 is not a formality: it
is where a counterexample that depends on something the real program cannot do
gets thrown away — and [the second half](#half-two-a-prediction-made-before-the-run)
of this experiment is one.

## What was already known

- **2026-08-30, `a9933bf`.** exp157's first run on the split `breadcrumb` came
  up as `boot #19` with a death `in step 92` — a note left by another firmware,
  believed. It cost a failed run to see.
- **`ecf659e`, the same day.** The fix: the token now carries the experiment's
  tag, and a note is believed only if the tag is this firmware's. Two attempts
  to prove a *different* tag is refused on silicon failed; the commit says so,
  and says it is **not hardware-proven**.
- **`crates/breadcrumb`'s own promise**, on `interpret`: *"a fresh flash must
  find nothing to believe."*
- **exp190's `capture.txt`**, recorded the same morning: arm 2, flashed onto a
  board running arm 1 — exp190 onto exp190 — reports its first boot as
  **`boot 4`**, not `boot 1`. Nobody read that number as a finding. Step 3
  below is what it was.

## Half one: calibration on a bug a board already found

### The model

[`model/Breadcrumb.tla`](./model/Breadcrumb.tla) models `WATCHDOG.SCRATCH0`
across flashes, deaths and reflashes, for four firmwares: two builds of exp190
(same tag, different code), exp174 (no breadcrumb at all) and exp157. It does
not model any crate alone, because **no crate here is wrong alone**:

- `breadcrumb::interpret` believes a same-tag token after a watchdog reset.
  That is its whole purpose.
- `lifeline::begin` arms the token, and `alive` never withdraws it, so a hang
  while running is still reported. That is its purpose too.
- SCRATCH0 survives the 1200-baud reflash — measured, and the reason the crate
  works at all.

Each is right. Together, a reflash of a running lifeline firmware hands its
token to whatever boots next. Every fact the model uses is cited to the line it
came from, and [`check.sh`](./check.sh) re-reads those lines on every run, so a
crate that changes under the model turns it red instead of leaving a model of
code that no longer exists.

### Three properties, each somebody else's sentence

| Property | Whose sentence |
| --- | --- |
| `NeverAnotherExperimentsNote` | `ecf659e`: *"A note from another build now reads as `Cause::Fresh`"* |
| `AFreshFlashBelievesNothing` | `interpret`: *"a fresh flash must find nothing to believe"* |
| `ADeathIsStillReported` | the reason the crate exists, which a fix must not break |

The third is not decoration. A fix checked only against the property it was
written for can break the feature it was written into, and a model is as happy
to check that as anything else.

### What TLC said

| Configuration | Another experiment's note | A fresh flash | A death |
| --- | --- | --- | --- |
| `before` — the code before `ecf659e` | **violated**: `exp190a -> exp157` | **violated**: `exp190a -> exp190a` | holds |
| `tagged` — the code on `main` before this experiment | holds | **violated**: `exp190a -> exp190a` | holds |
| `fixonly` — this experiment's fix, without the tag | holds | holds | holds |
| `fixed` — both | holds | holds | holds |

Read it row by row:

1. **`before`**: the first counterexample TLC prints is the 2026-08-30 bug —
   exp190 running, `yi26 flash` exp157, exp157 believes it. Nine states,
   under a second.
2. **`tagged`**: the tag fixed exactly what it was written for, exhaustively —
   something the board never managed to show. And the stronger sentence, the
   one the crate's documentation actually promises, is still false: flash the
   same experiment twice and the second believes the first. **The fix was
   verified against a weaker property than the one written down.**
3. **`fixonly`**: withdrawing the token on the reflash path satisfies all
   three *without the tag*. In this model, the 2026-08-30 bug would never have
   happened had the reflash path cleared the token.
4. **`fixed`**: what is in the tree now.

Row three needs its limits stated, because a model answers only for the paths
it has. This one has three ways a board changes firmware — the 1200-baud touch,
a power cycle, a death — and every firmware in it reflashes through
`crates/usb-reboot`, which is true of every firmware checked. A firmware that
reflashed some other way would be outside it. **The tag stays**: it costs nothing
and guards a path this model does not contain.

### The fix

One store, in `crates/usb-reboot`, just before it enters the bootrom: zero
`WATCHDOG.SCRATCH0`. A deliberate reflash is not a death, and the only thing
that knows a reflash is deliberate is the code performing it.

It is a raw address and not `breadcrumb::disarm`, because most firmwares that
link `usb-reboot` do not enable `embassy-rp`'s `unstable-pac`, and nothing else
in this repository reads SCRATCH0. It is the only crate change here that alters
a firmware image — every firmware that links `usb-reboot` gains it.

### Step 3, reproduced

**On a host**: `crates/breadcrumb` gains
`a_rebuild_reflashed_while_running_starts_fresh_only_if_the_reflash_withdrew_the_token`,
which replays TLC's trace through the real `interpret` and asserts both
premises of the fix: with the token left, the new build believes the old; with
it withdrawn, it starts fresh. The replay lives in the crate, not here — it is
the crate's behaviour, and the bridge between model and code has to be on the
code's side.

The test next to it, `a_reflashed_board_does_not_inherit_the_previous_builds_death`,
now says what it had silently assumed: `s0: 0` at the moment of the reflash.
That premise was the bug.

**On a board**: [`run.sh`](./run.sh) builds exp190's control arm once and
flashes the same image twice. The second flash is the measurement.

## Half two: a prediction made before the run

The half above has a flaw it cannot fix by itself: the bugs were found by
reading the code before the models were written, so TLC finding them again is
not independent evidence.

So `model/UsbLog.tla` — `line()` in `crates/usb-log`, under a cooperative and
a preemptive scheduler — was **committed and pushed with its predictions in
`4ab6233` before TLC had been run on it once**. [`PREDICTIONS.md`](./PREDICTIONS.md)
holds both, and the outcome below a line with nothing above it edited:

| | Predicted | TLC |
| --- | --- | --- |
| cooperative: every loss counted | holds | holds |
| cooperative: the marker lands where the gap is | holds | holds |
| preemptive: every loss counted | holds | holds |
| preemptive: the marker lands where the gap is | violated | violated |
| the shape of that counterexample | producer 1 claims the count, producer 2 slips in | **wrong**: a line that claimed *before* the loss arrives *after* it |

Four of four verdicts, and the shape missed — which is what a model is for: it
looked in a window the reasoning did not.

And step 3 **cannot reproduce it**. Six firmwares here have a `core1_main`;
none of them logs. Nothing logs from an interrupt. Under embassy's cooperative
executor the counterexample cannot occur, so it is not a bug in any firmware
that exists. It is a hazard for the callers `usb-log`'s documentation invites —
"on a different core or inside an interrupt" — and the right response to a
counterexample that depends on the scheduler is a sentence about the scheduler,
not a patch.

## What a model is not

- **Not a proof.** "Holds" means TLC visited every state *inside the bounds*:
  four firmwares, two producers, a queue two deep. Up to 808 states. A bigger
  world can hide a bug these bounds cannot.
- **Not the code.** It is a second description, which is what
  [`docs/what-belongs-to-an-experiment.md`](../../docs/what-belongs-to-an-experiment.md)
  warns against. The answer here is two bridges: citations `check.sh` re-reads,
  and every counterexample replayed as a test against the real crate.
- **Not a substitute for a board.** The fix changes every image that links
  `usb-reboot`; only the board says the change does on silicon what the model
  says it does in logic.

## Try it

Before reading `model/Breadcrumb.tla` to the end, delete the three properties
and write your own from `interpret`'s documentation. Run
`../../tools/tlc/tlc.sh table model`. If you wrote the property `ecf659e` was checked against, every
configuration after `before` passes — which is exactly how that fix came to be
called done.

## Running it

```sh
../../tools/tlc/setup.sh   # once, needs the network: TLC v1.7.4, checked against its sha256
./check.sh                 # no board: models, citations, the crate's tests; rules on capture.txt
./run.sh                   # records capture.txt; the board half runs if a board is attached
../../tools/tlc/tlc.sh trace model bc-tagged-AFreshFlashBelievesNothing   # one counterexample in full
```

Java 11 or later. No board for the model half; any RP2350 board and **nobody**
for the board half.

## Expected output

The model half, from `capture.txt`:

```text
=== exp195 — the bug the model saw first ===
recorded at 2026-09-24T12:06:33Z from commit 06d51b8

>>> the model half: every configuration in model/expected.txt
    TLC Version 2.19, one worker, breadth first

Breadcrumb bc-before-NeverAnotherExperimentsNote    violated      9 states  blank -> exp190a -> exp157
Breadcrumb bc-before-AFreshFlashBelievesNothing     violated      6 states  blank -> exp190a -> exp190a
Breadcrumb bc-before-ADeathIsStillReported          holds        15 states  
Breadcrumb bc-tagged-NeverAnotherExperimentsNote    holds        13 states  
Breadcrumb bc-tagged-AFreshFlashBelievesNothing     violated      6 states  blank -> exp190a -> exp190a
Breadcrumb bc-tagged-ADeathIsStillReported          holds        13 states  
Breadcrumb bc-fixonly-NeverAnotherExperimentsNote   holds         7 states  
Breadcrumb bc-fixonly-AFreshFlashBelievesNothing    holds         7 states  
Breadcrumb bc-fixonly-ADeathIsStillReported         holds         7 states  
Breadcrumb bc-fixed-NeverAnotherExperimentsNote     holds         7 states  
Breadcrumb bc-fixed-AFreshFlashBelievesNothing      holds         7 states  
Breadcrumb bc-fixed-ADeathIsStillReported           holds         7 states  
UsbLog     usblog-cooperative                       holds       162 states  
UsbLog     usblog-preemptive                        violated    214 states  12 states long — ./model.sh --trace usblog-preemptive
UsbLog     usblog-preemptive-count                  holds       808 states  
```

The full preemptive counterexample follows it in `capture.txt`.

The board half: **not captured yet.** It needs a board, and this experiment's
fix has not been run on one.
