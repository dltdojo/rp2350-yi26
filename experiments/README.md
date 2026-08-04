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
| exp122 | Any RP2350 board. Needs the udev rule for raw USB access — a vendor interface has no device node, so `yi26 echo` claims it directly. This one said "no browser" for a year; exp132 established that a page can claim class `0xFF` too, with no BOS descriptors. |
| exp123 | Any RP2350 board. No browser. The evidence is partly in sysfs, so a host whose storage driver is not `usb-storage` will show different names for the same thing. |
| exp124 | Any RP2350 board. No browser. Uses 64 KiB of SRAM as the disk, which is nothing on an RP2350 and would matter on a smaller part. |
| exp125 | Any RP2350 board. No browser. The layout crate runs `cargo test` on any machine, board or not. |
| exp126 | Any RP2350 board, and a Chromium browser for the last step — which is opening a file off the board's own volume. |
| exp127 | Any RP2350 board with a plain LED (change the pin). No browser. The pad readback is `SIO GPIO_IN`, which every RP2350 and RP2040 has. |
| exp128 | Any RP2350 board. No browser. Whether a 64-byte message ever completes depends on the **host's** USB stack, so that one result may differ elsewhere — and the check says which answer it got. |
| exp129 | Any RP2350 board. No browser. **RP2350 only** — it uses the TRNG, which the RP2040 does not have. The `draw` crate runs `cargo test` on any machine, board or not. |
| exp130 | Any RP2350 board, and a Chromium browser for the last step. **RP2350 only** — it uses the TRNG. The volume is declared read-only, and a host that honours that never writes to it. |
| exp131 | Same as exp130. The volume carries two pages and uses 55 of its 125 clusters; the third page it briefly carried took 38 more, so a board with less SRAM would need to choose between them. |
| exp132 | Any RP2350 board. **RP2350 only** — it uses the TRNG. The two-channel build needs the udev rule for raw USB access, as exp122 does. `check.sh` needs no browser; the two-tab finding needs one, and a phone. |
| exp133 | Any RP2350 board, a Chromium browser, and the udev rule for raw USB access. **RP2350 only** — it uses the TRNG. Four interfaces, which is the same count as the composites this repository already enumerates cleanly. |
| exp134 | Any RP2350 board with a plain LED (change the pin). No browser. Every policy is decided in `crates/log-policy`, which runs `cargo test` on any machine, board or not. |
| exp135 | A board running **exp128**, which is the instrument. No firmware of its own. The census needs raw USB access — the udev rule — because a tty cannot express the packet being measured. |
| exp136 | Any RP2350 board. No browser. The comparison it is named for needs no board at all — `cargo test` in `crates/framing` cuts a stream at every offset; the board is where you watch one of those cuts arrive over a real endpoint. |
| exp137 | Any RP2350 board. No browser. Uses 64 KiB of SRAM as the disk. The measurement is what **your** host's storage stack does with a media change, so this is the experiment here most likely to answer differently elsewhere — and the check reports which answer it got. |

Two cases need more than a pin change: the **Pico 2 W** routes its LED through
the wireless chip, and boards whose only LED is an **RGB/NeoPixel** need a PIO
driver rather than a plain output. Both are out of scope for now.

Boards also differ in how you enter BOOTSEL — a button, a jumper, or shorting
a pad. Whatever the mechanism, the ROM behaviour it triggers is the same.

If you run these on a third-party board, a report either way is welcome: only
the official Pico 2 has been verified here.

There are **two** of those, and it is worth saying which, because it bounds
what the evidence in this repository means. Both are official Pico 2 (non-W).
One lives with an Ubuntu machine and is what every `Expected output` here was
captured from; the other lives with an Android phone and is what
[`docs/platforms.md`](../docs/platforms.md) verified the phone-flashing route
against. They are never on the same bench, so nothing here has ever had two
RP2350s talking to each other, and nothing claims to.

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
  call to talk to the board. `lib.sh` builds it on first use, so **the scripts**
  need nothing installed. Run `yi26 doctor` when something is wrong, or
  `yi26 doctor --json` if the thing debugging is not a person.

