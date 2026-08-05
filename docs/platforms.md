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
| **Cloud Linux VM for building, your own machine for flashing** | All but exp101 | Both halves, separately. The build half on 2026-08-02, and the flashing half from an Android phone on 2026-08-03 — never yet in one continuous run. See below. |
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
| exp126 | Same | Drag, then open `INDEX.HTM` off the drive that appears. **The end of this route**: after this flash, the local machine needs nothing at all that it did not already have |
| exp127 | Same | Drag, then send one byte and *watch the LED* — the only experiment here whose result no software can see. `console.html` sends `\x01` from a browser; a serial terminal that cannot type a raw byte will not do |
| exp128 | Same | Drag, then send messages of chosen lengths and read the log. Needs something that can send an exact number of raw bytes — a terminal that appends a newline changes the measurement |
| exp129 | Same | Drag, then send a byte per draw and read the log. Numbers only, so the serial port is not optional |
| exp130 | Same | Drag, then open `INDEX.HTM` off the drive. **No serial port needed** — the page carries its own log pane |
| exp131 | Same | Drag, then open the drive. `FLASH.HTM` is on it, so this is the first build that leaves the local machine able to reach the *next* one with nothing downloaded |
| exp132 | Same | Drag, then read the vendor channel. Needs a program that can claim a USB interface — `yi26`, or the experiment's own page in a browser. A serial terminal reaches only half of it |
| exp133 | Same | Drag, then open two pages off the drive at once. A Chromium browser is the whole local requirement; on Linux, the udev rule and `yi26 detach` first |
| exp134 | Same, **three times** — this experiment is three builds of one firmware | Drag each in turn, ignore the port for a minute, then read what survived. Download all three `.uf2` files before you start |
| exp135 | Nothing to build | A board already running exp128, and a program holding the CDC interface. **On this route the browser is not the fallback, it is the shorter path**: `console.html` can end a message with a zero-length packet, and no terminal on any platform can |
| exp136 | `./check.sh`, then download `target/*.uf2` (two builds) | Drag, then send framed bytes and read the log. The sweep that is the real evidence runs on the build machine and needs no board at all |
| exp137 | Same | Drag, then mount the volume, send one byte, and read the same file twice. Needs a file manager and a way to unmount — the second read is the experiment |

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

**Not once the board has a partition table.** Measured on 2026-08-05
([exp144](../experiments/exp144-one-file-either-half/)), on the Ubuntu machine
where this procedure has always worked: with a partition table in flash, the ROM
does not consume a `.uf2` copied onto that drive. One partition or two, the file
addressed at `0x10000000` or at a partition's own start — refused every time,
and the refusal is silent in the worst way: the copy succeeds, the file appears
in the listing, and it is gone after an unmount and remount, because the host's
FAT cache was showing a write the board never took. Erase the table and the
identical file, same command, same cable, flashes.

So the drag-and-drop route does not degrade on boards that partition their flash
for field updates — it stops being available at all. `yi26 pflash` (PICOBOOT, no
drive) is the route that keeps working, which is what
[exp141](../experiments/exp141-two-doors-into-the-bootrom/) built. One
configuration is untested: a BOOTSEL entered by holding the button, with a table
present.

**This is also the correction to what this page said about phones**, below: the
2026-08-04 verdict that Android's drag-and-drop was undependable was measuring a
board that had just been given a partition table. On a board without one, the
drive path works — on Ubuntu, measured, and on the Pixel 9a the day before the
table existed.

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
Firefox and Safari do not implement it. **This repository has never used Web
Serial for anything** — it is reported here as an option, not as a tested one,
and it does not exist on Android, which is the host the next section is about.

The browser path that *has* been verified here is the other one, **WebUSB**:
[`tools/pages/`](../tools/pages/) holds four pages — a descriptor inspector, a
log viewer, a console that types back, and one that puts the board into its
bootloader — which need no installation either and work on a phone.

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
page can stream the same log.

