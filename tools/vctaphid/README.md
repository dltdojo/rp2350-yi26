# `vctaphid` — the board's half of CTAP-HID, with no board

```sh
cd tools/vctaphid && ./selftest.sh
```

That runs [`tools/ctaphid`](../ctaphid/)'s whole suite — every case where
CTAP-HID says what the right answer is — against a device that is a Unix socket
and `crates/ctap-hid`. No board, no USB, nobody in the room, about a second.

## What it is not, before what it is

**This is a pre-flight check. It is not a verification, and it is not
evidence about any board.**

It exercises two things: the decisions in
[`crates/ctap-hid`](../../crates/ctap-hid/), and the client that grades them. It
touches no `embassy-usb`, no RP2350 USB DPRAM, no enumeration, no timing and no
`hidraw`. So:

- Nothing it prints may be pasted into an experiment's `Expected output`.
- No experiment's `Needs` level moves because this passes.
- A passing run and a board are not substitutes. `main` still means somebody
  plugged one in and watched it work.

Every row the client emits carries a `transport` field (`hidraw` or `socket`)
so the two can never be confused after the fact.

## Why it exists

The suite's ten cases each cost a flash and a board. That is the right price
for grading a *firmware*. It is the wrong price for finding out that the suite
itself has a typo — and this repository has already paid it twice:

- [exp194](../../experiments/exp194-the-transport-that-drifted/) found **seven
  copies of this client**, six of them textually different, and the shared
  `drain()` that only one of them had.
- `wall.html` was written, shipped, and had **every one of its patterns wrong**
  — it looked for a string no build had ever printed. On a board that worked
  perfectly, the page would have sat on *waiting*.

Both are the same failure: a parser that has never seen real input is an
unverified claim in a file that looks like a tool.
[`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md) calls it
lever 4.

## What it answers, and what it borrows

Every answer comes out of the crate. `Transaction::feed` decides what an
arriving report means, `init_reply` builds the seventeen bytes, `fragment` cuts
a reply into reports. What is left in `main.rs` is the same three lines
`ctap_hid::board` leaves to a firmware — **which commands this device
implements** — because a second implementation of the transport would be
grading itself rather than the crate:

```rust
match cmd {
    CTAPHID_PING => send(stream, cid, CTAPHID_PING, &body[..n])?,
    _            => send(stream, cid, CTAPHID_ERROR, &[ERR_INVALID_CMD])?,
}
```

`INIT` advertises `0x08` (`CAPABILITY_NMSG`) and not `0x04` (`CBOR`), because
this device has no CBOR and [exp169](../../experiments/exp169-what-it-says-it-can-do/)
measured what claiming a capability a build does not have costs.
`--capabilities` exists so a firmware's dishonest claim can be imitated on
purpose.

## It can fail, and `selftest.sh` proves it every run

`--wrong bad-cid-par` makes the device answer `ERR_INVALID_PAR` on a channel it
never allocated, where the specification names `ERR_INVALID_CHANNEL`. That is
not an invented mistake: it is what exp194 measured
[exp189](../../experiments/exp189-the-same-salt-twice/) doing. The last check in
`selftest.sh` points the suite at it and fails if the verdict comes back
`spec`.

This is here because of exp160, which shipped a check that proved its verifier
could fail by corrupting a hex digit to `f` — in a capture whose digit was
already `f`. A replay is only worth what its own failure case is worth.

## Usage

```sh
vctaphid --socket /tmp/v.sock &                       # a correct device
vctaphid --socket /tmp/v.sock --wrong bad-cid-par &   # one measured mistake
python3 ../ctaphid/ctaphid.py --socket /tmp/v.sock init
python3 ../ctaphid/ctaphid.py --socket /tmp/v.sock ping 1025
```

| Flag | |
| --- | --- |
| `--socket PATH` | where to listen. An existing file at `PATH` is removed first. |
| `--capabilities 0xNN` | the byte `INIT` advertises. Default `0x08`. |
| `--wrong bad-cid-par` | answer one question the way exp189 answered it. |
| `--once` | serve one client and exit. |

The socket carries bare 64-byte reports in both directions — **no leading
report-number byte.** That zero is a Linux `hidraw` convention, added by the
client's own hidraw transport, and putting it here too would make the two
transports disagree about what a report is.

## Where this goes next

This covers the decisions and the client. The layer it cannot reach is
`embassy-usb` turning those decisions into packets on an endpoint, and the
host's real driver reading them.

That layer is reachable without a board too, and the route is measured rather
than guessed: `vhci-hcd` is in Ubuntu's own kernel packages and loads on a
machine with no USB hardware involved, so a userspace program can present
itself to the local kernel over USB/IP and be enumerated by the real
`cdc_acm`, `hidraw` and `libfido2`. What does not exist yet is the piece in
between — an `embassy_usb_driver::Driver` implementation over USB/IP. The
`usb-device` ecosystem has one and this repository does not use `usb-device`.

It still would not be a verification. It would move the line from *the
decisions are right* to *the decisions and the descriptors and the class
implementations are right*, and leave the silicon where it has always been.
