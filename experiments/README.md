# Experiments

Step-by-step, numbered experiments for learning RP2350 development on the
Raspberry Pi Pico 2 with Rust and Embassy. Each proves exactly one thing and
builds on the ones before it — do them in order, at least the first time.

Assumed setup: **any RP2350 board**, a USB data cable, and an Ubuntu machine.
Written and verified on an official Raspberry Pi Pico 2 (non-W) — see
[Boards](#boards) for what changes elsewhere.

## Boards

You do not need the official board. BOOTSEL mode, the `RP2350` boot drive, the
USB ID `2e8a:000f`, and the USB controller all live in the RP2350's own ROM
and silicon, so they behave identically on any RP2350 design — including the
RP2350B and RP2354 variants.

Only two things are board-specific, and both are one-line changes:

| What | Default here | Change it when |
| --- | --- | --- |
| The LED's GPIO | `PIN_25` (official Pico 2) | Your board wires its LED elsewhere. One clearly-marked line in `src/main.rs`. |
| The package feature | `rp235xa` (30-GPIO RP2350A) | Your board uses the 48-GPIO **RP2350B** — then `rp235xb` in `Cargo.toml`. |

Per experiment:

| Experiment | Portability |
| --- | --- |
| exp101 | Any RP2350 board. Pure ROM behaviour — nothing board-specific at all. |
| exp102 | Any machine. No board involved. |
| exp103 | Any RP2350 board with a plain LED on a GPIO (change the pin). |
| exp104 | Any RP2350 board. The serial port does not depend on the LED. |

Two cases need more than a pin change: the **Pico 2 W** routes its LED through
the wireless chip, and boards whose only LED is an **RGB/NeoPixel** need a PIO
driver rather than a plain output. Both are out of scope for now.

Boards also differ in how you enter BOOTSEL — a button, a jumper, or shorting
a pad. Whatever the mechanism, the ROM behaviour it triggers is the same.

If you run these on a third-party board, a report either way is welcome: only
the official Pico 2 has been verified here.

## Platform

The scripts are written and tested on **Ubuntu Linux**, and they say so up
front: on any other platform they stop immediately with an explanation
instead of failing confusingly halfway through.

On a different platform, the supported path is a **port, not a workaround** —
and this repository is deliberately good input for one: the scripts are
short, every command is shown and explained, and each experiment ships a
`check.sh` that verifies the result. Hand an experiment's `run.sh`,
`check.sh`, and `README.md` to an AI assistant and ask it to translate the
steps to macOS, Fedora, Arch, or WSL2. Demonstrating that
small-open-documented code makes AI-assisted porting fast is part of this
repository's point.

Running another Linux that is close enough (apt equivalents, udisks2)?
Acknowledge the difference and proceed: `RP2350_ANY_PLATFORM=1 ./run.sh`.

## Conventions

Shared helpers — output formatting, the `run_cmd` show-then-run pattern,
PASS/FAIL accounting, and the platform guard above — live in one place,
[`lib.sh`](./lib.sh), sourced by every script. One copy means the scripts
cannot drift apart; it also means experiments assume a full checkout of this
repository, not a copied-out directory.

Every experiment directory contains the same two scripts, always with these
names:

- **`run.sh`** — the interactive walkthrough. It guides you through every
  manual step (button presses, replugging), runs each command visibly, and
  explains the output. Use it the first time through.
- **`check.sh`** — the quick verdict. Non-interactive, no prompts, exit code
  0/1. Use it to re-verify a setup you already understand.

Plus a **`README.md`**: what the experiment proves, the manual commands behind
the scripts, an **Expected output** section captured from real hardware, the
ideas to take away, and a troubleshooting table.

## Index

| Experiment | Proves |
| --- | --- |
| [exp101-board-bringup](./exp101-board-bringup/) | The board, cable, and host can see each other (no Rust yet) |
| [exp102-rust-toolchain](./exp102-rust-toolchain/) | This machine can cross-compile RP2350 firmware (no board needed) |
| [exp103-embassy-blink](./exp103-embassy-blink/) | Source code becomes a blinking LED — the toolchain end to end |
| [exp104-usb-serial](./exp104-usb-serial/) | The board talks back over USB CDC-ACM — no extra hardware |

Planned (order not final). The early track holds to one rule: **a Pico 2 and
a USB cable, nothing else to buy.**

- **USB serial, two-way** — read what the host types, and use the 1200-baud
  touch to retire the BOOTSEL button.
- **async tasks and channels** — several `#[task]`s, `select`, and passing
  data between them.
- **BOOTSEL as a button** — the classic button-controls-LED experience with
  zero extra parts. The Pico 2 has no user button, and `embassy-rp` does not
  expose BOOTSEL on the RP2350, so the register work is quarantined behind a
  one-line API in this repo — labelled magic, the same way exp103 handles
  `rp2350-linker`.
- **boot anatomy** — open both boxes: hand-write the memory map and the
  image-definition block the ROM scans for, and read BOOTSEL the hard way.
- **defmt/RTT logging** *(needs a debug probe — optional side track)*.
