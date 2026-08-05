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

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. **This is the last experiment for which step 2 needs your
hand**, and proving that is the whole point of it.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable. A charge-only cable is the
    commonest single cause of everything in this repository.
  * Ubuntu. `lsusb` and `stty` are already there; nothing to install.
  * No root, no udev rule, no network.

1. UNPACK IT.

       unzip exp105-usb-reboot.zip
       cd exp105-usb-reboot

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold the BOOTSEL button
   down, plug the board in, then let go. A drive called `RP2350` appears.

       cp firmware/exp105-usb-reboot.uf2 /media/$USER/RP2350/

   The board reboots by itself as the copy finishes and the drive vanishes.

   *There is no without-hands route into this one, and that is the experiment.*
   Whatever the board was running before either had this watcher or did not; if
   it did not, a button is the only way in. From here on it does.

3. CONFIRM IT IS RUNNING.

       lsusb -d 1209:0001 && ls /dev/ttyACM*

   Expect: `Bus 001 Device 016: ID 1209:0001 Generic pid.codes Test PID` and
   `/dev/ttyACM0`. The bus and device numbers change every time; the ID does
   not.

4. TOUCH THE PORT AT 1200 BAUD. Do not send anything. Opening it at that speed
   and closing it again is the entire signal.

   **Give the board a few seconds first.** Ubuntu runs ModemManager, which
   opens every new `ttyACM` device for a while to find out whether it is a
   modem. Touch the port during that window and `stty` sits there with no
   output and no error, because its `open()` is queued behind something else's.
   Wait, and it returns instantly.

       sleep 5
       stty -F /dev/ttyACM0 1200
       sleep 2
       lsusb -d 2e8a:000f
       ls /dev/ttyACM*

   Expect: `Bus 001 Device 017: ID 2e8a:000f Raspberry Pi RP2350 Boot`, and
   `ls: cannot access '/dev/ttyACM*': No such file or directory`.

   **The board is now in its bootloader and nobody touched it.** The serial
   port is gone because the firmware that was serving it is gone.

   The board has no magic 1200-baud behaviour — your code does. Run the same
   two lines against exp104, which has no watcher, and nothing happens at all.

5. LOOK AT THE BOOT DRIVE. It came back when the firmware left.

       lsblk -f /dev/sda | tail -1
       ls /media/$USER/RP2350/

   Expect a FAT16 volume labelled `RP2350`, about 128 MiB, already mounted, and
   two files: `INDEX.HTM` and `INFO_UF2.TXT`.

   Note `/dev/sda1` and not `/dev/sda`: the bootloader's drive has a partition
   table. Later experiments serve a volume with none, so the device name is
   different there — a detail worth having met once.

6. CLOSE THE LOOP. Copy the same firmware back on, with nothing pressed.

       cp firmware/exp105-usb-reboot.uf2 /media/$USER/RP2350/
       sleep 4
       lsusb -d 1209:0001 && ls /dev/ttyACM*

   Expect the `1209:0001` line and `/dev/ttyACM0` again, and `lsusb -d
   2e8a:000f` now finds nothing.

   That is a complete edit-flash-run cycle with your hands off the board, which
   is what every experiment after this one assumes.

IF IT DOES NOT WORK
  * `stty: /dev/ttyACM0: No such file or directory` — the board is not running
    this firmware, or the cable is charge-only.
  * `stty` prints nothing and never returns. It is blocked in `open()` because
    something else has the port. On Ubuntu that is almost always ModemManager,
    which probes each new `ttyACM` for a few seconds after it appears — press
    Ctrl-C, wait, and run it again. A serial monitor left running does the same
    thing and does not go away by itself.
  * The touch does nothing and the port stays. Something else has the port open
    and the touch never reached the firmware.
  * The drive appears but the copy fails partway — that is normal and is
    success. The board reboots the instant it has the whole image, so the
    copying program may never get to close the file tidily. Some file managers
    report it as an error.
  * The board is in BOOTSEL and you want the firmware back but have no `.uf2`
    — that is what `firmware/` in this zip is for.

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
