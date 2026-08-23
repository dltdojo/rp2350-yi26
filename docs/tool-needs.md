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
| [exp169](../experiments/exp169-what-it-says-it-can-do/) – [exp173](../experiments/exp173-a-client-that-is-not-ours/) | speak CTAPHID to the board and read `authenticatorGetInfo` | `ctaphid.py`, hand-written — **and copied into four experiments**, where it then diverged | yes | **the reach was the lesson** up to exp172: hand-writing CTAPHID *is* exp168's subject, and a tool would have deleted it |
| [exp176](../experiments/exp176-the-same-question-of-two-devices/) | the same, once the client had stopped being the subject | `fido2-token -I`, the host's own tool | yes | fine, until it was not: see the next row |
| [exp177](../experiments/exp177-the-same-chip-somebody-elses-decisions/) | the **raw COSE algorithm identifiers**, because `fido2-token -I` prints an algorithm it cannot name as `unknown` | imported [exp173](../experiments/exp173-a-client-that-is-not-ours/)'s `ctaphid.py` across experiment directories, by path | yes | **build it.** Rule 1 is met four times over; rule 2 stopped applying at exp173, which deliberately handed the client job to somebody else's tool. `fido2-token -I` is lossy in a way that nearly produced a wrong ruling, and the workaround was one experiment reaching into another's scripts |
| [exp177](../experiments/exp177-the-same-chip-somebody-elses-decisions/), [exp178](../experiments/exp178-the-shape-of-the-contract/) | a CBOR reader that a real authenticator's `getInfo` does not defeat | [`experiments/cbor.py`](../experiments/cbor.py), promoted out of exp178 | yes, but **not** a `yi26` job | **keep in Python.** JSON cannot carry integer map keys, byte strings or negative COSE labels without a convention every caller then undoes; `crates/cbor` is a `no_std` cursor that deliberately skips text-key ordering; both callers are Python. Revisit when a `check.sh` needs CBOR from bash — there is none today |

**What the fifth row bought.** `yi26 fido info` is the first command here that
speaks a protocol to *application* firmware rather than to the bootrom or a
serial port, and it exists because a pretty-printer's `unknown` is not an
answer. It does not replace exp168's hand-written client: that client is what
exp168 *is*, and it stays where it is. Nothing before exp177 uses the command,
for the same reason nothing before exp177 imports `experiments/cbor.py`.

## How to add a row

When an experiment reaches for something the toolkit does not have, add a row
here before working around it — the workaround is easy to forget once it works,
and the point of the ledger is the pattern across rows, which no single
experiment can see. Record what was reached for, how the gap was actually met,
whether it is host-side, and a verdict. Leave the verdict at "watching" if one
occurrence is not yet a case.
