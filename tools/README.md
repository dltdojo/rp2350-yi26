# tools/

Host-side programs. Everything here runs on your computer, not on the board.

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
| `send <text>` | bytes to the firmware, then its reply (`--seconds N`, default 3) |
| `flood` | numbered packets at full speed (`--packets N`, `--storm`) |
| `bootsel` | put the board into BOOTSEL mode via the 1200-baud touch |
| `drive` | the RP2350 boot drive, mounting it if the system has not |
| `flash <file.uf2>` | the whole cycle: bootsel, mount, copy, wait for it to come back |
| `udev` | can a browser open this board? `--install` fixes it (Linux) |

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
