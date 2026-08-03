# exp128-reassemble-by-hand — a message is not a thing USB hands you

exp118 printed what arrived and refused to call it a message: a hundred bytes
written once came back as `64` and then `36`. exp127 dodged the problem by
making its commands one byte long, and was explicit that one byte needs no
framing only because one is smaller than 64.

This one pays the bill. The host writes a message of any length and the
firmware puts it back together, so this line can finally be printed honestly:

```text
msg #2: 100 bytes, 2 packets: 64 36
```

Nothing about the device changed to allow it. The descriptors are still
exp115's, and the byte still travels on `endpoint 0x01 OUT bulk 64 bytes` —
the same endpoint every firmware here has had since exp104. What changed is
that somebody decided where a message ends.

Needs: any RP2350 board, and the exp102 toolchain. No browser, and nobody in
the room.

## The boundary was on the wire, and the class threw it away

It is worth being exact, because "USB has no messages" is a half-truth that
sends people to build length prefixes they did not need.

A bulk transfer ends at the **first packet shorter than `wMaxPacketSize`**.
The host controller puts it there, the device sees it, and no guessing is
involved. `embassy-usb-driver` even has a method for exactly this, whose
default implementation is four lines:

```rust
// embassy-usb-driver-0.2.2/src/lib.rs:273
async fn read_transfer(&mut self, buf: &mut [u8]) -> Result<usize, EndpointError> {
    let mut n = 0;
    loop {
        let i = self.read(&mut buf[n..]).await?;
        n += i;
        if i < self.info().max_packet_size as usize {
            return Ok(n);
        }
    }
}
```

**`CdcAcmClass`'s `Receiver` does not expose it.** Its entire read surface is
`read_packet`, which forwards one packet and nothing else:

| Holding this | Can call | Experiment |
| --- | --- | --- |
| A raw `EndpointOut` | `read`, **and `read_transfer`** | exp122's vendor interface |
| A CDC `Receiver` | `read_packet` only | exp118, exp127, and this one |

That is not an oversight. CDC-ACM presents a serial port; RS-232 has no
message boundaries; so the class discards the one the wire underneath it was
carrying. The loop in [`src/main.rs`](./src/main.rs) is that discarded
boundary, put back by hand.

`Receiver::into_buffered` is not the way out either, despite the name. Its own
documentation says it exists so a caller can read **fewer** bytes than a
packet, for `embedded_io_async::Read`. It turns packets into a byte stream
with no boundaries at all — further from a message, not closer.

## The message that never arrives

A message whose length is an exact multiple of 64 has no short packet to end
it. This firmware waits, and the **next** message is appended to the one
already buffered.

That is measured, not feared. Against exp118, on the machine this was written
on:

```text
yi26 send <64 bytes>    →  in #1: 64 bytes          (and nothing else)
yi26 send <128 bytes>   →  in #2: 64 bytes
                           in #3: 64 bytes          (and nothing else)
```

No zero-length packet followed either one. The host had no reason to send one:
it wrote exactly what it was asked to write.

So this firmware does two things rather than pretending. It **says out loud**
every time it takes a full packet and cannot know whether the message is over,
and it **caps** the buffer instead of growing forever — announcing that as a
loss, because a firmware that quietly drops a message is the failure this
repository keeps finding.

Making a 64-byte message arrive is a fix with a name — a zero-length packet,
described in `embassy-usb`'s own CDC docs — and measuring it is exp129.

## One case that looks like a bug and is not

`read_packet` returning 0 means two entirely different things:

| When | What it is | What this firmware does |
| --- | --- | --- |
| Nothing buffered | The endpoint completing empty as it is enabled — exp118 settled this, and nobody sent it | Reports it, counts nothing |
| Mid-message | A real **zero-length packet**, which is shorter than 64 and therefore ends the message | Completes the message and says so |

The second case is the terminator this experiment says nothing provides. It is
handled, and it has never fired here — which is the whole of exp129 in one
sentence.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp118's select loop, with the accumulator
  that turns packets back into messages and the two states it can be caught in.

## Two ways to do it

```sh
./run.sh      # guided: watch 100 bytes become one message, then watch 64 fail
./check.sh    # verdict: six lengths, including the one that must NOT complete
```

## Expected output

Captured from a Pico 2. `yi26 log --seconds 7` straight after flashing:

```text
[      37 ms] exp128 up. A message ends at the first packet under 64 bytes.
[      37 ms] zero-length packet — nobody sent it
[     155 ms] control: 8000 baud, DTR off
[     270 ms] control: 8000 baud, DTR off
[     401 ms] control: 9600 baud, DTR off
[     415 ms] control: 9600 baud, DTR on
[     416 ms] control: 115200 baud, DTR on
[     416 ms] control: 115200 baud, DTR off
[     422 ms] control: 115200 baud, DTR on
[    5037 ms] idle: nothing yet — try  yi26 send hello
```

