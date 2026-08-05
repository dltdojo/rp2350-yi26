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
| exp138 | Any RP2350 board. No browser. **RP2350 only, and in the strongest sense yet**: the ROM functions it calls do not exist on the RP2040. Reads only — nothing here writes to flash. |
| exp139 | Any RP2350 board. No browser. **RP2350 only** — partition tables are a ROM feature the RP2040 has no equivalent of. The sector numbers assume 4 MiB of flash; a board with more can extend the partition, and one with less must shrink it or the table describes memory that is not there. |
| exp140 | Any machine. **No board at all** — the whole thing is `cargo test` in `crates/image-integrity`, plus a demo against any `.uf2` this repository has built. |
| exp141 | Any RP2350 board, in BOOTSEL mode. Needs a Chromium browser. **RP2350/RP2040 bootrom behaviour** — PICOBOOT is the bootrom's own interface, identical on any board. Reads only; writes no flash. |
| exp142 | Any RP2350 board. No browser. **RP2350 only** — A/B partitions and image-version selection are ROM features. Two ~64 KiB slots near the start of flash; reads only, nothing here writes flash from firmware. |
| exp143 | Any RP2350 board. No browser. **RP2350 only** — try-before-you-buy, `explicit_buy` and flash update boot are ROM features. The same two ~64 KiB slots as exp142. This one **does** write flash from firmware: the ROM rewrites slot B's first sector to clear the TBYB bit. Slot A and the table are never written. |
| exp144 | Any RP2350 board. No browser. **RP2350 only** — partition tables, UF2 routing and A/B selection are ROM features. The drop half needs the BOOTSEL drive and `udisksctl`, as every `yi26 flash` does; the asking half needs neither. |
| exp145 | Any RP2350 board. No browser. **RP2350 only** — it writes flash from firmware into an A/B partition. Uses 67 KiB of SRAM (1.5 for the filesystem, 64 to stage the image), which is nothing on an RP2350 and would decide the design on a smaller part. |
| exp146 | Any RP2350 board, in BOOTSEL mode. Needs a Chromium browser — a phone's is the point. **RP2350/RP2040 bootrom behaviour** — PICOBOOT is the bootrom's own interface. It **writes flash**, which is what exp141 stopped short of. |
| exp147 | Any RP2350 board **with an LED you can see** (change the pin), and a Chromium browser — a phone's is the point. **RP2350 only** — the whole A/B machinery is the ROM's. The board ends up with a partition table, so from then on `pflash.html` is how it is reflashed. |
| exp149 | Same as exp148, and the same caveat with the sides swapped: the board is now the DHCP server, so what a given host does with an offer is that host's business. Ubuntu takes it; a Pixel 9a takes it and still lists no network. |
| exp152 | Same as exp151, plus a **mass-storage** function — six USB interfaces, the most complex composite here. The measurement is what *your* host does with a medium that appears ten seconds after the device: Ubuntu mounts it. |
| exp151 | Same as exp150, and the first experiment here a **non-Chromium** browser can be part of — reading the log needs no WebUSB. Finding the board still does, which is the half that is missing. |
| exp150 | Same as exp149, plus **a browser — any browser**, which is the point. This is the first experiment here whose page needs no WebUSB, no permission dialog and no Chromium. Whether the browser can reach the board is a property of the host's routing, not of this firmware. |
| exp148 | Any RP2350 board **with an LED you can see** (change the pin). No browser. Portable to the RP2040 in principle — CDC-NCM is a USB class, not a chip feature — except for the TRNG it seeds the stack from. **What is not portable is the result**: the desktop half needs a host that binds `cdc_ncm` and can share a connection, and the answer on any given phone is a property of that phone. Report either way. |

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
- **[`pack.sh`](./pack.sh)** — `./pack.sh exp152` puts one experiment in a
  `.zip` somebody without a checkout can flash from: the firmware, the pages
  that write it from a phone, the experiment's own README, and the output of
  the `check.sh` run that built it. A README section headed exactly
  `## Do this, in order` is lifted into the zip verbatim as the standalone
  walkthrough — every step, every command, and what each should print, for
  somebody who has only the zip. Markdown links are flattened on the way out.
  exp151 and exp152 have one; the rest are a gap the zip names out loud. It refuses on a non-zero exit, so a zip is
  evidence rather than a hope. Which zips have had their own steps followed,
  what is left and in what order, and the hazards to keep off an unattended
  run are in [`docs/pack-verification.md`](../docs/pack-verification.md).
  It carries **no buildable source** and says so:
  an experiment directory depends on `../../crates/` and sources `../lib.sh`,
  so anybody who wants the code wants `git clone`. Repository-wide and one
  copy, like the two above — packaging is not a third script per experiment.

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
the argument still holds. Four of them say so today — exp130's page build,
exp131's UF2 size and cluster count, exp132's one-channel build, exp133's
`FLASH.HTM` size. The last two entries in exp131's and all of exp133's arrived
the same way, on 2026-08-05: renaming `tools/pages/flash.html` to
`bootsel.html` meant rewriting its header, which grew the page by 630 bytes,
which moved a number in three volumes that embed it. **A rename is never only
a rename** — and the rule above is what stops that turning into three edited
captures nobody re-ran.

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
| **0 · none** | No board at all. A machine and nothing else | exp102, exp140 |
| **1 · board** | A board attached, and nothing but software after that | exp104, exp105, exp107–exp114, exp118, exp119, exp121–exp125, exp128, exp129, exp134, exp136–exp139, exp142–exp145 |
| **2 · a moment** | A person for one action, then software does the rest | exp101, exp115–exp117, exp120, exp126, exp130–exp133, exp135, exp141, exp146 |
| **3 · a person** | A person **is** the instrument — nothing here can see the result | exp103, exp106, exp127, exp147 |

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
| exp138 | `cdc` | `log` | `cdc_acm` | `own` |
| exp139 | `cdc` | `log` | `cdc_acm` | `own` |
| exp140 | `none` | `none` | `none` | `none` |
| exp141 | `vendor` | `control` | `webusb` | `bootrom` |
| exp142 | `cdc` | `log` | `cdc_acm` | `own` |
| exp143 | `cdc` | `log` | `cdc_acm` | `own` |
| exp144 | `cdc` | `log` | `cdc_acm` | `own` |
| exp145 | `cdc+msc` | `log+scsi` | `cdc_acm+usb-storage` | `own` |
| exp146 | `vendor` | `control` | `webusb` | `bootrom` |
| exp147 | `cdc` | `log` | `cdc_acm` | `own` |
| exp148 | `cdc+ncm` | `log+frames` | `cdc_acm+cdc_ncm` | `own` |
| exp149 | `cdc+ncm` | `log+frames` | `cdc_acm+cdc_ncm` | `own` |
| exp150 | `cdc+ncm` | `log+frames` | `cdc_acm+cdc_ncm` | `own` |
| exp151 | `cdc+ncm` | `log+frames` | `cdc_acm+cdc_ncm` | `own` |
| exp152 | `cdc+ncm+msc` | `log+frames+scsi+files` | `cdc_acm+cdc_ncm+usb-storage` | `own` |

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
| `frames` | Ethernet frames, in both directions, with an IP stack above them |

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
| [exp138-what-the-rom-already-knows](./exp138-what-the-rom-already-knows/) | 1 · board | The A/B firmware machinery everyone hand-rolls is already in this chip's ROM — asked, not assumed, and empty |
| [exp139-a-table-of-one](./exp139-a-table-of-one/) | 1 · board | A partition table takes flash offset 0, so the firmware moves — and the eight words that do it are checked before any board sees them |
| [exp140-a-checksum-that-passes](./exp140-a-checksum-that-passes/) | 0 · none | A CRC forged to any value by four bytes, and the same attack failing on a hash — why *reliability* and *authenticity* are different words |
| [exp141-two-doors-into-the-bootrom](./exp141-two-doors-into-the-bootrom/) | 2 · a moment | BOOTSEL has two USB interfaces; a browser cannot claim the drive but can claim the other one — the flash port `picotool` drives |
| [exp142-two-images-one-version](./exp142-two-images-one-version/) | 1 · board | Two firmwares in an A/B pair with different versions, and the ROM boots the higher — then swap the versions and the other one boots, the choice live |
| [exp143-the-image-that-is-never-bought](./exp143-the-image-that-is-never-bought/) | 1 · board | An image marked provisional runs once on a 16.8-second clock and is taken back unless it calls `explicit_buy` — a rollback built out of not asking to stay |
| [exp144-one-file-either-half](./exp144-one-file-either-half/) | 1 · board | The ROM names the half a dropped file should go into, correctly — and then will not take a file from its own drive at all while a partition table exists |
| [exp145-a-drive-of-our-own](./exp145-a-drive-of-our-own/) | 1 · board | A volume served out of three sectors of filesystem takes the dropped file the ROM's drive refused, writes it into the other half, and hands over — the control the update road was built to measure against |
| [exp146-a-page-that-writes-flash](./exp146-a-page-that-writes-flash/) | 2 · a moment | The browser port of `yi26 pflash` — a phone writes firmware over PICOBOOT and reboots the board, which is the only route left once a partition table closes the drive |
| [exp147-two-firmwares-one-phone](./exp147-two-firmwares-one-phone/) | 3 · a person | The whole A/B arc arranged so a phone can run it and an LED reports the answer — fast blink or slow, and two different ways to make it change |
| [exp148-a-wire-with-no-address](./exp148-a-wire-with-no-address/) | 3 · a person | A CDC-NCM link and a DHCP client, kept apart: the firmware can see a host driver claim it, and can see that having a wire is not having an address |
| [exp149-the-board-hands-out-the-address](./exp149-the-board-hands-out-the-address/) | 3 · a person | The board answers DHCP itself — four packets, hand-rolled — so a phone gets an address with nothing to configure, because a phone has no setting to configure |
| [exp152-the-volume-that-waits](./exp152-the-volume-that-waits/) | 3 · a person | The board carries a drive that does not exist until it knows its own address — verified on a phone: plug in, turn on tethering, tap two things, and the log is there |
| [exp151-the-log-in-any-browser](./exp151-the-log-in-any-browser/) | 3 · a person | The board serves its own log over HTTP — verified rendering in Chrome on a phone — and answers to a name that phone will not ask it for |
| [exp150-a-page-served-by-the-board](./exp150-a-page-served-by-the-board/) | 3 · a person | The board serves its own web page: no WebUSB, no permission dialog, no chooser, any browser — and the question of whether a phone can route to an address it never showed as a network |

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