Anything platform-specific belongs in the tool, not in a script. That is the
rule the third one exists to enforce: the shell scripts are the teaching
narrative, and the tool is the single implementation of the parts that would
otherwise need one version per operating system. Every subcommand takes
`--explain` and prints what it stands in for, so replacing the commands does
not mean hiding them.

### Typing `yi26` yourself needs one command first

Inside a script, `yi26` is a shell function that `lib.sh` defines — not a
program on your `PATH`. So the scripts work out of the box and a bare
`yi26 detach` in your own terminal answers **command not found**. Every README
here that tells you to run `yi26 something` assumes you have done one of these:

```sh
cargo install --path tools/yi26     # once, and then just: yi26 detach
tools/yi26/target/release/yi26 detach   # or the built binary, by its full path
```

This is written down because the instruction appears in thirty files and the
answer used to appear in one.

**The scripts do not use your installed copy**, and that is deliberate.
`cargo install` takes a snapshot; pull a change that adds a flag and every
script here would quietly run the old binary and fail on an option the source
plainly supports. `lib.sh` builds and uses the copy in this checkout, and
rebuilds it whenever the source is newer. So an installed `yi26` is for *your*
typing only — re-run `cargo install` after a pull if you want the two to
agree.

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
2. **Ask what has already been answered.** Before deriving anything, check the
   prior art you actually have access to — this repository's own earlier
   experiments, and any private or unpublished work of your own on the same
   ground. A question settled once by hardware does not need settling again,
   and an approach already tried and rejected does not need proposing again.

   This step exists because it was skipped. exp117's behaviour on Android was
   presented here as an open question and verified from scratch; the answer
   was already sitting in an earlier project on the same machine, along with
   several others. Nothing was wrong with the result — independent
   verification is never wasted — but the *framing* was: a finding described
   as unexpected had in fact been found before, and a day of somebody's
   attention went to re-deriving it.

   Where prior work is private, its findings may be cited here as facts. Its
   code, its paths and its identity must not appear in this repository.
3. **Name the contradictions, not the request.** Not a restatement of what was
   asked, but the specific places where the obvious implementation goes wrong.
4. **Separate the decisions.** Whatever can be decided from the code, the
   repo's conventions, or plain judgement gets decided and stated. Only
   choices where different answers mean *materially different work* become
   questions.
5. **Ask two to four focused questions**, each with concrete options and a
   recommendation.
6. **Only then** plan and build.

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
- **The way back** — if this firmware serves a volume and can be rebooted by
  software, is `FLASH.HTM` on that volume? A phone user looks in one place, and
  a build that omits it strands whoever flashed it — at the moment they next
  want to change something, which is the worst time to find out. This is a
  property of the chain rather than of one build, so it is checked and not
  merely intended. [exp131](./exp131-the-volume-is-the-app-drawer/) is where it
  became a rule, and why.

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

### A capture ages, and where that is written down

`Expected output` is what one run printed on one day. When the code moves
afterwards — a page grows, a shared crate changes, a file is re-pointed at a
different source — the capture does not follow it, because editing a capture to
match what you expect is the exact thing this section exists to forbid.

So an aged capture is **recorded, not repaired**: the experiment's own
`What is not verified here` says which lines have moved, by how much, and why
the argument still holds. Three of them say so today — exp130's page build,
exp131's UF2 size, exp132's one-channel build.

They are not a backlog, and deliberately so. This repository is walked
experiment by experiment, and the run that teaches an experiment to somebody is
the run that produces its capture; a number taken outside that order arrives
with no walkthrough attached to it. Whoever next works through one of those
experiments replaces its block with what their board actually printed.

### Of the two sizes in every capture, only one is the firmware

