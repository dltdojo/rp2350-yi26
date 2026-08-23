# tools/

Host-side programs. Everything here runs on your computer, not on the board.

Two of them talk to the board, and they are for two different hosts (there is
also one build-time helper, [`partimg`](#partimg), that touches no board at all):

| | For a host with | Opened by |
| --- | --- | --- |
| [`yi26`](#yi26) | a Rust toolchain and a terminal | typing a command |
| [`pages/`](./pages/) | **a browser and nothing else** — a phone, most importantly | double-clicking a file |

They overlap in exactly four jobs — read the log, send bytes, enter the
bootloader, look at the descriptors — and nowhere else, because a page cannot
mount a drive or write a udev rule and a terminal cannot come off the board on
a volume. [`pages/README.md`](./pages/README.md) has both tables, and the four
overlapping jobs are kept speaking the same language on purpose: `console.html`
accepts the same escape grammar as `yi26 send`, and a check proves it.

## `yi26`

One binary that knows how to find an RP2350 board, read its log, put it into
BOOTSEL mode, and flash it.

```sh
cargo run --release --manifest-path tools/yi26/Cargo.toml -- doctor
# or, once:
cargo install --path tools/yi26
yi26 doctor
```

The experiments call it for you — `experiments/lib.sh` builds it on first use
if you have not — so there is nothing to install before starting.

### Why it exists

The experiment scripts used to do this work with `lsusb`, `lsblk`,
`udisksctl`, `stty` and `/dev/serial/by-id`. Those five were the only parts of
this repository that could not work outside Linux, and they were also the
parts most likely to behave differently on a machine that is not the one this
was written on.

They now live in one place, written once. **This is a replacement, not an
alternative** — there is no shell fallback racing a Rust implementation,
because two implementations means one of them is wrong and nobody notices.

### It explains itself

Replacing the commands should not mean hiding them. Every subcommand takes
`--explain`, which prints the equivalent by hand before doing the work:

```console
$ yi26 bootsel --explain
# by hand:
$ stty -F /dev/ttyACM0 115200
$ sleep 1
$ stty -F /dev/ttyACM0 1200
# Two stty calls, not one: if the port already happens to be at 1200, asking
# for 1200 changes nothing, so no SET_LINE_CODING goes out and the firmware
# never hears the request. Bouncing via 115200 makes it unconditional.
...
```

Where there is no reasonable hand-typed equivalent — `doctor` is the case —
`--explain` says so and says **why**. "Use the tool" is not an explanation.

### It is built for agents first

The first user of this tool is an AI assistant helping somebody debug: yours,
or ours. An assistant handed human prose has to guess at it with regular
expressions. So `--json` is a first-class output on every subcommand, and
`doctor --json` returns one document with a `problems` array, each entry
carrying an `id`, a `severity`, and a `fix`:

```console
$ yi26 doctor --json
{"tool":"yi26","version":"0.1.0","host":{"os":"linux","arch":"x86_64","verified":true},
 "toolchain":{"cargo":"...","rustup":"...","elf2flash":"..."},
 "board":{"state":"running","port":{"path":"/dev/ttyACM0","vid":"0x1209","pid":"0x0001",
 "product":"exp107 debug logging","serial_number":"107","manufacturer":"rp2350-yi26"}},
 "boot_drive":null,"problems":[]}
```

`yi26 log --json` goes further and takes the firmware's own log apart —
timestamp, dropped-line count, text — one JSON object per line, with a summary
at the end saying how many lines went missing over what span. That is
something no combination of `cat` and `grep` was ever going to hand you.

**If you are an AI assistant reading this:** start with `yi26 doctor --json`.
It is one call and it tells you the platform, whether the toolchain is
installed, whether a board is attached and in which mode, where its serial
port and boot drive are, and what is wrong. Then `yi26 log --json --seconds N`
for what the firmware is actually doing.

### Commands

| Command | Answers |
| --- | --- |
| `doctor` | everything observable, plus a `problems` array. Start here. |
| `state` | one word: `bootsel`, `running`, `detached`, or `absent` |
| `port` | the serial port of a board running one of these firmwares |
| `log` | what the firmware is printing (`--seconds N`, default 10) |
| `send <text>` | bytes to the firmware, then its reply (`--seconds N`, default 3; `--raw`, `--end`) |
| `flood` | numbered packets at full speed (`--packets N`, `--storm`) |
| `echo <text>` | send to a vendor-specific interface and read the reply |
| `markers <f.uf2>` | the `yi26-cfg:` build markers inside a firmware image |
| `fido info [dev]` | what a FIDO device says it can do — `authenticatorGetInfo` |
| `bootsel` | put the board into BOOTSEL mode via the 1200-baud touch |
| `drive` | the RP2350 boot drive, mounting it if the system has not |
| `flash <file.uf2>` | the whole cycle: bootsel, mount, copy, wait for it to come back |
| `pflash <file.uf2>` | flash over PICOBOOT, no drive — the reliable path (needs BOOTSEL) |
| `nuke` | erase the first 64 KiB over PICOBOOT — un-brick a bad partition table |
| `udev` | can a browser open this board? `--install` fixes it (Linux) |
| `detach` | take the CDC interfaces from the kernel, so a browser can claim them |
| `attach` | give them back — `/dev/ttyACM0` returns |

Exit codes: `0` success, `1` not found or failed, `2` usage error. `doctor`
exits `1` only when it found an `error`-severity problem.

`detached` is the fourth state and exists because the other three hid a real
one. A board whose CDC interfaces have been taken from the kernel — which is
what `detach` does, and what exp116 needs — is enumerated, working, and has no
serial port. Everything built on "is there a serial port" called that `absent`,
and `doctor` answered a working board with *plug it in with a data cable*.
Where it can, `doctor` also names the process holding the device, because on
Linux the usual answer is a browser tab somebody forgot.

### `send` is one command because two would lose the answer

```sh
yi26 send hello                  # write, then listen on the same open port
yi26 send 'A\x00\xff\ttab\r\nZ'  # \n \r \t \0 \\ and \xNN reach the wire
```

The bytes go out exactly as given, with no trailing newline added: a firmware
reading a bulk endpoint gets a packet, not a line, and a newline nobody typed
shows up in its hex dump as a byte the sender never sent.

Sending and listening are deliberately not separable. Opening a CDC-ACM port
asserts DTR and closing it drops DTR, and `crates/usb-log` will not write a
line while DTR is low — so `printf > /dev/ttyACM0` followed by a separate
`cat` closes the port in between, and the firmware's reply to what was just
sent lands in the gap where nobody is listening. `yi26 send --explain` prints
that trap next to the three commands it replaces.

The rate is always 115200 and cannot be given. 1200 is the reboot signal from
exp105, and a send command that took a baud rate would let a typo reset the
board.

### `send --raw` and `--end`, for the packet a tty cannot describe

```sh
yi26 detach                      # the kernel has to let go first
yi26 send --raw hello            # claim the CDC data interface, submit the transfer
yi26 send --end "$(printf 'X%.0s' $(seq 1 64))"   # ...and end it with a zero-length packet
```

Writing to `/dev/ttyACM0` hands bytes to `cdc_acm`, which decides how to
packetise them, and nothing in that path can say *and that is the end of the
message*. A zero-length packet is not a byte you can echo: it is a **transfer
with no bytes in it**, and only the program holding the interface can submit
one. So `--end` implies `--raw`, and `--raw` needs `yi26 detach` first — an
interface has exactly one owner.

The terminator is added only when the payload's length is a **non-zero multiple**
of the endpoint's packet size; any other length already ends in a short packet,
and a terminator after that arrives as an empty message somebody has to
interpret. The tool says which of the three cases it took, every time:

```text
terminator: a zero-length packet was submitted
terminator: none — this message has no short packet to end it (try --end)
terminator: none needed — the last packet is already short
```

This is the one place a browser page got there first — WebUSB never had a tty
in the way, so `console.html` could always do it and the command line had to
give up its serial port to catch up.
[exp135](../experiments/exp135-a-packet-with-no-bytes/) is the measurement, and
`console.html` reads the same rule off the descriptor.

### `echo`, for an interface with no device node

```sh
yi26 echo "hello vendor"      # sent 12 bytes: hello vendor
                              # received 12 bytes: HELLO VENDOR
```

exp122's firmware declares a vendor-specific interface — class `0xFF`, which
is USB for *no promise about behaviour*. No operating system driver claims it,
so there is no `/dev` entry, so there is nothing for a shell to redirect into.
Talking to it means claiming the interface and submitting bulk transfers.

That absence is the point rather than a limitation. Because nothing holds the
interface, this command takes it without displacing anything: the CDC pair
stays with the kernel and `/dev/ttyACM0` stays where it is for the whole
exchange. Compare `detach`, which exp116 needs and which costs the serial port
for as long as a browser holds the interfaces.

### `fido info`, because `unknown` is not an answer

```sh
yi26 fido info                 # the one FIDO device attached
yi26 fido info /dev/hidraw4    # name it when there is more than one
yi26 fido info --json
```

`fido2-token -I` is libfido2's own tool, needs nothing installed, and answers
most of this. **Use it.** This exists for what it does not do.

It prints what it can name. An algorithm outside its table comes out as the word
`unknown` — and in [exp177](../experiments/exp177-the-same-chip-somebody-elses-decisions/)
that word was one step from a wrong finding: a third-party authenticator's third
algorithm read as "probably EdDSA, then". Asking the device for the numbers gave
COSE `-7`, `-35`, `-36` — three ECDSA curves and no Ed25519, which reversed the
ruling. So this command reports **identifiers**, names them only when it can,
and lists any `getInfo` field it does not interpret rather than dropping it.

It also says whether the device's CBOR is **canonical**, which nothing else here
reports about a live device — and reports rather than refuses, because a
diagnostic that will not speak to a sloppy device is one you cannot use on the
day you need it.

Three things it is not:

- **Not a replacement for exp168's client.** Hand-writing CTAPHID is what
  [exp168](../experiments/exp168-a-security-key-that-knows-nothing/) *is*, and
  exp169 to exp172 keep their own. This is for the experiments after exp177,
  where the client had stopped being the subject and one experiment was
  importing another's script across directories to get at a number.
- **Not a second CBOR implementation.** It walks the shape CTAP 2.1 defines and
  reads the bytes underneath with [`crates/cbor`](../crates/cbor/), the same
  cursor the firmware uses.
- **Not an operation.** `getInfo` only: no `makeCredential`, no `getAssertion`,
  no PIN. It changes nothing on the device and asks nobody to touch anything.

It finds devices the way libfido2 does — by report descriptor, `06 D0 F1 09 01`
— so a board running exp168 or later and a commercial key are found alike. With
two attached it refuses and lists them rather than picking one, because exp176
spent a run on an answer that came from the wrong one of two devices.

### `markers`, because `strings` on a .uf2 lies

```sh
yi26 markers firmware.uf2      # yi26-cfg:auto-reboot=on
```

Every firmware here stamps its security-relevant build choices into the image
as plain text, and `experiments/audit.sh` reports them. The obvious way to read
one back is `strings firmware.uf2 | grep yi26-cfg`, and that is wrong in a way
that reads as right.

A `.uf2` is a **container**, not a flat image: 512-byte blocks, each with a
32-byte header and 256 bytes of firmware. The image is chopped up in the file,
so a marker that happens to straddle a payload boundary exists nowhere in the
file as a single run of bytes. `strings` reports nothing while the firmware
plainly declares itself.

That is not hypothetical — exp112's hardware build does it, and the audit
spent a while reporting *cannot determine* about whether any host program can
reboot that board. A disclosure tool that can silently fail to find a
disclosure is worse than no tool, so this decodes the container first. The
test for it builds a UF2 with a marker deliberately cut in half and asserts
that a naive contiguous search fails on the same bytes.

### `flood` has no shell equivalent, and that is what it is for

```sh
yi26 flood --packets 20000            # numbered packets at full speed
yi26 flood --packets 20000 --storm    # ...while toggling RTS throughout
```

Each packet carries its sequence number in the first four bytes,
little-endian, so a firmware can tell whether it got every one. Sequence 0 goes
first and means "clear your counters", so two runs do not look like one
enormous gap.

`--storm` is the part a shell cannot do. It writes at full speed *while*, from
another thread and through the same open handle, toggling RTS. `dd` can do the
first and `stty` the second, but not simultaneously — and if they are not
simultaneous, nothing gets cancelled and the experiment measures nothing.
exp119 is the caller.

RTS rather than DTR for the same reason `send` is one command: `crates/usb-log`
will not write while DTR is low, so a DTR storm would silence the log the
measurement is read from.

### `pflash` and `nuke`, because the drag-and-drop drive is not reliable

```sh
yi26 pflash firmware.uf2   # flash over PICOBOOT — no drive, no drag-and-drop
yi26 nuke                  # erase the first 64 KiB over PICOBOOT
```

There are two ways to put bytes into an RP2350's flash, and only one of them is
dependable. `flash` uses the bootrom's **mass-storage drive**: mount it, copy a
`.uf2`, the bootrom consumes it. `pflash` uses **PICOBOOT**, the bootrom's
vendor interface — `EXCLUSIVE_ACCESS`, `EXIT_XIP`, `FLASH_ERASE`, `WRITE`,
`REBOOT2` — writing flash directly.

The drive is convenient and it is fragile. The host's storage layer caches the
drive's sectors, so a copy can report success while the bytes never reach the
bootrom — verified here on **both Android and Linux**, where UF2s piled up on
the drive unflashed. And once the bootrom has loaded a partition table (exp139)
it routes a dragged UF2 by partition rather than to the address on it, so an
image aimed at a sector the table now owns has nowhere to land and the write is
refused — which looks exactly like a bricked board. PICOBOOT goes through none of
that: it hands bytes to the bootrom directly, and `pflash` reads the first sector
back to prove they landed. `nuke` is the same path pointed at recovery — erase
the first 64 KiB and a table that reroutes the drive is gone.

Both `flash` and `pflash` run a **pre-flight** before touching the board: the ROM
boots by finding a block loop (an IMAGE_DEF, or a partition table) in the first
4 KiB of flash, so a UF2 whose lowest address is not `0x10000000`, or which has
no such block, is refused with the reason — a mis-linked image caught before the
write, not after, as a dark board. It is deliberately a *structural* check, the
same class [`partimg`](#partimg) makes when it assembles: a pass means "the ROM
will find something to boot," never "this is safe" — a well-linked image can
still panic and go dark. `--force` skips it, for the rare UF2 you mean to write
that has no boot block (a data-only region).

This is the command-line half of what [exp141](../experiments/exp141-two-doors-into-the-bootrom/)
does from a browser: `recover.html` erases over PICOBOOT from a phone, `pflash`
and `nuke` do it over `libusb` from a terminal. Both need the BOOTSEL device
reachable, which on Linux is one udev line (`yi26 udev --install` now covers
`2e8a:000f` too).

Two things that cost a debugging round each, written down so they do not again.
`FLASH_ERASE`/`WRITE`/`READ` take an **absolute** address (`0x10000000`), not a
flash offset — a zero `dAddr` stalls. And the reboot that boots the freshly
written image is **`REBOOT2`** (the RP2350 command) with `dFlags` type `NORMAL`,
not the RP2040-style `REBOOT` with `pc`/`sp`, which lands this chip in BOOTSEL
even with a valid image.

### `udev`, the one command that changes your machine

Everything else here reads. `yi26 udev --install` writes a file to
`/etc/udev/rules.d/` as root, and it is the only thing in this repository that
does — so it is opt-in, it prints what it will run first, and `--explain`
gives you the commands to type instead if you would rather not hand a program
your password.

It exists because the browser experiments (exp115 onward) need something the
earlier ones do not. A serial port and a mounted drive are already yours to
open; the raw USB device node is `root`-only, and WebUSB claims the interface
directly. Without the rule, Chrome's first Connect fails with **Access
denied** — a message that names nothing you could search for.

```console
$ yi26 udev
FAIL  /dev/bus/usb/001/007 will not open read-write
      permission denied (errno 13)

Chrome's first Connect will fail with "Access denied". To fix it:

    yi26 udev --install
```

One note on the install itself. The three privileged steps end with
`udevadm settle`, and that last one is not tidiness: `udevadm trigger` returns
as soon as the events are *queued*, so without settling, the verification that
runs immediately afterwards races the ACL it is looking for. The first real
run of this command reported a failure against a rule that was working
perfectly — the tool was simply faster than the system it was checking.

Two things worth knowing about how it checks. It **opens the device**, the
same operation the browser performs, rather than testing whether the rule file
exists — a rule that is present but not working is worse than none, because it
sends you looking somewhere else. And the rule it writes uses
`TAG+="uaccess"`, which grants access to whoever is physically logged in at
this seat: narrower than the `MODE="0666"` in a lot of hobby instructions,
which opens the board to every account on the machine, and narrower than
adding yourself to a group, which persists whether or not you are there.
Deleting the file undoes all of it.

`doctor` reports the same thing as a `warn`, never an `error`, because
everything up to exp107 works without it.

### Verified on Linux only

This is written with portable crates — `nusb` for USB enumeration and
`serialport` for serial ports, both pure Rust with no system libraries — and
the platform-specific paths for macOS and Windows are implemented. **Nobody
has run it on either.** It has been tested on Ubuntu, against a real Pico 2,
and nowhere else.

That is stated plainly rather than advertised as "cross-platform" because this
repository does not ship claims it has not checked. If you run it elsewhere, a
report either way is welcome — `yi26 doctor --json` output is the useful thing
to include, and it will tell you itself that the host is unverified.

### Dependencies, and one that is deliberately absent

Two crates, both pure Rust:

- **`nusb`** — USB enumeration. A board in BOOTSEL mode has no serial port, so
  it can only be found this way. No libusb.
- **`serialport`**, with `default-features = false` — enumeration with USB
  metadata, opening, and line coding. The default features link `libudev`,
  which would mean a learner without `libudev-dev` gets a build failure the
  first time they run a script. That was checked before choosing: without
  libudev the crate still reports vendor and product IDs on Linux.

There is no `serde` and no `clap`. The JSON shapes here are fixed and few, and
the argument grammar is a handful of flags; the cost of two more dependencies
to compile is paid by every learner on first run, and buys little.

### The exception: exp101

`exp101-board-bringup` keeps raw `lsusb`, `lsblk` and `udisksctl` in its
script, on purpose. It runs *before* exp102 installs Rust, so it cannot depend
on a tool that has to be compiled — and showing those commands directly is
what that experiment is for. Every later experiment delegates to `yi26`.

## `partimg`

A build-time helper for [exp139](../experiments/exp139-a-table-of-one/), and
nothing else — it never touches the board. It assembles a *partitioned* image:
it takes an ordinary firmware UF2 (linked at `0x10000000`, like every firmware
here), keeps every byte, shifts each block up one 4 KiB sector, and prepends the
partition table at flash offset 0. The result is `[table at sector 0] + [image
at sector 1]`, which `yi26 pflash` writes raw.

```sh
elf2flash convert -b rp2350 <elf> image.uf2
cargo run --manifest-path tools/partimg/Cargo.toml -- image.uf2 exp139.uf2
```

It exists because a partition image must **not** be moved to run at its physical
offset: the ROM remaps a booted partition's start to `0x10000000`, so the image
is built normally and only its *placement* changes — which is a post-link step,
not a linker trick. exp139 learned that from a board that went dark; `partimg`
refuses an image not linked at `0x10000000` so the mistake cannot be made twice.
The eight table words come from the [`partition-table`](../crates/partition-table/)
crate, so they stay defined and tested in one place.
