# exp127-host-owns-the-led — one byte changes the board

exp118 taught the firmware to listen and then printed what arrived. It stopped
deliberately: bytes went in, a hex dump came out, and the board itself was
unchanged by anything the host said.

This one lets the host change it. Send `0x01` and the LED comes on, `0x00` and
it goes off. That is the entire protocol, and it is the first time in this
repository that **a host owns a piece of the device's state** rather than
observing it.

Nothing about the device changes to allow that, again. The OUT endpoint that
carries the byte is `endpoint 0x01 OUT bulk 64 bytes` from exp115's descriptor
tree — the same one exp118 read and every firmware here has had since exp104.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## Two commands, and the third thing that happens

| Sent | Bytes | What the firmware does |
| --- | --- | --- |
| `yi26 send '\x01'` | `01` | LED on, and reports the pad |
| `yi26 send '\x00'` | `00` | LED off, and reports the pad |
| `yi26 send 'A'` | `41` | Refuses, names the byte, lists the two commands |
| `yi26 send 'led on'` | `6c 65 64 20 6f 6e` | Refuses **all six bytes** — see below |

## Why one byte needs no framing, and what that is hiding

exp118 established that USB delivers packets, not messages: a hundred bytes
written once arrive as `64` and then `36`. Any firmware that wants messages has
to define what one is and reassemble them itself.

This firmware does not have that problem, and it is worth being exact about
why, because it is easy to mistake for *USB is simple after all*:

> A one-byte command cannot be split, because the endpoint's packet size is 64
> and one is less than 64.

The framing problem has not been solved here. It has been **avoided by staying
underneath `wMaxPacketSize`**. That is a legitimate design — plenty of shipped
devices do exactly this — but it is a dodge, and calling it one now is cheaper
than discovering it later.

Which is why `led on` is refused rather than parsed. Six bytes are not a
command with a typo; they are a message this protocol cannot delimit. Acting on
the first byte would make `led on` mean `0x6c`, and turn a typo into a state
change.

## Where message boundaries come from

The question every reader asks next is *does this apply to SPI?* It does not,
and the reason is the most useful thing in this experiment. Every bus solves
framing, but they put the answer in different places:

| Bus | Where the boundary lives | Needs in-band framing? |
| --- | --- | --- |
| **SPI** | A **dedicated wire**. CS low starts the frame, CS high ends it. | No — a whole pin exists for this |
| **I²C** | **Electrical states on the bus**: START and STOP are SDA transitions while SCL is high, which no data byte can produce | No |
| **CAN** | The **frame is the hardware unit** — ID, up to 8 data bytes, CRC, ACK slot | No, until a message exceeds 8 bytes; then ISO-TP 15765-2 segments and reassembles |
| **USB bulk** | The **protocol layer**: a transfer ends at the first packet shorter than `wMaxPacketSize` | No — but see the trap below |
| **UART / RS-232** | **Nowhere.** It is a byte stream and nothing more | Yes, always |
| **CDC-ACM** | Nowhere — *and this is the interesting one* | Yes |

CDC-ACM is the case worth staring at. Underneath it is USB bulk, which **does**
have boundaries. On top it presents a serial port, which does not. The
abstraction throws the information away on purpose, because RS-232 had nothing
to map it onto — and that discarded boundary is precisely what exp118 saw
leaking through as `64 + 36`.

So the split is not "some buses are easier". It is:

> **Is the boundary carried by something other than the data?** A wire, a bus
> state, or a protocol layer — or must the data carry it itself?

### What people put in the data when they have to

Every one of these exists because UART had no answer. The two columns that
actually separate them:

| Scheme | Used by | Resync from mid-stream? | Overhead |
| --- | --- | --- | --- |
| Newline-delimited | AT commands, NMEA 0183 | Yes — but data cannot contain a newline | 1 byte |
| **SLIP** (RFC 1055) | Serial IP, embedded links | Yes — `0xC0` is a sentinel | Up to **2×** worst case |
| **COBS** | Modern embedded links | Yes — `0x00` appears only at boundaries | **Bounded**: ≤ ⌈n/254⌉ |
| **HDLC / PPP** (RFC 1662) | Telecom, PPP | Yes, plus a CRC | Flag + escapes + CRC |
| **Length prefix / TLV** | Almost everything | **No** — miss one length and you never realign | 1–4 bytes |
| **Modbus RTU** | Industrial serial | Yes — via a 3.5-character silence | Zero bytes, but costs *time* |

Two of those rows are the lesson. **COBS beats SLIP** not because it is
cleverer but because its overhead has an upper bound. And **length-prefix is
the one everybody reaches for first and the only one that cannot recover** —
lose sync once and every subsequent length is read out of the middle of a
payload.

Modbus RTU is the odd one out on purpose: its boundary is neither in the data
nor on a wire. It is a gap in time. A third answer to the same question.

**None of the non-USB rows are verified here** and they never will be. SPI or
I²C framing needs two pins wired together — either a loopback on one board or
two boards on one bench — and this repository holds to a board and a USB cable
and nothing else ([Boards](../README.md#boards)). That is a decision rather
than a shortage, and it was taken deliberately: adding jumper wires would
change what a reader has to own in order to follow along, which costs more
than the comparison is worth. The table is a map, not a result.

## The LED cannot be two things at once

Every firmware here since exp103 blinks the LED as a heartbeat, and that blink
has been doing real work: it is how you know the board is alive without opening
a terminal.

The moment the host can turn the LED off, that stops being true. A dark LED
now means one of:

- you turned it off,
- the firmware crashed,
- the firmware never started,

and **nothing on the board can tell you which**.

This is not a wart in the design. It is what happens whenever a status
indicator and a controllable output are the same resource, and it happens in
shipped products constantly.

This firmware does not dodge it. The heartbeat runs until the first command
arrives and then stops for good — and the log takes over the job:

```text
idle: led off, host-owned after 2 commands (0 refused)
  this line is now the only proof the firmware is alive
```

It repeats every five seconds rather than being printed once, because the
person who needs it is the one who arrives *after* the LED went dark.

## The register that would have lied

"The firmware says `led on`" proves a byte was received and a branch was taken.
It proves nothing electrical. The RP2350 offers two different answers, and the
difference is the point:

| Register | Answers | embassy-rp |
| --- | --- | --- |
| `SIO GPIO_OUT` | What I last wrote | `Flex::is_set_high()`, `Output::get_output_level()` |
| `SIO GPIO_IN` | What the pad is at | `Flex::is_high()` |

`Output` exposes only the first. It cannot fail in any interesting way — it
hands back the value that was just stored, so a log line built from it is the
command rephrased, not evidence about it.

`GPIO_IN` is the pad. Reading it back on an **output** pin works because
`Flex::new` turns the input buffer on unconditionally:

```rust
// embassy-rp-0.10.0/src/gpio.rs:619
pin.pad_ctrl().write(|w| {
    w.set_iso(false);
    w.set_ie(true);      // <- input enabled, even for outputs
});
```

That is the whole reason this firmware is the first here to use `Flex` where
every experiment before it used `Output`. One substitution, and the difference
is between a log that repeats itself and a log that has checked.

One detail that is easy to get wrong: `GPIO_IN` is sampled through a
two-flip-flop synchroniser, so a store followed immediately by a load can read
the **old** level and print `OUT high, pad low` — a hardware fault that did not
happen. The firmware waits 64 cycles first, which is ~400 ns at 150 MHz.

### And it still does not prove the LED lit

An unpopulated LED, a dead one, or a board that wires its LED to a different
GPIO all read back exactly like success. `check.sh` says so on every run rather
than letting sixteen green PASS lines imply otherwise:

```text
NOTE  the pad is checked; whether the LED lit is a question for an eye
```

That last gap closes with a person looking at the board, and with nothing else.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp118's select loop with a third branch,
  and the one line that chooses `Flex` over `Output`.

The third branch is why this is still one task and not two. exp118 gave the
`Receiver` to a single task because there is exactly one of it; there is also
exactly one LED, and the heartbeat wants it as much as the command handler
does. `select3` is what that costs.

## Two ways to do it

```sh
./run.sh      # guided: flash, take the LED, watch what you gave up
./check.sh    # verdict: sends both commands and checks the pad followed
```

## Expected output

Captured from a Pico 2, `yi26 log --seconds 8` straight after flashing:

```text
[      37 ms] exp127 up. The LED is the firmware's until the host takes it.
[      37 ms] zero-length packet — nobody sent it
[     147 ms] control: 8000 baud, DTR off
[     262 ms] control: 8000 baud, DTR off
[     392 ms] control: 9600 baud, DTR off
[     419 ms] control: 9600 baud, DTR on
[     419 ms] control: 115200 baud, DTR on
[     419 ms] control: 115200 baud, DTR off
[    5037 ms] idle: heartbeat, no command yet — try  yi26 send '\x01'
[    5325 ms] control: 115200 baud, DTR on
[   10037 ms] idle: heartbeat, no command yet — try  yi26 send '\x01'
```

Then `yi26 send '\x01'` and `yi26 send '\x00'`:

```text
[   18743 ms] control: 115200 baud, DTR on
[   18743 ms] cmd #1: 0x01 led on (OUT high, pad high)
[   18743 ms] heartbeat stopped — the LED is the host's now
[   20037 ms] idle: led on, host-owned after 1 command (0 refused)
[   20037 ms]   this line is now the only proof the firmware is alive
[   21849 ms] control: 115200 baud, DTR on
[   21849 ms] cmd #2: 0x00 led off (OUT low, pad low)
```

`yi26 send 'A'` and `yi26 send 'led on'` — the two refusals:

```text
[   32672 ms] 0x41 is not a command (refused 1)
[   32672 ms]   0x00 = off, 0x01 = on. Nothing else.
[   35037 ms] idle: led off, host-owned after 2 commands (1 refused)
[   35037 ms]   this line is now the only proof the firmware is alive
[   35851 ms] 6 bytes in one packet — one byte per command here
[   35851 ms]   nothing reassembles them; that needs framing
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  compiles (147592 byte ELF)
PASS  converts to UF2 (47104 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (the board can still be reflashed)
PASS  the LED is a Flex, so the pad can be read back
PASS  the readback reads GPIO_IN (led.is_high), not just GPIO_OUT
PASS  every endpoint address cited here appears in exp115's captured tree
PASS  board is running exp127
PASS  0x01 was accepted as a command
PASS  the pad reads high after 0x01
PASS  0x00 was accepted as a command
PASS  the pad reads low after 0x00
PASS  OUT and the pad agree on every command
PASS  an unknown byte is refused and named
PASS  a multi-byte packet is refused, not partly obeyed
PASS  the idle line reports host ownership and keeps repeating
NOTE  the pad is checked; whether the LED lit is a question for an eye
```

And the part no script produced, which is the only reason the pad readback is
worth trusting: **the LED was watched. It blinked after flashing, went solid on
at `0x01`, and went dark at `0x00`.**

The 1200-baud reboot also still works from the three-way select — `yi26
bootsel` put the board in BOOTSEL and `yi26 flash` brought it back, with no
hand on a button.

## What the log is telling you

- **`zero-length packet — nobody sent it` at 37 ms.** exp118 established what
  this is: the endpoint completing empty as it is enabled, before any host
  could have typed anything. It is not counted as a command or as a refusal.
- **The `control:` lines before anything is sent.** That is the host's serial
  stack probing the port — exp118's territory, and the reason the 1200-baud
  watcher has to stay in this loop.
- **`(OUT high, pad high)`.** Two registers, always both. Printing only the pad
  would leave a disagreement unattributable; printing only `OUT` would be
  exp103 with extra words.
- **`heartbeat stopped` appears exactly once**, at the moment it becomes true.
  Everything afterwards is the idle line's job.

## The same thing, from a browser

`yi26 send '\x01'` needs a toolchain. A phone has neither, and this is the
first experiment whose command cannot be *typed*: the byte that turns the LED
on is not a character anybody's keyboard produces.

[`tools/pages/console.html`](../../tools/pages/) closes that. It takes the same
six escapes `yi26 send` does, and shows what is about to go on the wire before
it goes — `\x01` previews as one byte, `01`, and `1` previews as one byte,
`31`. Captured from a Pico 2 running this firmware, with the page open in
Chrome on the desktop and the log read through the page's own CDC stream:

```text
[  321382 ms] cmd #3: 0x01 led on (OUT high, pad high)
[  325039 ms] idle: led on, host-owned after 3 commands (2 refused)
[  327191 ms] cmd #4: 0x00 led off (OUT low, pad low)
[  330039 ms] idle: led off, host-owned after 4 commands (2 refused)
[  338874 ms] 0x31 is not a command (refused 3)
[  338874 ms]   0x00 = off, 0x01 = on. Nothing else.
```

The LED came on and went off, watched by a person, which is the only place that
can be checked. The third line is the one worth typing yourself: the page sent
the character `1`, the firmware received `0x31`, and it refused — the same
answer `yi26 send 1` gets, from the same firmware, because the two sides agree
on what an escape means.

Until this page existed no browser in this repository could do it.
[exp120](../exp120-webusb-two-way/) could write to the OUT endpoint but only
ever text, so `0x01` was untypeable and `1` became `0x31`. That page is still
there with the gap intact.

One thing in the capture is not about this experiment: `(+50 lines lost)`
appeared while nothing was reading. `crates/usb-log` queues sixteen lines when
DTR is low, and this firmware prints two every five seconds — so the queue
overflows in under a minute between opening the page and pressing Connect.
Connect first, then send.

## Make it yours

1. Change the readback to `is_set_high()` for both values and watch every check
   still pass. That is the failure `check.sh` guards against, and feeling it is
   worth more than reading about it.
2. Send `0x01` a hundred times in a row and watch the sequence number. exp118's
   counter was built for exactly this kind of question.
3. Give the LED back: add `0x02` meaning *resume the heartbeat*. Notice that
   this makes ownership a thing the protocol has to represent, not a thing that
   happens once.
4. Comment out the 64-cycle settle and see whether you can ever catch
   `OUT high, pad low`. It is a genuine race; whether it is observable from the
   Cortex-M33 at 150 MHz is a measurement, not an opinion.
5. Do the whole thing from a phone. This firmware, `console.html` off the
   filesystem, and no toolchain anywhere near it — the LED is the one result in
   this repository that needs no screen to read.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The LED never blinks after flashing | The board wires its LED to another GPIO | One marked line in `src/main.rs` — see [Boards](../README.md#boards) |
| `6 bytes in one packet` | You typed a word. This firmware has no way to delimit one | Use `yi26 send '\x01'` — and read the framing section above |
| `0x31 is not a command` | `yi26 send 1` sends the *character* `1`, which is `0x31` | The escape is what makes it a byte: `'\x01'` |
| Nothing in the log at all | `cdc_acm` has the port, or a browser does | `yi26 attach`, then `yi26 log` |
| `OUT high, pad low` | Genuinely worth reporting — or the settle delay was removed | Check `SETTLE_CYCLES` in `src/main.rs` |
| The LED is dark and nothing responds | Exactly the ambiguity this experiment is about | `yi26 log --seconds 7`; if the idle line is there, the firmware is fine |

## Next

The framing question, which this experiment named and then stepped around. A
command longer than one byte has to survive arriving in pieces, and the table
above says who has to solve that and who gets it for free.

That is the road listed under [Planned](../README.md#planned).