Each `Expected output` carries a pair of lines like these, and they do not mean
the same kind of thing:

```text
PASS  compiles (217320 byte ELF)
PASS  converts to UF2 (140800 bytes)
```

**The UF2 is the firmware.** It is what goes on the chip, and if it changes,
something about the image changed.

**The ELF byte count is a file size**, and a file size includes symbol tables
and whatever padding the linker felt like leaving between segments. It can move
a long way while the firmware does not move at all — exp134 added one
`AtomicBool::new(true)` to `crates/usb-log`, which is the first static in that
crate with a non-zero initial value and therefore the first thing to land in
`.data` rather than `.bss`. A non-empty `.data` gets its own 64 KiB-aligned
segment, so **every dependent firmware's ELF grew by 65,608 bytes of hole**.
Built at that commit's parent, exp133's ELF is 217320 bytes, the number in its
README; built after it, 282928. `.bss` is byte-identical either way, so the RAM
cost is nothing, and the UF2 is 140800 in both.

So an ELF number that disagrees with a capture is not evidence of anything by
itself. Compare the UF2, and if that disagrees, compare it against what changed
in the source rather than against the toolchain.

## Which of these can I do right now

The **Needs** column in the index below answers one question: how much of a
*person* does this experiment cost? It exists because the answer changes what
you can do at two in the morning with the board plugged in and nobody else
awake — and because most of these experiments cost nothing.

| | Means | Experiments |
| --- | --- | --- |
| **0 · none** | No board at all. A machine and nothing else | exp102 |
| **1 · board** | A board attached, and nothing but software after that | exp104, exp105, exp107–exp114, exp118, exp119, exp121–exp125, exp128, exp129, exp134, exp136, exp137 |
| **2 · a moment** | A person for one action, then software does the rest | exp101, exp115–exp117, exp120, exp126, exp130–exp133, exp135 |
| **3 · a person** | A person **is** the instrument — nothing here can see the result | exp103, exp106, exp127 |

Three things the number means precisely, because a wrong "nobody needed" sends
somebody to a bench for no reason:

- **It describes verifying the claim in full**, which is usually more than
  `check.sh` reaches on its own. exp127 is the clearest case: all seventeen of
  its checks pass unattended, and not one of them can see whether the LED
  emitted light. Each `check.sh` says in a comment how far it gets alone.
- **Level 2 does not say where that person has to be.** A hand on BOOTSEL means
  somebody at the bench. A tap on a browser's WebUSB permission dialog means
  somebody at a browser — which, for exp115 onward, can be a phone anywhere
  with the board plugged into it. Same level, very different logistics.
- **Level 3 is not "harder", it is "unobservable"**. exp103's blinking LED is
  the simplest firmware here and it is a 3, because no software in this
  repository can watch a light.

### What the number deliberately leaves out

**The cost of flashing *into* an experiment is not in it**, because that is not
a property of the experiment. Putting exp104 on the board needs a hand on
BOOTSEL when the board is currently running exp103 — which has no USB at all —
and needs nothing when it is running exp105 or later, because from exp105 on
the firmware reboots itself on the 1200-baud touch.

Same experiment, two different answers, and only something that can see the
board right now can pick between them:

```sh
yi26 port --json     # "serial_number":"127" — this board is running exp127
yi26 state           # bootsel | running | detached | absent
```

A board running exp105 or later is reachable from software, so the only
presence cost left is the number in the table. A board running exp101–exp104,
or nothing at all, needs a hand once before any of that applies.

### Where it is declared

In `check.sh`, one line, beside the code it describes:

```sh
PRESENCE=3   # an eye on the LED — check.sh gets the pad, not the light
```

`presence_check` in [`lib.sh`](./lib.sh) fails if that number and the index
below ever disagree, so the table cannot quietly rot into a lie. It says
nothing when they agree.

## Which layer of USB is this?

