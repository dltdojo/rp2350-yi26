# exp122-vendor-bulk — an interface nobody claims

Every USB interface in this repository has had a **class**: CDC-ACM since
exp104, HID in exp121. A class is a promise about behaviour, and an operating
system that recognises the promise loads a driver and takes the interface.

That is where `/dev/ttyACM0` comes from. It is also why exp116 has to run
`yi26 detach` before a browser can have the port, and why doing so costs you
the serial port for as long as the browser holds it.

This one declares class **`0xFF`** — vendor specific, USB for *no promise at
all*. Nothing knows what to do with it, so nothing claims it, so anything in
userspace can take it without displacing anything.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## The demonstration is two owners at once

Read out of sysfs, which is the operating system's opinion rather than the
firmware's:

```text
1-7:1.0      class=0x02  cdc_acm
1-7:1.1      class=0x0a  cdc_acm
1-7:1.2      class=0xff  (no driver bound)
```

Two interfaces claimed, one left alone. And then both are used at the same
time — the log below arrives over CDC, which the kernel is driving, and
describes traffic on an interface a userspace program is driving:

```text
[      37 ms] exp122 up. One interface the kernel drives, one it will not touch.
[    5037 ms] idle: vendor interface waiting — try  yi26 echo hello
[    5449 ms] echo #1: 10 bytes back, uppercased
[   10037 ms] idle: 1 echo on the vendor interface, 0 CDC packets
```

`0 CDC packets` is the detail worth pausing on. The CDC console received
nothing at all; every byte of that exchange went over the vendor interface,
and the line saying so came back the other way. Neither had to wait for the
other and neither had to be taken from anyone.

The contrast, measured in the same session:

| | cost |
| --- | --- |
| `yi26 detach` — exp116's route to a class interface | `/dev/ttyACM0` **gone** until it is given back |
| `yi26 echo` — this experiment's route | `/dev/ttyACM0` **untouched** |

## Uppercased, not echoed

```console
$ yi26 echo "hello vendor"
sent     12 bytes: hello vendor
received 12 bytes: HELLO VENDOR
```

The change is deliberate. A plain echo cannot distinguish a firmware that
received your bytes and sent them back from a host stack that looped them
somewhere below — both look identical from here. A transformation that only
this firmware performs can, and `check.sh` asserts that the raw bytes in
`a\x00\xffz` come back untouched while the letters do not.

## No class also means no library

There is no `VendorClass::new`, no `read_packet` helper, and no `/dev` entry.
The interface is built by hand out of the pieces `CdcAcmClass::new` and
`HidWriter::new` have been using all along:

```rust
let mut function  = builder.function(0xFF, 0x00, 0x00);
let mut interface = function.interface();
let mut alt       = interface.alt_setting(0xFF, 0x00, 0x00, None);
let out = alt.endpoint_bulk_out(None, 64);
let in_ = alt.endpoint_bulk_in(None, 64);
```

Six lines, and what arrives on `out` is what the endpoint gives you. That is
less convenient than CDC-ACM and considerably easier to reason about, because
there is nothing in between with an opinion.

The host side loses its conveniences too. There is no device node, so there is
nothing for `printf >` to write to — talking to this interface means claiming
it and submitting bulk transfers, which is why `yi26 echo` exists and why
`yi26 echo --explain` has no shell equivalent to offer.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp118's CDC console unchanged, plus a raw
  interface and an echo task.
- [`tools/yi26`](../../tools/README.md) — gained `echo`, which claims the
  vendor interface with `nusb` and never detaches anything.

## Two ways to do it

```sh
./run.sh      # guided: who claimed what, an echo, and both at once
./check.sh    # verdict: asks sysfs which interfaces have drivers, then echoes
```

## Expected output

```console
$ yi26 echo "hello vendor"
sent     12 bytes: hello vendor
received 12 bytes: HELLO VENDOR

$ ls /dev/ttyACM0
/dev/ttyACM0
```

And the descriptors the host read:

```text
bNumInterfaces          3
  bInterfaceNumber      0   Communications          EP 0x81 interrupt
  bInterfaceNumber      1   CDC Data                EP 0x01 bulk OUT, 0x82 bulk IN
  bInterfaceNumber      2   Vendor Specific Class   EP 0x02 bulk OUT, 0x83 bulk IN
```

## What follows from this, and has not been measured here

A browser can claim this interface **without anything being detached first**,
because there is nothing holding it. That is the reason this experiment is on
the browser track at all: exp116's `yi26 detach` step is the largest remaining
piece of friction in it, and a vendor interface removes the step rather than
automating it.

It is stated here as a consequence and **not as a result**, because no page in
this repository has yet claimed it. The measurement above is the part that was
made: nothing owns the interface. What a browser does with that is a separate
click and a separate experiment.

## Windows

A vendor-specific interface on Windows must be bound to WinUSB, and that needs
**Microsoft OS 2.0 descriptors** in the firmware — a BOS platform capability
the host reads during enumeration. `embassy-usb` can emit them; this firmware
does not.

Not an oversight: there is no Windows machine here to check the result on, and
this repository does not publish claims it cannot check. On Linux and Android
nothing extra is needed, because an unclaimed interface is simply available.

## Make it yours

1. Change `CLASS_VENDOR` to `0x03` and reflash. The kernel binds `usbhid` to
   an interface whose report descriptor does not exist, and the friendly
   `yi26 echo` starts failing to claim. Then change it back.
2. Send exactly 64 bytes, then 65. The packet split from exp118 is a property
   of bulk endpoints, not of CDC.
3. Delete the uppercasing so it is a plain echo, and then try to convince
   yourself from the output alone that the firmware ran at all.
4. Add the MS OS 2.0 descriptors with `embassy_usb::msos` and try it on a
   Windows machine. If it works, that is a report this repository would like.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `cannot claim vendor interface` | No udev permission for raw USB | `yi26 udev --install` |
| `no vendor-specific interface` | A different experiment is flashed | `yi26 port --json` says which |
| `no reply within the timeout` | The firmware took the bytes and wrote nothing | Check the CDC log; the echo task logs every reply |
| The board enumerates as nothing | A malformed descriptor | Hold BOOTSEL while plugging in — there is no software route back |

## Next

**exp123** declares a mass-storage interface and answers nothing: it decodes
the command blocks the host sends and prints them. That is the first look at
what a disk is actually asked to do, and the beginning of the four steps that
end with the board serving its own debug page.
