# exp226 — the shell that speaks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Every experiment on the verified-kernel road so far, exp209 to exp225, has
had one LED to say what it found. This one gives the RISC-V shell a USB port.
exp225's shell and its proved Rule 30 kernel are compiled in unchanged. A new
CDC-ACM device, written in C for the shell, brings up a 48 MHz USB clock,
enumerates, and sends a log on a bulk IN endpoint. A phone opens that log with
`tools/pages/log.html`, and **Copy** brings back as text what the LED could
only blink. Not yet run on a board.**

Development here is done from a cloud session with no board. So the question
this experiment asks has a practical edge: can a board's report come back as
text from a phone, instead of as one bit described in a sentence? See
[docs/the-board-is-the-loop.md](../../docs/the-board-is-the-loop.md), lever 3:
ask for an artifact, never for a description.

## What is new, and what is not

| | From | Changed here |
| --- | --- | --- |
| The kernel, its proof, the four checks, the lives | exp225's `kernel.bin`, `shell/shell.c`, `gen.py` | **nothing**: compiled in from exp225's directory |
| How a result is shown | exp225's `shell/board_chip.c` | **replaced**: `shell/board_chip.c` here |
| The USB device's logic: descriptors, EP0, the queue | — | **new**: `tools/hazard3/shell/usbdev.c` |
| The controller and its clock | — | **new**: `tools/hazard3/shell/usb_chip.c` |

exp225's shell calls four functions to show what it found: `board_init`,
`board_play`, `board_fail`, `board_fault`. That seam is the whole interface.
exp226 provides a second set of them, and nothing the theorems are about is
recompiled differently.

## The device

It is the same device every Rust firmware in this repository presents
(`crates/cdc-console` over embassy-usb 0.6), so the pages already know it:
- VID:PID 1209:0001, class EF/02/01, an interface association;
- interface 0, CDC ACM, with interrupt IN `0x81` (8 bytes);
- interface 1, CDC data, with bulk OUT `0x01` and bulk IN `0x82` (64 bytes).

There is one difference: bcdUSB is 2.00, not 2.10, so no host asks for a BOS
descriptor. The serial number is `226`.

The register sequence follows embassy-rp 0.10 (`src/usb.rs`, `src/clocks.rs`)
write for write, with addresses and bits from rp-pac 7.0.0. The system clock
is left as the bootrom set it, so the LED's beat is what it was. Only clk_usb
is new: the 12 MHz XOSC through PLL_USB, ×120 ÷6 ÷5 = 48 MHz.

## What is checked without a board

`tools/hazard3/shell/usbdev_test.py` builds `usbdev.c` for this machine, with a
recorder in place of the controller, and checks:
- **the descriptors**, field by field;
- **the same device and interface tree as exp115 recorded from a real Pico 2**
  running a Rust firmware here: the IDs, EF/02/01, every interface and
  endpoint;
- **an enumeration as Linux does it**:
  - GET_DESCRIPTOR at 64 bytes;
  - SET_ADDRESS, taken only after its status stage;
  - the 70-byte configuration in two packets;
  - the strings;
  - the device qualifier and BOS stalled;
  - SET_CONFIGURATION;
- **log.html's own requests**: SET_LINE_CODING, then SET_CONTROL_LINE_STATE
  with DTR, which is when the device counts the port as open;
- **the bulk IN queue**: packets of 64, and what is dropped when nobody reads.

Six wrong versions of `usbdev.c` are caught. One of them is a real mistake made
while writing it: the configuration was first declared 75 bytes, and the tests
found the 70.

What cannot be checked here is `usb_chip.c`. The Hazard3 RTL has no USB
controller, so the first test of the registers is a board.

## Running it on a board, from a phone

You need a Pico 2, a phone with Chrome and an OTG cable or adapter, and three
files on the phone: `exp226.uf2`, plus `tools/pages/inspect.html` and
`tools/pages/log.html`, downloaded once and kept.

1. **Flash.** Hold BOOTSEL, plug the board into the phone, let go. Copy
   `exp226.uf2` onto the `RP2350` drive straight away: a phone that sleeps
   takes the board out of BOOTSEL
   ([docs/debugging-on-a-phone.md](../../docs/debugging-on-a-phone.md)).