By exp122 a single firmware here declared **three** USB functions at once, and
by exp126 a board was serving files over one interface while logging over
another. At that point "this experiment uses USB" had stopped saying anything.

Three questions, and they move independently:

- **Which interface** does the board declare? CDC-ACM, HID, mass storage, a
  vendor interface nobody claims — or none at all.
- **What travels** on it? A log, a command, a control request, a file. The same
  CDC interface carries the log in one direction and commands in the other,
  which is the most common place to get lost.
- **Who consumes it** on the host? A kernel driver, a browser, or `yi26`
  holding the interface raw.

That they are independent is not a technicality. **exp115, exp116 and exp117
change no firmware whatsoever** — same board, same descriptors, same CDC
interface. Only the host side moves, from the kernel's `cdc_acm` to a browser.
Read down the *Host side* column and that jump is the only thing that happens.

| | Interface | Carries | Host side | Runs on |
| --- | --- | --- | --- | --- |
| exp101 | `bootrom` | `descriptors+files` | `bootrom` | `bootrom` |
| exp102 | `none` | `none` | `none` | `none` |
| exp103 | `none` | `none` | `none` | `own` |
| exp104 | `cdc` | `log` | `cdc_acm` | `own` |
| exp105 | `cdc` | `log+control` | `cdc_acm` | `own` |
| exp106 | `cdc` | `log` | `cdc_acm` | `own` |
| exp107 | `cdc` | `log` | `cdc_acm` | `own` |
| exp108 | `cdc` | `log` | `cdc_acm` | `own` |
| exp109 | `cdc` | `log` | `cdc_acm` | `own` |
| exp110 | `cdc` | `log` | `cdc_acm` | `own` |
| exp111 | `cdc` | `log` | `cdc_acm` | `own` |
| exp112 | `cdc` | `log` | `cdc_acm` | `own` |
| exp113 | `cdc` | `log` | `cdc_acm` | `own` |
| exp114 | `cdc` | `log` | `cdc_acm` | `own` |
| exp115 | `cdc` | `descriptors` | `webusb` | `any` |
| exp116 | `cdc` | `log+control` | `webusb` | `any` |
| exp117 | `cdc` | `control` | `webusb` | `exp105+` |
| exp118 | `cdc` | `log+commands` | `cdc_acm` | `own` |
| exp119 | `cdc` | `log+commands+control` | `cdc_acm` | `own` |
| exp120 | `cdc` | `log+commands` | `webusb` | `exp118` |
| exp121 | `cdc+hid` | `log+keystrokes` | `cdc_acm+hid` | `own` |
| exp122 | `cdc+hid+vendor` | `log+commands` | `cdc_acm+libusb` | `own` |
| exp123 | `cdc+msc` | `log+scsi` | `cdc_acm+usb-storage` | `own` |
| exp124 | `cdc+msc` | `log+scsi` | `cdc_acm+usb-storage` | `own` |
| exp125 | `cdc+msc` | `log+files` | `cdc_acm+usb-storage` | `own` |
| exp126 | `cdc+msc` | `log+files` | `cdc_acm+usb-storage+webusb` | `own` |
| exp127 | `cdc` | `log+commands` | `cdc_acm` | `own` |
| exp128 | `cdc` | `log+commands` | `cdc_acm` | `own` |
| exp129 | `cdc` | `log+commands` | `cdc_acm` | `own` |
| exp130 | `cdc+msc` | `log+commands+files` | `cdc_acm+usb-storage+webusb` | `own` |
| exp131 | `cdc+msc` | `log+commands+files` | `cdc_acm+usb-storage+webusb` | `own` |
| exp132 | `cdc+vendor` | `log+commands` | `cdc_acm+libusb` | `own` |
| exp133 | `cdc+msc+vendor` | `log+commands+files` | `cdc_acm+usb-storage+libusb+webusb` | `own` |
| exp134 | `cdc` | `log` | `cdc_acm` | `own` |
| exp135 | `cdc` | `log+commands` | `libusb+webusb` | `exp128` |
| exp136 | `cdc` | `log+commands` | `cdc_acm` | `own` |
| exp137 | `cdc+msc` | `log+commands+files` | `cdc_acm+usb-storage` | `own` |

