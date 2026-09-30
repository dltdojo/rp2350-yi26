# exp199 — every length, not seven

<!-- SPDX-License-Identifier: Apache-2.0 -->

**`crates/ctap-hid`'s test `fragment_and_feed_are_inverses` asks seven message
lengths. This proves it for all 1025 — and it could only be proved after
naming the five things the test never said it needed. Writing the proof down
turned up where `fragment` itself stops being right: at 7609 bytes, CTAP-HID's
own maximum. Past that, `fragment` does not refuse a message — it cuts one that
`feed` reads as the start of a new message.**

[exp198](../exp198-a-proof-instead-of-a-search/) proved something already
modelled, so that the only new thing was the kind of certainty. This one proves
something that had only been *sampled*, and the lesson is what a sample leaves
out: not only the lengths between the samples, but the conditions under which
the sampled sentence is even true.

## What the test asked, and what the proof had to say

```rust
for len in [0usize, 1, 56, 57, 58, 116, 1024] {
    fragment(A, CTAPHID_PING, &payload, ...);   // one channel, one command
    let mut t = Transaction::new();             // one starting state
```

The test's name says "inverses". Its body holds four more things fixed without
saying so, and a proof cannot hold anything fixed without saying so.
`fragment_then_feed` is the whole sentence:

> For every message of at most `MAX_MESSAGE` bytes, on every channel that is
> neither broadcast nor reserved, with every command that is not `INIT` and
> fits in seven bits, handed to a transaction with no other message
> half-assembled: every packet but the last answers `More`, the last answers
> `Complete`, and `message()` is the channel, the command and the bytes that
> went in.

Each of those conditions is shown to be needed, not decoration — a theorem per
condition that shows what happens without it:

| Without | Theorem | What `feed` does instead |
| --- | --- | --- |
| a length of at most `MAX_MESSAGE` | `past_the_limit_is_refused` | `ERR_INVALID_LEN` on the first packet — refused, not truncated, for every length up to 65535 |
| a channel that is not broadcast | `broadcast_is_refused` | `ERR_INVALID_CHANNEL` |
| a channel that is not reserved | `reserved_is_refused` | `ERR_INVALID_CHANNEL` |
| a command that is not `INIT` | `init_is_not_a_message` | answers it as an `INIT`; nothing is assembled |
| a command below `0x80` | `a_command_loses_its_top_bit` | `0x90` arrives as `0x10`: the top bit is the packet type, not the command's |
| an idle transaction | `a_busy_device_refuses` | `ERR_CHANNEL_BUSY` |

`a_1024_byte_message_takes_eighteen_packets` is the crate's other test, likewise
for every 1024-byte message rather than one; `fragment_length` is the formula
it is an instance of.

## What the proof found

`fragment` numbers its continuation packets 0, 1, 2, … in the byte whose top bit
means "this is the first packet of a message". 128 of them fit before the number
reaches `0x80`, which is 57 + 128 × 59 = **7609 bytes — exactly CTAP-HID's
maximum message size**. The specification's number is this arithmetic.

| Theorem | |
| --- | --- |
| `fragment_to_7609_never_sets_the_init_bit` | up to 7609 bytes, no continuation packet can be mistaken for a first one |
| `past_7609_a_continuation_is_read_as_an_init` | at 7610 and beyond, the 129th continuation packet carries `0x80`: to `feed`, a new message |

`fragment` has no check for either. The crate is right **today** only because
nothing hands it more than `MAX_MESSAGE` = 1024 bytes. The proof says exactly how
far that can move: the last mutant in [`proof/mutants.txt`](./proof/mutants.txt)
raises `MAX_MESSAGE` to 7610, and `fragment_then_feed` stops checking. At 7609 it
still checks. `crates/ctap-hid/src/board.rs` already carries a comment about "a
larger `MAX_MESSAGE` one day"; this is the ceiling on that day.

That is a finding a sample could not have produced: the seven lengths all sit
far below 7609, and a test at 7610 would have needed somebody to already suspect
it. The proof needed the bound in order to go through — the `omega` step in
`fragment_then_feed` fails without it — and so it had to be written down.

