# Experiments

Step-by-step, numbered experiments for learning RP2350 development on the
Raspberry Pi Pico 2 with Rust and Embassy. Each proves exactly one thing and
builds on the ones before it — do them in order, at least the first time.

Assumed setup: a Pico 2 (**non-W**), a USB data cable, and an Ubuntu machine.

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

Planned next: exp103 — write, build, and flash a minimal Embassy blink; the
LED is the toolchain proven end to end.