### Reading the columns

**Interface** — what `src/main.rs` builds. `bootrom` means the RP2350's own
ROM is the USB device and no code here is involved, which is only exp101.

**Carries** — what the experiment's *result* rides on, not every transfer the
plumbing performs. Every WebUSB page sends `SET_LINE_CODING`; only the
experiments where a control request is the subject are marked `control`.

| | |
| --- | --- |
| `descriptors` | Reading what the device says it is, over EP0 |
| `control` | An EP0 request that *changes* something — the 1200-baud touch |
| `log` | Text, device to host |
| `commands` | Bytes the host sends that the firmware acts on |
| `keystrokes` | HID reports on an interrupt endpoint |
| `scsi` | Mass-storage command blocks |
| `files` | The contents of a volume |

**Host side** — who claims the interface. `cdc_acm`, `usb-storage` and `hid`
are kernel drivers; `libusb` means no driver claims it and `yi26` opens it
directly; `webusb` means a browser does, which is why the kernel has to let go
first (`yi26 detach`).

**Web Serial appears nowhere in this table, deliberately.** It is the obvious
way to read a serial port from a page and it does not exist on Android, which
is the one host this repository's browser track was built for. exp115 works
through that decision.

**Runs on** — whose firmware this runs against, and it is a separate column
because **six experiments here have no `src/` at all**. The difference between
them matters: exp116 works against any firmware in this repository, while
exp120 works against **exp118 and nothing else**, because exp118 is the only
one that reads the OUT endpoint. Flash the wrong one and the page fails for no
visible reason.

Every row is declared in that experiment's own `check.sh` and checked by
`usb_check` in [`lib.sh`](./lib.sh). The *Interface* column is checked against
`src/main.rs` as well as against this table, so adding a HID interface and
forgetting to write it down is caught rather than trusted.

## Which page do I open?

There are HTML files in several of these directories, and there are four more
in [`tools/pages/`](../tools/pages/). They are not the same kind of thing, and
one question separates them:

> Does this page work against **every** firmware in this repository?

**Yes — it is a tool**, and the maintained copy is in `tools/pages/`: a
descriptor inspector, a log viewer, a console that types bytes back, and the
page that puts a board into its bootloader. Those are the ones to open when you
want to *do* something to a board. They are also the browser's half of
[`yi26`](../tools/README.md), and that README's tables say exactly where the
two overlap and where neither can follow the other.

**No — it is an appliance**, and it belongs to the experiment whose protocol it
speaks. exp130's and exp133's prize-draw pages know one firmware's commands and
are useless against anything else. An appliance may even pin a serial number in
its device filter, which a tool may never do.

### Why the experiments still have their own copies

exp115, exp116, exp117 and exp120 each built one of those tools, and each still
contains the page as the experiment left it. That is on purpose. Each
experiment's page **is** its walkthrough — turning exp116 into a link to
somewhere else would delete what a reader came to exp116 for, and the history
of how the tool got there would go with it. exp120 is the clearest case: its
page cannot send `\x01`, and that gap is precisely why `console.html` exists.

Those copies are frozen, are not maintained, and say so in a box at the top of
the page. `tools/pages/check.sh` asserts every one of them still says it.

## Index

