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

This experiment carries it. Three pages on one read-only volume:

| File | What it is for | Embedded from |
| --- | --- | --- |
| `INDEX.HTM` | what this board **does** — the prize draw | [exp130](../exp130-the-board-draws/)'s `draw.html` |
| `LOG.HTM` | how to **read** it — the firmware's own log, live | [exp116](../exp116-webusb-cdc-log/)'s viewer |
| `FLASH.HTM` | how to **replace** it — into BOOTSEL, from here | [exp117](../exp117-webusb-reboot/)'s page |

Needs: any RP2350 board, the exp102 toolchain, and a Chromium browser. On
Linux, `yi26 detach` first.

## Nothing here was written for this experiment

Not one page. All three are `include_bytes!` from the experiment that owns
them, and `check.sh` fails if a copy ever appears in this directory. What is
new is the **composition**, and that is the claim being made: a phone that has
this board has everything, permanently, and never needs a download again.

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

## Why the log page is here, and the thing it turns out not to do

On a phone, until this file was on the volume, the firmware's log was
unreadable — there is no `yi26` there, and nothing to download it with if you
are standing somewhere with only a phone. `LOG.HTM` fixes that, and that alone
earns its 38 clusters.

**What it does not do is give you a second view of a draw while the draw is
happening**, and the first run on a phone is what established that. Opening
`LOG.HTM` with the draw page still connected in another tab produces:

```text
Error: cannot claim the interfaces — something else owns them, and an
interface has exactly one owner. [NetworkError: Failed to execute
'claimInterface' on 'USBDevice': Unable to claim interface.]
```

That is not a fault. It is exp116's own error message being right: **an
interface has exactly one owner**, and both pages want the same CDC pair.
Close one and the other works.

Nor does opening it afterwards recover the draw. `crates/usb-log` writes only
while DTR is asserted and queues sixteen lines otherwise; the lines describing
a draw were delivered to the page that was connected at the time, and are gone.
`LOG.HTM` opened later shows what happened *after* the disconnect.

So this experiment claimed a second, simultaneous view and did not have one.
Both ways out were then taken, and they went in different directions.

- **[exp132](../exp132-one-owner-or-two/)** built the architectural answer — a
  vendor interface carrying the commands while CDC carries the log — and
  measured two programs receiving the same draw at the same instant. It works,
  and it is **useless on a phone**: Android lets you choose which app opens a
  file and gives you no second window to put a page in, so "two pages, one
  each" is not something a person can do there.
- **exp130's page now shows every line it receives.** It always received them
  and filtered for `draw #`; showing the rest costs one function. One claimant,
  both views, no descriptor change — and it is what `INDEX.HTM` on this volume
  does today.

So the second view exists, and it is not in this file. **`LOG.HTM` keeps its
place for a different reason**: it is exp116's full viewer, with the
`Copy as JSON` export that `docs/platforms.md` builds the whole evidence-return
route on, and it reads the log of **any** firmware in this repository rather
than only this one. That is worth 38 clusters. Being the second witness to a
draw is no longer the argument for it.

## The one that names itself

`reboot.html` says what it does to somebody who already knows. In a file
listing on a phone, beside `INDEX.HTM` and `LOG.HTM`, it does not — reboot
into *what?* The file on the volume is called **`FLASH.HTM`**, because the
thing the person wants is to put new firmware on, and FAT12's 8.3 names leave
no room to explain.

The page's own text is unchanged and still explains the rest: press the
button, a drive named `RP2350` replaces this one, copy a `.uf2` onto it.

## What it costs

```text
125 clusters total, 512 bytes each
 22  INDEX.HTM  10871 bytes
 20  FLASH.HTM   9905
 38  LOG.HTM    19309
  2  README.TXT    817
 ---
 82  used, 43 free
```

Comfortable here, and not free: the log viewer is half the total. A board with
less SRAM would have to choose which pages it can carry, and choosing is a
design decision rather than an oversight — the rule above says which one is not
available to drop.

The FAT12 root directory has sixteen slots and the label takes one, so files
are not the constraint. Clusters are.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp130's firmware with three `include_bytes!`
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
[      41 ms] exp131 up. 64 KiB read-only volume, three pages on it.
[      41 ms] page build a1
[      42 ms] 125 clusters; INDEX.HTM is 9578 bytes, chained across 19 of them
[     106 ms] warmed up: 2048 bits through the health tests
[    1451 ms] INQUIRY  -> 36 bytes: yi26 / exp131 drawer
[    1453 ms] TEST UNIT READY  -> ok
```

The volume, mounted:

```text
$ lsblk -no RO /dev/sda
1

$ ls -la "/media/cyline/YI26 DRAW"
-rw-r--r--  1 cyline cyline  9905  8月  2 20:00 FLASH.HTM
-rw-r--r--  1 cyline cyline  9578  8月  2 20:00 INDEX.HTM
-rw-r--r--  1 cyline cyline 19309  8月  2 20:00 LOG.HTM
-rw-r--r--  1 cyline cyline   817  8月  2 20:00 README.TXT
```

Each one compared against the file it was embedded from:

```text
INDEX.HTM == exp130-the-board-draws/draw.html          ✓
FLASH.HTM == exp117-webusb-reboot/reboot.html          ✓
LOG.HTM   == exp116-webusb-cdc-log/cdc-log-viewer.html ✓
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
PASS  compiles (216736 byte ELF)
PASS  converts to UF2 (140288 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (a phone can reflash this without a button)
PASS  firmware and exp130's page agree on the build string (a1)
PASS  no page is copied into this directory — all three are embedded
PASS  the volume carries FLASH.HTM — the way back is on the device
PASS  the volume carries LOG.HTM — the second view is reachable too
PASS  MODE SENSE sets the write-protect bit
PASS  WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED
PASS  board is running exp131
PASS  the host created a block device (/dev/sda)
PASS  the host marked the device read-only, because MODE SENSE said so
PASS  the volume mounts at /media/cyline/YI26 DRAW
PASS  all three pages on the board are byte-identical to their sources
PASS  README.TXT is there beside it
PASS  a write to the volume fails (the host refuses before the device is asked)
PASS  the board still draws while the volume is mounted (draw #2: 2508  in 2100-2567)
PASS  the drawn number 2508 is inside 2100-2567
```

### On a phone, 2026-08-03

Google Pixel 9a, OTG cable. The volume, listed by the phone's own file manager:

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

- **`three pages on it`.** The only line that changed from exp130's boot, and
  the only thing that changed at all.
- **The UF2 is 140288 bytes**, against exp130's 81408. Nineteen kilobytes of
  log viewer, plus ten of flash page, live in the firmware image now — pages on
  a volume are not free just because the volume is synthetic.

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
