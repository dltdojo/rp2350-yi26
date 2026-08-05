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

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. The vendor
interface has no device node — no operating system claims it — so step 4
writes a client that talks to the raw USB device. About twenty-five lines of
Python, standard library only.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable.
  * Ubuntu with `python3`, and **write access to `/dev/bus/usb/*`** for this
    device. That is what a udev rule is for; without one you get
    `PermissionError` at step 5 and everything else still works.
  * `cat`, `stty`, `lsusb`. No `yi26`.

1. UNPACK IT.

       unzip exp122-vendor-bulk.zip
       cd exp122-vendor-bulk

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go:

       cp firmware/exp122-vendor-bulk.uf2 /media/$USER/RP2350/

3. LOOK AT THE INTERFACE NOBODY CLAIMED.

       sleep 6
       lsusb -d 1209:0001 -v 2>/dev/null | grep -E 'bInterfaceNumber|bInterfaceClass|bEndpointAddress'

   Expect:

       bInterfaceNumber  0    bInterfaceClass   2 Communications
         bEndpointAddress 0x81 EP 1 IN
       bInterfaceNumber  1    bInterfaceClass  10 CDC Data
         bEndpointAddress 0x01 EP 1 OUT
         bEndpointAddress 0x82 EP 2 IN
       bInterfaceNumber  2    bInterfaceClass 255 Vendor Specific Class
         bEndpointAddress 0x02 EP 2 OUT
         bEndpointAddress 0x83 EP 3 IN

   Interfaces 0 and 1 got `/dev/ttyACM0`. **Interface 2 got nothing** — class
   255 means "ask the vendor", and no kernel driver claims it. There is no
   file to open, which is why the next step opens the device itself.

4. WRITE A CLIENT FOR IT. Paste this exactly as it is, at the left margin —
   the body of a heredoc is literal, and indented Python is not Python.

```sh
cat > vecho.py <<'VECHO'
import os, sys, fcntl, struct, glob, ctypes
msg = (sys.argv[1] if len(sys.argv) > 1 else "hello").encode()
node = None
for d in glob.glob("/sys/bus/usb/devices/*/idVendor"):
    if open(d).read().strip() == "1209":
        base = os.path.dirname(d)
        if open(base + "/idProduct").read().strip() == "0001":
            b = int(open(base + "/busnum").read()); a = int(open(base + "/devnum").read())
            node = f"/dev/bus/usb/{b:03d}/{a:03d}"
if not node: sys.exit("no 1209:0001 found")
fd = os.open(node, os.O_RDWR)
IFACE = 2
fcntl.ioctl(fd, 0x8004550f, struct.pack("I", IFACE))
class Bulk(ctypes.Structure):
    _fields_ = [("ep", ctypes.c_uint), ("len", ctypes.c_uint),
                ("timeout", ctypes.c_uint), ("data", ctypes.c_void_p)]
def bulk(ep, buf, n, to=2000):
    b = Bulk(ep, n, to, ctypes.cast(buf, ctypes.c_void_p))
    return fcntl.ioctl(fd, 0xc0185502, b)
out = ctypes.create_string_buffer(msg)
bulk(0x02, out, len(msg))
inb = ctypes.create_string_buffer(64)
n = bulk(0x83, inb, 64)
print(f"sent {len(msg)} bytes, got back {n}: {inb.raw[:n]!r}")
fcntl.ioctl(fd, 0x80045510, struct.pack("I", IFACE))
os.close(fd)
VECHO
```

   It finds the board in sysfs, opens `/dev/bus/usb/BBB/DDD`, claims interface
   2, writes to endpoint `0x02` and reads from `0x83`. That sequence — claim,
   write, read, release — is the whole of what a USB library does for you.

5. TALK TO IT.

       python3 vecho.py hello

   Expect:

       sent 5 bytes, got back 5: b'HELLO'

   The board upper-cased it and sent it back on the other endpoint. **No
   driver, no device file, no library** — just the four ioctls above.

6. NOW DO BOTH AT ONCE. In one terminal:

       stty -F /dev/ttyACM0 -icrnl
       cat /dev/ttyACM0

   In another:

       python3 vecho.py "two owners"

   The serial log keeps running while the vendor interface is claimed by your
   Python. **Two owners, one device, neither aware of the other** — the kernel
   holds interfaces 0 and 1, your process holds interface 2, and USB arbitrates
   at the interface rather than at the device.

IF IT DOES NOT WORK
  * `PermissionError` opening `/dev/bus/usb/...` — no udev rule for this
    device. That is the one prerequisite this experiment cannot do without.
  * `OSError: [Errno 16] Device or resource busy` on the claim — something
    else already holds interface 2. A browser tab with a WebUSB page open will
    do it.
  * `no 1209:0001 found` — the board is not running this firmware.
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.

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