| Experiment | Needs | Proves |
| --- | --- | --- |
| [exp101-board-bringup](./exp101-board-bringup/) | 2 · a moment | The board, cable, and host can see each other (no Rust yet) |
| [exp102-rust-toolchain](./exp102-rust-toolchain/) | 0 · none | This machine can cross-compile RP2350 firmware (no board needed) |
| [exp103-embassy-blink](./exp103-embassy-blink/) | 3 · a person | Source code becomes a blinking LED — the toolchain end to end |
| [exp104-usb-serial](./exp104-usb-serial/) | 1 · board | The board talks back over USB CDC-ACM — no extra hardware |
| [exp105-usb-reboot](./exp105-usb-reboot/) | 1 · board | The firmware puts itself into the bootloader — the button retires |
| [exp106-bootsel-button](./exp106-bootsel-button/) | 3 · a person | BOOTSEL becomes a user button — input drives output, no parts |
| [exp107-debug-logging](./exp107-debug-logging/) | 1 · board | Three tasks share one serial log — printing that cannot stall the work |
| [exp108-adc-temperature](./exp108-adc-temperature/) | 1 · board | The chip takes its own temperature — one ADC channel and the datasheet's arithmetic |
| [exp109-hardware-trng](./exp109-hardware-trng/) | 1 · board | Real entropy, and what it costs to ask — a driver default that is wrong by a factor of thousands |
| [exp110-await-not-block](./exp110-await-not-block/) | 1 · board | The same slow hardware, awaited and blocked on, with the difference measured |
| [exp111-measuring-randomness](./exp111-measuring-randomness/) | 1 · board | Two sources that both look random — and what two cheap tests can and cannot tell you |
| [exp112-silent-fallback](./exp112-silent-fallback/) | 1 · board | A build that quietly stopped using the hardware RNG — and every test that fails to notice |
| [exp113-enumerable-seed](./exp113-enumerable-seed/) | 1 · board | A seed the board can crack in 46 ms — why a space is not an entropy |
| [exp114-health-tests](./exp114-health-tests/) | 1 · board | The two continuous tests SP 800-90B specifies — and a source that refuses to emit when they fail |
| [exp115-webusb-enumerate](./exp115-webusb-enumerate/) | 2 · a moment | A browser opens the board and prints its descriptors — no firmware, no driver, no server |
| [exp116-webusb-cdc-log](./exp116-webusb-cdc-log/) | 2 · a moment | The same log, read in a browser — claim the interfaces, drive the control pipe by hand |
| [exp117-webusb-reboot](./exp117-webusb-reboot/) | 2 · a moment | A web page puts the board into its bootloader — the request whose success looks exactly like failure |
| [exp118-one-receiver-two-jobs](./exp118-one-receiver-two-jobs/) | 1 · board | The firmware starts listening, and ownership — not taste — decides the shape of the program |
| [exp119-cancelled-reads](./exp119-cancelled-reads/) | 1 · board | Twenty thousand reads cancelled on purpose, and the control variable that makes a zero mean something |
| [exp120-webusb-two-way](./exp120-webusb-two-way/) | 2 · a moment | The page types and the firmware answers — a hundred bytes sent once, arriving twice |
| [exp121-composite-hid](./exp121-composite-hid/) | 1 · board | A keyboard beside the log on one cable, and what build order does to every number in the descriptors |
| [exp122-vendor-bulk](./exp122-vendor-bulk/) | 1 · board | An interface no operating system claims — and two owners on one device at once |
| [exp123-bot-framing](./exp123-bot-framing/) | 1 · board | Declare a disk and refuse every command, to read how a host decides whether one is there |
| [exp124-msc-scsi](./exp124-msc-scsi/) | 1 · board | Answer until the host agrees a disk is there — 64 KiB of RAM, and an unformatted volume |
| [exp125-fat12-by-hand](./exp125-fat12-by-hand/) | 1 · board | A boot sector, a FAT and a root directory written by hand, until the volume mounts with a file on it |
| [exp126-self-hosted-viewer](./exp126-self-hosted-viewer/) | 2 · a moment | The board carries its own debug page — and the bootloader drive from exp101 turns out to have been doing this all along |
| [exp127-host-owns-the-led](./exp127-host-owns-the-led/) | 3 · a person | One byte changes the board — and the LED stops being proof that the firmware is alive |
| [exp128-reassemble-by-hand](./exp128-reassemble-by-hand/) | 1 · board | A message is what you put back together — and the class API keeps the boundary the wire was carrying |
| [exp129-numbered-draws](./exp129-numbered-draws/) | 1 · board | A prize draw on the board — unbiased by construction, refused when the source fails, and numbered so a discarded draw shows |
| [exp130-the-board-draws](./exp130-the-board-draws/) | 2 · a moment | The board serves the page that shows its own draw — and a browser arrives between the TRNG and the room |
| [exp131-the-volume-is-the-app-drawer](./exp131-the-volume-is-the-app-drawer/) | 2 · a moment | Everything a phone ever needs is on the drive, including the way to replace the firmware |
| [exp132-one-owner-or-two](./exp132-one-owner-or-two/) | 2 · a moment | Two programs watching one draw at once — which one interface cannot do, and what a second one costs |
| [exp133-a-page-per-job](./exp133-a-page-per-job/) | 2 · a moment | The appliance page carries no log code, the log page knows nothing about draws, and both work at once |
| [exp134-the-log-nobody-reads](./exp134-the-log-nobody-reads/) | 1 · board | A full queue keeps the oldest lines, the newest, or none — three builds of one firmware, and the same silence reads three ways |
| [exp135-a-packet-with-no-bytes](./exp135-a-packet-with-no-bytes/) | 2 · a moment | The message that never ends, ended — and why a terminal cannot send the packet that ends it |
| [exp136-joining-halfway](./exp136-joining-halfway/) | 1 · board | Two boundaries built out of nothing, judged on joining the stream halfway — one loses messages, the other invents them |
| [exp137-the-volume-that-changes](./exp137-the-volume-that-changes/) | 1 · board | The volume is laid down again while the host is looking at it — the host honours the signal completely, and the file still does not change |

