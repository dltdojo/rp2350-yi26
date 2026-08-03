# exp133-a-page-per-job — the appliance page carries no log code

Three tools on one read-only volume, and **you can use them at the same time**:

| File | What it does | Which interface it claims |
| --- | --- | --- |
| `INDEX.HTM` | the prize draw | the **vendor** interface |
| `LOG.HTM` | the firmware's own log, live | the **CDC** pair |
| `FLASH.HTM` | into the bootloader, from here | the CDC control pipe, briefly |

[exp131](../exp131-the-volume-is-the-app-drawer/) tried this and could not: its
appliance page held the only CDC pair, so opening the log page always failed.
The fix there was to weld a log pane into the appliance page —
[exp130](../exp130-the-board-draws/) still carries it — and that fix cost
composability, which is what this experiment gets back.

Needs: any RP2350 board, the exp102 toolchain, a Chromium browser, and the
udev rule for raw USB access. On Linux, `yi26 detach` before the pages.

## The thing being demonstrated is a diff

exp130's page has a log pane, a `captured` buffer, an NDJSON exporter and two
copy buttons written into it, because on one channel the log has nowhere else
to live. This experiment's `index.html` has **none of that**:

```text
exp130/draw.html   16469 bytes   draw + log + JSON export
exp133/index.html   8486 bytes   draw (with a serial filter, see below)
```

Less than half, and the missing half is not gone — it is `LOG.HTM`, exp116's
file, byte for byte, which knows nothing about prize draws and works against
any firmware in this repository.

That is the whole argument. **A new appliance costs its own job.** Under the
merged design it costs its own job plus a log pane, and the second copy of that
pane is the one that drifts. `check.sh` fails if a log pane ever creeps back
into `index.html`, because the shape is the point and the shape is invisible
from a file listing.

## What the second interface cost

Four interfaces: CDC's two, mass storage, and the vendor one. That is the same
count as the composite this repository already enumerates cleanly, and
[exp121](../exp121-composite-hid/) measured what adding one does to every
number in the descriptor tree.

Nothing here depends on those numbers. Every page asks the descriptors — the
draw page looks for class `0xFF`, the log page for `0x02` and `0x0a` — which is
why the pages needed no changes when the tree moved.

## The protection that splitting nearly took away

exp130's page checks its own provenance by reading `page build a3` off the
firmware's boot log. **A page that holds only the vendor interface never sees
that log.** Splitting the channels would have removed the one thing that tells
somebody they are looking at a stale copy saved on their phone — the gap
earlier work recorded and did not close.

So the command channel answers the question directly:

```text
$ yi26 echo '?'
sent     1 bytes: ?
received 14 bytes: page build b2
```

One byte in, the build string out. The appliance page asks on connect and says
whether it matches, exactly as before, without needing a channel it does not
hold.

## Two entries in the picker, and why they are both ours

The first time the log page was opened on a phone that had used exp131, the
device chooser offered **two** boards: `exp133 a page per job` and
`exp131 draw and flash`. There is one board.

The descriptors rule out the obvious explanation — `lsusb` shows one
configuration, four interfaces and three interface associations, and nothing
that a host could read as two devices:

```text
bNumConfigurations      1
  bNumInterfaces          4
    bFunctionClass          2 Communications      → interfaces 0, 1
    bFunctionClass          8 Mass Storage        → interface 2
    bFunctionClass        255 Vendor Specific     → interface 3
```

The cause is a convention of this repository. Every firmware here sets
`config.serial_number` to its own experiment number — that is how
[`lib.sh`](../lib.sh)'s `exp_running` tells which one is flashed, and it is
worth keeping. But **Chrome identifies a device by vendor, product *and*
serial**, so to a browser each experiment is a *different device*. Grant
permission to exp131, flash exp133, and the permission store now holds two
identities for one board.

Nothing is broken by it. What it costs is a chooser with a stale entry that a
person can pick, and picking it fails with a message about a device rather than
about a firmware that is no longer there.

So the two pages answer it differently, and the split is the same one this
experiment is about:

| | Filter | Why |
| --- | --- | --- |
| `INDEX.HTM` | vendor, product **and `serialNumber: '133'`** | it is tied to this firmware anyway, so it can afford to be specific — and the picker then offers exactly one board |
| `LOG.HTM` | vendor and product | it is meant to work against **every** firmware here, so narrowing it would break the thing it is for |

An appliance may be picky. A general tool may not.

## Open the log first

`crates/usb-log` writes only while DTR is asserted and queues sixteen lines
otherwise, and this firmware answers a `TEST UNIT READY` every couple of
seconds. So the queue overflows in about half a minute with nobody reading —
exp130's phone capture recorded `(+64 lines lost)` before its page had
connected.

