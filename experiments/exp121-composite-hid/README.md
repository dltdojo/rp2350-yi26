# exp121-composite-hid — one cable, two functions

The board becomes a keyboard **and** stays the thing reporting on itself, on
one cable. That is the shape a phone needs: one port, and the device under
test is already in it.

It is also the first experiment here that changes the USB descriptors, which
is a different kind of risk from everything before it.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## The promise that was already there

Every firmware in this repository has set the same three bytes since exp104:

```rust
config.device_class     = 0xef;   // Miscellaneous
config.device_sub_class = 0x02;   // Common class
config.device_protocol  = 0x01;   // Interface Association Descriptor
```

That triple says *this device has several functions, and its interfaces are
grouped into them*. exp115's page annotates it when it sees it. Until now it
has been a promise about one function.

Nothing here changes it. A second function simply arrives and the promise
starts being true.

## Why this one is built in two steps

A wrong descriptor does not misbehave — it fails to enumerate. The board draws
power, appears in no listing, and the 1200-baud reflash cannot reach it,
because there is nothing there to reach. The only way back is a hand on the
BOOTSEL button. That has happened once in this repository already, in exp113,
and it cost its owner a trip to the bench.

So the change was landed in two builds, and each was checked before the next:

1. **Declare the keyboard, press nothing.** Flash, confirm it enumerates,
   confirm the log still works, confirm `yi26 bootsel` still gets in.
2. **Then teach it to press a key.**

If the board had died, which of the two did it would not have been a question
anyone had to work out. That is the whole value of the split, and it costs one
extra flash.

## It presses Scroll Lock, and only when asked

A device that types is a hazard: whatever window has focus receives it, and on
a machine where somebody is working that is a way to lose work.

Scroll Lock is the exception. Nothing pressed unless the host asks:

```sh
yi26 send k        # one press, one release
```

The command arrives on exp118's OUT endpoint, which is that endpoint doing a
second job.

### Where to look, and where not to

`xset q` **will not change**, and this is worth knowing before it wastes your
afternoon. Modern desktops bind nothing to Scroll Lock, so the key arrives and
the desktop ignores it — which looks exactly like the key never arriving.

The kernel's input layer is where the truth is:

```text
$ python3 read-events.py            # or evtest, or any input reader
  EV_KEY  SCROLLLOCK  press
  EV_KEY  SCROLLLOCK  release
```

Press and release, in order, exactly as sent. And the host's own opinion,
which no firmware can fake:

```text
$ ls /dev/input/by-id/
usb-rp2350-yi26_exp121_composite_hid_121-if02-event-kbd

$ xinput list
  ↳ rp2350-yi26 exp121 composite hid    id=17  [slave  keyboard (3)]
```

The operating system bound a keyboard driver to interface 2 and made an input
device out of it. That is not this repository claiming the descriptors are
right; it is Linux acting on them.

## Both halves of a keypress

```rust
let down = KeyboardReport { keycodes: [KEY_SCROLL_LOCK, 0, 0, 0, 0, 0], .. };
let up   = KeyboardReport { keycodes: [0; 6], ..down };
```

A HID keyboard reports **the set of keys currently held**, not events. A report
with a key in it and no report after it is a key held down forever, and the
host's autorepeat takes it from there. The release is not politeness.

It also costs time. `write_serialize` waits for the host to poll the interrupt
endpoint, and `poll_ms` here is 64 — so a press-and-release is up to two poll
intervals of the console task not listening to its own console. Measured on
this board: 63 ms between the packet arriving and the keypress being logged.
Harmless at this scale, and the control-line event latches, so a reboot request
arriving mid-press is delayed rather than lost.

## The second half: build order decides every number

Same firmware, same descriptors, one line moved:

```sh
cargo build --release                      # CDC first  (default)
cargo build --release --features hid-first # HID first
```

What the host sees:

