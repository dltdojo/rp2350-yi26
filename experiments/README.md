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
| exp105 | Any RP2350 board. Chip-level ROM and USB behaviour only. |
| exp106 | Any RP2350 board with a plain LED (change the pin) and a BOOTSEL button. |
| exp107 | Any RP2350 board with a plain LED (change the pin) and a BOOTSEL button. |
| exp108 | Any RP2350 board with a plain LED (change the pin). The temperature sensor is ADC channel 4 on every RP2350 — and on the RP2040 too. |
| exp109 | Any RP2350 board. **RP2350 only in a way the others are not**: the RP2040 has no TRNG at all. |
| exp110 | Any RP2350 board. Uses the TRNG, so RP2350 only. |
| exp111 | Any RP2350 board. Uses both, so RP2350 only. |
| exp112 | Any RP2350 board. Uses the TRNG, so RP2350 only. |
| exp113 | Any RP2350 board. Reads OTP for a chip identity; prints what it found, so an unprogrammed part still works. |
| exp114 | Any RP2350 board. Uses both the ADC and the TRNG, so RP2350 only. The health tests themselves run anywhere — `cargo test` in `crates/entropy-health`. |
| exp115 | Any RP2350 board running any firmware from this repository — it reads descriptors, and they all enumerate the same way. Needs a Chromium browser, and on Linux one udev rule. |
| exp116 | Same as exp115, plus `yi26 detach` on Linux — the kernel's `cdc_acm` driver has to let go before a browser can claim the interfaces. |
| exp117 | Any RP2350 board running exp105 or later — it needs the 1200-baud watcher to have something to talk to. Chromium browser, and on Linux `yi26 detach` first. |
| exp118 | Any RP2350 board. No browser: the host half is `yi26 send`, which talks to the same CDC port everything else here uses. |
| exp119 | Any RP2350 board. No browser. The host half is `yi26 flood`, which needs a port that can be written to and have RTS toggled at the same time. |
| exp120 | A board running **exp118** — it is the only firmware here that reads the OUT endpoint, and sending to any other looks identical to this page failing. Chromium browser, and on Linux `yi26 detach` first. |
| exp121 | Any RP2350 board. No browser. Checking the keypress needs read access to `/dev/input` — the `input` group — and the check says so rather than failing if you lack it. |

Two cases need more than a pin change: the **Pico 2 W** routes its LED through
the wireless chip, and boards whose only LED is an **RGB/NeoPixel** need a PIO
driver rather than a plain output. Both are out of scope for now.

Boards also differ in how you enter BOOTSEL — a button, a jumper, or shorting
a pad. Whatever the mechanism, the ROM behaviour it triggers is the same.

If you run these on a third-party board, a report either way is welcome: only
the official Pico 2 has been verified here.

## Platform

Verified on **Ubuntu Linux** only, against a real Pico 2. The scripts say so
up front and stop on other platforms rather than failing confusingly halfway
through.

The parts that used to make that a hard boundary have moved. Finding the
board, reading its log, triggering the 1200-baud reboot, locating the boot
drive and flashing it now live in [`tools/yi26`](../tools/README.md), a small
Rust program written with portable crates. Its macOS and Windows paths are
implemented; **nobody has run them**, which is why the guard is still there.
If you try it elsewhere, `yi26 doctor --json` will tell you the host is
unverified, and a report either way is welcome.

What remains genuinely Linux-bound is smaller than it was: mounting a
removable drive without root (`udisksctl` — macOS and Windows do it
automatically), and exp101, which deliberately uses raw `lsusb`, `lsblk` and
`udisksctl` because it runs before Rust is installed and because showing those
commands is what that experiment is for.

On a different platform the supported path is still a **port, not a
workaround**, and this repository is deliberately good input for one: the
scripts are short, every command is shown, and `yi26 --explain` prints the
hand-typed equivalent of everything the tool does. Hand an experiment's
`run.sh`, `check.sh` and `README.md` to an AI assistant and ask it to
translate the steps.

Running another Linux that is close enough (apt equivalents, udisks2)?
Acknowledge the difference and proceed: `RP2350_ANY_PLATFORM=1 ./run.sh`.

No Linux machine at all? Building and flashing are separable — the seam is the
`.uf2` file, and the two halves can sit on two different computers. A rented
Linux box builds; the machine you already own drags the file onto the board's
boot drive, which needs no toolchain and no drivers.
[`docs/platforms.md`](../docs/platforms.md) works that through experiment by
experiment, including what it costs you (exp101) and what still needs software
on your own machine (reading the serial port).

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
- **[`../tools/yi26`](../tools/README.md)** — the host-side helper the scripts
  call to talk to the board. `lib.sh` builds it on first use; there is nothing
  to install. Run `yi26 doctor` when something is wrong, or
  `yi26 doctor --json` if the thing debugging is not a person.

