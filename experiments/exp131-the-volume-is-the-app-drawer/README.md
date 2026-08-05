# exp131-the-volume-is-the-app-drawer — everything the phone needs is on the drive

[exp126](../exp126-self-hosted-viewer/) ended with a claim that turned out to
be false:

> The end of this route: after this flash, the local machine needs nothing at
> all that it did not already have.

It needed one thing. To put the *next* firmware on the board, a phone has to
reboot it into BOOTSEL, and the page that does that
([exp117](../exp117-webusb-reboot/)) was not on the board — it lived in this
repository, or in somebody's downloads folder. The demonstration in
`docs/platforms.md` walked straight into it: the page had to be sent to the
phone before the phone could flash anything.

This experiment carries it. Two pages on one read-only volume:

| File | What it is for | Embedded from |
| --- | --- | --- |
| `INDEX.HTM` | what this board **does** — the prize draw | [exp130](../exp130-the-board-draws/)'s `draw.html` |
| `FLASH.HTM` | how to **replace** it — into BOOTSEL, from here | [`tools/pages/bootsel.html`](../../tools/pages/), the maintained tool [exp117](../exp117-webusb-reboot/) built |

Needs: any RP2350 board, the exp102 toolchain, and a Chromium browser. On
Linux, `yi26 detach` first.

## Nothing here was written for this experiment

Neither page was. Both are `include_bytes!` from the file that owns them —
exp130's `draw.html` and the repository's `bootsel.html` — and `check.sh` fails
if a copy ever appears in this directory. What is new is the **composition**,
and that is the claim being made: a phone that has this board has everything,
permanently, and never needs a download again.

For a phone user the volume is not documentation. It is the **application
menu** — the only place they will think to look.

## Why the flash page has to be mandatory, not merely a good idea

It is a property of the **chain**, not of one firmware.

If this build ships `FLASH.HTM` and you use it to flash a build that does not,
the way back is gone — and you will not find out until the next time you want
to change the firmware, standing somewhere with only a phone. A missing file
discovered at that moment is the worst possible time to discover it.

