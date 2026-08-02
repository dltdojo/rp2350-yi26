# exp118-one-receiver-two-jobs — the firmware starts listening

Every experiment so far has talked **at** the host. This one listens: the host
sends bytes, the firmware prints exactly what arrived, and the round trip
finally closes.

Nothing about the device changes to allow it. exp115's descriptor tree already
listed `endpoint 0x02 OUT bulk 64 bytes`, and every firmware here has had one
since exp104. **The endpoint was always there. Nobody read it.**

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## The obstacle is ownership

The obvious design is exp107's — add a task that reads. It does not work, and
the reason is the experiment.

`CdcAcmClass::split_with_control()` hands out three pieces:

| Piece | Can do | Was going to |
| --- | --- | --- |
| `Sender` | `write_packet`, `line_coding`, `dtr` | `usb_log::run` |
| `Receiver` | `read_packet`, `line_coding`, `dtr` | `usb_reboot::watch` |
| `ControlChanged` | `control_changed`, `dtr` | `usb_reboot::watch` |

Look at what `ControlChanged` cannot do: **read the line coding.** The
1200-baud reboot from exp105 has to know the host's baud rate, which is why
`usb_reboot::watch` takes the `Receiver` — not to read from it, only to ask it
a question. That was free while nothing else wanted the OUT endpoint.

It is not free now. `read_packet` needs `&mut Receiver`, and there is exactly
one `Receiver`:

- give it to a reader task → the reboot watcher goes blind, the 1200-baud
  touch stops working, and the board can only be reflashed by a human holding
  BOOTSEL;
- leave it with the watcher → nothing can listen.

So one task has to do both, which means waiting on two things at once. That is
`select`, and it arrives here as a **consequence**, not as a feature being
shown off. This is the first firmware in the repository whose shape was
decided by ownership rather than taste.

## `select` drops the loser, and that had to be checked

`select` returns as soon as either future finishes and drops the other one
unfinished. Whether that costs anything deserves an answer rather than a hope,
because being wrong about the control side means a board that cannot be
reflashed.

`embassy-usb` stores the event in a latching flag, cleared only when somebody
observes it:

```rust
if self.changed.load(Ordering::Relaxed) {
    self.changed.store(false, Ordering::Relaxed);
    Poll::Ready(())
}
```

A dropped `control_changed()` future never observes the flag, so the flag stays
set and the next poll returns immediately. **A reboot request cannot be lost by
cancellation.** That was read out of the dependency's source before any of this
was flashed, and then confirmed on the board — step 5 of `run.sh` reboots from
inside the select loop.

The read side has no such answer yet, and this experiment does not pretend
otherwise. Every entry carries a sequence number so a gap would be visible;
measuring it is exp119.

## A message is not a thing USB has

This is the part worth staying for. A hundred bytes, sent once, arrive as
**two**:

```text
in #2: 64 bytes
in #3: 36 bytes
```

One `write` on the host, two `read_packet`s on the device. The host's USB stack
cuts the transfer into packets of the endpoint's size — the 64 that
`CdcAcmClass::new` was given — and hands the firmware the pieces. There is no
length prefix and no delimiter, because a bulk endpoint carries neither.

Any firmware that wants *messages* has to define what one is and reassemble
them itself. This one does not, and prints what actually arrived. The counter
is called `PACKETS` for the same reason.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — one `select` loop, a hex dump, and two
  atomics. The module documentation carries the ownership argument in full.
- [`crates/usb-reboot`](../../crates/usb-reboot/src/lib.rs) — gained
  `reboot_if_requested`, so the delicate 250 ms-then-reset sequence exists once
  in this repository rather than once per experiment that wants to listen.
  `watch` is now that function plus a loop, and its signature did not change.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, send things, watch a packet split in half