### The update road

A firmware that can be replaced in the field has to answer two questions that
are usually confused with each other: **can an update brick this board**, and
**whose firmware will it accept**. This road is the first; the second is a
separate group and is named at the end.

[exp138](./exp138-what-the-rom-already-knows/) opened it by asking rather than
assuming, and the answer reframed everything after it. The standard advice for
dual-firmware updates — *the boot ROM is fixed silicon, it cannot know which
slot you want, so hand-roll a bootloader* — is correct for most parts and
**wrong for this one**. The RP2350's ROM has partition tables, A/B links, an
image version it compares, a try-before-you-buy flag, `pick_ab_parition` and
`explicit_buy`. A stock board answers every one of those calls and has nothing
in them: the machinery is in the chip and it is empty.

So the road is not "build A/B". It is **use what is there, then measure what a
hand-rolled one would have bought you**. In order, and none of them
interrogated yet — a direction, not a schedule:

- **a partition table, and what the ROM does with one** — **Done, verified
  2026-08-04.** [exp139](./exp139-a-table-of-one/) puts one partition table at
  flash offset 0 and boots an ordinary image from the partition: the board comes
  up and `get_partition_table_info` reports **one** partition where a stock board
  reports none. It took getting it wrong first — a moved image that went *dark* —
  to learn the rule that makes it work: the ROM remaps a booted partition's start
  to the XIP base `0x10000000`, so a partition image is linked there like any
  other, not moved. The table's eight words live, tested, in
  [`crates/partition-table`](../crates/partition-table/) (byte-for-byte
  `embassy-rp`'s own minimal encoder output), and [`tools/partimg`](../tools/partimg/)
  assembles `[table at sector 0] + [ordinary image at sector 1]` — no `picotool`,
  no rolling-window item. `get_b_partition(0)` is still `-17` (one partition has
  no B side): the control for the next item.
- **two images, one version number** — **Done, verified 2026-08-04.**
  [exp142](./exp142-two-images-one-version/) puts a firmware in A and another in
  B with a higher version and lets the ROM choose: it booted the higher, and
  after the versions were swapped it booted the other slot — the choice the
  standard advice says you must hand-roll, made by the ROM, live.
  `get_b_partition(0)` turns from exp139's `-17` to `1`. The version lives in
  each image's own `IMAGE_DEF` (a `VERSION` item, via embassy-rp's
  `imagedef-none`), and `partimg ab` places both images and the linked A/B table.