So it is not a habit. `check.sh` asserts it, and the rule is written into the
[recurring questions](../README.md#how-this-repository-is-developed) that every
new experiment is put through: *a firmware that serves a volume and can be
rebooted by software carries the page that reboots it.*

## The page that was here and is not

A log viewer sat on this volume for a few hours as `LOG.HTM`, and removing it
is this experiment's real finding.

It never worked as intended. Opening it while the draw page was connected —
the only time anybody would want it — produced:

```text
Error: cannot claim the interfaces — something else owns them, and an
interface has exactly one owner. [NetworkError: Failed to execute
'claimInterface' on 'USBDevice': Unable to claim interface.]
```

That is not a fault. It is exp116's own error message being right, and
[exp132](../exp132-one-owner-or-two/) went on to measure the alternative: a
second interface really does give two owners, and a phone cannot use it because
Android offers no way to arrange two pages.

So the log moved into `INDEX.HTM`, where the port already has an owner, and
brought `Copy as JSON` with it. And then keeping `LOG.HTM` had nothing left to
offer — **a file whose only remaining effect was an error that reads like a
fault.** Two pages on one volume will always jam one of them; shipping the
second one just teaches the wrong lesson to whoever taps it.

`check.sh` now fails if it comes back. A guard against a file is unusual, and
it is here because the reason it was removed is not visible from the file list.

**And it is only right for a one-channel firmware, which this one is.**
[exp132](../exp132-one-owner-or-two/) went on to measure two tabs on a phone
against a two-channel build, and both held their interfaces — the backgrounded
log tab recorded every draw the other tab sent, with nothing lost. So on a
device with a second channel the log goes back to being one independent file
that drops onto anything, and welding it into each appliance page is the wrong
trade. This volume carries the merged page because this firmware has one
channel, not because merging is better. [exp133](../exp133-a-page-per-job/) is
the same drawer built on two, with the log back as an independent file and an
appliance page less than half the size.

## The one that names itself

This page has had three names, and each one is right for who is reading it.

| Where | Called | Because the reader |
| --- | --- | --- |
| [exp117](../exp117-webusb-reboot/) | `reboot.html` | is being shown the mechanism — one control transfer |
| [`tools/pages/`](../../tools/pages/) | `bootsel.html` | is standing beside `pflash.html` and needs to know which is which |
| **this volume** | **`FLASH.HTM`** | has a phone, three files, and no other context |

The last one is the interesting one. In a listing beside `INDEX.HTM` and
`LOG.HTM` — *what it does*, *how to read it* — "reboot" does not answer **into
what?**, and "bootsel" names a mechanism to somebody who has not been told the
mechanism exists. What that person wants is to put new firmware on, and FAT12's
8.3 names leave no room to explain. So the volume is the one place that keeps
the goal-shaped name, deliberately, and
[`tools/pages/README.md`](../../tools/pages/README.md) records that as a
decision rather than an oversight.

The page's own text is unchanged and still explains the rest: press the
button, a drive named `RP2350` replaces this one, copy a `.uf2` onto it.

## What it costs

```text
125 clusters total, 512 bytes each
 33  INDEX.HTM  16469 bytes
 20  FLASH.HTM   9905
  2  README.TXT    793
 ---
 55  used, 70 free
```

Comfortable here, and not free: the draw page alone is a quarter of the volume,
and the log viewer that briefly sat beside it was a further thirty-eight
clusters. A board with less SRAM would have to choose which pages it can carry,
and choosing is a design decision rather than an oversight — the rule above
says which one is not available to drop.

The FAT12 root directory has sixteen slots and the label takes one, so files
are not the constraint. Clusters are.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp130's firmware with two `include_bytes!`
  and a four-entry volume. The diff against exp130 is almost entirely the file
  list.

## Two ways to do it

```sh
./run.sh      # guided: mount the volume, look at what is on it, then use it
./check.sh    # verdict: every page byte-identical to its source, and the rule enforced
```

## Expected output

Captured from a Pico 2. `yi26 log` straight after flashing:

```text
[      40 ms] exp131 up. 64 KiB read-only volume, two pages on it.
[      40 ms] page build a3
[      40 ms] 125 clusters; INDEX.HTM is 16469 bytes, chained across 33 of them
[     102 ms] warmed up: 2048 bits through the health tests
```

The volume, mounted:

```text
$ lsblk -no RO /dev/sda
1

$ ls -la "/media/cyline/YI26 DRAW"
-rw-r--r--  1 cyline cyline  9905  8月  2 20:00 FLASH.HTM
-rw-r--r--  1 cyline cyline 16469  8月  2 20:00 INDEX.HTM
-rw-r--r--  1 cyline cyline   793  8月  2 20:00 README.TXT
```

Each one compared against the file it was embedded from:

```text
INDEX.HTM == exp130-the-board-draws/draw.html ✓
FLASH.HTM == tools/pages/bootsel.html ✓
```

And the draw still works with the volume mounted the whole time:

```text
[   39132 ms] draw #1: 2542  in 2100-2567 (468 values)
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the draw crate's tests pass
PASS  the fat12 crate's tests pass
PASS  compiles (151200 byte ELF)
PASS  converts to UF2 (115200 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (a phone can reflash this without a button)
PASS  firmware and exp130's page agree on the build string (a3)
PASS  no page is copied into this directory — both are embedded
PASS  the volume carries FLASH.HTM — the way back is on the device
PASS  the volume carries no second claimant of the CDC interface
PASS  MODE SENSE sets the write-protect bit
PASS  WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED
PASS  board is running exp131
PASS  the host created a block device (/dev/sda)
PASS  the host marked the device read-only, because MODE SENSE said so
PASS  the volume mounts at /media/cyline/YI26 DRAW
PASS  both pages on the board are byte-identical to their sources
PASS  README.TXT is there beside it
PASS  a write to the volume fails (the host refuses before the device is asked)
PASS  the board still draws while the volume is mounted (draw #2: 2345  in 2100-2567)
PASS  the drawn number 2345 is inside 2100-2567
```

### On a phone, 2026-08-03

Google Pixel 9a, OTG cable. **This is the three-page build**, captured before
`LOG.HTM` was removed — the file sizes and the product string below are that
build's, and the last paragraph is the reason there is no longer a third page.

The volume, listed by the phone's own file manager:

| | Phone shows | Firmware embedded |
| --- | --- | --- |
| `FLASH.HTM` | 9.90 KB | 9905 bytes |
| `INDEX.HTM` | 9.58 KB | 9578 |
| `LOG.HTM` | 19.31 KB | 19309 |
| `README.TXT` | 817 B | 817 |

The phone titles the volume **"Exp131 draw, log and flash"** — the USB product
string, not the FAT label. That is what a phone user reads, so it is where the
file list gets described.

`INDEX.HTM` opened from that drive and drew:

```text
2289        draw #8 · from 2100–2567
[   65549 ms] draw #8: 2289  in 2100-2567 (468 values)
```

with the provenance box reporting a match, so the page was the one on the
volume rather than a copy.

And `LOG.HTM`, opened while that page was still connected in another tab,
refused — which is the finding above, and the reason this section is not
simply three ticks.

## What the log is telling you

- **`two pages on it`.** The only line that changed from exp130's boot, and the
  only thing that changed at all.
- **Ten kilobytes of flash page live in the firmware image now**, on top of the
  draw page that was already there — pages on a volume are not free just
  because the volume is synthetic. The capture above puts this build's UF2 at
  115200 bytes; the build that also carried the log viewer came to 140288, and
  dropping that page is most of the difference.

## What is not verified here

**This experiment's own `Expected output` is two commits behind.** It was taken
before `FLASH.HTM` was re-pointed at the maintained page in `tools/pages/` — the
same 9905 bytes, from a different file — and before that day's edits to
`src/main.rs`. A build from this checkout comes out **512 bytes larger** than
the `115200` recorded below, which is one UF2 block and nothing about the
firmware's behaviour.

**And on 2026-08-05 that page was renamed and its header rewritten**, from
`flash.html` to [`bootsel.html`](../../tools/pages/bootsel.html) — see
[`tools/pages/README.md`](../../tools/pages/README.md) for why, and why the
name **on this volume** stayed `FLASH.HTM`. The rename changes nothing here;
the rewrite changes two numbers. The page went from 9905 to **10,535 bytes**,
so at 512 bytes to a cluster it now takes **21 clusters, not 20**, and the
volume uses **56 of its 125, not 55**. Both listings below still say the old
numbers, and are left saying them.

`check.sh` passes against the current build — it counts what is there rather
than comparing against a number written down, which is why a page growing by
630 bytes does not break it.

It is **deliberately not being re-taken now.** This repository is walked
experiment by experiment, and the run that teaches exp131 to somebody is the
run that produces its capture; a number taken outside that order has no
walkthrough attached to it. Whoever next works through this experiment replaces
the block above with what their board actually printed.

**The phone section is the three-page build**, and says so where it appears.
That capture is kept rather than re-taken because the page it shows failing is
the whole reason this experiment ships two files instead of three.

## Make it yours

1. Delete `FLASH.HTM` from the file list and run `check.sh`. It fails, which is
   the rule having teeth rather than being advice.
2. Flash this from a phone using its **own** `FLASH.HTM`, then flash it again
   the same way. The second time proves the loop closed: nothing was downloaded
   between the two.
3. Open `INDEX.HTM` and `LOG.HTM` at once. The second one refuses, and its
   error message tells you why before you have to work it out. That is the
   contention above, and it is worth feeling once.
4. Make exp130's draw page show every line it receives instead of filtering for
   `draw #`. The contention disappears, because there is then one claimant
   instead of two — and the second view arrives without a second interface.
5. Work out what to drop for a board with 32 KiB to spare. The answer is not
   `FLASH.HTM`, and the reason is in this file.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `FLASH.HTM` opens but says no WebUSB | Not Chromium, or a `file://` address on Android | Open from the Files app and choose Chrome |
| After pressing the button the page cannot reload | Expected — that drive no longer exists, `RP2350` replaced it | Copy the `.uf2` onto `RP2350`, as the page says |
| The pages will not open on Linux | The kernel owns the serial interfaces | `yi26 detach`, then reload |
| A second page says it cannot claim the interfaces | Another tab is still connected — one interface, one owner | Disconnect or close the other tab. Expected, not a fault |
| Only some pages are on the volume | The build ran out of clusters | The log prints the count at boot; drop a page or grow the disk |

## Next

Nothing on this road. What is left is under
[Planned](../README.md#planned).
