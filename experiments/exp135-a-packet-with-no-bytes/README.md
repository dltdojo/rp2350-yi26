# exp135-a-packet-with-no-bytes — ending a message a terminal cannot end

[exp128](../exp128-reassemble-by-hand/) found that a message whose length is an
exact multiple of 64 never completes: no short packet follows it, so a receiver
reassembling by hand waits forever and the *next* message is silently glued on.
It named the fix — a zero-length packet — and could not send one.

This experiment sends one. **No firmware of its own**: exp128 is the instrument,
because it already says out loud what it received.

| Sent | Terminator | What exp128 says |
| --- | --- | --- |
| 63 bytes | none needed | `msg #1: 63 bytes, 1 packet: 63` |
| 64 bytes | none | `+64 full packet, 64 held — the message may not be over` |
| 64 bytes | `--end` | `msg #2: 128 bytes, ended by a zero-length packet` |
| 65 bytes | none needed | `msg #3: 65 bytes, 2 packets: 64 1` |
| 128 bytes | none | `128 held` |
| 128 bytes | `--end` | `discarded; a message this long needs framing` |

Needs: a board running exp128, the udev rule for raw USB access, and
`yi26 detach`. No firmware to build.

## A terminal cannot send this packet, and that is the finding

`printf > /dev/ttyACM0` hands bytes to the kernel's `cdc_acm` driver, which
decides how to packetise them. Nothing anywhere in that path can say *and that
is the end of the message*. A zero-length packet is not a byte you can echo: it
is a **transfer with no bytes in it**, and only the program holding the
interface can submit one.

So `yi26 send --end` had to grow a second path — claim the CDC data interface
directly, exactly as a browser does — and `--end` therefore implies `--raw`:

```console
$ yi26 detach
$ yi26 send --end "$(printf 'X%.0s' $(seq 1 64))"
sent 64 bytes raw: 1 full packet(s) (endpoint packet size 64)
terminator: a zero-length packet was submitted
[    4942 ms]   +64 full packet, 128 held — the message may not be over
[    4942 ms] msg #2: 128 bytes, ended by a zero-length packet
```

This is worth pausing on, because it runs against the grain of everything else
here. [`tools/pages/README.md`](../../tools/pages/README.md) lists eight things
`yi26` can do that a browser page cannot. This is the first one the other way:
**the page could always have done it**, because WebUSB has never had a tty in
the way, and the command-line tool had to give up its serial port to catch up.

## The line that had never run

exp128's firmware contains this, at `src/main.rs:237`:

```rust
log!("msg #{}: {} bytes, ended by a zero-length packet", seq, held);
```

Written, verified, pushed, and documented — and **no measurement had ever
produced it**. The receiving half was finished six experiments ago; what was
missing was any host that could speak the other half. exp128's own `Next`
section promised the measurement as "exp129", and exp129 turned out to be a
prize draw.

A code path with no way to reach it is not tested by the experiment that ships
it. That is the general lesson, and this repository had one in plain sight.

## The row two libraries disagree about

Sending *nothing at all* is the sharpest case, and it is where independent
prior work on this machine and `nusb`'s own source say opposite things:

- an earlier census, taken through a different host library, recorded a
  zero-length request as **0 packets, nothing on the wire**;
- `nusb`'s `submit_end` documents the opposite in as many words — *if the
  buffer is empty, this sends a zero-length packet*.

Measured here, through `nusb`, against exp128:

```text
$ yi26 send --raw            # no payload at all
sent 0 bytes raw: 1 zero-length packet (endpoint packet size 64)
[   63451 ms] zero-length packet — nobody sent it
```

It arrives. So this is **a property of the host library, not of the bus** — one
of the two drops the request before it becomes a URB. That distinction matters
more than the row itself: "USB does X" and "the library I used does X" are
different claims, and a census that does not say which one it measured is not
reusable by anybody on a different stack.

