# exp120-webusb-two-way — the page types, the firmware answers

exp116 read the log. This one talks back.

It is the same connect, the same claim, the same two control transfers, and
one call that was not there before:

```js
await device.transferOut(epOut, bytes);
```

That call is what turns a screen into an input device. On a phone it is the
only way to say anything to a board at all: Android has WebUSB and no Web
Serial.

Needs: a board **running exp118**, a Chromium browser, and on Linux
`yi26 detach` first.

## Why exp118 specifically, and why getting it wrong is silent

Every firmware in this repository has a bulk OUT endpoint. exp115's descriptor
tree prints it, and it has been there since exp104. **exp118 is the first one
that reads it.**

Send to any of the others and the bytes arrive, are never collected, and
nothing is printed. There is no error anywhere: not in the page, not in the
firmware, not in `dmesg`. It looks exactly like this page being broken, which
is why `check.sh` refuses to pass unless exp118 is what is flashed.

## A hundred bytes is not a message

The button marked **Send 100 bytes** is the part worth staying for. One
`transferOut`, and the firmware reports **two** packets:

```text
in #2: 64 bytes
in #3: 36 bytes
```

USB has no messages. The endpoint has a packet size — the 64 this firmware
asked for — and the host's stack cuts everything down to it. There is no
length prefix and no delimiter, because a bulk endpoint carries neither.
Anything that wants messages has to define what one is and reassemble them
itself.

exp118 measured the same split from a terminal with `yi26 flood`. Same wire,
same rule, completely different host software — which is what makes it a
property of USB rather than of either tool. A page with a text box makes it
very easy to believe otherwise, and that is precisely why the button exists.

## The log pane shows only what the device said

Nothing this page generates is ever written into the log. What you sent is
reported in the status line instead.

That is a deliberate constraint and not a limitation to be fixed later. The
moment a viewer mixes host-invented text into the same pane as device bytes,
you can no longer tell which is which by looking — and this repository's whole
argument is that the artifact is the evidence.

## Endpoints are found, not remembered

exp116 needed only the IN endpoint; this needs both, and both are read out of
the descriptors:

```js
if (e.direction === 'in'  && iIn  === null) iIn  = e.endpointNumber;
if (e.direction === 'out' && iOut === null) iOut = e.endpointNumber;
```

On connecting, the page says what it found:

```text
Connected. Interfaces 0 and 1; endpoint 2 IN, endpoint 1 OUT.
```

**Two IN, one OUT — not the same number.** Worth printing rather than
assuming, and this experiment is the reason it is now printed: exp118's
documentation claimed the OUT endpoint was `0x02`, three times, in prose
citing exp115's captured descriptor tree. That tree says `0x01`, and `0x02` is
not an address this device has at all. The mistake survived because prose is
not checked; exp118's `check.sh` now compares every endpoint address it quotes
against the capture it quotes from.

exp121 adds a second function to this device, and every interface and endpoint
number after it moves. Code that reads the descriptors keeps working; code
that remembers what it saw last time quietly writes to the wrong endpoint.

## The code IS the walkthrough

- [`two-way.html`](./two-way.html) — one file, no dependencies, no build step,
  no server. Most of it is exp116; the differences are marked in the comments.

## Two ways to do it

```sh
./run.sh      # guided: flash exp118, detach, open the page, send things
./check.sh    # verdict: everything about this that is checkable from a shell
```

## Expected output

Captured from a real Pico 2 on Ubuntu, read back with `yi26 log` from the same
board. `hello` was typed into the page and Enter pressed; then **Send 100
bytes**:

```text
[  122610 ms] in #1: 5 bytes
[  122610 ms]   0000  68 65 6c 6c 6f                                   hello
[  124983 ms] in #2: 64 bytes
[  124983 ms]   0000  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms]   0010  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms]   0020  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms]   0030  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms] in #3: 36 bytes
[  124983 ms]   0000  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms]   0010  41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41  AAAAAAAAAAAAAAAA
[  124983 ms]   0020  41 41 41 41                                      AAAA
[  125038 ms] idle: 3 packets, 105 bytes received so far
```

Five bytes plus sixty-four plus thirty-six is a hundred and five, and the
firmware's own counter agrees.

The page's side of the same moment, in its status line:

```text
Sent 100 bytes (ok). Watch what the firmware says it received.
```

One send, and the wording is deliberate. The page knows only that the host's
USB stack accepted a hundred bytes; what the device made of them is the
device's to report, and it reported two packets.

### The gap that shows when the page connected

The same capture, earlier, before anything was typed:

```text
[     723 ms] control: 115200 baud, DTR off
[    5037 ms] idle: nothing received yet — try  yi26 send hello
...
[   45037 ms] idle: nothing received yet — try  yi26 send hello
[  110038 ms] (+14 lines lost) idle: nothing received yet — try  yi26 send hello
```

Nothing was wrong. DTR went low at 723 ms when `yi26 detach` finished, and
`crates/usb-log` will not write a line while nobody is listening — so the
idle reports queued, the queue filled, and the rest were dropped. The count
came back at 110038 ms because **that is the moment the page asserted DTR**,
which is to say the moment somebody pressed Connect.

The page's own `control:` lines from that instant are among the fourteen that
were lost, which is why they do not appear. A log that can say how much of
itself is missing is a log you can reason about; exp116's **Copy as JSON**
button carries the same number as a field.

## Make it yours

1. Type a single character and send it. Then hold a key down and send. The
   endpoint does not care what a keystroke is.
2. Send exactly 64 bytes, then exactly 65. One packet, then two — and the
   64-byte case is the one that catches naive framing code in the wild.
3. Delete the `TextEncoder` and send `new Uint8Array([0, 255, 10])` instead.
   The hex dump shows bytes; text was always the page's interpretation.
4. Open exp116's page in a second tab while this one is connected. It fails to
   claim, and the message names both possible owners — an interface has
   exactly one.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `cannot claim the interfaces` | `cdc_acm` owns them, or another tab does | `yi26 detach`; `yi26 doctor` names the other owner |
| Sends appear to work, nothing is printed | The board is not running exp118 | `yi26 port --json` shows which experiment is flashed |
| Nothing at all in the log | Nothing has been sent and the board is idle | exp118 prints an idle line every five seconds |
| `/dev/ttyACM0` is missing afterwards | The tab still holds the interfaces | Disconnect or close it, then `yi26 attach` |

## Next

**exp121** stops leaving the device alone. A second function alongside the
CDC pair — and with it, every interface and endpoint number in this page
moves. The pages that read descriptors will not notice.
