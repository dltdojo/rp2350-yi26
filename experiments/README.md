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

Repository-wide, alongside `lib.sh`:

- **[`audit.sh`](./audit.sh)** — disclosure report. Prints the
  security-relevant choices baked into each firmware, with the evidence for
  each and the risk it carries, so you can decide whether they suit you.

## Security disclosure

These experiments are tuned for learning, which means convenience settings are
on by default — most visibly the 1200-baud auto-reboot, which lets any host
program put your board into its bootloader. That is the right default for
development and the wrong default for a lot of other places.

Rather than make you hunt for such choices, `./audit.sh` lists them:

```sh
cd experiments
./audit.sh                    # every experiment
./audit.sh exp105-usb-reboot  # just one
```

Two things make the report trustworthy enough to act on:

- **Every line states its evidence** — which file, which resolved cargo
  feature, which string inside the `.uf2`. Nothing asks to be taken on faith.
- **The artifact is ground truth, not the source.** `Cargo.toml` describes
  what a *default* build would produce; firmwares therefore stamp a plain-text
  marker into the image recording how they were actually compiled
  (`strings firmware.uf2 | grep yi26-cfg`). When the two disagree, the report
  says so loudly — that gap is how someone audits one thing and flashes
  another.

It is **disclosure, not verification**: it reports declared and observable
build choices. It cannot tell you what is running on a board right now, and it
is not a security review of the code. The output says as much, every time.

Plus a **`README.md`**: what the experiment proves, the manual commands behind
the scripts, an **Expected output** section captured from real hardware, the
ideas to take away, and a troubleshooting table.

## How this repository is developed

### Every new experiment starts with an interrogation

No new experiment and no new idea goes straight to a plan or to code. It first
has to survive a round of questioning against what this repository is for —
teaching a beginner — and against YAGNI and KISS. The point is to surface the
contradictions while changing course is still free.

The sequence:

1. **Establish the facts first.** Never offer an option built on an
   assumption: compile it, run it, read the crate source. Asking "stable or
   nightly?" is only useful once stable has been proven to build the thing;
   proposing a BOOTSEL-button experiment is only honest once the compiler has
   confirmed whether the HAL exposes it.
2. **Name the contradictions, not the request.** Not a restatement of what was
   asked, but the specific places where the obvious implementation goes wrong.
3. **Separate the decisions.** Whatever can be decided from the code, the
   repo's conventions, or plain judgement gets decided and stated. Only
   choices where different answers mean *materially different work* become
   questions.
4. **Ask two to four focused questions**, each with concrete options and a
   recommendation.
5. **Only then** plan and build.

Questions that keep recurring, worth asking of anything new:

- **Scope** — what is the single thing this proves? Is it one experiment or
  two wearing a trench coat?
- **Prerequisites** — does this add a hardware or tool requirement? The early
  track holds to a board and a USB cable (see [Boards](#boards)).
- **Magic** — what stays hidden behind a labelled one-liner, and what gets
  opened? (exp103's `rp2350-linker` is the reference case.)
- **Duplication** — where does this live so it cannot drift out of sync? (see
  [`lib.sh`](./lib.sh), and the rule that code comments beat README excerpts.)
- **Exercise** — does the reader do something, or only read?

The gate has teeth. It has already cut the flashing half and ~100 lines of
script out of exp101, split toolchain setup from the first firmware into
exp102 and exp103, deleted a vendored binary and the five files that existed
only to support it, replaced nightly Rust with stable, and demoted picotool
from required to optional.

### Nothing is pushed unverified

One rule governs what reaches GitHub:

> **Nothing is pushed until it has been verified on real hardware.**

Work in progress is committed locally as often as is useful, but a push means
someone plugged a board in and watched it work. The `Expected output` section
of each experiment is that verification, pasted in — never hand-written,
never predicted from what the code "should" do.

This exists because the gap between "it compiles" and "it works" is where
learners get stranded. An experiment that only ever built cleanly is not
evidence that a reader following it will succeed; it is a hypothesis. Hardware
runs also surface things no amount of reading finds — exp104's discovery that
the firmware stalls mid-write when nothing is draining the serial port came
out of a real capture, not the source.

Practical consequences:

- Build-only checks (`cargo build`, UF2 conversion) can be verified anywhere,
  and `check.sh` is written so it passes with or without a board attached.
- The board-dependent half waits for hardware. If an experiment is committed
  but not yet verified, its commit message says so plainly.
- A firmware without USB cannot be rebooted from the host, so flashing the
  next experiment needs a human on the BOOTSEL button. That is a real cost of
  the early track, and the reason the 1200-baud experiment is worth reaching.

## Index

| Experiment | Proves |
| --- | --- |
| [exp101-board-bringup](./exp101-board-bringup/) | The board, cable, and host can see each other (no Rust yet) |
| [exp102-rust-toolchain](./exp102-rust-toolchain/) | This machine can cross-compile RP2350 firmware (no board needed) |
| [exp103-embassy-blink](./exp103-embassy-blink/) | Source code becomes a blinking LED — the toolchain end to end |
| [exp104-usb-serial](./exp104-usb-serial/) | The board talks back over USB CDC-ACM — no extra hardware |
| [exp105-usb-reboot](./exp105-usb-reboot/) | The firmware puts itself into the bootloader — the button retires |

Planned (order not final). The early track holds to one rule: **a Pico 2 and
a USB cable, nothing else to buy.**

- **USB serial, two-way** — read what the host types, so the keyboard becomes
  the first input device.
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