It is **recorded, not fixed.** Nothing here sends more than 1024 bytes, so no
behaviour changes today, and the fix — `fragment` refusing a message it cannot
carry — changes its signature for every caller. That is its own change.

## The mutants

Six wrong versions of the crate, written into the Lean with `sed`. Lean must
refuse every one, and `check.sh` requires it:

| Half | The wrong version |
| --- | --- |
| `fragment` | the first continuation packet is numbered 1, not 0 |
| `fragment` | continuation packets carry 58 bytes where `feed` reads 59 |
| `fragment` | BCNT loses its high byte |
| `feed` | the expected sequence number never advances |
| `feed` | the command keeps the init bit |
| both | `MAX_MESSAGE` is raised past 7609 |

The third is invisible below 256 bytes, and six of the test's seven lengths
are below 256. The test catches it only because 1024 is on its list.

## What it does not prove

- **`u8`.** Bytes are `Nat` here. No data byte's value is ever read, and the
  header bytes are written with the Rust's own `|`, `>>`, `&` and `% 256`.
- **Time.** Every packet arrives at one instant. Expiry is in the transcription
  — `feed` still runs it first — but whether a slow host is told the right thing
  is exp196's model's question, not this proof's.
- **The Rust itself.** Forty-one cited lines say the Rust is still what was
  transcribed; they do not say the transcription is faithful. That is read by a
  person, as in exp198. The one structural liberty: the Rust's `buf` and `have`
  are one list here, the bytes written so far.
- **The other direction.** `feed` then `fragment` is not the identity, and is
  not claimed: the padding after a message's last byte is ignored by `feed`
  whatever it holds, so many packet sequences assemble into the same message.
- **The board.** `board.rs`'s `reply` truncates anything past `MAX_PACKETS`
  packets; that is outside `fragment` and outside this proof.

## Try it

In `proof/CtapHid.lean`, change `def MAX_MESSAGE : Nat := 1024` to `7609` and
check the file. Which theorem stops checking, and why is it not
`fragment_then_feed`? Then try `7610`.

## Running it

```sh
../../tools/lean/setup.sh   # once, needs the network: Lean 4.34.0 by sha256, 580 MB
./check.sh                  # no board: the proof, its axioms, six mutants, the citations, the crate
./run.sh                    # records capture.txt
```

No board and nobody. `cargo` for the crate's tests.

## Expected output

```text
=== exp199 — every length, not seven ===
recorded at 2026-09-30T00:34:06Z from commit 597d475

>>> the proof: every theorem, and what it rests on
    Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)

'CtapHid.fragment_then_feed' depends on axioms: [propext, Quot.sound]
'CtapHid.a_1024_byte_message_takes_eighteen_packets' depends on axioms: [propext, Quot.sound]
'CtapHid.init_is_not_a_message' depends on axioms: [propext]
'CtapHid.broadcast_is_refused' depends on axioms: [propext]
'CtapHid.reserved_is_refused' depends on axioms: [propext]
'CtapHid.a_command_loses_its_top_bit' depends on axioms: [propext]
'CtapHid.past_the_limit_is_refused' depends on axioms: [propext, Quot.sound]
'CtapHid.a_busy_device_refuses' depends on axioms: [propext]
'CtapHid.fragment_to_7609_never_sets_the_init_bit' depends on axioms: [propext, Quot.sound]
'CtapHid.past_7609_a_continuation_is_read_as_an_init' depends on axioms: [propext, Quot.sound]
exit 0

>>> the wrong versions: each must be refused
fragment  the first continuation packet is numbered 1, not 0        refused in fragment_then_feed
fragment  continuation packets carry 58 bytes where feed reads 59   refused in feedAll_conts
fragment  BCNT loses its high byte                                  refused in feed_initPacket
feed      the expected sequence number never advances               refused in feedAll_conts
feed      the command keeps the init bit                            refused in feed_initPacket
both      MAX_MESSAGE is raised past CTAP-HID's 7609                refused in fragment_then_feed
```

There is no board half: nothing in this claim is on silicon.
