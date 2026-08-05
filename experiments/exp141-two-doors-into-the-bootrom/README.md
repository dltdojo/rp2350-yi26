# exp141-two-doors-into-the-bootrom — a flash port a browser can claim

> **Verified on hardware, 2026-08-04.** A Pixel 9a's Chrome claimed the
> bootrom's PICOBOOT interface and drove it through a full flash erase — the
> descriptor, the claim on Android, and every command including `FLASH_ERASE`.
> A browser flashed the bootrom without the drag-and-drop drive. See
> [Expected output](#expected-output).

[`docs/platforms.md`](../../docs/platforms.md) recorded, on 2026-08-04, that
dragging a `.uf2` onto the phone's BOOTSEL drive **stopped working**, and blamed
Android's storage layer. [exp144](../exp144-one-file-either-half/) later found
the real cause — the board had a partition table, and a board with a table takes
nothing from that drive on *any* host — so the phone was acquitted. The threat
to the repository's premise (a phone, one cable, no second computer) is
unchanged in shape and only moved: if a board can only be reflashed by
drag-and-drop, then the moment it carries a partition table, nothing can reflash
it.

This experiment is the way out, and it starts by confirming the way out exists.

## BOOTSEL has two doors, and only one of them is the drive

Hold BOOTSEL and the bootrom presents **two** USB interfaces, not one:

| Interface | Class | What it is | Can a browser claim it? |
| --- | --- | --- | --- |
| 0 | `0x08` Mass Storage | the `RP2350` drive you drag `.uf2` onto | **No** — Chrome's WebUSB blocks the mass-storage class outright, and this is the door that takes nothing at all once the board has a partition table (exp144) |
| 1 | `0xFF` Vendor | **PICOBOOT**, the interface `picotool` drives | **Yes** — `0xFF` is not on Chrome's block list, and this repository already claims `0xFF` in [exp122](../exp122-vendor-bulk/) and [exp132](../exp132-one-owner-or-two/) |

Read from a real board in BOOTSEL, not from a datasheet:

```text
Interface 0  bInterfaceClass   8 Mass Storage / SCSI / Bulk-Only
Interface 1  bInterfaceClass 255 Vendor Specific
             EP 0x03 OUT  Bulk 64      EP 0x84 IN  Bulk 64
```

So the door that WebUSB refuses and Android writes badly is *not the only door*.
The other one — the one `picotool` uses on a desktop to flash without ever
touching a filesystem — is a plain vendor interface with bulk endpoints, and
this repository has claimed that class from a browser before.

## What this experiment confirms, and where it stops

It claims PICOBOOT from a browser and talks to it, using two control requests
that touch no flash:

- `IF_RESET` (`0x41`) — clear any half-finished command.
- `IF_CMD_STATUS` (`0x42`) — read the 16-byte status structure back.

A status of `PICOBOOT_OK` (0) means the round trip worked: the browser claimed
the bootrom's flash interface, sent it a request, and read a structured reply.

**`picoboot.html` stops before writing anything** — `check.sh` fails if a flash
command ever appears in it, so it stays the safe confirmation it is meant to be.
The writing is in a second page, [`recover.html`](#recovering-a-bricked-board-below-the-way-out),
because it earned its way in the hardest possible way: it is what un-stuck a
board exp139 bricked.

## Recovering a bricked board, below (the way out)

exp139 wrote a partition table to flash offset 0, and on real silicon it did
not boot the image — it made the bootrom's **drag-and-drop** flashing refuse
every ordinary UF2. The board enumerated in BOOTSEL, its `RP2350` drive
appeared, and dropping a `.uf2` on it did nothing: no error, no reboot, just a
board that looked bricked. Only PICOBOOT still reached it.

So [`recover.html`](./recover.html) drives PICOBOOT to erase the first 64 KiB
of flash — the bad table and anything after it — and the board is a stock board
again. Same claim, same first commands as `picoboot.html`, then:

```text
EXCLUSIVE_ACCESS → EXIT_XIP → FLASH_ERASE(0x10000000, 0x10000)
```

Verified on the phone (see [Expected output](#expected-output)). The command
line has it too: **`yi26 nuke`** does the same over `libusb` for anyone with the
tool built. `picotool erase -a` is the official equivalent, and any of the three
works because all three drive PICOBOOT rather than the drive.

This is why the arc matters more than one experiment. The drag-and-drop drive
was thought to be fragile in two directions at once — Android writing to it
unreliably, and a bad partition table making it refuse writes.
[exp144](../exp144-one-file-either-half/) collapsed that into one direction on
2026-08-05: **any** partition table makes the drive refuse a `.uf2`, on any
host, and the Android half was the same board with the same table rather than a
platform problem. One cause, and **PICOBOOT is immune to it**, because it does
not go through the drive or the storage layer. The
recovery is the sharpest proof the browser track has: a phone un-bricked a board
from a web page, with no drive, no toolchain, and nothing installed.

## The protocol, for the experiment that writes more

Established here so the next step does not start from zero. A PICOBOOT command
is a 32-byte packet on the bulk OUT endpoint:

```text
dMagic (0x431fd10b) │ dToken │ bCmdId │ bCmdSize │ _unused │ dTransferLength │ args[16]
```

The command IDs: `EXCLUSIVE_ACCESS` (0x1), `FLASH_ERASE` (0x3), `WRITE` (0x5),
`EXIT_XIP` (0x6), `REBOOT2` (0xa). A `bCmdId` with the top bit set (e.g.
`GET_INFO` 0x8b) is a device-to-host transfer. `recover.html` uses the erase
path; `WRITE` — putting a whole `.uf2` on over the bulk endpoint, then
`REBOOT2` to boot it — is what remains for a full *browser* flasher.

That full path is not theoretical: **`yi26 pflash` already does it on the
command line** — `EXCLUSIVE_ACCESS` → `EXIT_XIP` → `FLASH_ERASE` → `WRITE` in
4 KiB chunks → read-back verify → `REBOOT2` — and it flashed and booted exp138
on real silicon. So the browser experiment starts from a proven host reference,
not from the protocol alone.

**A range command's `dAddr` is absolute** — `0x10000000`, the flash XIP base,
not a zero offset. That one word cost a debugging round (see the Expected
output), and it is the thing to get right first in any command that names a
flash address. **The reboot is `REBOOT2` (0xa) with `dFlags` type `NORMAL`**,
not the RP2040-style `REBOOT` with a `pc`/`sp` pair — that pair lands the
RP2350 back in BOOTSEL even over a valid image, which cost a second round.

## The code IS the walkthrough

- [`picoboot.html`](./picoboot.html) — the read-only confirmation. Finds
  PICOBOOT by class `0xFF` (as exp132 does), claims it, sends the two read-only
  control requests, shows the status. No flash command, enforced by `check.sh`.
- [`recover.html`](./recover.html) — the write. Same claim, then
  `EXCLUSIVE_ACCESS` → `EXIT_XIP` → `FLASH_ERASE`. This is what un-bricks an
  exp139 board, verified on the phone.
- [`../../tools/yi26/src/picoboot.rs`](../../tools/yi26/src/picoboot.rs) —
  `yi26 nuke`, the same erase over `libusb` for the command line, and
  `yi26 pflash`, the full write+`REBOOT2` flasher that this experiment's
  browser version aims at (verified on hardware: it flashed and booted exp138).

## Two ways to do it

```sh
./run.sh      # guided: put the board in BOOTSEL, open the page, read the status
./check.sh    # verdict: the static half needs no board; the descriptor half
              # needs a board already in BOOTSEL
```

`check.sh` deliberately does not move the board into BOOTSEL — that is `run.sh`'s
job, so that the person deciding when to enter BOOTSEL is the one who does.

## Expected output

Captured on a **Pixel 9a, Chrome on Android, 2026-08-04**, from
[`recover.html`](./recover.html) — the write-capable sibling of
`picoboot.html`, built to un-stick a board exp139 bricked (see
[Recovering a bricked board](#recovering-a-bricked-board-below-the-way-out)).
It drives the same claim and the same first commands, then erases:

```text
claimed PICOBOOT (interface 1, OUT ep 3, IN ep 4)
IF_RESET: interface cleared
EXCLUSIVE_ACCESS: accepted
EXIT_XIP: accepted
FLASH_ERASE: accepted
=> Erased 64 KB from offset 0. The board is blank again.
```

Every line is a first for this repository. **`claimed PICOBOOT`** is the answer
to the one real unknown: Android's Chrome *does* claim the PICOBOOT interface
of this composite (MSC+PICOBOOT) device. And **`FLASH_ERASE: accepted`** is a
browser writing the bootrom's flash — no drive, no drag-and-drop, no toolchain.

Two operational details, learned in the same run and easy to trip on:

- **The device picker offers two entries; one opens, one does not.** Selecting
  the wrong one fails with `open: Access denied`. On Android the MSC half of
  the device is already held by the kernel's `usb-storage`, so that
  representation refuses to open; the PICOBOOT half is unclaimed and opens.
  Pick the one that opens.
- **After erasing, unplug and replug before flashing a UF2.** The erase leaves
  Chrome still holding the interface and the mass-storage drive mounted at its
  old state; re-enumerating gives a clean `RP2350` drive that accepts a dragged
  `.uf2` (or `yi26 flash`). Dragging onto the stale mount does nothing.

### The bug that the capture found

The first version of `recover.html` sent `FLASH_ERASE` with `dAddr = 0` and got
`acknowledgement stall` — while every command before it succeeded, which is
what localised it. `picotool`'s own `picoboot_flash_erase` passes the
**absolute** address, so `dAddr` is `0x10000000` (the flash XIP base), not a
zero offset. One word, confirmed against `picoboot_connection.c` rather than
guessed. Both `recover.html` and `yi26 nuke` carry the fix.

## What is not verified here

**The claim on Android specifically.** exp132 proved per-interface claiming of
a `0xFF` vendor interface on a phone, but against the *application* firmware,
not the bootrom's composite device. Desktop Chrome is the first place to run
this — it removes every variable except the one being tested.

**`WRITE` *from a browser*.** `picoboot.html` cannot write, by design and by
`check.sh`, and `recover.html` only erases. That PICOBOOT `WRITE`+`REBOOT2`
programs and boots flash at all is settled — `yi26 pflash` proved it over
`libusb`. What the next experiment adds is doing that same write *from a web
page*, which carries the brick risk this one was built to avoid.

## Make it yours

1. Open the page against a board that is **not** in BOOTSEL. The device picker
   offers nothing matching the filter — the application firmware is `0x1209`,
   not `0x2e8a`. That is the filter earning its place.
2. Change the filter to the application firmware and connect to a running
   board. There is no `0xFF` PICOBOOT interface there — only the bootrom has
   one. Working out why from the two device identities is the point.
3. Read the `dStatusCode` after sending nothing. It is `PICOBOOT_OK` on a fresh
   interface, which is why a reset-then-status pair is a valid liveness check.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The picker is empty | The board is not in BOOTSEL | `yi26 bootsel`, or hold the button while plugging in |
| `claimInterface` throws | Something else holds the interface, or the platform blocks it | Close other tabs; try desktop Chrome as the control |
| No status comes back | The device was claimed but not answering | Reload; confirm this is a bootrom device (`2e8a:000f`) |
| The page reports no WebUSB | Not a Chromium browser | Chrome or Edge, desktop or Android |

## Next

The experiment this one clears the ground for: **PICOBOOT `WRITE` from a
browser** — erase a region, write a `.uf2`'s payload, `REBOOT2`, and watch the
board come up on new firmware, with no drive and no drag-and-drop. The command
line already does exactly this (`yi26 pflash`, verified on hardware), so the
browser version is a port of a working path, not a leap — but it writes flash,
so it carries the brick risk this one was built to avoid, and it is under
[Planned](../README.md#planned) rather than started.
