# exp194 — the transport that drifted

**Six firmwares off one accretion chain, asked the same twelve questions. Five
answer the specification on every one. The sixth — the newest, the largest, the
one on the authenticator road's front — is wrong twice, and one of them takes
away the client's only way to recover.**

**Then a seventh, assembled from a crate instead of copied, answers all twelve
in seventeen lines.**

## Why this exists

`ctaphid_task` is defined in **fourteen experiments here as thirteen different
functions**. Sorted by experiment number, its length is:

```
exp168 110 → 169 → 241 → 333 → 451 → 451 → 531 → 567
                                          ↘ exp184 424      a fork from an older point
                      exp185 516 → 669 → 694 → 791 → exp189 959
```

That is not a shared component that grew. It is fourteen forks, and
[`docs/what-belongs-to-an-experiment.md`](../../docs/what-belongs-to-an-experiment.md)
is the argument for extracting it. **This experiment is what tells the extraction
what to be.** A crate copied out of one fork inherits that fork's bugs; a crate
built to a measured specification does not.

Every case below is one where **CTAP-HID says what the right answer is**, so a
firmware is graded rather than described. None of them reaches user presence, so
the whole run needs a board and nobody.

## What was measured

```
      case           exp168  exp170  exp172  exp174  exp184  exp189  exp194
      bad-cid        ok      ok      ok      ok      ok      DIFF    ok
      bad-seq        ok      ok      ok      ok      ok      ok      ok
      busy           ok      ok      ok      ok      ok      ok      ok
      busy-recovers  ok      ok      ok      ok      ok      DIFF    ok
      init           ok      ok      ok      ok      ok      ok      ok
      init-resets    ok      ok      ok      ok      ok      ok      ok
      ping 1024      ok      ok      ok      ok      ok      ok      ok
      ping 1025      ok      ok      ok      ok      ok      ok      ok
      ping 57        ok      ok      ok      ok      ok      ok      ok
      stray-cont     ok      ok      ok      ok      ok      ok      ok
      truncated      ok      ok      ok      ok      ok      ok      ok
      unknown        ok      ok      ok      ok      ok      ok      ok
```

exp194 is the last column and it is the only subject held to a standard by
`verify.py`: **built on the crate, it must be `spec` in every cell.** The
others are evidence; it is the product.

**Ten of twelve cases: identical across all six.** The chain drifted in size
from 110 lines to 959 and in behaviour almost not at all — which is a real
answer, and not the one the accretion picture predicts.

## The two that drifted, both at the head

### 1. `bad-cid` — the wrong error

A message on a channel the device never allocated. CTAP-HID names
`ERR_INVALID_CHANNEL` (0x0B). exp189 answers `ERR_INVALID_PAR` (0x02).

Five firmwares before it answer 0x0B. This is a regression, not a choice.

### 2. `busy-recovers` — the recovery path refused

This is the one that matters. A client leaves a transaction unfinished on one
channel and another channel speaks; the device correctly refuses the second with
`ERR_CHANNEL_BUSY` — every one of the six gets that right. Then the client does
what CTAP-HID tells it to do when it has lost track: **a broadcast INIT**.

| | after a busy refusal |
| --- | --- |
| exp168, exp170, exp172, exp174, exp184 | a channel, immediately |
| **exp189** | `ERR_CHANNEL_BUSY` |

Measured with a clock on it:

```text
  broadcast INIT after 0.1s:  ERR_CHANNEL_BUSY
  broadcast INIT after 1.0s:  ERR_CHANNEL_BUSY
  broadcast INIT after 3.0s:  ERR_MSG_TIMEOUT     the abandoned transaction expiring
  broadcast INIT after 5.0s:  a channel
```

It is **not a brick** — it recovers when the abandoned transaction times out,
about four seconds later, and CTAP-HID names 750 ms for that. But for those four
seconds the device has told the client to go away and left it no way back. A
first reading of this said "stuck forever"; putting a clock on it is what made
it true.

