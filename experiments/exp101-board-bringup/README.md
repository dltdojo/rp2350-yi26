# exp101-board-bringup — is my Pico 2 alive?

You just bought a Raspberry Pi Pico 2 and plugged it into an Ubuntu machine.
Before writing a single line of Rust, this experiment answers one question:
**does the whole physical chain work — board, cable, USB port, host?**

No Rust toolchain, no compilation, no sudo. Everything needed is either stock
Ubuntu or already in this directory.

## Why start without Rust?

Deliberately. When something fails later in a Rust + Embassy experiment, you
want to be certain the failure is in the software stack, not in a broken cable
or a confused host. This experiment establishes that baseline: after it
passes, every later failure is a software problem by elimination. Comparing
"flash someone else's UF2" (this experiment) against "build the same UF2 from
source" (exp102) is also the first of many comparisons this repository uses as
a teaching device.

## Requirements

- Raspberry Pi Pico 2 — the **non-W** board. (The Pico 2 W's LED is wired to
  the wireless chip, not GPIO25, so this experiment's firmware will not blink
  it. W support may come later.)
- A USB **data** cable. Charge-only cables are the single most common cause of
  "my board is dead".
- Ubuntu 22.04 or 24.04 (any desktop Linux with `lsusb`, `lsblk`, and
  `udisksctl` will work).

## Run it

```sh
cd experiments/exp101-board-bringup
./run.sh
```

The script is interactive: it tells you when to hold the **BOOTSEL** button
(the only button on the board, next to the USB connector), when to plug in,
and what it found at each step. It is safe to re-run any number of times.

## What the script does

| Step | What happens | What it proves |
| --- | --- | --- |
| 1 | Checks `lsusb`, `lsblk`, `udisksctl` exist | Host has the basics |
| 2 | Guides you into BOOTSEL mode; waits for USB `2e8a:000f` | Board + cable + port work |
| 3 | Mounts the `RP2350` drive; prints `INFO_UF2.TXT` | The ROM bootloader is talking to you |
| 4 | Runs `picotool info` if installed (optional, skipped otherwise) | Host can query the chip |
| 5 | Copies `assets/blink.uf2` to the drive; waits for reboot | Flashing works |
| 6 | Asks you to confirm the LED blinks at 1 Hz | The firmware actually runs |

## The three ideas to take away

1. **BOOTSEL mode is burned into ROM.** Hold BOOTSEL while plugging in and the
   RP2350 always comes up as a USB drive named `RP2350`, no matter what
   firmware is on it — even firmware that crashes instantly. You cannot brick
   this board. This recovery loop (unplug → hold BOOTSEL → plug in) is the
   safety net under every experiment in this repository.

2. **Flashing is a file copy.** A `.uf2` file is firmware packaged so that
   copying it onto the boot drive writes it to flash. The board reboots into
   it automatically. No flashing tool is strictly required.

3. **A running board can be invisible.** After flashing, `lsusb` shows
   nothing: the blink firmware contains no USB code, so the board simply is
   not a USB device anymore — while being perfectly alive and blinking. "Not
   in lsusb" does not mean "dead". Later experiments add USB back, one class
   at a time.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nothing in `lsusb` in Step 2 | Charge-only cable | Use a known data cable |
| Still nothing | BOOTSEL released too early | Keep it held until the cable is fully in |
| Still nothing | Bad port / hub | Try a direct port on the machine |
| Drive won't mount in Step 3 | udisks/polkit quirk | Open the drive once in the file manager, re-run |
| `INFO_UF2.TXT` says RPI-RP2, not RP2350 | That's a Pico 1 (RP2040) | This repo needs a Pico 2 |
| LED doesn't blink in Step 6 | Pico 2 **W** board | See Requirements above |

## About `assets/blink.uf2`

The prebuilt firmware is built from `assets/blink-src/` — a minimal Rust +
Embassy program in this repository, licensed Apache-2.0 like everything else
here. You do not need to build it for this experiment; exp102 is where you
build it yourself and compare. See [assets/README.md](./assets/README.md) for
provenance and rebuild instructions.

## Next

**exp102** installs the Rust toolchain and builds this exact same blink from
source. Same LED, same 1 Hz — the only thing that changes is where the UF2
comes from. The diff between "copied a file" and "compiled, linked, and
converted an ELF" is the entire toolchain, made visible.