## The browser track, finished

Twelve experiments, exp115 through exp126, built toward one destination:
**debugging firmware with a phone.** Plug the board into an Android phone,
open a page, and read the device's own log — no app to install, no second
computer, no debug probe.

That mattered because a phone is the most hostile host to debug against. Its
only USB port is occupied by the device under test, so `adb` is unavailable
exactly when you need it, and there is no Wireshark on a stock phone. When you
cannot observe from the host, the device has to observe itself, and you have
to be able to read that on the phone.

Two facts set the shape of the whole thing:

- **Chrome on Android has WebUSB, but not Web Serial.** The desktop-only Web
  Serial API is the obvious way to read a serial port from a page, and it is
  useless here.
- **WebUSB can claim a CDC-ACM interface directly.** It sends
  `SET_LINE_CODING` and `SET_CONTROL_LINE_STATE` itself and reads the bulk IN
  endpoint — so the first three experiments changed no firmware at all.

Where it arrived: a phone with one USB port can **flash** the board
([exp117](./exp117-webusb-reboot/)), **talk to** it
([exp120](./exp120-webusb-two-way/)) and **read its log**
([exp116](./exp116-webusb-cdc-log/)) — with the log page coming off the board
itself ([exp126](./exp126-self-hosted-viewer/)) and the reboot page joining it
there ([exp131](./exp131-the-volume-is-the-app-drawer/)), which is what makes
the next flash need no download either.

[exp126](./exp126-self-hosted-viewer/) closes a loop that opens in exp101. The
`RP2350` drive that appears when you hold BOOTSEL is not a real disk — the
bootrom synthesises a FAT volume on the fly, `INDEX.HTM` and all, and
DAPLink's `MBED.HTM` does the same. The trick that made the first experiment
work is the one the last experiment built.

Two costs, stated when the track was planned and still true. `embassy-usb` has
no MSC class, so Bulk-Only Transport and the SCSI subset are hand-rolled —
which is why exp123 to exp126 are four steps rather than one experiment that
lands four hundred lines at once. And WebUSB is Chromium-only: Firefox and
Safari do not implement it, which makes exp115 the first experiment here to
name a specific vendor's software. It buys the phone, and nothing else buys
the phone.