./check.sh    # verdict: builds, then sends real bytes and checks the report
```

## Talking to the board

```sh
yi26 send hello                  # bytes, then three seconds of listening
yi26 send 'A\x00\xff\ttab\r\nZ'  # \n \r \t \0 \\ and \xNN all reach the wire
yi26 send --explain hello        # why this is one command and not two
```

Send and listen are one command on purpose. Opening a CDC-ACM port asserts DTR
and closing it drops DTR, and `crates/usb-log` will not write a line while DTR
is low. So `printf > /dev/ttyACM0` followed by a separate `cat` closes the port
in between, and the firmware's answer lands in the gap where nobody is
listening. One open handle, no gap.

The rate is always 115200 and cannot be given. 1200 is exp105's reboot signal,
and a send command that took a baud rate would let a typo reset the board.

## Expected output

Captured from a real Pico 2 on Ubuntu, flashed and then sent to:

```text
[      37 ms] exp118 up. The OUT endpoint has a reader for the first time.
[      37 ms] zero-length packet — not counted, nobody sent it
[     149 ms] control: 8000 baud, DTR off
[     264 ms] control: 8000 baud, DTR off
[     395 ms] control: 9600 baud, DTR off
[    2437 ms] control: 9600 baud, DTR on
[    2437 ms] control: 115200 baud, DTR on
[    5037 ms] idle: nothing received yet — try  yi26 send hello
[    9447 ms] control: 115200 baud, DTR off
[    9455 ms] control: 115200 baud, DTR on
[    9455 ms] in #1: 5 bytes
[    9456 ms]   0000  68 65 6c 6c 6f                                   hello
[   10037 ms] idle: 1 packet, 5 bytes received so far
[   12644 ms] control: 115200 baud, DTR off
[   12656 ms] control: 115200 baud, DTR on
[   12656 ms] in #2: 64 bytes
[   12656 ms]   0000  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms]   0010  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms]   0020  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms]   0030  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms] in #3: 36 bytes
[   12657 ms]   0000  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms]   0010  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[   12657 ms]   0020  41 41 41 41                                      AAAA
[   15037 ms] idle: 3 packets, 105 bytes received so far
```

And the ten-byte send, which is the one that proves nothing was altered on the
way:

```text
[   11050 ms] in #2: 10 bytes
[   11050 ms]   0000  41 00 ff 09 74 61 62 0d 0a 5a                    A...tab..Z
```

`A`, NUL, `0xff`, TAB, `tab`, CR, LF, `Z`. Ten bytes in, ten bytes out, and
only six of them survive being printed as characters. The hex column is the
fact; the text column is an interpretation of it, which is why the dump shows
both and puts the hex first.

## What the log is telling you

**`control:` lines say why the task woke.** `control_changed()` fires for DTR,
RTS *or* the line coding and does not say which, so the firmware reads the
state and reports it — "something changed" is not a debugging aid. The pair at
9447 and 9455 ms is one `yi26 send`: the previous port closing, then this one
opening and setting 115200.

**8000 baud is not a typo.** It is `embassy-usb`'s default line coding, visible
until the first host that bothers to set one.

**The zero-length packet at 37 ms.** `read_packet` returns `Ok(0)` once, before
the host has asserted DTR — so before anything could have opened the port, let
alone typed into it. It is the endpoint completing empty as it is enabled, not
somebody sending nothing.

Counting it as a message cost nothing visible and broke something invisible:
every sequence number afterwards was one too high. exp119's entire question is
whether a gap in those numbers means a lost packet, and a counter that starts
by miscounting cannot answer it. The first version of this firmware got that
wrong, and the log said `in #1: 0 bytes` in a way that looked like a feature.

## Make it yours

1. Echo it back. `Sender` belongs to `usb_log::run`, so the reply has to go
   through `log!` — or you have to decide the logger no longer owns the
   writing half, which is this experiment's argument again from the other end.
2. Reassemble messages: buffer until a `\n` arrives, then act. You will need a
   rule for a line longer than your buffer, and that rule is the whole of what
   "framing" means.
3. Make one byte do something — `t` for a temperature reading from exp108.
   Notice that the heartbeat keeps running while you wait, and ask yourself
   what would happen if answering took most of a second. exp110 has the
   measurement.
4. Set `ROW` to 8 and watch the dump reflow. Then set it to 32 and watch lines
   truncate with `...`, because `usb_log::LINE_CAPACITY` is 96 and the
   timestamp already spent thirteen of them.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `no board running one of these firmwares` | Nothing flashed, or it is in BOOTSEL | `yi26 doctor` |
| `Permission denied` right after flashing | udev has not tagged the new node yet | Wait a second and retry |
| Sent 100 bytes, saw two entries | Working exactly as described | Not a fault — read the section above |
| Nothing appears, but `idle:` lines do | The bytes went somewhere else | `yi26 send` writes to the port `yi26 port` prints; check it is this board |
| The first send after a long silence shows stale lines | `usb-log` holds 16 lines and flushes them when DTR returns | Read for a second first; `check.sh` does exactly that |

## Next

**[exp119](../exp119-cancelled-reads/)** answers the question this one left
open: when `select` drops a `read_packet` that was already in flight, does a
packet die with it? It cancels twenty thousand reads on purpose and counts.

The answer is no, and the reason turns out to be a *different* one from the
reason a cancelled `control_changed()` is safe — hardware state in one case,
a software latch in the other. Which is why it had to be measured rather than
inferred from this experiment.
