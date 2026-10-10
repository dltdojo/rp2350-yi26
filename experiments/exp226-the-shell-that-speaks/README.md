# exp226 — the shell that speaks

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Every experiment on the verified-kernel road so far, exp209 to exp225, has
had one LED to say what it found. This one gives the RISC-V shell a USB port.
exp225's shell and its proved Rule 30 kernel are compiled in unchanged. A new
CDC-ACM device, written in C for the shell, brings up a 48 MHz USB clock,
enumerates, and sends a log on a bulk IN endpoint. A phone opens that log with
`tools/pages/log.html`, and **Copy** brings back as text what the LED could
only blink. On a Pico 2, round 4, with clk_sys moved to 48 MHz: a phone enumerated
it and read its whole descriptor tree, exactly as tested here, and `log.html`
brought back two lives that are `rule30.py`'s, minstret 3082, and the first
measurements of the clock the bootrom leaves: clk_sys 10966 kHz against the
crystal. Round 5, with the log's own faults fixed, sent every line whole.
Rounds 1-3 had got no further than a bus reset.**

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
write for write, with addresses and bits from rp-pac 7.0.0. The 12 MHz XOSC
goes through PLL_USB, ×120 ÷6 ÷5 = 48 MHz, for clk_usb and, from revision 4,
for clk_sys as well; both are measured against the crystal before USB starts.

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
2. **Read the LED.** It shows one thing at a time, in one shape you can count:
   **N flashes, then 3 seconds dark, repeated**.
   - **Without a long light first, it is how far the host got**:
     - 1 flash: nothing from the host at all
     - 2: bus reset
     - 3: a SETUP packet arrived
     - 4: the host took a packet the device sent
     - 5: addressed
     - 6: configured
     - 7: a page opened the port

     It changes as the host gets further. Report the last number you see.
   - **With a 2-second light first, it is an error**, and the board stops there:
     - 1 to 4: one of exp225's checks, as exp225 counts them; the log has a
       FAIL line too
     - 5: the crystal oscillator
     - 6: PLL_USB
     - 7: clk_usb not enabled, or not 48 MHz against the crystal (revision 3
       measures it with the chip's frequency counter)
     - 8: the controller's reset
     - 9: clk_sys would not move onto PLL_USB (revision 4)

     After an error 1 to 4, the stage count follows, in turn: two numbers,
     each after its own 3 seconds dark.

   The life no longer plays on the LED. It goes out over USB as LIFE lines.
   Revision 1 played the life and showed the stage in between, and on a board
   that could not be read.
3. **`inspect.html`**: open it with Chrome, tap the button, pick the board in
   the dialog, then **Copy report**, and paste it back. On a Pixel 9a, from a
   `content://` page, Copy report gave nothing in round 4; select the report's
   text and copy that instead. This is the descriptor
   tree as the phone sees it. **If the dialog lists nothing, say so, and press
   Any device…**: it drops the 1209:0001 filter, and what it lists, or that it
   lists nothing, tells a device that never enumerated from one that did with
   the wrong IDs.
4. **`log.html`**: close `inspect.html` first, because one interface has one
   owner. Open `log.html`, connect, wait for a LIFE line (up to a minute and a
   half), then **Disconnect**, then **Copy**, and paste it back. In round 4,
   on the Pixel 9a, Copy did nothing while the log was still arriving: a status
   line a second keeps redrawing the page under the selection. Disconnected, the
   whole page copied.

Every step ends in a number or in text. Nothing has to be described.

## What the log says

```
exp226 usb=6 setups=… stalls=… dropped=… errors=… ref=… sys=… xosc=… pll=… usb_khz=… sys_khz=… sys48_khz=… ref_khz=… sof_khz=… lives=… minstret=…
LIFE round minstret gen1 gen256 centre-column
```

The status line comes about once a second. `ref`, `sys`, `xosc` and `pll` are
the clock registers as the bootrom left them, read before anything changed.
`usb_khz`, `sys_khz` (as the bootrom left it), `sys48_khz` (once moved) and
`ref_khz` are the chip's frequency counter, taken
against the crystal so that clk_ref's unknown rate cancels; `sof_khz` is clk_sys
counted again against the host's 1 ms frames. They are the first measurements
in this repository of the clock `led.h` has only assumed. `errors` counts the
CRC, bit-stuff, overflow and timeout errors the controller saw on the bus.

The LIFE line comes once per life, the same words the RTL prints. A pasted log
goes under `board/`, and `check.sh` replays it with `replay.py`: every LIFE
line must be `rule30.py`'s life, with minstret 3082.

## On the board

| Round | Firmware | What came back |
| --- | --- | --- |
| 1 | revision 1, `exp226.uf2` built at baf9fb7 (`fbe75028…`) | Flashed from a Pixel 9a. `inspect.html`: *No device chosen*. Asked afterwards, with revision 1 still on the board: the filtered chooser was **empty**, and so was **Any device…** — the phone sees no USB device at all, so enumeration did not complete, whatever the IDs. The LED was irregular. An unfinished step would have been a regular count, so the clock and the controller most likely came up and the life was playing; how far enumeration got could not be read from it. |
| 2 | revision 2 (`64b907e9…`) | No long light, then **2 flashes**: a bus reset, and no SET_ADDRESS completed. The pull-up is seen and the host resets the bus; nothing after that worked. |
| 3 | revision 3 (`2a7068dc…`) | A long light, then **4 flashes**: exp225's check 4, the first life's SHA-256 not `rule30.py`'s — which revision 2 had passed, since it showed a stage, and only board_play shows one. And clk_usb **was** measured at 48 MHz ± 0.5%, or it would have been error 7. Both choosers empty again. |
| 4 | revision 4 (`dac41ee2…`) | No long light, **6 flashes**: configured. `inspect.html` connected and read the whole tree — 1209:0001, *exp226 the shell that speaks*, serial 226, EF/02/01, `0x81` interrupt 8, `0x01` and `0x82` bulk 64 — exactly what `usbdev_test.py` and exp115's recording say ([board/round4-inspect.txt](./board/round4-inspect.txt), replayed by `check.sh`). And no error, so exp225's four checks held, check 4 included. **Copy report** gave nothing on the phone; the report was selected and copied by hand. Then `log.html`: twelve status lines and **LIFE lines for lives 9 and 10, both `rule30.py`'s, minstret 3082** ([board/round4-log.txt](./board/round4-log.txt), replayed by `check.sh`), and the clocks below. Copy worked only after Disconnect. |
| 5 | revision 5 (`5762b0d8…`) | `log.html`, copied after Disconnect: eleven status lines, **all whole**, `dropped=0`, `errors=0`, every one ending `minstret=3082`, and a **LIFE line for life 12, `rule30.py`'s** ([board/round5-log.txt](./board/round5-log.txt), replayed by `check.sh`). clk_sys as left 10950 kHz, clk_usb 47997 kHz, clk_sys moved 48000 kHz, 47998-47999 kHz against the frames. |

**Round 4 is the first time a RISC-V shell on the verified-kernel road was
seen by a host as a USB device**, and the first time one sent its findings back
as text. What the log measured, every status line the same:

| Quantity | Round 4 |
| --- | --- |
| `CLK_REF_CTRL`, `CLK_SYS_CTRL` as the bootrom left them | 0 and 0: clk_ref on the ROSC, clk_sys on clk_ref |
| `XOSC_STATUS`, `PLL_USB_CS` as left | 0 (crystal off) and 1 (refdiv 1, PLL off) |
| clk_sys as left, against the crystal | **10966 kHz** — `led.h`'s "about 11 MHz", measured for the first time |
| clk_ref as left | 10965 kHz |
| clk_usb | 48000 kHz |
| clk_sys moved onto PLL_USB | 48001 kHz against the crystal, 47999 kHz against the phone's 1 ms frames |
| bus errors, stalls | 0 errors; 3 stalls (requests a CDC-ACM device has no answer for) |

The log also showed three faults of revision 4's own, none in the life:
every status line was cut at 190 bytes, inside `minstret`, by a 192-byte line
buffer; once the page had been away, the queue filled (`dropped=307`) and
kept half a line, which the next line was then glued onto; and the last
`sof_khz` was 7877451, a count of about 80 s over 500 frames, as if the host
had stopped sending frames for a while. `replay.py` reads revision 4's lines up
to `lives` and says which were cut. Revision 5 (`5762b0d8…`) fixes all
three: a 256-byte line, a write that goes into the queue whole or not at all
(`usbdev_test.py` and a seventh mutant hold it), and a frame count kept only
when it could be 1 ms frames. In round 5 every status line arrived whole,
198 bytes ending in `minstret=3082`, with nothing dropped.

Round 5 was a second boot, so it also says how much of round 4's table is the
chip and how much is the boot. The ROSC-derived clocks moved, clk_sys as left
10950 kHz against round 4's 10966, about 0.15%; everything taken from the
crystal stayed within a few kHz of 48 MHz (clk_usb 47997, clk_sys moved 48000,
against the frames 47998-47999). The registers the bootrom left were the same,
and so were the three stalls.

The change from revision 3 that touches USB is
clk_sys moved to 48 MHz; the rest of revision 3 — the clock measured, the finer
stages, the SETUP kept after a reset — was already there. So the inference is
that the controller needs clk_sys at least as fast as clk_usb. It is the
inference of one round, not a measured threshold; no revision ran with clk_sys
between 11 and 48 MHz.

Round 2 stopped between the reset and the address, where revision 2's LED had
one number for three different failures: no SETUP decoded, a SETUP decoded and
never answered, or an answer never taken. Revision 3 splits them (stages 3 and
4) and, before anything else, measures clk_usb against the crystal with the
chip's frequency counter, because a reset is a 10 ms level that any clock sees
and a packet is not: a wrong 48 MHz would stop exactly here. It also stops
dropping a SETUP that arrives in the same poll as the reset before it, and
answers the host for its first seconds before going on to the kernel.

Round 3 settled the clock that was suspected: clk_usb is 48 MHz against the
crystal. What it left is the one difference between this shell and every
implementation that enumerates on this board: they run clk_sys at or above
clk_usb (embassy-rp at 150 MHz), and the shell had kept the bootrom's, about
11 MHz, so that `led.h`'s beat would not change. Revision 4 moves clk_sys onto
PLL_USB too, measures it, and counts its waits in units of the measured clock.
Check 4 failing in round 3, and not in round 2, is not explained: revision 3
added the frequency counter and a few seconds of answering the host before the
kernel runs, and neither writes where the kernel or the check reads. Revision 4
shows the stage after an error as well, so one round gives both numbers, and
if USB comes up the FAIL line carries the first generation the check saw.

Round 1's lesson is the LED's, and it is this repository's own rule
([docs/debugging-without-a-board.md](../../docs/debugging-without-a-board.md)):
a debug channel says one thing in one shape. Revision 2 stops playing the life
on the LED and shows only the stage, as a count that repeats.

## What it does not say

- **That the log is the life.** The shell reads the generations out of the
  region and formats them in C; the USB code carries them. Neither is proved.
  `replay.py` checks what arrives against `rule30.py`, which shares nothing
  with them, so a corrupted line is caught after the fact.
- **That the controller code is right.** It follows embassy-rp, and it has
  run on one board against one phone: enumeration, a control transfer of every
  kind Linux makes, and bulk IN. Bulk OUT has never carried a byte.
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
recorded at 2026-10-10T09:13:40Z from commit b2f5268

>>> the USB device's descriptors, as a host reads them
PASS  the device: USB 2.00, EF/02/01, EP0 64 bytes, 1209:0001, bcdDevice 0.10, strings 1-3, one configuration
PASS  the configuration: 70 bytes, 2 interfaces, bus powered, 100 mA
PASS  interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64
PASS  the same device and tree exp115 recorded from a real Pico 2 running a Rust firmware here

>>> the shell, for the chip and for the RTL
build/expect.h: kernel 559d70d93ee6242d…, model 3079, RTL minstret 3082, first life 8c3f6e7f0f4aa2dc…
build/exp226.bin  10964 bytes, the build allows 16384
build/exp226.uf2  22016 bytes  sha256 5762b0d84220ea91ab628bf377eb32df464f0985aa4a2220c4437a7ff01351aa

>>> on the RTL, which has no USB: exp225's shell as exp226 builds it
4c494645 00000000 00000c0a 00038000 02bb07b0 bae4d19d 4c494645 00000001 00000c0a 06a28c28 27266abc bd221e08 exit=0 

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  a bus reset is the first stage the LED can show
PASS  a SETUP packet is stage 2, before anything is sent
PASS  the host taking the first packet is stage 3
PASS  GET_DESCRIPTOR device, 64 asked: 18 bytes in one packet, then the status stage
PASS  SET_ADDRESS 7 is answered with an empty IN packet
PASS  the address is taken only after that status stage, and the stage is 4
PASS  GET_DESCRIPTOR device again, at the new address: the same 18 bytes
PASS  GET_DESCRIPTOR configuration: 9 bytes, then all 70 in two packets, 64 and 6, no empty packet
PASS  asked for exactly 64, it sends exactly 64 and no empty packet after
PASS  string 0: English (US)
PASS  strings 1-3: ['rp2350-yi26', 'exp226 the shell that speaks', '226']
PASS  the device qualifier is stalled: a full-speed device has none
PASS  so is BOS: bcdUSB 2.00 does not promise one
PASS  SET_CONFIGURATION 1 enables the endpoints, then its status stage; the stage is 5
PASS  GET_CONFIGURATION: 1
PASS  GET_STATUS: bus powered, no remote wakeup
PASS  the device: USB 2.00, EF/02/01, EP0 64 bytes, 1209:0001, bcdDevice 0.10, strings 1-3, one configuration
PASS  the configuration: 70 bytes, 2 interfaces, bus powered, 100 mA
PASS  an interface association over interfaces 0 and 1, CDC ACM
PASS  interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64
PASS  the CDC functional descriptors: header 1.10, ACM capabilities 0x02, union 0 -> 1
PASS  the same device and tree exp115 recorded from a real Pico 2 running a Rust firmware here
PASS  SET_LINE_CODING: 7 bytes taken, then its status stage
PASS  SET_CONTROL_LINE_STATE 3: DTR, the port is open, stage 6
PASS  GET_LINE_CODING gives back what was set
PASS  SET_CONTROL_LINE_STATE 2, RTS alone: DTR is bit 0, so the port is not open
PASS  SET_CONTROL_LINE_STATE 1, DTR alone: open
PASS  SET_CONTROL_LINE_STATE 0 when the page closes: DTR off, the stage stays 6
PASS  a class request to interface 1 is stalled: 0 is the communications interface
PASS  a vendor request is stalled
PASS  a bus reset in the middle of a transfer abandons it; the stage reached is kept
PASS  a 64-byte descriptor asked for with 255: one full packet, then an empty one, then the status stage
PASS  100 bytes go out as 64 and 36: [64, 36, 0]
PASS  1100 bytes into a 1024-byte queue: all 1100 dropped, the shell not stopped (1100)
PASS  ten 100-byte lines fit and the 30 bytes after them do not: whole lines out, none cut (1130 dropped, 1000 out)
PASS  a write of exactly the queue fits and comes out: 1024
PASS  the tests catch a usbdev.c where the configuration's length is miscounted, 75 for 70: GET_DESCRIPTOR configuration: 9 bytes, then all 70 in two packets, 64 and 6, no empty packet — 9 75 75
PASS  the tests catch a usbdev.c where the address is taken before SET_ADDRESS's status stage: SET_ADDRESS 7 is answered with an empty IN packet — [('ADDRESS', 7), ('IN', b'')]
PASS  the tests catch a usbdev.c where the bulk IN endpoint is 0x81, the interrupt endpoint's: interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64 — [('interface', 0, 2, 2, 0), ('endpoint', 129, 'interrupt', 8), ('interface', 1, 10, 0, 0), ('endpoint', 1, 'bulk', 64), ('endpoint', 129, 'bulk', 64)]
PASS  the tests catch a usbdev.c where DTR is read from bit 1, RTS: SET_CONTROL_LINE_STATE 2, RTS alone: DTR is bit 0, so the port is not open
PASS  the tests catch a usbdev.c where a 64-byte answer short of what was asked gets no empty packet after: a 64-byte descriptor asked for with 255: one full packet, then an empty one, then the status stage — [('OUT', 0)]
PASS  the tests catch a usbdev.c where a write is taken when only part of it fits: 1100 bytes into a 1024-byte queue: all 1100 dropped, the shell not stopped (0)
PASS  the tests catch a usbdev.c where the device qualifier is answered with the device descriptor: the device qualifier is stalled: a full-speed device has none — [('OUT', 0)]
PASS  the shell builds for the chip from exp225's shell.c and expect.h, in 10964 of the 16384 bytes it may use
PASS  all 43 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 16 KiB of flash, 0x10000000..0x10004000
PASS  together they are exactly the 10964-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 5762b0d84220ea91…
PASS  on the RTL, exp225's shell as exp226 builds it lives exp225's two lives, minstret 3082
PASS  round4-inspect.txt: inspect.html on a phone saw the device usbdev.c describes — 1209:0001, exp226 the shell that speaks, serial 226, EF/02/01, 0x81 interrupt 8, 0x01 and 0x82 bulk 64
PASS  round4-log.txt: 12 status lines, the last: usb=6 setups=37 stalls=3 dropped=307 errors=0 lives=11 minstret=?
      the bootrom left clk_ref_ctrl=00000000 clk_sys_ctrl=00000000 xosc_status=00000000 pll_usb_cs=00000001
      against the crystal: clk_usb 48000 kHz, clk_sys 10966 kHz as left and 48001 kHz moved, clk_ref 10965 kHz; clk_sys against the host's frames 7877451 kHz
      11 of them cut at 190 bytes (revision 4's line buffer) and 1 came after half of another (revision 4's queue cut a write): read up to lives
      sof_khz=7877451 is a count across a gap in the host's frames, which revision 4 kept
PASS  every LIFE line (2) is rule30.py's life, minstret 3082
```
