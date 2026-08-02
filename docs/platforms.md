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
exp108. Until then, treat the phone-only path as unfinished rather
than as something this page is recommending.

### The 1200-baud signal from a browser

exp105 teaches the firmware to reboot into its bootloader when the host sets
the port to 1200 baud. That is what retires the BOOTSEL button, and it works
from a browser — but it takes two steps, not one:

1. Open the port at **115200** and close it.
2. Open it at **1200** and close it.

Both, in that order. Setting a port to the baud rate it is already at sends no
`SET_LINE_CODING` control transfer, so the firmware never hears the request.
Bouncing through 115200 first makes it unconditional. `yi26 bootsel --explain`
prints the same reasoning for the shell equivalent.

Once that works, the loop is: edit in the cloud, `./check.sh`, download,
trigger the reboot from the browser, drag the new `.uf2` onto the drive. The
button stays untouched.

## What this page will not tell you

Which provider to rent from, what it costs, or which image to pick. Those
change faster than this repository does, and none of them could be verified
here — see [Nothing is pushed unverified](../experiments/README.md#nothing-is-pushed-unverified)
for why this project does not publish claims it cannot check.

What you need is a Linux machine that can pass exp102. If it can install
`rustup` and a C linker, it can build every experiment here.