Anything platform-specific belongs in the tool, not in a script. That is the
rule the third one exists to enforce: the shell scripts are the teaching
narrative, and the tool is the single implementation of the parts that would
otherwise need one version per operating system. Every subcommand takes
`--explain` and prints what it stands in for, so replacing the commands does
not mean hiding them.

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
| [exp106-bootsel-button](./exp106-bootsel-button/) | BOOTSEL becomes a user button — input drives output, no parts |
| [exp107-debug-logging](./exp107-debug-logging/) | Three tasks share one serial log — printing that cannot stall the work |
| [exp108-adc-temperature](./exp108-adc-temperature/) | The chip takes its own temperature — one ADC channel and the datasheet's arithmetic |
| [exp109-hardware-trng](./exp109-hardware-trng/) | Real entropy, and what it costs to ask — a driver default that is wrong by a factor of thousands |
| [exp110-await-not-block](./exp110-await-not-block/) | The same slow hardware, awaited and blocked on, with the difference measured |
| [exp111-measuring-randomness](./exp111-measuring-randomness/) | Two sources that both look random — and what two cheap tests can and cannot tell you |
| [exp112-silent-fallback](./exp112-silent-fallback/) | A build that quietly stopped using the hardware RNG — and every test that fails to notice |
| [exp113-enumerable-seed](./exp113-enumerable-seed/) | A seed the board can crack in 46 ms — why a space is not an entropy |
| [exp114-health-tests](./exp114-health-tests/) | The two continuous tests SP 800-90B specifies — and a source that refuses to emit when they fail |
| [exp115-webusb-enumerate](./exp115-webusb-enumerate/) | A browser opens the board and prints its descriptors — no firmware, no driver, no server |
| [exp116-webusb-cdc-log](./exp116-webusb-cdc-log/) | The same log, read in a browser — claim the interfaces, drive the control pipe by hand |
| [exp117-webusb-reboot](./exp117-webusb-reboot/) | A web page puts the board into its bootloader — the request whose success looks exactly like failure |
| [exp118-one-receiver-two-jobs](./exp118-one-receiver-two-jobs/) | The firmware starts listening, and ownership — not taste — decides the shape of the program |
| [exp119-cancelled-reads](./exp119-cancelled-reads/) | Twenty thousand reads cancelled on purpose, and the control variable that makes a zero mean something |
| [exp120-webusb-two-way](./exp120-webusb-two-way/) | The page types and the firmware answers — a hundred bytes sent once, arriving twice |
| [exp121-composite-hid](./exp121-composite-hid/) | A keyboard beside the log on one cable, and what build order does to every number in the descriptors |

## Planned

The early track holds to one rule: **a Pico 2 and a USB cable, nothing else to
buy.** The next run of experiments keeps it, and adds one requirement that is
free but not neutral — a Chromium browser. Where that comes from is below.

### The browser track

These build toward a specific destination: **debugging firmware with a phone**.
Plug the board into an Android phone, open a page, and read the device's own
log — no app to install, no second computer, no debug probe. That matters
because a phone is the most hostile host to debug against: its only USB port is
occupied by the device under test, so `adb` is unavailable exactly when you
need it, and there is no Wireshark on a stock phone. When you cannot observe
from the host, the device has to observe itself, and you have to be able to
read that on the phone.

Two facts set the whole shape of this track:

- **Chrome on Android has WebUSB, but not Web Serial.** The desktop-only Web
  Serial API is the obvious way to read a serial port from a page, and it is
  useless here. WebUSB is what a phone has.
- **WebUSB can claim a CDC-ACM interface directly.** It sends
  `SET_LINE_CODING` and `SET_CONTROL_LINE_STATE` itself and reads the bulk IN
  endpoint. A page does *not* need the firmware to grow a vendor-specific
  interface, BOS capabilities or Microsoft OS descriptors. So the first
  experiment on this track changes no firmware at all.

| Planned | Proves |
| --- | --- |
| **exp122-vendor-bulk** | USB with no class driver at all — a raw vendor interface, two bulk endpoints, and an echo |
| **exp123-bot-framing** | The host's storage commands, printed. Declare a mass-storage interface, decode the command blocks that arrive, answer nothing — and read what a disk is actually asked |
| **exp124-msc-scsi** | Answering those commands until the host agrees a disk is there. No filesystem yet — an unformatted volume is the goal |
| **exp125-fat12-by-hand** | Boot sector, FAT, root directory, clusters, synthesized per sector. The volume mounts, with one `README.TXT` on it |
| **exp126-self-hosted-viewer** | `INDEX.HTM` on that volume *is* the exp116 page. Plug the board into anything and its debug UI is already there |

The numbering has a gap in it and that is not an accident. Verifying a browser
experiment needs a person: a WebUSB permission comes from a native dialog
behind a required user gesture, it does not survive restarting the browser, and
no tool in this repository can click it. Firmware and host-side work need
nobody. So when the board is reachable and its owner is not, the work that can
proceed is the work that proceeds — and exp118 and exp119 were built before
exp117 for no better and no worse reason than that. exp117 was finished later
the same day, in the two minutes its owner was at the bench, because that
click was the only part of it that could not be done without them.

exp126 closes a loop that opens in exp101. The `RP2350` drive that appears when
you hold BOOTSEL is not a real disk — the bootrom synthesizes a FAT volume on
the fly, `INDEX.HTM` and all, and DAPLink's `MBED.HTM` does the same. The trick
that made the first experiment work is the one the last experiment builds.

Two costs stated in advance, since neither will look smaller later.
`embassy-usb` has no MSC class, so Bulk-Only Transport and the SCSI subset are
hand-rolled — that is why exp122 – exp125 exist as four steps rather than one
experiment that lands four hundred lines at once. And WebUSB is Chromium-only:
Firefox and Safari do not implement it, which makes exp115 the first
experiment here to name a specific vendor's software. It buys the phone, and
nothing else buys the phone.

### Independent of that track

- **boot anatomy** — open both boxes: hand-write the memory map and the
  image-definition block the ROM scans for, and read BOOTSEL the hard way.
- **defmt/RTT logging** *(needs a debug probe — optional side track)*.
