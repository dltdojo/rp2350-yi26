# exp141-two-doors-into-the-bootrom — a flash port a browser can claim

> **The WebUSB step is not verified on hardware yet.** The page is written, the
> descriptor it depends on is confirmed against real silicon, and the static
> half of `check.sh` passes. What remains is a person clicking the WebUSB
> dialog — see [Expected output](#expected-output).

[`docs/platforms.md`](../../docs/platforms.md) recorded, on 2026-08-04, that
dragging a `.uf2` onto the phone's BOOTSEL drive **stopped working** — Android's
storage layer writes to that drive unreliably, and it is not a file problem or
an app problem. That threatens the repository's whole premise: a phone, one
cable, no second computer. If a board can only be reflashed by drag-and-drop,
the phone cannot be relied on to do it.

This experiment is the way out, and it starts by confirming the way out exists.

## BOOTSEL has two doors, and only one of them is the drive

Hold BOOTSEL and the bootrom presents **two** USB interfaces, not one:

| Interface | Class | What it is | Can a browser claim it? |
| --- | --- | --- | --- |
| 0 | `0x08` Mass Storage | the `RP2350` drive you drag `.uf2` onto | **No** — Chrome's WebUSB blocks the mass-storage class outright, and this is the door Android writes to unreliably |
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

**It stops before writing anything.** Flashing — `FLASH_ERASE`, `WRITE`,
`REBOOT2` — is the next experiment, and it has a brick risk this one does not.
`check.sh` fails if a flash command ever appears in the page, because the moment
one does, this stops being the safe confirmation it is meant to be.

## The protocol, for the experiment that writes

Established here so the next step does not start from zero. A PICOBOOT command
is a 32-byte packet on the bulk OUT endpoint:

```text
dMagic (0x431fd10b) │ dToken │ bCmdId │ bCmdSize │ _unused │ dTransferLength │ args[16]
```

The command IDs that matter for flashing: `EXCLUSIVE_ACCESS` (0x1),
`FLASH_ERASE` (0x3), `WRITE` (0x5), `EXIT_XIP` (0x6), `REBOOT2` (0xa). A
`bCmdId` with the top bit set (e.g. `GET_INFO` 0x8b) is a device-to-host
transfer. None of that is used by this page; it is the map for the one after.

## Why this matters more than one experiment

The browser track's promise — debug and flash a board with a phone and nothing
else — quietly depended on drag-and-drop flashing, and drag-and-drop turned out
to be the fragile part. PICOBOOT over WebUSB is the same shape as everything
else in this track: a browser claiming a USB interface and speaking its
protocol, bypassing the storage layer entirely, exactly as the WebUSB log
readers (exp115–exp126) bypass it. The reading half never had this fragility;
the flashing half can stop having it too.

## The code IS the walkthrough

- [`picoboot.html`](./picoboot.html) — finds PICOBOOT by class `0xFF` (as
  exp132 does), claims it, sends the two read-only control requests, and shows
  the status. Every command ID and the reason it is safe is in the comments.

## Two ways to do it

```sh
./run.sh      # guided: put the board in BOOTSEL, open the page, read the status
./check.sh    # verdict: the static half needs no board; the descriptor half
              # needs a board already in BOOTSEL
```

`check.sh` deliberately does not move the board into BOOTSEL — that is `run.sh`'s
job, so that the person deciding when to enter BOOTSEL is the one who does.

## Expected output

**Pending the WebUSB tap.** The descriptor half is verified — a board in
BOOTSEL shows the vendor interface and its bulk endpoints, and `check.sh`
confirms it. The browser half needs a person to open the page and pick the
device from Chrome's dialog, which no tool here can do.

What it should show when taken: `claimed interface 1`, an `IF_RESET` accepted,
and a 16-byte status with `dStatusCode=0`. If it does, one line goes in the
history that the browser track has been missing — **a browser drove the
bootrom's flash interface** — and the experiment that writes flash can begin.

If instead the claim is refused, that is also a result and goes here: which
platform, which Chrome, and the exact error. The one real unknown left is
whether Android's Chrome claims the PICOBOOT interface of this *composite*
(MSC+PICOBOOT) device; desktop Chrome is the control, and can be tried first.

## What is not verified here

**The claim on Android specifically.** exp132 proved per-interface claiming of
a `0xFF` vendor interface on a phone, but against the *application* firmware,
not the bootrom's composite device. Desktop Chrome is the first place to run
this — it removes every variable except the one being tested.

**Anything about writing flash.** This page cannot, by design and by
`check.sh`. Whether PICOBOOT `WRITE` from a browser actually programs flash is
the next experiment's question, with the next experiment's brick risk.

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
board come up on new firmware, with no drive and no drag-and-drop. That one
writes flash, so it carries the brick risk this one was built to avoid, and it
is under [Planned](../README.md#planned) rather than started.
