# exp117-webusb-reboot — the request whose success looks like failure

A web page puts the board into its bootloader. The drive named `RP2350`
appears, you copy a `.uf2` onto it, and the firmware you built somewhere else
is running — with no toolchain on this machine and no hand on the button.

This is the last experiment on the browser track that changes no firmware.
exp105 taught the board to reboot when the host sets the port to 1200 baud,
and every firmware here has done it since. Nothing new is being taught to the
board; something new is doing the asking.

Needs: any RP2350 board running exp105 or later, a Chromium browser, and on
Linux one command before you start.

## Why this is the experiment that closes the loop

exp115 read the descriptors, exp116 read the log. Both are ways of *watching*.
This one is the first that changes the board's state, and it is the piece the
phone story was missing.

With it, every step of the cycle has a home:

| Step | Where it happens with no local toolchain |
| --- | --- |
| Edit and compile | a rented Linux box — see [docs/platforms.md](../../docs/platforms.md) |
| Download the `.uf2` | the browser you already have |
| Put the board in BOOTSEL | **this page** |
| Copy the file onto the drive | the file manager you already have |
| Read the log | [exp116](../exp116-webusb-cdc-log/), and its **Copy as JSON** button |

## One request, not two

Through a serial API this takes two steps: open at 115200, close, open at
1200. A driver asked for the rate a port is already at sends no
`SET_LINE_CODING`, so the firmware never hears it, and bouncing through
another rate first is what makes the request unconditional.

None of that applies through WebUSB. The page composes the seven bytes and
hands them to the device:

```js
const coding = new DataView(new ArrayBuffer(7));
coding.setUint32(0, 1200, true);   // rate, little-endian
coding.setUint8(4, 0);             // 1 stop bit
coding.setUint8(5, 0);             // no parity
coding.setUint8(6, 8);             // 8 data bits

await device.controlTransferOut({
  requestType: 'class', recipient: 'interface',
  request: 0x20, value: 0, index: control,
}, coding.buffer);
```

The workaround exists to defeat an optimisation in a driver. **When you are
the driver, there is no optimisation to defeat.** That is worth noticing
beyond this page: a great deal of received wisdom about serial ports is
wisdom about the software between you and the port.

It also decides the phone case. Android has WebUSB and not Web Serial, so on
the machine this page is really for, the one-step path is the only path.

## Success looks exactly like failure

The board resets while the request is in flight. Everything the page is
holding — the device, the claimed interface — refers to hardware that has
stopped existing, and the very next call will fail.

So the transfer's own outcome carries no information. It can resolve, if the
chip acknowledges before it resets; it can reject, if it does not. Neither
says whether the firmware acted.

What is unambiguous is the device going away, so that is what the page waits
for:

```js
navigator.usb.addEventListener('disconnect', (e) => {
  if (e.device === device) /* this is the confirmation */;
});
```

A page that reported the transfer result would be right about half the time
and would teach the wrong lesson both times.

## The code IS the walkthrough

- [`reboot.html`](./reboot.html) — one file, no dependencies, no build step,
  no server. About a hundred and fifty lines with the comments.

## Two ways to do it

```sh
./run.sh      # guided: detach, open the page, and check the board afterwards
./check.sh    # verdict: everything about this that is checkable from a shell
```

## Expected output

Captured in Chrome on Ubuntu, against a board running exp119. The page's own
step list:

```text
device            exp119 cancelled reads
open()            ok
claimInterface(0) ok
SET_LINE_CODING   1200 baud, one request, sent now
transfer returned ok  <- means nothing on its own; wait for the disconnect
disconnect event  <- the board reset; this is the confirmation
```

> Rebooted. The board is in BOOTSEL mode and a drive named RP2350 should
> appear — copy a .uf2 onto it. This page can no longer see the device, which
> is correct: it is a different device now.

On this run the transfer resolved rather than rejecting, which is why the
message under it is worded the way it is. It is not a guarantee; it is one of
the two things that can happen.

And from a terminal, at the same moment, with nothing but the page having
touched the board:

```text
$ yi26 state
bootsel

$ lsusb -d 2e8a:000f
Bus 001 Device 127: ID 2e8a:000f Raspberry Pi RP2350 Boot

$ lsusb -d 1209:0001
(nothing — the firmware's identity is gone)

$ yi26 drive
/media/cyline/RP2350
```

