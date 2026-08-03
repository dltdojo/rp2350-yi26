# exp115-webusb-enumerate — what is inside this device?

A web page opens the board over USB and prints its descriptors. No firmware
changes, no driver, no install, no server — one HTML file you open from the
filesystem.

It is the smallest possible experiment, and it is deliberately small, because
it is where the browser track's one host-side obstacle gets cleared.

Needs: any RP2350 board running any firmware from this repository, a Chromium
browser, and on Linux one udev rule.

## Why a browser at all

Everything up to here read the board through a serial port, which the
operating system had already claimed and handed you as `/dev/ttyACM0`. A
browser does something different: it talks to the USB device itself.

That matters because of where this track is going. **Chrome on Android
implements WebUSB but not Web Serial.** Every desktop answer to "read a serial
port from a page" is unavailable on the one host this track cares about — a
phone, which is the most hostile place to debug a USB device and the place
where the device's own log is the only observability you have.

So the track starts by learning to talk to the device the way a phone will
have to.

## The deliverable is one file

[`usb-inspector.html`](./usb-inspector.html) — about two hundred lines, no
dependencies, no build step, no network. Open it directly:

- **Desktop:** double-click it, or hand the file to Chrome.
- **Android:** Files app → *Open with Chrome*. That yields a `content://`
  URI, which is a secure context. Typing a `file:///sdcard/...` URL into
  Chrome does **not** work — scoped storage blocks it.

There is deliberately **no local web server**. A server is fine on a desktop
and impossible on a phone, and this repository is not going to teach a
workflow that stops at the desk.

> **This page became a tool.** The maintained copy is
> [`tools/pages/inspect.html`](../../tools/pages/). The copy in this directory
> is frozen as the experiment left it and says so when you open it — kept,
> rather than replaced by a link, because reading this file *is* exp115.

## Two ways to do it

```sh
./run.sh      # guided: checks the obstacle, prints the reference, opens the page
./check.sh    # verdict: everything a shell can check, and it says what it cannot
```

## The obstacle, cleared once

On Linux the raw USB device node under `/dev/bus/usb` is root-only. A serial
port and a mounted drive are already yours; this is not. WebUSB claims the
interface directly, so without a rule Chrome's first *Connect* fails with
**Access denied** — a message that names no file, no rule, and nothing you
could search for.

```sh
yi26 udev --install
```

One command, one password, and it prints what it will run first. See
[`tools/README.md`](../../tools/README.md) for why the rule grants `uaccess`
rather than `MODE="0666"`, and `yi26 udev --explain` for the commands to type
yourself instead.

## Expected output

Captured from a real Pico 2 on Ubuntu, with `exp114` on the board. Any of this
repository's firmwares gives the same tree apart from the product string.

```
device   0x1209:0x0001
         manufacturer  rp2350-yi26
         product       exp114 health tests
         serial        114
         USB           2.1
         class         0xef  Miscellaneous (IAD composite)
         subclass      0x02
         protocol      0x01

         ^ EF/02/01 is the IAD triple: a composite device whose
           interfaces are grouped into functions.

config 1
  interface 0  alt 0
    class     0x02  Communications
    subclass  0x02  Abstract Control Model
    protocol  0x00
    endpoint 0x81  IN  interrupt 8 bytes
  interface 1  alt 0
    class     0x0a  CDC Data
    subclass  0x00
    protocol  0x00
    endpoint 0x01  OUT bulk      64 bytes
    endpoint 0x82  IN  bulk      64 bytes
```

And the same device, from the host side, by a completely different route:

```console
$ lsusb -d 1209:0001 -v | grep -E 'bInterfaceClass|bEndpointAddress|wMaxPacketSize'
      bInterfaceClass         2 Communications
        bEndpointAddress     0x81  EP 1 IN
        wMaxPacketSize     0x0008  1x 8 bytes
      bInterfaceClass        10 CDC Data
        bEndpointAddress     0x01  EP 1 OUT
        wMaxPacketSize     0x0040  1x 64 bytes
        bEndpointAddress     0x82  EP 2 IN
        wMaxPacketSize     0x0040  1x 64 bytes
```

Every number agrees. One route goes through the kernel's USB stack and
`lsusb`; the other through a browser sandbox and a permission prompt. That
they arrive at the same tree is the point of the experiment — and it is the
check that caught a real bug in this page, described below.

## What the tree is telling you