Ten bytes, then a hundred — the line exp118 could not print:

```text
[    3509 ms] msg #1: 10 bytes, 1 packet: 10
[   15636 ms]   +64 full packet, 64 held — the message may not be over
[   15636 ms] msg #2: 100 bytes, 2 packets: 64 36
[   15636 ms]   AAAAAAAAAAAAAAAAAAAAAAAA...
```

Two hundred, and then the cap at 256:

```text
[   18655 ms]   +64 full packet, 64 held — the message may not be over
[   18655 ms]   +64 full packet, 128 held — the message may not be over
[   18655 ms]   +64 full packet, 192 held — the message may not be over
[   18655 ms] msg #3: 200 bytes, 4 packets: 64 64 64 8
[   37898 ms]   +64 full packet, 64 held — the message may not be over
[   37898 ms]   +64 full packet, 128 held — the message may not be over
[   37898 ms]   +64 full packet, 192 held — the message may not be over
[   37898 ms] buffer full at 256 bytes — no short packet ever came
[   37898 ms]   discarded; a message this long needs framing, not a bigger buffer
```

Exactly 64 bytes. There is no `msg #` line, because there is no short packet:

```text
[   50854 ms]   +64 full packet, 64 held — the message may not be over
[   55037 ms] idle: 64 bytes held, waiting for a packet under 64
[   55037 ms]   send anything short and it will complete — wrongly
```

And what that costs — five more bytes, sent as a message of their own:

```text
[   58055 ms] msg #4: 69 bytes, 2 packets: 64 5
[   58055 ms]   DDDDDDDDDDDDDDDDDDDDDDDD...
```

**69 bytes.** The second message was not lost, it was merged, and the firmware
can no longer tell there were two. That is worse than a hang, because a hang
is visible.

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  compiles (147396 byte ELF)
PASS  converts to UF2 (47616 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (the board can still be reflashed)
PASS  every endpoint address cited here appears in exp115's captured tree
PASS  board is running exp128
PASS  10 bytes arrive as one message in one packet
PASS  100 bytes arrive as ONE message, from packets of 64 and 36
PASS  a full packet is reported as undecided, not silently held
PASS  200 bytes arrive as one message from four packets
PASS  an over-long message is discarded loudly, not quietly
PASS  a 64-byte message does not complete: no short packet ever arrives
PASS  the wait is visible in the idle line, not silent
PASS  the next message is merged into the stuck one — 64 + 5 became 69
NOTE  the 69-byte message above is the bug this experiment hands to exp129
```

The 1200-baud reboot still works: `yi26 bootsel` put the board in BOOTSEL and
`yi26 flash` brought it back, with no hand on a button.

## What the log is telling you

- **`msg #2: 100 bytes, 2 packets: 64 36`.** The sizes are the evidence, not
  decoration. exp118 reported this same write as two separate events; only the
  responsibility for noticing the end moved.
- **`+64 full packet, N held`.** Printed every time, because a firmware that
  went quiet here would look identical to one that had lost the packet.
- **The order of checks in `check.sh` is load-bearing.** Everything before the
  trap leaves the buffer empty; the trap deliberately leaves 64 bytes in it,
  and the test after it is what clears them.

## Make it yours

1. Send 65 bytes and then 63. Both complete; work out why before running it.
2. Raise `MESSAGE` to 1024 and send 1024 bytes. The cap moves, the trap does
   not — 1024 is a multiple of 64 too. A bigger buffer was never the fix.
3. Delete the `+64 full packet` line and use the firmware for a minute. The
   difference between "waiting" and "broken" disappears, which is the argument
   for that line existing.
4. Make the host send a terminating zero-length packet. `yi26 send` does not
   have a flag for it today — finding out what would need to change is the
   first half of exp129.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Every message is 64 bytes too long | A 64-byte message is still buffered from an earlier send | Send 256 bytes to trip the cap, or replug the board |
| `msg #` never appears | The message length is a multiple of 64 | That is the experiment — see above |
| A 64-byte message *does* complete on your machine | Your host's USB stack appends a zero-length packet; this one does not | Report it. It changes what exp129 has to measure |
| Nothing in the log at all | `cdc_acm` has the port, or a browser does | `yi26 attach`, then `yi26 log` |

## Next

**exp129** — the zero-length packet. `embassy-usb`'s CDC documentation states
the rule for the IN direction in its own source: a packet of exactly
`max_packet_size` is not delivered until something shorter follows, and a ZLP
is what you send when there is nothing shorter to send. This experiment shows
the OUT direction has the same shape and no such terminator arriving.

The rest of the road is under [Planned](../README.md#planned).
