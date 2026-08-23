# Tool needs — a ledger, not a road

These experiments produce findings about the RP2350. They also produce, as a
side effect, a list of **things the host-side toolkit did not have when an
experiment reached for it**. That list is worth keeping, because a need that
recurs is a real signal — and worth keeping *as a ledger rather than a road*,
because a road would invert this repository's method. A road needs experiments
to justify itself, and would tempt us to invent tool needs to fill it. A ledger
only records needs that actually happened.

## The rule for growing `yi26`

A gap becomes a `yi26` command only when **both** are true:

1. **It recurred.** One experiment reaching for something is a note here. Two or
   more reaching for the same thing is a case for building it.
2. **It is genuinely host-side.** Some gaps should *not* be closed in `yi26`,
   because the reach is the lesson. Reading flash is the standing example: a
   browser does it through the bootrom's PICOBOOT interface in
   [exp141](../experiments/exp141-two-doors-into-the-bootrom/), and *that a
   browser can and the firmware cannot* is the point. A `yi26 read-flash` would
   make [exp175](../experiments/exp175-the-secret-is-the-file/) step B one
   command and delete the understanding with the keystrokes.

The second rule is why this is a ledger and not a backlog. Not every gap is a
defect; some are the shape of the subject.

## The ledger

| experiment | what was reached for | how it was met instead | host-side? | verdict |
|---|---|---|---|---|
| [exp175](../experiments/exp175-the-secret-is-the-file/) | read a running board's flash, to show the secret is there | [exp141](../experiments/exp141-two-doors-into-the-bootrom/)'s browser PICOBOOT page | **no** — reading flash is the bootrom's, and the reach teaches that | **do not add to `yi26`.** The detour is the finding |
| [exp175](../experiments/exp175-the-secret-is-the-file/) | reassemble a `.uf2` into its flat image, and search it | `unpack.py`, written in the experiment | yes, but tiny and experiment-specific | **keep local** unless a second experiment needs it, then promote to a shared crate or `yi26 uf2` |

## How to add a row

When an experiment reaches for something the toolkit does not have, add a row
here before working around it — the workaround is easy to forget once it works,
and the point of the ledger is the pattern across rows, which no single
experiment can see. Record what was reached for, how the gap was actually met,
whether it is host-side, and a verdict. Leave the verdict at "watching" if one
occurrence is not yet a case.
