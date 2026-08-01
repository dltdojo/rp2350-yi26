# Experiments

Step-by-step, numbered experiments for learning RP2350 development on the
Raspberry Pi Pico 2 with Rust and Embassy. Each experiment builds on the ones
before it — do them in order, at least the first time.

Not every experiment is Rust: the early ones deliberately use plain host tools
first, so that each new layer (toolchain, USB class, async structure) is
introduced against a working baseline and the *comparison* itself teaches.

## Conventions

Every experiment directory looks the same:

- **`run.sh`** — the one command you run. Always this name, in every
  experiment. It checks prerequisites, guides you through any manual steps
  (button presses, replugging), and verifies the result.
- **`README.md`** — what the experiment does, why it exists, what to take
  away, and a troubleshooting table.
- **`assets/`** — anything prebuilt the experiment needs, always with
  provenance and rebuild instructions.

All experiments assume a Pico 2 (**non-W**) and an Ubuntu host, per exp101.

## Index

| Experiment | Question it answers |
| --- | --- |
| [exp101-board-bringup](./exp101-board-bringup/) | Is my board, cable, and host actually working? (no Rust yet) |

More to come — the planned track continues with building the same blink from
source with Rust + Embassy, then defmt/RTT logging, then USB serial.