- **the image that is never bought** — **Done, verified 2026-08-05**, and
  [exp147](./exp147-two-firmwares-one-phone/) later sharpened what it means: a
  flash update boot of an image **without** the TBYB flag is not a trial at all
  but a completed update, and the ROM erases the half it replaced. The trial is
  the flag's doing, not the reboot's — the bit below is the whole mechanism, and
  exp147 is what its absence looks like.
  [exp143](./exp143-the-image-that-is-never-bought/) marks slot B
  try-before-you-buy and watches the board be taken back from it, again and
  again, because B never calls `explicit_buy`. Three things were measured that
  this line, written before the experiment, had wrong or did not know:
  - **A plain reset is not how a provisional image is tried.** An unbought TBYB
    image is not a current image: B is v2.0 against A's v1.0 and the ROM boots
    **A**. The only way in is `reboot(FLASH_UPDATE, update_base)` — so exp143's
    slot A hands the board over on purpose, which is what a field update does
    once it has written the new half.
  - **The trial is a clock, and the clock is the watchdog.** A trial boot starts
    with `WATCHDOG.CTRL` enabled and 16,775,289 µs left of the hardware's
    16,777,215 µs maximum; an ordinary boot of the same binary reads 0. Two
    samples nine seconds apart differ by exactly the nine seconds. So a trial
    image has about **16.8 seconds** — room for USB to enumerate and say what it
    found, which is why nothing in exp143 has to race or feed the watchdog.
  - **The buy is a flash write, done by the ROM to the sector the image is
    running from.** `explicit_buy` returned 0 in 37 ms, the IMAGE_TYPE word in
    flash went `0x90210142` → `0x10210142`, and the ROM **disabled the trial
    clock itself**. After that the same binary boots on a plain reset and reads
    its own TBYB bit as clear.

  `WATCHDOG.REASON.TIMER` is not the evidence it looks like: it is set after an
  ordinary `pflash` too, because the ROM's own reboot goes through the watchdog.
