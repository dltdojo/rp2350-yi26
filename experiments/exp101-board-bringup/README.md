# exp101-board-bringup — is my Pico 2 alive?

You just bought an RP2350 board — a Raspberry Pi Pico 2 or a third-party
equivalent — and plugged it into an Ubuntu machine.
This experiment proves one thing: **the board, the cable, and the host can see
each other.** Nothing is flashed; nothing on the board changes.

No Rust, no toolchain, no sudo. If this passes, every failure in a later
experiment is a software problem — the physical chain is already ruled out.

Not on Ubuntu? The scripts stop up front with a porting note — see
[Platform](../README.md#platform).

## Two ways to do it

**Guided (recommended the first time):**

```sh
./run.sh
```

An interactive walkthrough. It tells you exactly when to hold the **BOOTSEL**
button and shows each command as it runs it, with the output explained — you
learn the commands without having to type them error-free on the first try.

**Quick verdict (once you know the drill):**

```sh
./check.sh
```

Non-interactive, one screen, exit code 0/1. Use it to re-verify a setup in
seconds.

## What's actually happening (the manual version)

Everything the scripts do is four commands. Hold BOOTSEL while plugging the
board in, then:

```sh
lsusb -d 2e8a:000f                  # 1. is the board enumerated? (2e8a = Raspberry Pi)
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT # 2. find the drive labelled RP2350
udisksctl mount -b /dev/sdX1        # 3. mount it (usually auto-mounted on desktop)
cat /media/$USER/RP2350/INFO_UF2.TXT# 4. the bootloader describes itself
```

## Expected output

Captured from a real Pico 2 on Ubuntu — yours should look the same (device
numbers and mount paths will differ):

```console
$ ./check.sh
PASS  lsusb installed
PASS  lsblk installed
PASS  udisksctl installed
PASS  Pico 2 in BOOTSEL mode (USB 2e8a:000f)
PASS  RP2350 boot drive mounted at /media/USER/RP2350
PASS  INFO_UF2.TXT identifies an RP2350

$ lsusb -d 2e8a:000f
Bus 001 Device 008: ID 2e8a:000f Raspberry Pi RP2350 Boot

$ lsblk -o NAME,SIZE,LABEL,MOUNTPOINT | grep -B1 RP2350
sda           128M
└─sda1        128M RP2350 /media/USER/RP2350

$ cat /media/USER/RP2350/INFO_UF2.TXT
UF2 Bootloader v1.0
Model: Raspberry Pi RP2350
Board-ID: RP2350
```

Two details worth noticing: the "128M drive" is fake — it is the ROM
bootloader impersonating a drive, not real storage (the chip has 4 MB of
flash). And besides `INFO_UF2.TXT` there is an `INDEX.HTM` that redirects to
the Raspberry Pi site. On a desktop Ubuntu the drive usually auto-mounts, so
the `udisksctl` step is often unnecessary.

## The three ideas to take away

1. **BOOTSEL mode is burned into ROM.** Hold the button while plugging in and
   the RP2350 always comes up as a USB drive — no matter what firmware is in
   flash, even firmware that crashes instantly. You cannot brick this board.
   Unplug → hold BOOTSEL → plug in is the recovery loop under everything else
   in this repository.

2. **"Enumeration" is the host learning what just got plugged in.** `lsusb`
   shows the result: vendor ID `2e8a` (Raspberry Pi), product ID `000f`
   (RP2350 Boot). Watching devices appear and disappear in `lsusb` is a skill
   you will use in every USB experiment here.

3. **The boot drive is the flashing interface.** Copying a `.uf2` firmware
   file onto that drive writes it to flash and reboots the board — flashing
   is literally a file copy. And here is the part that surprises everyone the
   first time: **the moment the copy finishes, the drive vanishes.** No safe
   eject, no file appearing on the drive, possibly even a "device was
   removed" complaint from your file manager. That is not a failure — it is
   the success signal. The board took the firmware, rebooted, and is now
   running it; the bootloader (and its fake drive) are simply gone until you
   next hold BOOTSEL. This experiment stops right before that; **exp103**
   builds a firmware with Rust + Embassy, copies it on, and you will see the
   vanishing act live.

## "But other boards don't need the button?"

You may have seen boards (Arduino, ESP32, even Picos in other people's
videos) reflash again and again without anyone touching a button. That is not
a different kind of board — it is the **currently-running firmware
cooperating**. A firmware can offer the host a way to say "reboot yourself
into the bootloader":

- `picotool reboot` can ask a running firmware to jump back to BOOTSEL mode
  over USB — if that firmware kept a USB interface alive for it.
- The *1200-baud touch*: a convention (from Arduino) where opening the
  firmware's USB serial port at 1200 baud means "reboot to bootloader". The
  flashing tool does it, the firmware notices and jumps.
- A debug probe writes flash directly over the SWD pins, no bootloader
  involved at all.

All three need something on the board playing along. Your brand-new Pico 2
has no firmware yet — and exp103's minimal blink has no USB code — so there
is nothing to cooperate, and the button is the only door in. That is also
why the button can never stop working: it is handled by ROM, below any
firmware.

A later experiment adds the 1200-baud touch to our own firmware, and the
button-pressing stops. Until then, every press is a reminder of which layer
you are talking to: ROM, not firmware.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nothing in `lsusb` | Charge-only USB cable | Use a known **data** cable — this is the #1 dead-board report |
| Still nothing | BOOTSEL released too early | Keep it held until the cable is fully in |
| Still nothing | Bad port / hub | Plug directly into the machine |
| Drive won't mount | udisks/polkit quirk | Open the drive once in the file manager, re-run |
| `INFO_UF2.TXT` says RPI-RP2 | That's an RP2040 board (Pico 1) | This repo needs an RP2350 |

**Any RP2350 board works here**, official or not — everything this experiment
touches lives in the chip's ROM. That includes the Pico 2 W. Board differences
only start at exp103, where the LED pin matters; see
[Boards](../README.md#boards).

## Next

**exp102** — install the Rust cross-compilation toolchain and prove it works,
no board needed. Then **exp103** builds a minimal Embassy blink and flashes it
through the drive you just met — the LED turning on is the whole toolchain,
proven end to end.