That page exists now. The
[browser track](../experiments/README.md#the-browser-track-finished) was built
for exactly this reader, and it finished: a phone with one USB port can
**flash** the board ([exp117](../experiments/exp117-webusb-reboot/)), **read
its log** ([exp116](../experiments/exp116-webusb-cdc-log/)) and **talk to** it
([exp120](../experiments/exp120-webusb-two-way/)) — with the first two of those
pages coming off the board's own volume
([exp126](../experiments/exp126-self-hosted-viewer/) put the log page there,
[exp131](../experiments/exp131-the-volume-is-the-app-drawer/) the reboot page),
so there is nothing to download and no server to run. The console is the one
job still opened from a file you keep: it lives in
[`tools/pages/`](../tools/pages/), and no firmware here ships it on a volume.

Two costs, and they are the reason this is a paragraph and not a
recommendation. **WebUSB is Chromium-only** — Firefox and Safari do not
implement it, on any platform. And **the permission is a native dialog behind a
user gesture**: somebody has to tap it, and it does not survive restarting the
browser. Neither is a problem for a person holding the phone. Both make the
phone path unusable for anything automated.

#### What was verified on the phone

The half of this route nobody had run. Whether an Android phone can *write* to
the RP2350's boot drive is not something the ROM decides — it is the phone's
storage layer, and there was no reason to assume it would work.

On **2026-08-03**, on a **Google Pixel 9a**, with an OTG cable and nothing
else. The board it flashed is a **second official Pico 2**, which lives with
the phone and has never been attached to the machine that built the `.uf2` —
so nothing the build machine did could have put that firmware there:

- A `.uf2` built elsewhere was copied onto the `RP2350` boot drive from the
  phone's Files app. **The write succeeded**, which is the whole question this
  paragraph exists to answer.
- The board rebooted into it and presented its own volume, which the phone
  mounted and listed.
- `README.TXT` opened in the phone's file viewer and carried the one line that
  had been edited into the source before the build. That line exists in no
  other artifact, so it could not have come from anywhere else.

Later the same day, the one manual step left in that sequence was removed. The
first run put the board into BOOTSEL by hand — hold the button, plug in the
cable — because that was the instruction. It turns out not to be necessary:
[exp117](../experiments/exp117-webusb-reboot/)'s page, opened on the phone,
sent the 1200-baud request over WebUSB and the board rebooted itself. The
`RP2350` drive appeared without anybody touching the board.

**So a phone can run the whole cycle with no physical access to the board at
all**: reboot it from a page, drag the `.uf2` onto the drive that appears, and
read the result. That is the same hands-free loop the Ubuntu machine has had
since exp105, arriving on the platform that has none of the tools.

#### What looked like a fragile phone was a partition table — corrected 2026-08-05

**This section used to say the phone was unreliable. It was wrong, and the
correction matters more than the original claim did.**

What happened: dragging a `.uf2` onto the boot drive worked on 2026-08-03. It
was tried again on the **same Pixel 9a, the next day**, with a file proven
byte-for-byte intact, and it did not work at all. Two file managers, two
different-looking failures:

- **Google Files** (a privileged system app) shows the drive, accepts the copy,
  and reports success — but the flash never happens. The `.uf2` appears in the
  listing and then vanishes on the next mount.
- **Material Files** (a third-party app) cannot open the drive at all:
  `AccessDeniedException: /mnt/media_rw/…: opendir: Permission denied`.

The first of those was written up as Android's storage cache swallowing the
write, and from there as a property of *phones*. It is not.
[exp144](../experiments/exp144-one-file-either-half/) measured the same failure
on **Ubuntu**, on the machine where this procedure has always worked, and
isolated the cause with a control: **a board that has a partition table does not
consume a UF2 written to its BOOTSEL drive.** Erase the table and the identical
file, same host, same cable, flashes.

And the board that phone was facing on 2026-08-04 had one — the exp139 table,
flashed that day, which is the same table that "made the BOOTSEL drive refuse
every dragged `.uf2` until PICOBOOT erased it". The symptom that was read as a
host-side cache — *the file lists, then vanishes on remount* — is exactly what a
**device-refused** write looks like, on any operating system, because the host
is showing its own FAT cache of a write the board never took.

So, corrected:

| Claim | Status |
| --- | --- |
| A phone can flash the board by copying a `.uf2` onto the boot drive | **Stands, verified 2026-08-03.** No evidence against it |
| The phone / Android is unreliable at this | **Withdrawn.** The 2026-08-04 run was measuring the board, not the phone |
| The bootrom's synthetic FAT is one Android tolerates badly | **Withdrawn.** Nothing supports it; the write was refused at the device |
| A third-party Android file manager cannot reach a USB drive by path | **Stands.** Scoped storage, and it never reaches the device at all — use the system Files app |
| Dragging onto a board **that has a partition table** does nothing | **Stands, and it is the real rule** — on Android and on desktop alike |

Not re-tested on the phone since the cause was found, so the honest statement is
"the case against the phone collapsed", not "the phone was re-verified". The one
thing to plan around is the table, not the platform.

There is still an asymmetry worth keeping: the **reading** half over WebUSB
(exp115–exp126) never showed any of this, because a browser claiming a USB
interface does not go through the storage layer at all.

#### And the phone can now write firmware without the drive at all

Verified 2026-08-05 on the Pixel 9a:
[`tools/pages/pflash.html`](../tools/pages/pflash.html) claimed the bootrom's
PICOBOOT interface, erased six sectors, wrote 23,040 bytes, read the first page
back to check it, and rebooted the board, which came up on that firmware and
streamed its log to `log.html` on the same phone — all from pages opened out of
the Files app, with the `.uf2` on the phone's own storage. The chip ID the
firmware reports equals the serial the bootrom gave the flashing page, so it is
the same board at both ends. So the
phone no longer depends on the drive for flashing at all, which matters most on
exactly the boards where the drive takes nothing: partitioned ones.

**One thing to know before you try it.** Android's device chooser listed the
same board **three times**, and two of those entries failed with
`SecurityError: Failed to execute 'open' on 'USBDevice': Access denied`. The
third worked. Nothing in the names distinguishes them — **the live entry is the
one that makes Android put up its own USB permission dialog**. Picking a dead
one is free: the page has not sent a command by then, so work down the list.

**Building something for this route?** The mechanics of getting a page right
when the person running it is holding the only board are collected in
[`debugging-on-a-phone.md`](./debugging-on-a-phone.md).

#### A phone will also be a network for the board

Verified 2026-08-05 on the Pixel 9a with
[exp148](../experiments/exp148-a-wire-with-no-address/): plug in a board that
declares a **CDC-NCM** virtual Ethernet function and **Android binds a driver
for it**. The firmware can tell, because a host only enables the data
interface's endpoints once one of its drivers owns the function, and the board
reported the change on its LED.

This had been an open question with no way around it — attaching an
Ethernet-class gadget is OS policy, not an app-visible API, and unlike WebUSB
there is no userspace fallback when the OS declines. It does not decline.

What the phone will *not* do is give the board an address. Android runs a DHCP
**client** on such an interface, and so does a board using `embassy-net`'s
`dhcpv4`; two clients wait for each other forever. This is not an Android
quirk — an unconfigured Ubuntu does exactly the same, and the difference is only
that a laptop can be told to share a connection and a phone has no such setting.
A board that wants to be reachable from a phone has to hand out the address
itself.

#### ...and then a browser cannot reach it

Measured the same day with [exp150](../experiments/exp150-a-page-served-by-the-board/),
and it is the boundary of this whole route. The board hands the phone an address
and serves HTTP on it; Chrome at `http://192.168.7.1/` returns
**`ERR_TIMED_OUT`**, and the board reports `0 request(s) served` for the whole
attempt. Not one connection arrived.

The error code is the useful part. `ERR_TIMED_OUT` rather than
`ERR_ADDRESS_UNREACHABLE` or `ERR_CONNECTION_REFUSED` means the packets left by
*some* route and nothing answered — the phone's default network, where a private
address goes nowhere. **The interface never becomes a network Android's per-app
routing will select**, and no firmware can reach that decision.

Tested with and without a DHCP **router option**, in case a gatewayless network
was one Android declined to promote. Identical result, so that is not the cause.

The compensation is that the risk everyone expected did **not** happen: mobile
data survived every variant, including the build that announced the board as the
gateway. A USB Ethernet gadget on this phone does not displace anything. It also
does not carry anything.

So on an unrooted phone, from a browser: **PICOBOOT and CDC over WebUSB work; IP
does not.** That is why
[`tools/pages/`](../tools/pages/) is built the way it is, and it is now a
measurement rather than an assumption.

**And a board does not sit in BOOTSEL safely on a phone.** If the screen sleeps
and the port is power-cycled, the board resets — and a reset boots a firmware
rather than returning to the bootloader. Nothing announces it: the next page
just finds a chooser full of dead entries. So put the board into BOOTSEL
*immediately before* the action that needs it, not several steps earlier and not
while reading instructions. This came from the person running
[exp147](../experiments/exp147-two-firmwares-one-phone/) on a phone; it is a
hazard to design around rather than something this repository has measured, and
it fits every failure in that run that was not a bug in the page.

A route that does not depend on the storage layer at all — driving the
bootrom's **PICOBOOT** interface, the way `picotool` drives it — sidesteps every
failure above, and as of 2026-08-04 **it exists and is verified**.
[exp141](../experiments/exp141-two-doors-into-the-bootrom/) claims PICOBOOT from
a browser: a Pixel 9a's Chrome erased flash from `recover.html` with no drive
and no drag-and-drop, which is what un-bricked the board below. On the command
line, `yi26 nuke` erases and `yi26 pflash` does a full write+`REBOOT2` over
`libusb` — `pflash` flashed and booted exp138 on real silicon. So the phone is
no longer dependent on the fragile drive: PICOBOOT is the path that works.

**One cause, not two.** The same board, moved to an unrelated Linux machine,
*also* refused every drag-and-drop `.uf2` — no error, no reboot, the files just
piling up unflashed. At the time that was read as a second, independent failure
sitting next to the phone's. [exp144](../experiments/exp144-one-file-either-half/)
showed it is the same one: the partition table, on any host. It was also thought
to be a *routing* failure specific to an image aimed at `0x10000000` — that is
ruled out too, because the same image shifted to a partition's own start sector
is refused identically, and so is a `.uf2` dropped on a board with a single
partition.

The rule, as measured: **table present → the drive takes nothing; no table → the
drive works.** PICOBOOT is immune either way, because it writes raw addresses
and never touches the drive or the storage layer. When a drag-and-drop flash
silently does nothing, reach for `yi26 pflash` / `recover.html`, not another
copy — and check whether the board has a table before blaming the host.

That run still had one dependency this page walked into without noticing: the
reboot page had to be *sent to the phone first*, because it lived in this
repository and not on the board.
[exp131](../experiments/exp131-the-volume-is-the-app-drawer/) closed it by
putting `FLASH.HTM` on the board's own read-only volume beside the page that
shows what the board does, and made it a rule rather than a good idea — a
firmware that can be rebooted by software and serves a volume ships the way
back on that volume, or it strands whoever flashed it.
[exp133](../experiments/exp133-a-page-per-job/) carries three, and two of them
were driven from a phone at the same time on 2026-08-03. For a phone the volume
is not documentation, it is the application menu: after such a flash there is
nothing left to download, permanently.

One detail decides whether any of this works, and the obvious approach is the
wrong one. **Open the page from the Files app or a share sheet and choose
Chrome.** That yields a `content://` URI, which is a secure context, and WebUSB
runs. **Typing a `file:///sdcard/...` URL does not work** — scoped storage
blocks Chrome from reading it, and the symptom is a page that will not load or
a button that reports no WebUSB, neither of which names the cause.

The same route is how exp126's viewer gets opened off the board's own volume,
so this is not a detail about one page. It is how the browser track is reached
on a phone at all.

It also leaves a gap that is worth naming, because it cannot be seen. A page
served off the board and a copy saved on the phone weeks ago produce the
**same kind of address**, from the same file manager. Nothing on screen
distinguishes them, so "I opened it from the drive" is a belief rather than an
observation. [exp130](../experiments/exp130-the-board-draws/) closes it by
having the firmware announce a build string that the page compares against its
own — verified on the phone on 2026-08-03, with the page reporting a match. If
you build anything that matters on a page served from a device, build that in.

Three numbers on the phone's screen agreed with the build machine without
being told to:

| On the phone | Where it comes from |
| --- | --- |
| `README.TXT` **646 B** | the length of `const README` in exp126's `src/main.rs` |
| `INDEX.HTM` **19.31 KB** | 19309 bytes, the size exp126's `check.sh` asserts against exp116's page |
| Both files dated identically | FAT12 directory timestamps written by hand at boot, not by the host |

And one thing nobody designed. Android created a **`LOST.DIR`** directory on
the volume within a minute of mounting it — its storage layer does that to
removable media. On exp126 that write lands in 64 KiB of the chip's SRAM and
disappears at the next reset, which is harmless here and worth knowing before
you put a volume in flash. It is also the clearest proof available that the
phone had write access to the board, not merely read access.

**What this does not establish.** The `.uf2` for that run was built on a Linux
machine its owner owns, not on a rented one, so this verifies the *flashing*
half only. The *building* half was verified separately on 2026-08-02, above.
The two halves have not yet been done in one continuous run by one person who
owns neither a Linux machine nor a compiler, which is the claim this page
would need to make in full.

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
honestly verify such a service: two boards and two hosts, no server, and
nobody else's device to test against.

Longer term the file may not need a browser at all, and half of that has now
been built. The board does present its own volume —
[exp124](../experiments/exp124-msc-scsi/) answers SCSI until the host agrees a
disk is there, [exp125](../experiments/exp125-fat12-by-hand/) lays down a FAT12
by hand, and [exp126](../experiments/exp126-self-hosted-viewer/) puts a file on
it that a phone can open. A log written there would travel the way the `.uf2`
already travels: a file manager, on any machine.

**The log is not one of those files, and the reason is now measured rather
than assumed.** The volume is 64 KiB of SRAM whose contents the firmware lays
down at boot. Appending to a file after the host has mounted the volume means
fighting the thing that makes mounting fast: the host caches sectors, so bytes
the device writes afterwards are simply not read. Real devices answer that with
a media-change signal — SCSI `UNIT ATTENTION` — and
[exp137](../experiments/exp137-the-volume-that-changes/) sends one.

It works, and it is not enough. The host acts on the signal completely: it asks
why, is told `key 6 asc 28`, re-reads the capacity, and re-reads the boot
sector, the FAT and the root directory. And `cat` on the mounted file returns
the bytes it returned before, because **`UNIT ATTENTION` is a notification, not
an invalidation** — the block layer honoured it and the filesystem above it had
already decided what that file says.

A fresh mount reads the new contents, so what the device buys is a volume that
is correct **at every mount**. For this page that is a qualified answer rather
than the one it wanted: the log can come back as a file if whoever reads it
unmounts and remounts between reads, which on a phone is a person pulling down
a notification shade. So the seam is still a file in one direction for anything
automatic: `.uf2` in, and the log comes back through a browser.

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