## The crate, and where the deciding went

[`crates/ctap-hid`](../../crates/ctap-hid/) is not exp189's transport tidied up.
It is **the behaviour five firmwares agreed on and the specification requires**,
which is a thing that could only be written after the table above existed.

The shape that made it testable is one decision: `Transaction::feed` takes the
clock as a `u64` of milliseconds rather than reaching for `Instant`. With that,
deciding what an arriving packet means needs no board:

| | |
| --- | --- |
| `crates/ctap-hid/src/lib.rs` | 384 lines of deciding, no `async`, no embassy, **22 host tests** |
| `crates/ctap-hid/src/board.rs` | 141 lines: the loop, the deadline, `INIT`, every error |
| exp194's `answer_task` | **17 lines** — `PING`, and `ERR_INVALID_CMD` for the rest |
| exp189's `ctaphid_task` | 959 lines |

The twenty-two tests are the same twelve questions the hardware suite asks, plus
the reassembly and fragmentation identities. **Two witnesses for one contract**:
if the tests pass and the board fails, the fault is in the USB half; if both
fail, it is in the crate.

**The loop is in the crate because the ratchet said so, not because anyone was
far-sighted.** This firmware first carried a 97-line `ctaphid_task` — already
ten times smaller than what it replaced — and `experiments/duplication.sh`
failed it for being a fifteenth one. A loop small enough to feel harmless is
exactly the kind that gets copied. What is left in the experiment is the only
question that was ever its own: which commands does it answer?

One of those tests was wrong when it was written — it expected a late
continuation packet to be ignored, where the correct answer, and what five
boards do, is `ERR_MSG_TIMEOUT` on its own channel. The crate was right and the
test was not, which is the direction that costs nothing to find.

This repository's existing split, applied again: `log-policy` and `log-ring`
have tests where `usb-log` cannot, `lifeline`'s give-up rule is arithmetic where
`lifeline::board` is not.

## What this does not establish

- **Six of fourteen.** The samples span the chain — 110, 241, 451, 531, the
  exp184 fork, and 959 — and cost one flash each. The other eight are untested,
  so "only exp189 drifted" is a statement about these six.
- **Where between exp184 and exp189 it drifted.** exp184 is correct and exp189
  is not; exp185 to exp188 were not run. The interval is named, not narrowed.
- **The transport layer only.** No case here sends CBOR, makes a credential or
  asks for a press. What every firmware does *above* the transport is each
  experiment's own subject and is untouched by this.
- **Nothing was fixed.** exp189 still answers `ERR_INVALID_PAR` and still
  refuses the recovery path; the fourteen copies are grandfathered and this
  changes none of them. What exists now is a crate the *next* CTAP experiment
  can be built on, and a measurement saying what it owes.
- **The crate has one caller.** exp194 and nothing else. Its value is entirely
  in what comes after it, which is the same bet `crates/cdc-console` made in
  exp190 and had paid off by exp193.

## Run it

```sh
./drift.sh    # needs a board and nobody. Flashes six firmwares, writes capture.txt.
./check.sh    # rules on the capture. No board needed.
```

The client is [`tools/ctaphid/`](../../tools/ctaphid/), and it is there rather
than here because **seven experiments each grew their own** — 238 to 689 lines,
six of them textually different, the same accretion mirrored on the host side.
`experiments/duplication.sh` cannot see those: it only reads Rust. This is the
first caller that needs one client to speak to several firmwares, and a suite
that changes between boards is not a comparison.

## Standing on

- [exp168](../exp168-a-security-key-that-knows-nothing/) — the 110-line
  original, and still correct on all twelve.
- [exp128](../exp128-reassemble-by-hand/) — reassembly, which is what a CTAPHID
  transaction is.
- [exp190](../exp190-the-board-that-brings-itself-back/) and
  [exp193](../exp193-how-many-doors-fit/) — the design change this serves, and
  the rule that an extraction waits for a caller.