- **the drag-and-drop that lands in the right slot** — **Done, verified
  2026-08-05, and the answer is half a yes.**
  [exp144](./exp144-one-file-either-half/) asked the ROM and then dropped the
  file. Asked, the ROM is right: with partition 1 running,
  `get_uf2_target_partition(rp2350-arm-s)` names partition 0 and
  `pick_ab_parition(0)` names 1, so the routing answer an update wants is
  available to any firmware, from the table alone, with no drive involved.
  Dropped, nothing happens: **a board with a partition table does not consume a
  UF2 written to its BOOTSEL drive** — one partition or two, file addressed at
  `0x10000000` or at the partition's own start, all refused; erase the table and
  the identical file, same command, flashes. The refusal has exp137's shape: the
  copy succeeds, the file lists, and it is gone after a remount, because the
  host's cache was showing a write the board never took. So exp139's note that
  "a *bad* partition table makes the bootrom reject the drive's writes" was the
  wrong half of the sentence — a good one does too, and that is why every
  partitioned board in this arc was flashed over PICOBOOT without anyone
  noticing. Not tested: a BOOTSEL entered by the button with a table present.
- **the hand-rolled bootloader, as the control** — **Done, verified
  2026-08-05.** [exp145](./exp145-a-drive-of-our-own/) serves its own FAT12
  volume, takes the dropped `.uf2` the ROM's drive refused, and writes it into
  the half of the pair that is not running. Dropped v3.0 on a board running
  v2.0 from partition 1: 109 UF2 blocks arrived, 27,904 bytes were erased and
  programmed into sectors 17..32 in 273 ms, the board rebooted, and the ROM
  booted v3.0 from partition 0. Dropped v4.0 next and it went back into
  partition 1 — the halves alternate on their own, each firmware writing the
  one that replaces it.

  Three things it did not need: a disk (three sectors — boot, FAT, root — is a
  whole FAT12 filesystem, and every data sector is read for UF2 blocks and
  thrown away), a protocol for "the file is complete" (UF2 blocks carry
  `blockNo`/`numBlocks`, so the last one announces itself — exp137 is the
  record of how little a host will tell a device), and any placement tool (the
  ROM says where via `get_uf2_target_partition`, exp144).

  **What it cost, measured against the ROM's own path:** about 4.5 KiB more
  flash, 67 KiB of SRAM (1.5 for the filesystem, 64 to stage the image), and
  around 390 lines over a plain firmware, most of them SCSI. **And what it
  cannot do:** it lives inside the application. If the running firmware is
  broken there is no volume, no SCSI and no way in — while the ROM's BOOTSEL is
  there whatever you have done to flash. That is the trade the whole road was
  built to price: a hand-rolled updater buys the write the ROM refused, and
  costs the one guarantee the ROM was giving away.
