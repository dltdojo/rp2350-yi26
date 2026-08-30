# exp194 — the transport that drifted

**Six firmwares off one accretion chain, asked the same twelve questions. Five
answer the specification on every one. The sixth — the newest, the largest, the
one on the authenticator road's front — is wrong twice, and one of them takes
away the client's only way to recover.**

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
      case           exp168  exp170  exp172  exp174  exp184  exp189
      bad-cid        ok      ok      ok      ok      ok      DIFF
      bad-seq        ok      ok      ok      ok      ok      ok
      busy           ok      ok      ok      ok      ok      ok
      busy-recovers  ok      ok      ok      ok      ok      DIFF
      init           ok      ok      ok      ok      ok      ok
      init-resets    ok      ok      ok      ok      ok      ok
      ping 1024      ok      ok      ok      ok      ok      ok
      ping 1025      ok      ok      ok      ok      ok      ok
      ping 57        ok      ok      ok      ok      ok      ok
      stray-cont     ok      ok      ok      ok      ok      ok
      truncated      ok      ok      ok      ok      ok      ok
      unknown        ok      ok      ok      ok      ok      ok
```

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

## What this does not establish

- **Six of fourteen.** The samples span the chain — 110, 241, 451, 531, the
  exp184 fork, and 959 — and cost one flash each. The other eight are untested,
  so "only exp189 drifted" is a statement about these six.
- **Where between exp184 and exp189 it drifted.** exp184 is correct and exp189
  is not; exp185 to exp188 were not run. The interval is named, not narrowed.
- **The transport layer only.** No case here sends CBOR, makes a credential or
  asks for a press. What every firmware does *above* the transport is each
  experiment's own subject and is untouched by this.

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
