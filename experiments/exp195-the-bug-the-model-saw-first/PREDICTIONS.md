# exp195 — what the usb-log model will say, written before it said anything

<!-- SPDX-License-Identifier: Apache-2.0 -->

This file and [`model/UsbLog.tla`](./model/UsbLog.tla) were committed **before
TLC was run on that model even once**. The only tool that has touched it is
SANY, the parser, which checks that it is well-formed TLA+ and evaluates
nothing. The commit that adds this file is the proof of the order; the results
arrive in a later commit and are compared against what is written here, not the
other way round.

This half exists because of a contradiction the
[briefing](../../docs/2026-09-24-1020-model-round-briefing-zh-tw.md) names:
the three bugs in the rest of this experiment were found by reading the code
*before* their models were written, so TLC finding them again is not
independent evidence. A prediction written down in advance is the cheapest
remedy there is.

## What is modelled

`line()` in `crates/usb-log/src/board.rs` under the default policy
(`DropNewest`), two producers, the writer task, a queue two deep, three lines
per producer. Two schedulers:

- **cooperative** — embassy's executor. `line()` never awaits, so no other task
  runs inside it; it is one atomic step.
- **preemptive** — what the crate's documentation invites: senders "on a
  different core or inside an interrupt". `line()` becomes three steps —
  admit, claim, try_send — and anything can happen between them.

## The two properties, each a sentence from the crate

| | Property | Source |
| --- | --- | --- |
| `EveryLossIsCounted` | reported + `DROPPED` + claimed-but-unplaced = lines really lost | "Losing data is survivable; not knowing you lost it is not." |
| `TheMarkIsWhereTheGapIs` | the first line into the queue after a loss carries a marker | "The count is attached to the first line that survives after the gap, so the loss is marked exactly where it happened." |

## Predictions

| Scheduler | `EveryLossIsCounted` | `TheMarkIsWhereTheGapIs` |
| --- | --- | --- |
| cooperative | **holds** | **holds** |
| preemptive | **holds** | **violated** |

**Why the count survives preemption.** `claim` is one atomic swap and `refund`
one atomic add, so a count is always in exactly one of three places — the
queue's markers, `DROPPED`, or one producer's hand — and the accounting only
ever moves it between them.

**Why the mark does not.** Predicted shape of the counterexample: the queue
fills, a line is refused (a gap), the writer takes one line out, producer 1
claims the count and is interrupted before `try_send`, and producer 2 runs a
whole `line()` — admitted, claims zero, sends. Producer 2's line is the first
after the gap and carries no marker. (What becomes of producer 1's count after
that is not predicted: it depends on whether the queue has room left.)

## Predicted outcome of step 3, reproduction

**Not reproducible in any firmware in this repository.** Six firmwares have a
`core1_main` and none of them calls `usb_log::log!` from it; nothing logs from an
interrupt handler. Under embassy's cooperative executor the preemptive
counterexample cannot occur. If the prediction above holds, the violation is a
*latent* one: real for the callers the documentation invites, absent for every
caller that exists.

So this half is also the negative control for the method. A counterexample is a
hypothesis about a program under a scheduler; if step 3 cannot reproduce it, the
right conclusion is about the scheduler, not a patch.

## If a prediction is wrong

It is recorded as wrong, here, in the commit that runs the model — with what TLC
said instead, and nothing above this line edited.