**Done.** *a correct checksum on somebody else's firmware* —
[exp140](./exp140-a-checksum-that-passes/), and it needed no board, so it is
verified and pushed while the flash experiments wait. It forges a CRC to any
value by changing four bytes of a real `.uf2`, at the same size, and runs the
identical attack against SHA-256 to watch it fail — because CRC32 is linear and
a hash is not. *Reliability* and *authenticity* stop being two words for the
same thing once you have seen the forgery a CRC waves through.

### Flashing from a browser, with no drive

The route around the wall [`docs/platforms.md`](../docs/platforms.md) ran into
on 2026-08-04, and the wall turned out to be a different one than it looked.
That day's verdict was "dragging a `.uf2` onto a BOOTSEL drive is not dependable
— the host storage layer writes to that synthetic drive badly, seen on Android
*and* on a desktop Linux machine". **Corrected on 2026-08-05 by
[exp144](./exp144-one-file-either-half/):** the host was never the problem. A
board with a **partition table** — any table, well-formed or not — does not
consume a UF2 written to its BOOTSEL drive, and both of those machines were
facing a board that had just been given one. Erase the table and the same file
flashes on the same host. So the rule is *table present → the drive takes
nothing*, and the phone was acquitted; the road out is still worth having,
because a partition table is exactly what a field-updatable board has.
[exp141](./exp141-two-doors-into-the-bootrom/)
is the way around it, and on 2026-08-04 it went from an idea to a verified path:
BOOTSEL exposes a second interface, PICOBOOT (vendor `0xFF`), a browser *can*
claim it, and a **Pixel 9a's Chrome erased the bootrom's flash from a web page**
with no drive at all. On the command line, `yi26 nuke` erases and `yi26 pflash`
does a full write+`REBOOT2` over `libusb` — verified flashing and booting
exp138. What remains:

- **PICOBOOT `WRITE` from a browser** — **Done, verified 2026-08-05 on a
  Pixel 9a.** [exp146](./exp146-a-page-that-writes-flash/) is
  [`tools/pages/pflash.html`](../tools/pages/pflash.html): a phone opened a
  local HTML file, read a `.uf2` off its own storage, claimed PICOBOOT, erased
  six sectors, wrote 23,040 bytes, **read the first page back and compared it**,
  and rebooted the board, which came up on that firmware and said so over its
  own log. No drive, no drag-and-drop, no toolchain, no second computer. The two
  halves even name the same silicon: the bootrom gave the flashing page the
  serial `7FCAF01F5613A90C`, and the firmware that booted reports its chip ID as
  `0x7fcaf01f 0x5613a90c` — so the board written and the board that booted are
  provably one board, which had been an assumption. It refuses before it writes
  (wrong base address, no boot block, wrong chip family) and refuses to reboot
  if the read-back does not match, because the person using it may have no way
  back.

  Two things learned by doing it. Android's chooser listed the same board
  **three times** and two of those entries failed `open()` with *Access denied*
  — the live one is **the entry that makes Android ask for USB permission**, and
  nothing in the names says which. And this page's own diagnostics were wrong
  the first time: it named the picked device *after* opening it, so it said
  nothing about exactly the attempts that failed.

### The network road

