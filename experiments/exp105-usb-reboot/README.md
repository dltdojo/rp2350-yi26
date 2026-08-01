# exp105-usb-reboot — retire the BOOTSEL button

exp101 explained why some boards reflash without anyone pressing anything:
the running firmware cooperates. **This is that firmware.** After this
experiment, reflashing is a command, not a ritual.

The mechanism is the *1200-baud touch*: the host sets the serial port to 1200
baud, the firmware reads that as "put yourself into the bootloader", and jumps
into ROM. Nothing is transmitted — the baud rate itself is the message.

Needs: any RP2350 board, the exp102 toolchain, and a board already running
exp104 (or anything with a USB serial port).

## The code IS the walkthrough

The interesting code is **not** in this experiment. It is in
[`crates/usb-reboot/src/lib.rs`](../../crates/usb-reboot/src/lib.rs), shared by
every experiment that wants the behaviour so there is one copy rather than one
per experiment. Read that file — it explains the trick and its downside.

This experiment's [`src/main.rs`](./src/main.rs) is exp104 plus one spawned
task, and its comments cover only what changed: `split_with_control` instead
of `split`, and why the receiver exp104 threw away now has a job.

## Two ways to do it

```sh
./run.sh      # guided: flash it, then watch the board reboot itself
./check.sh    # verdict: builds both ways, converts, checks the port
```

## The switch is yours

Auto-reboot is **on by default**, because the convenience is the point. To
build a firmware that ignores the touch — so nothing but the BOOTSEL button
can reach the bootloader — flip it off at build time:

```sh
cargo build --release --no-default-features
```

No file edits, and `check.sh` verifies both configurations still compile so
the switch cannot quietly rot.

**Why you might want it off.** A baud rate is not a secret handshake. *Any*
program that opens your port at 1200 baud reboots your board: a terminal
emulator with 1200 in its saved settings, a modem script, a colleague's tool
probing serial devices. Half the time that is a delight — your flashing tool
triggers it deliberately — and half the time it is a mystery ("why does my
board keep disappearing?"). Convenience and footgun are the same mechanism,
which is why this is a decision rather than a default you cannot see.

## Expected output

Captured from a real Pico 2 on Ubuntu:

```console
$ ./check.sh
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (144752 byte ELF)
PASS  also builds with auto-reboot disabled (--no-default-features)
PASS  converts to UF2 (37888 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  board enumerated as 1209:0001
PASS  serial port present: /dev/ttyACM0
```

A useful control, run against exp104's firmware — the one *without* the
watcher — before flashing this one:

```console
$ stty -F /dev/ttyACM0 1200
$ lsusb -d 2e8a:000f
        (nothing — exp104 ignored it entirely)
```

The touch does nothing on firmware that is not listening for it. The board
does not have a magic 1200-baud behaviour; your code does.

And the reboot itself, hands off the board:

```console
$ stty -F /dev/ttyACM0 1200
$ lsusb -d 2e8a:000f
Bus 001 Device 023: ID 2e8a:000f Raspberry Pi RP2350 Boot
```

Two seconds after the touch, the serial port is gone and the boot drive is
back. Copying a new `.uf2` onto it brings the firmware back up two seconds
later — a complete edit-flash cycle with nothing pressed.

## The bug this experiment shipped with, briefly

The first version of this firmware **did not work**, and the way it failed is
worth keeping.

It called `reset_to_usb_boot()` the instant `control_changed()` fired. That
turns out to be too soon: the waker fires while the host's `SET_LINE_CODING`
request is still in flight, before its status stage completes. Resetting the
chip at that moment tore USB down mid-transfer, and the result was worse than
not rebooting — the host's `stty` blocked forever waiting for a status stage
that would never arrive, and the board ended up *enumerated but dead*: still
listed by `lsusb`, serial port unreadable, and never actually in the
bootloader.

The fix is the `Timer::after_millis(250)` in
[`crates/usb-reboot/src/lib.rs`](../../crates/usb-reboot/src/lib.rs): finish
the conversation, then reboot. Worth internalising as a general shape —
**tearing down a transport while it is mid-transaction hangs the other end**,
and USB, being request/response, punishes it particularly clearly.

## The three ideas to take away

1. **The button was never the only door — it was the only door for firmware
   that could not cooperate.** BOOTSEL still works and always will, because it
   is handled by ROM below any firmware. What changed is that there is now a
   second door, opened from the inside.

2. **A separate task is what makes it reliable.** exp104 measured the printing
   loop parking mid-write when nothing drained the port, and a parked task
   notices nothing. The watcher lives in its own task and sleeps on
   `control_changed()`, so it stays responsive no matter what the rest of the
   firmware is doing. This is the first experiment where concurrency is
   load-bearing rather than decorative.

3. **Shared behaviour belongs in one place.** The watcher is a crate, not a
   snippet to copy into each experiment, for the same reason the scripts share
   `lib.sh`: copies drift.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `stty ... 1200` does nothing | Firmware built with the feature off | Rebuild without `--no-default-features` |
| Still nothing | Board is running an older experiment | exp103/exp104 have no watcher — use the button once |
| Board reboots when you did not ask | Something else opened the port at 1200 baud | That is the footgun; build with `--no-default-features` |
| `stty` hangs with no output | Another process holds the port | `fuser -v /dev/ttyACM0` names it |

## Next

Flashing is now hands-free, which changes what is comfortable to build: any
experiment that needs many edit-flash cycles just became practical. The board
still cannot *listen*, though — reading what the host types is the other half
of the serial port, and the next natural step.