2. **Read the LED.**
   - **5 to 9 flashes and a pause, repeated**: a step of bringing up USB never
     finished. Report the number. That is the whole round.
     - 5: the crystal oscillator
     - 6: PLL_USB
     - 7: clk_usb
     - 8: the controller's reset
     - 9: the bootrom left the system clock on PLL_USB, so it was not touched
   - **1 to 4 slow flashes and a pause, repeated**: one of exp225's checks
     failed, as exp225 counts them. The log has a FAIL line too.
   - **Otherwise**, after a few seconds, a few **quick** flashes, then
     exp225's life. The number of quick flashes is how far the host got:
     - 0: nothing seen
     - 1: bus reset
     - 2: addressed
     - 3: configured
     - 4: a page opened the port

     They repeat before every life, about every 92 seconds.
3. **`inspect.html`**: open it with Chrome, tap the button, pick the board in
   the dialog, then **Copy report**, and paste it back. This is the descriptor
   tree as the phone sees it.
4. **`log.html`**: close `inspect.html` first, because one interface has one
   owner. Open `log.html`, connect, wait for a LIFE line (up to a minute and a
   half), then **Copy**, and paste it back.

Every step ends in a number or in text. Nothing has to be described.

## What the log says

```
exp226 usb=4 setups=… stalls=… dropped=… ref=… sys=… xosc=… pll=… sys_khz=… lives=… minstret=…
LIFE round minstret gen1 gen256 centre-column
```

The status line comes about once a second. `ref`, `sys`, `xosc` and `pll` are
the clock registers as the bootrom left them, read before anything changed.
`sys_khz` is clk_sys counted against the host's 1 ms frames. Both are the
first measurement in this repository of the clock `led.h` has only assumed.

The LIFE line comes once per life, the same words the RTL prints. A pasted log
goes under `board/`, and `check.sh` replays it with `replay.py`: every LIFE
line must be `rule30.py`'s life, with minstret 3082.

## On the board

Not yet run.

## What it does not say

- **That the log is the life.** The shell reads the generations out of the
  region and formats them in C; the USB code carries them. Neither is proved.
  `replay.py` checks what arrives against `rule30.py`, which shares nothing
  with them, so a corrupted line is caught after the fact.
- **That the controller code is right.** It follows embassy-rp, and it has not
  run.
- **Recovery without a hand.** There is no 1200-baud reboot. BOOTSEL by hand is
  the way back.
- **More than one phone.** The walkthrough was written for a Pixel 9a, where
  `log.html` was verified on 2026-08-05.

## Running it

```sh
./check.sh     # under a minute
./run.sh       # the same, recorded to capture.txt
```

## Expected output

Pasted from `capture.txt`, recorded by `./run.sh` from a clean commit:

```text
=== exp226 — the shell that speaks ===
recorded at 2026-10-10T03:41:24Z from commit baf9fb7

>>> the USB device's descriptors, as a host reads them
PASS  the device: USB 2.00, EF/02/01, EP0 64 bytes, 1209:0001, bcdDevice 0.10, strings 1-3, one configuration
PASS  the configuration: 70 bytes, 2 interfaces, bus powered, 100 mA
PASS  interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64
PASS  the same device and tree exp115 recorded from a real Pico 2 running a Rust firmware here

>>> the shell, for the chip and for the RTL
build/expect.h: kernel 559d70d93ee6242d…, model 3079, RTL minstret 3082, first life 8c3f6e7f0f4aa2dc…
build/exp226.bin  9764 bytes, the build allows 16384
build/exp226.uf2  19968 bytes  sha256 fbe75028ba876925be71845b81908b3e5a9539b36e4610da9b0ffdce97d0d09d

>>> on the RTL, which has no USB: exp225's shell as exp226 builds it
4c494645 00000000 00000c0a 00038000 02bb07b0 bae4d19d 4c494645 00000001 00000c0a 06a28c28 27266abc bd221e08 exit=0 

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  a bus reset is the first stage the LED can show
PASS  GET_DESCRIPTOR device, 64 asked: 18 bytes in one packet, then the status stage
PASS  SET_ADDRESS 7 is answered with an empty IN packet
PASS  the address is taken only after that status stage, and the stage is 2
PASS  GET_DESCRIPTOR device again, at the new address: the same 18 bytes
PASS  GET_DESCRIPTOR configuration: 9 bytes, then all 70 in two packets, 64 and 6, no empty packet
PASS  asked for exactly 64, it sends exactly 64 and no empty packet after
PASS  string 0: English (US)
PASS  strings 1-3: ['rp2350-yi26', 'exp226 the shell that speaks', '226']
PASS  the device qualifier is stalled: a full-speed device has none
PASS  so is BOS: bcdUSB 2.00 does not promise one
PASS  SET_CONFIGURATION 1 enables the endpoints, then its status stage; the stage is 3
PASS  GET_CONFIGURATION: 1
PASS  GET_STATUS: bus powered, no remote wakeup
PASS  the device: USB 2.00, EF/02/01, EP0 64 bytes, 1209:0001, bcdDevice 0.10, strings 1-3, one configuration
PASS  the configuration: 70 bytes, 2 interfaces, bus powered, 100 mA
PASS  an interface association over interfaces 0 and 1, CDC ACM
PASS  interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64
PASS  the CDC functional descriptors: header 1.10, ACM capabilities 0x02, union 0 -> 1
PASS  the same device and tree exp115 recorded from a real Pico 2 running a Rust firmware here
PASS  SET_LINE_CODING: 7 bytes taken, then its status stage
PASS  SET_CONTROL_LINE_STATE 3: DTR, the port is open, stage 4
PASS  GET_LINE_CODING gives back what was set
PASS  SET_CONTROL_LINE_STATE 2, RTS alone: DTR is bit 0, so the port is not open
PASS  SET_CONTROL_LINE_STATE 1, DTR alone: open
PASS  SET_CONTROL_LINE_STATE 0 when the page closes: DTR off, the stage stays 4
PASS  a class request to interface 1 is stalled: 0 is the communications interface
PASS  a vendor request is stalled
PASS  a bus reset in the middle of a transfer abandons it; the stage reached is kept
PASS  a 64-byte descriptor asked for with 255: one full packet, then an empty one, then the status stage
PASS  100 bytes go out as 64 and 36: [64, 36, 0]
PASS  1100 bytes into a 1024-byte queue: 76 dropped, the shell not stopped (76)
PASS  and the 1024 that fit come out: 1024
PASS  the tests catch a usbdev.c where the configuration's length is miscounted, 75 for 70: GET_DESCRIPTOR configuration: 9 bytes, then all 70 in two packets, 64 and 6, no empty packet — 9 75 75
PASS  the tests catch a usbdev.c where the address is taken before SET_ADDRESS's status stage: SET_ADDRESS 7 is answered with an empty IN packet — [('ADDRESS', 7), ('IN', b'')]
PASS  the tests catch a usbdev.c where the bulk IN endpoint is 0x81, the interrupt endpoint's: interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64 — [('interface', 0, 2, 2, 0), ('endpoint', 129, 'interrupt', 8), ('interface', 1, 10, 0, 0), ('endpoint', 1, 'bulk', 64), ('endpoint', 129, 'bulk', 64)]
PASS  the tests catch a usbdev.c where DTR is read from bit 1, RTS: SET_CONTROL_LINE_STATE 2, RTS alone: DTR is bit 0, so the port is not open
PASS  the tests catch a usbdev.c where a 64-byte answer short of what was asked gets no empty packet after: a 64-byte descriptor asked for with 255: one full packet, then an empty one, then the status stage — [('OUT', 0)]
PASS  the tests catch a usbdev.c where the device qualifier is answered with the device descriptor: the device qualifier is stalled: a full-speed device has none — [('OUT', 0)]
PASS  the shell builds for the chip from exp225's shell.c and expect.h, in 9764 of the 16384 bytes it may use
PASS  all 39 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 9764-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: fbe75028ba876925…
PASS  on the RTL, exp225's shell as exp226 builds it lives exp225's two lives, minstret 3082
SKIP  replaying a board's log: none recorded yet (board/*.txt)
```