The Pico 2 has no network interface, and does not need one to be on a network:
**CDC-NCM** makes it a USB Ethernet adapter, and the machine it is plugged into
is the other end of the wire. That machine can be a laptop or a phone, which is
the whole reason this road is worth walking — a board that serves a web page is
reachable from *any* browser, with no WebUSB, no permission chooser, and no
Chromium requirement. The entire `tools/pages/` track exists inside those
constraints; this is the way out of them.

The stack is the one this repository already runs — `embassy-net 0.9.1` sits on
exactly the `embassy-rp 0.10` / `embassy-usb 0.6` / `embassy-time 0.5` versions
exp147 was built against, so nothing had to move to start.

- **[exp148](./exp148-a-wire-with-no-address/) — a link is not a network.**
  **Done, verified 2026-08-05.** A CDC-NCM link and a DHCP client, kept
  deliberately apart, because "networking works" is two achievements and they
  arrive from different places. The firmware can see the first one happen: a
  host driver claiming the function is what selects the data interface's alt
  setting, and until it does, `is_link_up()` is false. On this Ubuntu machine
  the kernel bound `cdc_ncm` shortly after enumeration — 400 ms on one run and
  1,400 ms on another — and the board reported the change before anything on
  the host did.

  The second achievement never arrived, and that is the finding. The prediction
  was that a *phone* would leave the board at "link up, no address" — Android
  runs a DHCP client on a USB Ethernet gadget, and so does this board, so two
  clients wait for each other. NetworkManager does the identical thing: its
  default for a new wired interface is to be a client. **The deadlock is not a
  phone problem; it is what every host does until somebody tells it otherwise.**
  Turning on connection sharing is a manual step on a laptop and does not exist
  at all on a phone.

  **Verified on a Pixel 9a the same day: slow blink.** So the first genuinely
  open question on this road is closed — **Android does bind `cdc_ncm` for an
  arbitrary RP2350 gadget**. That is OS policy, not something a firmware can
  influence, and there is no WebUSB-style fallback if a phone declines; the rest
  of this road was a guess until a phone was holding one. It then stopped in
  exactly the same place, for exactly the same reason, as the laptop.

  What that run did *not* settle: whether a phone lets a USB Ethernet link
  capture its default route. Mobile data stayed up throughout — but an interface
  with no address was never a candidate to become the default network, so
  nothing was at stake. exp149 is where that becomes a real question.

  The firmware got onto that board with [`pflash.html`](../../tools/pages/pflash.html),
  writing **straight over exp147's partition table** with no erase step in front
  of it. PICOBOOT clears every sector it is about to write and the table lives in
  the first of them. Which is the other half of exp144: the ROM's own *drive*
  refuses a dropped `.uf2` while a table exists, and PICOBOOT does not consult
  the table at all. Same board, same table, opposite answers depending on the
  door.

  Cost, against exp147 as the nearest network-free equivalent: **+17,408 bytes**
  of flash and **+9,704 bytes** of static RAM, most of the latter being eight
  whole-MTU packet buffers. A firmware with a TCP/IP stack in it still fits a
  64 KiB A/B slot with 25 KiB spare, so the network road does not close the
  update road.

- **exp149 — the board hands out the address.** `embassy-net`'s `dhcpv4` is a
  client only; there is no server socket in it, and `mdns` is a resolver rather
  than a responder. So a board that wants to be reachable the moment it is
  plugged in has to answer DHCP itself: four packets on UDP 67, DISCOVER→OFFER
  and REQUEST→ACK, hand-rolled and visible. exp148 turned this from "the thing
  that rescues the phone case" into "the thing that removes a manual step from
  every host".

  Built, and the protocol lives in [`crates/dhcp`](../crates/dhcp/) with no
  socket in it — 14 host-side tests. **Working on Ubuntu**: the four packets
  complete in 2 ms and the host ends up with `192.168.7.2/24` and a route to
  that subnet *and nothing else*, which is the evidence for the decision not to
  offer a router option. Not yet finished: the ten-boot reliability run, a
  README, and `check.sh`.

  **On a Pixel 9a, 2026-08-05 — and the result is three things that do not
  obviously belong together:**

  | | |
  | --- | --- |
  | The LED went **fast** | the board sent an `ACK`, so Android ran a DHCP client and completed the handshake |
  | Mobile data **survived** | 5G throughout — the link did not capture the default route |
  | Settings showed **no Ethernet network at all** | nothing appeared under Network & internet |

  So Android took the address at a layer that never became a user-visible
  network. That is good news for exp151 — nothing was displaced — and it makes
  exp150's question sharper rather than easier: **an address a browser cannot
  route to is not reachability.** Chrome's sockets go to the default network,
  and whether a literal `192.168.7.1` still finds its way out of the USB
  interface is now the thing to measure, not to assume.

  One likely cause is a decision made here on purpose. The offer carries no
  router and no DNS, because the board routes nothing — and a network with no
  gateway is one Android may correctly decline to promote. The code comment in
  `crates/dhcp` already named this: if a host will not talk to a network with no
  gateway, that is a finding, and adding six bytes is the experiment. exp150
  runs both builds in one round trip rather than finding out twice.