Four independent confirmations that a web page rebooted a microcontroller.

Flashing back afterwards needs no browser and no button:

```text
$ yi26 flash experiments/exp119-cancelled-reads/target/exp119-cancelled-reads.uf2
flashed ... (44544 bytes), running at /dev/ttyACM0
```

## On Linux, run `yi26 detach` first

The same requirement exp116 explains at length: the kernel's `cdc_acm` driver
owns the interface, an interface has exactly one owner, and Chrome's WebUSB
does not take it away for you. The claim fails until something does.

```sh
yi26 detach     # take the interface from the kernel
yi26 attach     # give it back — though flashing anything also does
```

**On Android none of this applies.** There is no `cdc_acm` to move aside, so
the page simply works. The asymmetry is worth sitting with: the platform with
the fewest tools needs the fewest steps, and the desktop's helpfulness is what
gets in the way.

### Captured on Android, 2026-08-03

That paragraph was a prediction until this date. It is now a capture, from a
Google Pixel 9a with an OTG cable, against a board running exp126:

```text
device            exp126 self hosted viewer
open()            ok
claimInterface(0) ok
SET_LINE_CODING   1200 baud, one request, sent no…
transfer returned ok  <- means nothing on its own
disconnect event  <- the board reset; this is the…
```

> Rebooted. The board is in BOOTSEL mode and a drive named RP2350 should
> appear — copy a .uf2 onto it. This page can no longer see the device, which
> is correct: it is a different device now.

And it did appear, in the phone's own file manager, carrying the bootrom's
synthesised files rather than anything this repository wrote:

| | |
| --- | --- |
| `INDEX.HTM` | 241 B |
| `INFO_UF2.TXT` | 64 B |
| Both dated | 5 September 2008 — the ROM's fixed timestamp, not the host's |

No `yi26 detach`, because there was nothing to detach. **No hand on BOOTSEL**,
which is the point: a phone can now run the whole cycle — reboot the board,
drag a `.uf2` onto the drive that appears, and watch the new firmware come up —
without touching the board at all.

One thing that was not obvious beforehand and is worth writing down. The page
was opened from the phone's file manager, so its address was a
**`content://` URI**, not `file://`. WebUSB requires a secure context and there
was no reason to assume Chrome grants one to that scheme; it does. Had it not,
this page could not have run on a phone at all, and neither could exp126's —
which is opened the same way.

## What is not verified here

The page's three-second timeout — the message that appears when no disconnect
arrives — has never been seen. Producing it means flashing firmware built with
`--no-default-features`, which compiles the 1200-baud watcher out, and that
firmware can only be replaced by holding BOOTSEL by hand. Deliberately not
done: this repository's board is often the only one in the room and its owner
often is not.

So that path is written, reasoned about, and untested. It is described here
rather than in an `Expected output` section, because those are captures.

## Make it yours

1. Change `MAGIC_BAUD` to 9600 and press the button. Nothing happens, and the
   timeout message appears — which is also the cheapest way to see that path
   without risking the board.
2. Run `experiments/audit.sh` and find the `auto-reboot` line. It reads the
   setting out of the `.uf2` itself, not out of the source, because the
   `.uf2` is what is on the board.
3. Put the board into BOOTSEL from the page, then open exp115's page. The
   bootloader is a USB device too, with its own descriptors, and the picker
   will offer it if you ask for any device.
4. Consider what this means if a page you did not write is open in another
   tab. `audit.sh` has a section about that, and it is not a hypothetical.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `cannot claim interface 0` | `cdc_acm` still owns it, or another tab does | `yi26 detach`; `yi26 doctor` names the other owner |
| The picker lists nothing | The board is already in BOOTSEL | `yi26 state`; it is `2e8a:000f` now, not `1209:0001` |
| No disconnect after 3 s | Firmware predates exp105, or was built without `auto-reboot` | `experiments/audit.sh` reads it from the `.uf2` |
| The drive does not appear | The system did not mount it | `yi26 drive` mounts it and prints where |

## Next

The browser track's remaining experiments all change the device itself:
teaching it to be more than one thing at once, then giving it a volume of its
own. **exp120** turns exp118 around — the page sends bytes rather than only
receiving them — which is what makes a phone an input device and not just a
screen.