### The numbers ran in order; the work did not

Verifying a browser experiment needs a person: a WebUSB permission comes from
a native dialog behind a required user gesture, it does not survive restarting
the browser, and no tool in this repository can click it. Firmware and
host-side work need nobody.

So exp118 and exp119 were built while exp117 sat empty — not because they were
more important, but because the board was reachable and its owner was not.
exp117 was finished later the same day, in the couple of minutes its owner was
at the bench, because that click was the only part of it that could not be
done without them. The same shape decided exp121 onward: a descriptor change
waits for someone who can reach the BOOTSEL button, since a malformed
descriptor leaves no software route back.

## Planned

### The framing road

[exp127](./exp127-host-owns-the-led/) let the host change the board with one
byte, and was explicit that one byte needs no framing only because it fits
inside a packet. What follows is the bill for that dodge.
[exp128](./exp128-reassemble-by-hand/),
[exp135](./exp135-a-packet-with-no-bytes/) and
[exp136](./exp136-joining-halfway/) paid it in three instalments, and the road
is now finished: where a boundary comes from, what the transport's own boundary
costs, and what it takes to build one out of nothing. Each of the three
corrected something this section claimed before anything was built, which is
the argument for interrogating a direction rather than scheduling it.

**Done.** [exp128](./exp128-reassemble-by-hand/) reassembles messages from
packets, and corrected a claim this section made before anything was built:
`read_transfer()` does exist in `embassy-usb-driver` and does loop until a
short packet, but **`CdcAcmClass`'s `Receiver` does not expose it**. Only a
firmware holding a raw endpoint can call it, so on CDC the boundary has to be
put back by hand. That is a better lesson than the comparison planned here,
and it was only findable by reading the crate.

**Done.** *the message that never arrives* — a message whose length is an exact
multiple of 64 has no short packet to end it, and exp128 measured what happens:
the message never completes and the *next* one is silently merged into it.
[exp135](./exp135-a-packet-with-no-bytes/) made one arrive, and the cost of
doing so is the finding. A zero-length packet is not a byte you can echo, so
nothing behind a tty can send one: `yi26 send --end` had to claim the CDC data
interface directly, exactly as a browser does, which is the first thing here a
page could do before the command line could. Both host stacks put it on the
wire, and one unterminated message still poisons the next — a terminator
prevents the merge and cannot undo it.

**Done.** *building a boundary out of nothing* —
[exp136](./exp136-joining-halfway/) built both, length-prefix and COBS, and
judged them on the one question that separates them: join a stream halfway and
see which can resynchronise. The answer inverted the expectation.
`crates/framing` cuts a stream at every offset, and length-prefix **loses fewer
messages while inventing three that were never sent**; COBS invents none and
drops one per boundary it cannot recognise. The trade is loss against
fabrication, and they are not equally bad — a dropped message announces itself,
an invented one is indistinguishable from a real one.

**SPI, I²C and CAN are not on this road, and will not be.** Their boundaries
live on a dedicated wire, in the bus's electrical states, and in the frame
itself — which is exactly why they are worth *comparing* to USB, and exactly
why verifying them needs hardware this repository does not have. The
comparison is written down in
[exp127's README](./exp127-host-owns-the-led/#where-message-boundaries-come-from)
as a map, labelled as unverified, rather than faked as an experiment. See
[Platform](#platform) for why that line is where it is.

### Standing alone

- **boot anatomy** — open both boxes: hand-write the memory map and the
  image-definition block the ROM scans for, and read BOOTSEL the hard way.
  The most dangerous idea in this list: a malformed image definition is a
  board the ROM will not start, and there is no software route back from that.
- **defmt/RTT logging** *(needs a debug probe — optional side track, and the
  first thing here that would break the one-cable rule)*.