Under the merged design that did not matter much: the log pane started filling
the moment you connected, which was before you drew. Here the log is a separate
tab and **connecting it after a draw means missing that draw**. The volume's
`README.TXT` says so, and it is the one piece of operating order this design
asks for.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp131's volume and SCSI, exp132's channel
  split, and `handle()` with the `?` query that gives provenance back.
- [`index.html`](./index.html) — the appliance page. Look at how little is in
  it; that is the result.

## Two ways to do it

```sh
./run.sh      # guided: flash, then use two tools at once
./check.sh    # verdict: three owners at once, and the shape of the page
```

## Expected output

Captured from a Pico 2. `yi26 log` straight after flashing:

```text
[      41 ms] exp133 up. 64 KiB read-only volume, three pages on it.
[      41 ms] page build b2
[      41 ms] 125 clusters; INDEX.HTM is 8486 bytes, chained across 17 of them
[     110 ms] warmed up: 2048 bits through the health tests
```

The two vendor commands:

```text
$ yi26 echo '?'
sent     1 bytes: ?
received 14 bytes: page build b1

$ yi26 echo '2100-2567'
sent     9 bytes: 2100-2567
received 41 bytes: draw #2: 2257  in 2100-2567 (468 values)
```

The volume, read-only, with all three tools on it:

```text
$ lsblk -no RO /dev/sda
1

$ ls -la "/media/cyline/YI26 TOOLS"
-rw-r--r--  1 cyline cyline  9905  8月  2 20:00 FLASH.HTM
-rw-r--r--  1 cyline cyline  8486  8月  2 20:00 INDEX.HTM
-rw-r--r--  1 cyline cyline 19309  8月  2 20:00 LOG.HTM
-rw-r--r--  1 cyline cyline   830  8月  2 20:00 README.TXT
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the draw crate's tests pass
PASS  the fat12 crate's tests pass
PASS  compiles (217320 byte ELF)
PASS  converts to UF2 (140800 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (a phone can reflash this without a button)
PASS  firmware and page agree on the build string (b2)
PASS  the two tools are embedded, not copied — only the appliance page is local
PASS  the appliance page carries no log code at all
PASS  the volume carries FLASH.HTM — the way back is on the device
PASS  the volume carries LOG.HTM — and nothing else claims CDC
PASS  MODE SENSE sets the write-protect bit
PASS  WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED
PASS  board is running exp133
PASS  the host created a block device (/dev/sda)
PASS  the host marked the device read-only, because MODE SENSE said so
PASS  the volume mounts at /media/cyline/YI26 TOOLS
PASS  all three pages on the board are byte-identical to their sources
PASS  README.TXT is there beside it
PASS  a write to the volume fails (the host refuses before the device is asked)
PASS  the vendor interface drew while the volume was mounted (draw #1: 2346  in 2100-2567)
PASS  the drawn number 2346 is inside 2100-2567
PASS  the vendor channel answers ? with the build string (page build b2)
PASS  a range sent to the log channel is redirected, not ignored
```

Three owners at once in that run: the kernel holds mass storage, the kernel
holds the serial port, and libusb holds the vendor interface — and a real
command travelled over the third while the other two were in use.

The last check is worth its line. Inheriting exp131's board half is what caught
the architecture moving: it sent a range over CDC and got told where commands
had gone, because in this build they are not there any more.

## What is not verified here

**The three pages open at once, on a phone.** exp132 measured two tabs — a log
page in the background recording draws sent from another — and this is the same
arrangement with a third file on the volume. It has not been run.

## Make it yours

1. Open `LOG.HTM`, connect it, switch to `INDEX.HTM` and draw. Then switch
   back. Everything should be there, including the draws made while the log tab
   was in the background.
2. Do it the other way round — draw first, then open the log — and watch the
   draw be missing. That is the operating order this design asks for, and the
   reason is the queue rather than the channels.
3. Write a second appliance page: send `?` on connect, send your own command,
   read one reply. You will not write a log pane, and that is the point.
4. Put exp120's two-way page on the volume as a fourth file. It claims CDC,
   which `LOG.HTM` already holds — so the two of them still collide. Splitting
   channels moved the boundary; it did not remove it.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `INDEX.HTM` finds no vendor interface | An older firmware is flashed | Its `?` answer, or absence of one, says which |
| `LOG.HTM` cannot claim | `cdc_acm` on Linux, or another tab | `yi26 detach`; on a phone, close the other tab |
| A draw is missing from the log | The log tab connected after it happened | Connect the log first — see above |
| The picker offers a board that is not there | An older experiment's grant is remembered; serial numbers differ per experiment | Pick the one naming this experiment. `INDEX.HTM` filters it out; `LOG.HTM` cannot and should not |
| A range sent to the serial port does nothing | Commands are on the vendor interface here | The log says so, with the command to use |

## Next

Nothing on this road. The queue depth this design leans on is a separate
question and is under [Planned](../README.md#planned).