| | default | `--features hid-first` |
| --- | --- | --- |
| interface 0 | CDC Communications | **HID** |
| interface 1 | CDC Data | CDC Communications |
| interface 2 | **HID** | CDC Data |
| notification endpoint | `0x81` | **`0x82`** |
| bulk IN | `0x82` | **`0x83`** |
| bulk OUT | `0x01` | `0x01` |

Every interface number moves, and two of the three endpoint addresses with
them. The bulk OUT keeps `0x01` because IN and OUT endpoints are numbered
separately — which is its own small lesson in why `0x01` and `0x81` are not
the same endpoint.

**Nothing in this repository needed changing to survive that.** `yi26` finds
interfaces by class; exp116 and exp120's pages find endpoints by direction.
The tool's own output shows the move without a line of code being touched:

```text
default:    detached kernel driver from interface(s) 0, 1
hid-first:  detached kernel driver from interface(s) 1, 2
```

That is what all the insistence on reading descriptors rather than remembering
them was for. It stopped being a style preference the moment this experiment
landed.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp118's console loop, plus a HID interface
  and a keypress. The two build orders differ by which side of one line the
  keyboard is declared on.

## Two ways to do it

```sh
./run.sh      # guided: both orderings, the descriptors, and the keypress
./check.sh    # verdict: builds both, then asks the host what it thinks
```

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. Two firmware
images, differing only in **which order the two functions are declared** — and
that turns out to change things nobody thought were involved.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable.
  * Ubuntu, and membership of the `input` group so you can read
    `/dev/input/*`. Check with `id -nG | grep input`; if it is missing,
    `sudo usermod -aG input $USER` and log out and back in.
  * `cat`, `stty`, `printf`, `lsusb`. No `yi26`.

1. UNPACK IT.

       unzip exp121-composite-hid.zip
       cd exp121-composite-hid

2. FLASH THE DEFAULT ORDERING. **[HUMAN STEP]** Hold BOOTSEL, plug in, let go:

       cp firmware/exp121-composite-hid.uf2 /media/$USER/RP2350/

3. SEE ONE CABLE CARRYING TWO DEVICES.

       sleep 6
       lsusb -d 1209:0001 -v 2>/dev/null | grep -E 'bInterfaceNumber|bInterfaceClass'
       ls /dev/input/by-id/ | grep exp121
       ls /dev/ttyACM*

   Expect three interfaces and two host drivers:

       bInterfaceNumber  0    bInterfaceClass  2 Communications
       bInterfaceNumber  1    bInterfaceClass 10 CDC Data
       bInterfaceNumber  2    bInterfaceClass  3 Human Interface Device

       usb-rp2350-yi26_exp121_composite_hid_121-if02-event-kbd
       /dev/ttyACM0

   **The same cable is a serial port and a keyboard at once**, and your desktop
   bound a driver to each without being told anything.

