# Platforms

The scripts in this repository are written and verified on Ubuntu Linux. This
page is for everyone else: what your options are, which parts of each one this
repository has actually verified, and which parts it has not.

There is a related page in the experiments index —
[Platform](../experiments/README.md#platform) — which states the rule. This one
works through the consequences.

## The seam is a file

Almost every discussion of "can I do this on my machine?" gets easier once you
notice where the work splits. Building firmware and flashing firmware have
nothing to do with each other:

- **Building** needs a Rust toolchain, a few hundred megabytes of disk, and no
  hardware whatsoever. It produces one file: a `.uf2`.
- **Flashing** needs the board and a way to copy a file onto a USB drive. It
  needs no compiler, no Rust, and no terminal.

That second half is the RP2350's own ROM at work, not your operating system's.
Hold BOOTSEL, plug in, and the chip presents itself as a small removable drive.
Dragging a `.uf2` onto it is the entire flashing procedure, and a file manager
on any operating system can do it.

So the seam is the `.uf2` file, and the two halves can live on two different
machines.

## Routes

| Route | Runs every experiment? | Verified here |
| --- | --- | --- |
| **Ubuntu, board attached** | Yes | Yes — this is the reference path |
| **Cloud Linux VM for building, your own machine for flashing** | All but exp101 | The cloud half, yes. See below. |
| **Local VM with USB passthrough** (VirtualBox, VMware, Multipass) | Yes | No |
| **WSL2 + [usbipd-win](https://github.com/dorssel/usbipd-win)** (Windows) | Yes | No |
| **Port the scripts to your OS** | Yes | No — but every command is shown, which is what makes a port tractable |

Only the first row has a board on the same machine as the compiler, and only
the first row is fully verified. The rest of this page is about the second,
because it is the one that costs nothing but a browser and works when you have
no Linux machine at all.

## Building in the cloud, flashing at home

If you have no Linux machine and no budget for one, you can rent a Linux
machine by the hour, build there, download the `.uf2`, and drag it onto your
board from whatever computer you already own.

That machine can also be where an AI assistant does the editing: this
repository is small, every experiment is self-contained, and `check.sh` gives a
machine-readable verdict without a board present. Change a line, run
`./check.sh`, download the `.uf2` when it passes.

### What was verified

On 2026-08-02, from a clean `git clone` at commit `793fa87`, with the checkout
in a directory the repository had never seen:

- All five firmware experiments (exp103 – exp107) compiled.
- All five converted to `.uf2` with the correct RP2350 family ID `e48bff59`.
- `exp107`'s `.uf2` came out at 43008 bytes — the same size recorded in that
  experiment's verified `Expected output`.
- With no board visible to the host, `exp107/check.sh` printed five `PASS`
  lines, one `SKIP`, and **exited 0**. A missing board is not a failure.
- That `.uf2` — the one built from the clean checkout — was then flashed to a
  real Pico 2 and ran correctly: heartbeat, button watcher and scheduler probe
  all logging into one stream.

So the cloud half is not a guess. What has *not* been verified is any
particular cloud provider, or the local half on any operating system other
than Ubuntu.

Two notes while we are being precise. Builds here are **not** bit-reproducible
across directories — two clean checkouts of the same commit produce `.uf2`
files that differ in a few thousand bytes for the experiments that pull in a
local crate. The firmware is equivalent; the bytes are not identical. Nothing
in this repository depends on them being identical, and chasing that is a
different project. And `run.sh` is the wrong script for a machine with no
board — it is an interactive walkthrough that expects hardware. Use
`check.sh` there.

### Which half does what

| Experiment | On the build machine | On the machine with the board |
| --- | --- | --- |
| exp101 | Nothing. This experiment *is* the physical connection. | All of it — and it needs `lsusb`, `lsblk`, `udisksctl`, so Ubuntu or a port |
| exp102 | All of it. This is the experiment the build machine exists to pass. | Nothing |
| exp103 | `./check.sh`, then download `target/*.uf2` | Drag onto the drive, watch the LED. **No serial port needed** — the cleanest fit for this route |
| exp104 | Same | Drag, then open the serial port and read the log |
| exp105 | Same | Drag, read the log, and send the 1200-baud signal (see below) |
| exp106 | Same | Drag, read the log, press BOOTSEL as a button |
| exp107 | Same | Drag, then *deliberately ignore* the port for twenty seconds before reading it — that is the experiment |
| exp108 – exp114 | Same | Drag, then read the log. Every one of these produces numbers and nothing else — a temperature, an entropy score, a health verdict — so the serial port is not optional for any of them |
| exp115 – exp117 | Same, but there is nothing to build: these are single HTML files | **The best fit on this route.** A Chromium browser is the whole local requirement — read the descriptors, read the log, and put the board into BOOTSEL from the page. On Linux they need `yi26 detach` first; on Android they do not |
| exp118 | Same | Drag, then **write to the port as well as read it**. This is the first experiment where the port is not enough on its own: something has to send bytes, and whatever you use has to be able to send a raw byte like `0x00` |
| exp119 | Same | Drag, then send twenty thousand numbered packets while toggling RTS. `yi26 flood` does both at once through one handle, and nothing that cannot do that will reproduce it |
| exp120 | Nothing to build | A browser, and a board already running exp118. This is the page that lets a phone *type* at the board |
| exp121 | Same | Drag, then read the log and send one byte. Checking that the keypress landed needs an input-event reader — a desktop's `xset` will not show it |
| exp122 | Same | Drag, then talk to an interface with no device node. Needs a program that can claim a USB interface — `yi26 echo`, or any libusb binding. A serial terminal cannot reach it |
| exp123 | Same | Drag, then read the log. The host interrogates the board on its own the moment it enumerates, so the local half is just watching |
| exp124 | Same | Drag, then look at your own disk listing — the board appears in it. `lsblk` on Linux, Disk Management on Windows, Disk Utility on macOS |
| exp125 | Same | Drag, then open the drive that appears. A file manager is the whole local requirement — **this one needs no serial port at all**, which makes it the second-best fit on this route after exp103 |

exp101 is the one genuine casualty, and it is unavoidable: an experiment about
whether your board, cable and host can see each other cannot be run on a host
that has none of them. Read it, then start at exp102.

### Getting the file onto the board

1. Hold BOOTSEL, plug the board in, release. A drive named `RP2350` appears.
2. Copy the `.uf2` onto it.
3. The drive disappears on its own. That is the ROM rebooting into your
   firmware, and it means the copy worked.

No tools, no drivers, no administrator rights. This is the same procedure on
Windows, macOS and Linux because it is the chip doing it, not the host.

From exp105 onward the firmware can put itself back into BOOTSEL, so step 1
stops needing a human — see below.

### Reading the serial port

Everything from exp104 onward reports what it is doing over USB serial, and on
a machine with no toolchain that is the one thing you still need software for.
The board enumerates as a standard CDC-ACM device, so anything that opens a
serial port will do. **115200 8N1**, although CDC-ACM makes the rate nominal —
the firmware does not act on it, with one deliberate exception noted below.

The option that needs no installation is the browser. Chrome and Edge ship the
[Web Serial API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API),
which lets a page open a serial port after you pick it from a permission
prompt. It behaves the same on Windows, macOS, Linux and ChromeOS, and it can
also send the 1200-baud signal, which no other zero-install option can.
Firefox and Safari do not implement it. **This repository has not verified any
browser path** — it is reported here as an option, not as a tested one.

If you would rather use what your platform already has:

| Platform | Option |
| --- | --- |
| Windows | [PuTTY](https://www.putty.org/) (Serial, `COMn`, 115200), or Tera Term |
| macOS | `screen /dev/tty.usbmodem* 115200` — built in. Exit with `Ctrl-A` then `k` |
| Linux | `screen` or `picocom`, or `yi26 log` from this repository |
| Any | The Arduino IDE's Serial Monitor, if you already have it installed |

### If the machine you already own is a phone

Worth saying plainly, because for the reader this page is written for it may be
the only machine there is. An Android phone cannot build firmware, but it can
be the local half: OTG cable, the board's boot drive mounts, the Files app
copies the `.uf2` onto it.

Reading the log is where it gets specific. **Web Serial does not exist on
Android** — every option in the table above is desktop-only. Chrome on Android
does implement **WebUSB**, which can claim a CDC-ACM interface directly, so a
page can stream the same log. That is a different API and a different page, and
this repository does not have one yet: it is the destination of the planned
[browser track](../experiments/README.md#the-browser-track), starting at
exp115. Until then, treat the phone-only path as unfinished rather
than as something this page is recommending.

### Getting the log back to the machine that built it

This is the half of the cloud route that is easy to miss. The `.uf2` goes
**out** from the build machine, and it goes by hand: you download it and drag
it onto the board. Evidence has to come **back** the same way, and until it
does, whoever is helping you from that rented Linux box — a person or an
assistant — is a compiler and not a developer. They can produce firmware. They
cannot see it run.

There is no magic here and there does not need to be. **A human is already in
the loop**: somebody had to drag the file onto the drive. The return path can
ride the same person. What matters is not automation, it is that one copy and
one paste carry everything worth knowing.

So exp116's page has a **Copy as JSON** button, and what it produces is
byte-for-byte what `yi26 log --json` produces on a machine that has the tool:

```text
{"type":"line","t_ms":21037,"lost":26,"text":"scheduler: 210 wakeups"}
{"type":"summary","lines":8,"lost_total":26,"gaps":1,"first_t_ms":37,"last_t_ms":3000}
```

An assistant reading that cannot tell which instrument produced it, which is
the point. And it keeps `lost` — the field that says how many lines the
firmware dropped before they ever reached you. In prose that is a marker you
have to notice; a capture that quietly lost a third of its lines reads almost
the same as one that lost none.

Two implementations of one format drift unless something compares them, so
neither is the authority: `tools/yi26/tests/log-format/` holds one fixture and
one committed expectation, a Rust test runs the tool over it, and exp116's
`check.sh` runs the page's parser over the same fixture with `node`.

What this does **not** do is upload anything anywhere, and that is deliberate.
A page opened from `file://` cannot post to an arbitrary host anyway, this
repository does not run a server (a server is exactly what a phone cannot
provide, which is why the browser track opens files instead), and sending the
contents of somebody's device to a third party is a decision to be asked
about, not a convenience to be shipped. There is also nothing here that could
honestly verify such a service: one board, one host.

Longer term the file may not need a browser at all. The planned mass-storage
track ends with the board presenting its own volume, and a log written there
as an ordinary file would travel the way the `.uf2` already travels — a file
manager, on any machine, including a phone. The seam is a file in both
directions.

### The 1200-baud signal from a browser

exp105 teaches the firmware to reboot into its bootloader when the host sets
the port to 1200 baud. That is what retires the BOOTSEL button, and how many
steps it takes depends on which API you reach through.

**Through a serial API — Web Serial, `stty`, a terminal program — it takes
two:**

1. Open the port at **115200** and close it.
2. Open it at **1200** and close it.

Both, in that order. A driver asked for the rate the port is already at sends
no `SET_LINE_CODING` at all, so the firmware never hears the request. Bouncing
through another rate first is what makes it unconditional.
`yi26 bootsel --explain` prints the same reasoning for the shell equivalent.

**Through WebUSB it takes one**, and [exp117](../experiments/exp117-webusb-reboot/)
is that page. There is no driver deciding on your behalf: the page composes
the seven bytes of `SET_LINE_CODING` and hands them to the device, so the
request always goes out. The workaround exists to defeat an optimisation, and
when you are the driver there is no optimisation to defeat.

That matters here because Android has WebUSB and not Web Serial, so on the
machine this page is really for, the one-step path is the only path.

The loop closes there: edit in the cloud, `./check.sh`, download the `.uf2`,
open exp117's page and press the button, drag the file onto the drive that
appears. No toolchain on the local machine and no hand on the button.

## What this page will not tell you

Which provider to rent from, what it costs, or which image to pick. Those
change faster than this repository does, and none of them could be verified
here — see [Nothing is pushed unverified](../experiments/README.md#nothing-is-pushed-unverified)
for why this project does not publish claims it cannot check.

What you need is a Linux machine that can pass exp102. If it can install
`rustup` and a C linker, it can build every experiment here.
