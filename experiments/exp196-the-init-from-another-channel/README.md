# exp196 — the INIT from another channel

<!-- SPDX-License-Identifier: Apache-2.0 -->

**`crates/ctap-hid` let one client's INIT throw away another client's
half-sent message, and told nobody. exp194's `busy-recovers` stopped one step
before it. A model of the transport found it in three states, then — once it
was fixed — found a second silent loss behind it.**

This is the method [exp195](../exp195-the-bug-the-model-saw-first/) calibrated,
applied to a protocol: model → counterexample → reproduce → fix. exp195 checked
the method against a bug a board had already found; this one uses it where the
answer was not known in advance.

## What was already known

- **[exp194](../exp194-the-transport-that-drifted/)** asked six firmwares twelve
  CTAP-HID questions and wrote `crates/ctap-hid` to the answers five agreed on.
  Its `busy-recovers` case: A leaves a message half-sent, B is refused as busy,
  then a broadcast INIT arrives — and the case asks one thing, *was the INIT
  answered?*
- **The crate's reason for answering it**: "INIT is not a new transaction, it is
  a reset … it clears whatever was in flight."
- **CTAP 2.1 and 2.2, word for word the same**:
  - §11.2.5.1 — "If an application tries to access the device from a different
    channel while the device is busy with a transaction, that request will
    immediately fail with a busy-error message".
  - §11.2.5.3 — "If the device detects an INIT command during a transaction that
    has the **same channel id** as the active transaction, the transaction is
    aborted".

  Neither text has an exception for a broadcast INIT, and neither contains the
  number 750.

## Step 1: the model

[`model/CtapHid.tla`](./model/CtapHid.tla) is `Transaction::feed`, `expire`,
and the board loop that drives them, with two clients: A sends a request that
needs two packets; B is another program that either enumerates (a broadcast
INIT) or pings its own channel. Time is abstract ticks. Every transition cites
the line it translates, in [`model/cited.txt`](./model/cited.txt), and
[`check.sh`](./check.sh) re-reads those lines on every run.

Two properties, neither invented here:

| Property | Whose sentence |
| --- | --- |
| `NoSilentLoss` | the crate's own contract — an `Action` is `More`, `Complete`, or an error *sent on a channel*; `expire` "returns the channel to send `ERR_MSG_TIMEOUT` on" — and §11.2.5.3, which aborts only a transaction on the same channel |
| `AnInitIsAnswered` | exp194's `busy-recovers`: a broadcast INIT is answered whatever else is going on |

The second is **this repository's choice, not the specification's** — §11.2.5.1
read literally refuses it. The model carries both readings as a constant, so the
choice is visible rather than argued:

| `InitPolicy` | |
| --- | --- |
| `clears` | the crate before exp196: an INIT from anyone clears the message buffer |
| `answers` | exp196: answered without touching another channel's message; its own channel reset |
| `busy` | §11.2.5.1 read literally: refused while another channel is busy |

and `FixH1` selects whether an expiry decided by another channel's packet is
handed to the caller.

## Step 2: what TLC said

| `InitPolicy` | H1 | `NoSilentLoss` | `AnInitIsAnswered` |
| --- | --- | --- | --- |
| `clears` | either | **violated**: `ASendInit -> BBcastInit` | holds |
| `answers` | open | **violated**: `ASendInit -> Tick -> Tick -> BBcastInit` | holds |
| `answers` | fixed | holds | holds |
| `busy` | fixed | holds | **violated**: `ASendInit -> BBcastInit` |

Read it top to bottom:

1. **H2, three states.** A sends the first packet; B enumerates. The INIT went
   through the same buffer as A's message and cleared it. A's next packets were
   `Ignore("a continuation packet with no transaction")` — no error, no
   answer. A waits for a reply that is never coming.
2. **H1, found only once H2 was fixed.** A sends the first packet and goes
   quiet; time reaches the deadline; B's packet arrives before the board's timer
   arm is polled. `feed` expires A — so B finds the device free — and the
   channel owed `ERR_MSG_TIMEOUT` is computed and dropped. The timer, when it
   looks, finds nothing to expire. The crate's own test for this moment said
   "B is not told about A's expiry — that is A's business", and nobody minded
   that A was never told either.
3. **Both fixed**: no counterexample in 220 states.
4. **The road not taken**: refusing the INIT also ends the silent loss, and gives
   up the recovery path exp194 measured and chose. The model does not decide
   between them; it shows the price of each.

A model searches breadth first and reports the shortest counterexample, so a
second bug can hide behind the first until the first is fixed. That is what
happened here, and it is why a fix is checked by running the model again, not
by re-reading the patch.

## Step 3: reproduced

**Against the crate before and after, in one command.**
[`replay/`](./replay/) depends on `crates/ctap-hid` twice: pinned by git to
`fe5b2bb`, the last commit before this experiment, and by path to the tree.
Each counterexample is one test per side, and each asserts what that side
should do — the bug present before, gone after — so the pair passes only while
both the reproduction and the fix are still true.