**`EF/02/01` on the device.** The Interface Association Descriptor triple:
"several functions live here, and the interfaces are grouped". Every firmware
in this repository sets it, including the ones with a single function.

**Interface 0, one interrupt IN endpoint of 8 bytes.** This is where a CDC
device reports line-state changes. It is the path exp105's 1200-baud reboot
travels: the host's `SET_LINE_CODING` arrives on the control pipe and the
firmware's watcher sees it.

**Interface 1, bulk IN and OUT at 64 bytes.** `0x82` is the log. Everything
exp107 through exp114 printed came out of that endpoint, and **exp116 reads it
directly** — no serial port, no kernel driver, from a web page.

## Opening is not claiming

This page calls `device.open()` and then `close()`. It never claims an
interface, and that distinction is visible from the shell:

```console
$ ls -l /dev/ttyACM0
crw-rw---- 1 root dialout 166, 0 /dev/ttyACM0     # still there
```

Opening asks the operating system for access to the device. Claiming takes an
interface away from whatever driver holds it — and when exp116 claims the CDC
pair, Chrome detaches the kernel's `cdc_acm` driver and `/dev/ttyACM0`
**disappears** for as long as the page is connected. Same device, two views,
one at a time.

The page opens rather than only describing, on purpose: Chrome already read
the descriptor strings during enumeration, so a page that merely printed the
tree would appear to work on a machine where nothing else would. Opening is
the part that exercises the permission.

## The permission is asked once per browser session

Grant it, and `navigator.usb.getDevices()` returns the device afterwards with
no picker and no click:

```
Opened exp114 health tests (reconnected automatically, no picker
— the permission persisted). Read-write access confirmed.
```

Measured, because guessing at the scope would have been wrong in both
directions. What was confirmed on Chrome 137:

- it survives a **hard reload** of the same page;
- it is inherited by a **different file** at a different path — the grant
  belongs to the `file://` origin, not to one document. A page in `/tmp`
  that never called `requestDevice()` got the device from `getDevices()`;
- it does **not** survive the browser restarting.

That last one matches Chrome's `Preferences`, where `usb_chooser_data` stays
empty: the grant is held for the session and never written to disk.

Two consequences. Every later page in this track reconnects with no click, so
the grant is per session rather than per experiment. And **any local HTML file
on the machine can reach the board** once you have granted it — which is worth
knowing before granting, and is the honest cost of a `file://` origin having
no finer identity than "a file".

## A bug this experiment caught

The page originally annotated interface 0's subclass with "Abstract Control
Model" and the annotation never appeared. The cause:

```js
i.interfaceClass === 0x02    // wrong: USBInterface has no interfaceClass
a.interfaceClass === 0x02    // right: it lives on the alternate setting
```

A `USBInterface` carries only its number and its alternates. The class,
subclass and protocol live on each `USBAlternateInterface`, because one
interface can present entirely different functions depending on which
alternate is selected.

`undefined === 0x02` is simply `false`, so the code ran, produced no error,
and every other line was correct. It was found by putting the page's output
next to `lsusb` — which is step 4 of `run.sh`, and the reason that step exists.

## Make it yours

1. Press **Any device…**, which drops the `1209:0001` filter, and look at what
   else is plugged into your machine. Keyboards, webcams, hubs — all of them
   have this same tree, and most are more interesting than a Pico.
2. Flash a different experiment and reload the page. The product string and
   serial change; the interface and endpoint layout does not, because every
   firmware here builds the same CDC-ACM device.
3. Open the page in Firefox. It says WebUSB is missing rather than failing
   confusingly, which is a small thing worth copying: a feature check that
   names the feature beats an exception.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Access denied` on Connect | The udev rule | `yi26 udev --install`, then replug |
| Picker is empty | Filter matches nothing | **Any device…** — `1209:0001` is a shared test ID |
| `no WebUSB` | Firefox or Safari | Chromium browsers only |
| Page shows an old version | `file://` caching | The build marker under the title says which; `Ctrl-Shift-R` |
| Nothing happens on Android | Typed a `file:///sdcard/...` URL | Files app → *Open with Chrome* |

## Next

**exp116** claims the two interfaces this page just described, sends
`SET_LINE_CODING` and `SET_CONTROL_LINE_STATE` by hand, and streams endpoint
`0x82` — the log, in a browser, with no firmware changes and no serial port.
And on a phone.