- **[exp150](./exp150-a-page-served-by-the-board/) — a page served by the
  board.** Hand-rolled HTTP/1.0 over the same link, so a page needs no WebUSB,
  no permission dialog, no chooser and no Chromium. The honest cost beside it:
  `http://` is not a secure context, so the origin the board serves can never
  also use WebUSB. This road opens one door by closing another.

  **On Android it does not open. Measured 2026-08-05 on a Pixel 9a, and this is
  the wall the whole road was walking towards.** Chrome at
  `http://192.168.7.1/` returns `ERR_TIMED_OUT` — not `ERR_ADDRESS_UNREACHABLE`
  and not `ERR_CONNECTION_REFUSED`, so the packets went *somewhere* and nothing
  came back. The board says where they did not go:

  ```text
  link UP, 192.168.7.2 leased, 0 request(s) served
  ```

  for 245 seconds, with no connection line at all. **Both builds behaved
  identically**, so it is not about the gateway.

  **Then the roles were swapped and it worked.** Built with
  `--features ask-for-an-address`, with Android's **Ethernet tethering** on, the
  phone is the DHCP server and the router and the board is a client on its
  network — the arrangement Android actually supports. The board came up on
  `10.206.115.122` with a gateway, and its page rendered in Chrome on the phone.

  Three ways were tried in one sitting and only one goes through: `fetch()` is
  refused before it leaves and an `<iframe>` stays blank, because a
  `content://` page may not pull an `http://` resource into itself — that is
  **mixed content**. A top-level **navigation** is not mixing anything into
  anything, so it goes. The restriction was never about reaching a private
  address.

  So the boundary is narrower and more useful than "IP does not work on a
  phone": **the address has to be the phone's to give, and the page has to be
  navigated to rather than fetched.**

  Two things this settles rather than leaves open:

  - **The default-route risk is retired.** Mobile data survived throughout —
    including with the board announcing itself as the gateway, which was the
    worst case anyone had reason to fear. exp151 does not have to work around it.
  - **exp152 is no longer forced.** A browser reaching the board over IP *is*
    possible on this phone, under the conditions above. It remains interesting
    for the case where the board wants to fetch something from the internet
    rather than be fetched.

  Still expected to work on a desktop, where the interface is an ordinary one —
  `curl http://192.168.7.1/` is the check, and it is waiting on a board.

- **exp151 — the board as an HTTP client** (desktop only, and deliberately so).
  The same stack pointed outward. It needs the host to route and NAT for it,
  which a laptop can be told to do and a phone cannot — there is no such UI. It
  is here to be built, run, and then to hit that wall in front of the reader,
  because a warning in prose does not teach the same thing.

- **exp152 — the browser as the board's gateway.** The answer to exp151's wall:
  the board asks over CDC for a URL, the page fetches it, and the reply comes
  back. Over **CDC/WebUSB rather than NCM**, so it never competes with Android's
  routing and the phone's Wi-Fi stays up — the page has to reach the internet
  before it can fetch anything on the board's behalf. The limit to teach here is
  CORS: a page can only read a response the server allowed it to read, which is
  the first time in this repository that `curl` can fetch something a browser
  cannot.

Not on this road: TLS, and two boards talking to each other. The first is a
different curriculum and a much larger binary; the second is something this
repository cannot do, because its two boards are never on the same bench.