**In the crate**, as regression tests named after the wrong answer:
`another_clients_init_does_not_silently_eat_a_message_in_flight`,
`an_init_on_another_allocated_channel_leaves_the_message_alone_too`,
`an_expiry_decided_by_another_channels_packet_is_still_owed_to_its_channel`.

**End to end, over a socket.** `tools/ctaphid` gains `init-keeps-other`:
`busy-recovers`, and then the question after it — A sends the rest of its
message and waits for its echo. `tools/vctaphid`, the device built on the crate,
answers it to spec; `--wrong init-clears` puts the old behaviour back, and
`selftest.sh` asserts the case catches it: *"A's message vanished: no answer at
all after another client's INIT"*. CI runs this on every push.

## Step 4: the fix

In `crates/ctap-hid`:

- **`Action::Init(cid, nonce)`**. An INIT is answered from its own packet and
  never goes through the message buffer; it aborts a transaction only on its own
  channel. `Complete` no longer carries INITs.
- **`Transaction::take_expired()`**. When `feed` expires a transaction while
  judging another channel's packet, it keeps the stale channel for the caller,
  and the board sends `ERR_MSG_TIMEOUT` before answering the packet itself.
  `board.rs` and `tools/vctaphid` both call it after every `feed`.
- **Two sentences corrected**, because the model forced a choice of text: the
  busy-refusal carve-out is described as this repository's choice rather than
  the specification's, and "750 ms is the specification's number" now says the
  number is in neither CTAP 2.1 nor 2.2 and still needs a source.

exp189 and exp194 use the transport through `ctap_hid::board::Wire` and needed
no change; both build.

## What a model is not

- **Not a proof.** Two clients, one message each, four ticks. A third client, or
  a message that needs three packets, is outside it.
- **Not the code.** Every transition cites a line, and `replay/` runs each
  counterexample through the real `feed` — before and after.
- **Not a board.** The fix changes exp189's and exp194's images, and only the
  board half below says it behaves on silicon.

## Try it

Set `InitPolicy = "busy"` in one of the `answers-*` configurations and run
`../../tools/tlc/tlc.sh table model`. Then decide which of the two properties
you would give up — and write down whose sentence each one was.

## Running it

```sh
../../tools/tlc/setup.sh   # once, needs the network: TLC v1.7.4 by sha256
./check.sh                 # no board: model, citations, replay/, the crate, the socket suite
./run.sh                   # records capture.txt; the board half runs if a board is attached
../../tools/tlc/tlc.sh trace model answers-h1open-NoSilentLoss   # one counterexample in full
```

Java 11 or later and the network once (for TLC, and for `replay/`'s pinned
crate). Any RP2350 board and **nobody** for the board half.

## Expected output

```text
=== exp196 — the INIT from another channel ===
recorded at 2026-09-24T12:43:17Z from commit efd1952

>>> steps 1 and 2: every configuration in model/expected.txt
    TLC Version 2.19, one worker, breadth first

CtapHid    clears-h1open-NoSilentLoss               violated      7 states  ASendInit -> BBcastInit
CtapHid    clears-h1open-AnInitIsAnswered           holds       299 states  
CtapHid    clears-h1fixed-NoSilentLoss              violated      7 states  ASendInit -> BBcastInit
CtapHid    clears-h1fixed-AnInitIsAnswered          holds       287 states  
CtapHid    answers-h1open-NoSilentLoss              violated     44 states  ASendInit -> Tick -> Tick -> BBcastInit
CtapHid    answers-h1open-AnInitIsAnswered          holds       244 states  
CtapHid    answers-h1fixed-NoSilentLoss             holds       220 states  
CtapHid    answers-h1fixed-AnInitIsAnswered         holds       220 states  
CtapHid    busy-h1open-NoSilentLoss                 violated     49 states  ASendInit -> Tick -> Tick -> BBcastInit
CtapHid    busy-h1open-AnInitIsAnswered             violated      7 states  ASendInit -> BBcastInit
CtapHid    busy-h1fixed-NoSilentLoss                holds       262 states  
CtapHid    busy-h1fixed-AnInitIsAnswered            violated      7 states  ASendInit -> BBcastInit

>>> step 3 and 4 on a host: replay/, the crate before exp196 and after
test h1_after_exp196_the_expiry_is_still_owed_to_a ... ok
test h1_before_exp196_the_expiry_was_decided_and_dropped ... ok
test h2_after_exp196_the_message_arrives_whole ... ok
test h2_before_exp196_another_clients_init_ate_the_message_in_silence ... ok

>>> end to end over a socket: tools/vctaphid/selftest.sh
PASS  the device builds
PASS  init
PASS  ping
PASS  bad-seq
PASS  busy
PASS  truncated
PASS  unknown
PASS  bad-cid
PASS  busy-recovers
PASS  stray-cont
PASS  init-resets
PASS  init-keeps-other
PASS  ping 1024
PASS  ping 1025
PASS  the suite catches a wrong answer, and names it: ERR_INVALID_PAR, not ERR_INVALID_CHANNEL
PASS  the suite catches a message eaten by another client's INIT: A's message vanished: no answer at all after another client's INIT
PRE-FLIGHT ONLY: this says nothing about any board.
```

The board half: **not captured yet.**
