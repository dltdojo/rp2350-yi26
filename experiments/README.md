# Experiments

Step-by-step, numbered experiments for learning RP2350 development on the
Raspberry Pi Pico 2 with Rust and Embassy. Each proves exactly one thing and
builds on the ones before it — do them in order, at least the first time.

Assumed setup: a Pico 2 (**non-W**), a USB data cable, and an Ubuntu machine.

## Conventions

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

Planned next: exp102 — build and flash a minimal Embassy blink, proving the
Rust toolchain end to end.