4. MAKE IT TYPE, AND READ THE KEYPRESS FROM THE KERNEL. Two terminals. In the
   first:

       timeout 6 cat /dev/input/by-id/*exp121*event-kbd > /tmp/k.bin

   In the second, within those six seconds:

       printf 'k' > /dev/ttyACM0

   Then:

       stat -c%s /tmp/k.bin

   Expect a non-zero size — 144 bytes here. **That is the kernel's own input
   layer**, not the firmware's opinion of itself. The board said it pressed a
   key and the operating system agrees.

   It presses Scroll Lock, deliberately, because nothing modern acts on it.
   Do not look at a desktop indicator to check: GNOME does nothing with Scroll
   Lock, so a working keypress and a broken one look identical there. Read the
   event bytes.

5. NOW FLASH THE OTHER ORDERING AND RUN STEP 3 AGAIN.

       cp firmware/exp121-hid-first.uf2 /media/$USER/RP2350/
       sleep 6
       lsusb -d 1209:0001 -v 2>/dev/null | grep -E 'bInterfaceNumber|bInterfaceClass'
       ls /dev/input/by-id/ | grep exp121

   Everything has moved:

       bInterfaceNumber  0    bInterfaceClass  3 Human Interface Device
       bInterfaceNumber  1    bInterfaceClass  2 Communications
       bInterfaceNumber  2    bInterfaceClass 10 CDC Data

       usb-rp2350-yi26_exp121_composite_hid_121-event-kbd

6. LOOK AT WHAT THE FILENAME DID. In step 3 the keyboard was
   `..._121-if02-event-kbd`. Now it is `..._121-event-kbd` — **the `if02`
   is gone**, because the HID function is no longer interface 2.

   One line moved in the source. The interface numbers changed, so the
   endpoint numbers changed, so the path your host uses to name the device
   changed. Anything that hard-coded that path is now broken, and nothing in
   the firmware's own log would tell you.

IF IT DOES NOT WORK
  * `Permission denied` reading `/dev/input/...` — you are not in the `input`
    group. That is a permission, not a person: see WHAT YOU NEED.
  * `/tmp/k.bin` is empty — the `printf` missed the six-second window, or went
    to the wrong port. Start the reader first.
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * Nothing under `/dev/input/by-id` matches `exp121` — the board is not
    running this firmware.

## Expected output

Captured from a real Pico 2 on Ubuntu. At boot:

```text
[      37 ms] exp121 up. Two functions on one cable, and nothing is pressed.
[      37 ms] HID report descriptor: 69 bytes, first eight: 05 01 09 06 a1 01 05 07
[      37 ms] zero-length packet — not counted, nobody sent it
```

Those eight bytes are readable if you want them: `05 01` Usage Page (Generic
Desktop), `09 06` Usage (Keyboard), `a1 01` Collection (Application), `05 07`
Usage Page (Keyboard).

Sending the command:

```text
[    2667 ms] in #1: 1 bytes
[    2667 ms]   0000  6b                                               k
[    2730 ms] key: pressed and released Scroll Lock (usage 0x47)
```

Sixty-three milliseconds between the two, which is one `poll_ms` interval —
the host collecting the report is what makes `write_serialize` return.

And the descriptor set the host read:

```text
bNumInterfaces          3
  bFunctionClass        2 Communications          <- IAD
    bInterfaceNumber    0   Communications        EP 0x81 interrupt
    bInterfaceNumber    1   CDC Data              EP 0x01 bulk OUT, 0x82 bulk IN
  bFunctionClass        3 Human Interface Device  <- IAD
    bInterfaceNumber    2   HID, Boot, Keyboard   EP 0x83 interrupt
```

Two Interface Association Descriptors, which is the `0xef/0x02/0x01` triple
finally doing its job.

## Make it yours

1. Change `KEY_SCROLL_LOCK` to `0x04` — the letter `a` — and press it with a
   text editor focused. Then think about what a device with a keyboard
   interface can do to a machine it is plugged into, and read `audit.sh`.
2. Set `HID_POLL_MS` to 255 and watch the delay between the command and the
   keypress grow to a quarter of a second. Then to 1, and watch the bus do
   nothing useful a thousand times a second.
3. Shrink `CONFIG_DESCRIPTOR` from 256 bytes to 64 and build. This is the
   failure mode this experiment was split in two to avoid — and the reason to
   try it deliberately, once, while you are sitting next to the board.
4. Add a third function. The IAD triple already promises it, and by now
   nothing on the host side will notice.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The board enumerates as nothing at all | A malformed or oversized descriptor | Hold BOOTSEL while plugging in; there is no software route back |
| `xset q` never shows Scroll Lock changing | The desktop ignores that key | Read the input event device instead — see above |
| No `*event-kbd` under `/dev/input/by-id` | The host did not bind a HID driver | `lsusb -v -d 1209:0001` and look at the report descriptor |
| `Permission denied` reading the event device | Not in the `input` group | `sudo usermod -aG input $USER`, then log out and in |
| The keypress is logged but nothing arrives | The host is not polling the interrupt endpoint | The firmware says so instead of pressing into the void |

## Next

**exp122** takes the class drivers away entirely: a vendor-specific interface
with two bulk endpoints and no operating-system driver to claim it — which is
where WebUSB stops needing anything detached first.
