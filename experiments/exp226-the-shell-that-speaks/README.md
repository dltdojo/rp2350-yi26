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

To be pasted from a recording.