It also makes exp128's wording wrong in one case. `zero-length packet — nobody
sent it` is right about the startup artefact and wrong here: somebody did send
it, deliberately. The line stays as it is, because exp128 is finished and the
capture that contradicts it lives here.

## The rule for when a terminator is added

Both implementations use the same one, and it is not "always":

> Append a zero-length packet only when the payload's length is a **non-zero
> multiple** of the endpoint's packet size.

Any other length already ends in a short packet. A terminator after *that*
would not be redundant — it would arrive as an **empty message**, which a
receiver has to interpret, and interpreting it is a decision nobody asked for.
`yi26` says which of the three cases it took, every time:

```text
terminator: a zero-length packet was submitted
terminator: none — this message has no short packet to end it (try --end)
terminator: none needed — the last packet is already short
```

## What this does not conclude

**Not "use zero-length packets for framing."** Independent prior work on this
machine evaluated exactly that for a real protocol carrying signed
transactions, and **rejected it** — keeping an explicit frame layer instead.
The reasons were not about the bus:

- three implementations of the protocol had to stay in agreement, and a
  transport-dependent boundary would have forked them into six half-versions;
- byte-identical frames were what made a transport comparison testable at all;
- the deframer already handled chunking and resynchronisation.

So a transfer boundary is real, cheap, and still not a good place to put your
protocol's message boundary. The terminator is a fix for *this* firmware's
buffer; it is not a framing layer, and the difference is the whole of the
[framing road](../README.md#planned).

## The code IS the walkthrough

- [`../../tools/yi26/src/board.rs`](../../tools/yi26/src/board.rs) —
  `cdc_raw_send`: claim the interface, the two control transfers a browser also
  performs, then the transfers.
- [`../../tools/pages/console.html`](../../tools/pages/console.html) — the same
  rule in the browser, reading `packetSize` off the descriptor.
- [`../exp128-reassemble-by-hand/src/main.rs`](../exp128-reassemble-by-hand/src/main.rs)
  — the receiver, unchanged.

## Two ways to do it

```sh
./run.sh      # guided: the whole census, one case at a time
./check.sh    # verdict: four cases, detaching and re-attaching around itself
```

## Expected output

Captured from a Pico 2 running exp128. `./check.sh`:

```text
PASS  toolchain present (cargo)
PASS  yi26 can claim the CDC data interface and submit transfers itself
PASS  console.html can end a message too (the browser half of the census)
PASS  yi26 appends the terminator only when the length calls for it
PASS  console.html uses the same rule, read off the descriptors
PASS  the CDC interfaces are detached (an interface has exactly one owner)
PASS  63 bytes completes on its own — the last packet is already short
PASS  64 bytes does NOT complete — nothing follows it that means 'over'
PASS  64 bytes WITH --end completes, ended by a zero-length packet
PASS  a lone zero-length transfer reaches the device (nusb submits it)
```

The two cases that hurt, side by side:

```text
===== 128 bytes --raw
terminator: none — this message has no short packet to end it (try --end)
[    9663 ms]   +64 full packet, 64 held — the message may not be over
[    9663 ms]   +64 full packet, 128 held — the message may not be over

===== 128 bytes --end
terminator: a zero-length packet was submitted
[   11852 ms]   +64 full packet, 192 held — the message may not be over
[   11852 ms]   discarded; a message this long needs framing, not a bigger buffer
```

The second one had a terminator and still lost the message, because the *first*
one was still buffered: 128 held plus 64 more is past exp128's cap. **One
unterminated message poisons the next**, and no terminator on the later message
can undo it. That is the cost of a boundary that lives in the transport instead
of in the protocol, stated as a measurement.

## What is not verified here

**The browser row.** Whether Chrome puts the same packet on the wire for
`transferOut(ep, new Uint8Array(0))` has not been measured. The page can now
ask — `tools/pages/console.html` has the checkbox and a *Send 64 bytes* button —
and doing it needs a person, a permission dialog and an eye on the log.

It is not a formality. WebUSB is a different host stack from `nusb`, and the
row above is precisely the kind that differs between stacks.

## Make it yours

1. Send 64 bytes without `--end`, then send `z`. The one-byte message completes
   the *previous* one as 65 bytes. That is the silent merge exp128 warned about,
   and you just used it as a reset.
2. Send with `--end` twice in a row against a 63-byte payload. The rule refuses
   to add a terminator either time — work out from the code why adding one
   anyway would be worse than useless.
3. Do the same census from `console.html` and fill in the missing row. If Chrome
   and `nusb` disagree, that is a finding worth a paragraph here.
4. Change exp128's cap and repeat the 128-byte `--end` case. The message stops
   being discarded, which feels like a fix and is not: raise it enough and the
   buffer is just a slower way to lose.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `interface N is held by something else` | `cdc_acm`, or a browser tab | `yi26 detach`; `yi26 doctor` names a tab |
| Nothing in the log at all | Raw mode asserts DTR itself — if it did not, the firmware would never write | Check the board is running exp128: `yi26 port --json` |
| `unknown option: --raw` | An installed `yi26` older than this checkout | The scripts now build and use the checkout's copy; if you typed it yourself, `cargo install --path tools/yi26` again |
| The counts look off by one message | A previous unterminated message is still buffered | Send one short packet to flush, which is what `check.sh` does between cases |

## Next

The framing road, which this experiment has now cleared the ground for: a
boundary that lives in the protocol rather than in the transport, judged on
whether it can resynchronise. Under [Planned](../README.md#planned).
