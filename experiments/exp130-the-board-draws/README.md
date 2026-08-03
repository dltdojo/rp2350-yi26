# exp130-the-board-draws — the board serves the page that shows its own draw

[exp129](../exp129-numbered-draws/) drew numbers with `yi26 send` and nothing
in between. This one puts the draw behind a page and serves that page off the
board's own volume — plug the board into a phone, open `INDEX.HTM`, enter the
range on the tickets, press Draw.

That is the form the job is actually for. It is also a **different security
picture**, and the difference is the experiment.

Needs: any RP2350 board, the exp102 toolchain, and a Chromium browser for the
last step. On Linux, `yi26 detach` first.

## What moved between exp129 and here

| | exp129 | exp130 |
| --- | --- | --- |
| Between the TRNG and you | `yi26 log`, whose source is in this repository | a browser, a page, and a screen |
| The number you read is | what the device said | **a claim about** what the device said |
| How you check it | there is no middle to check | the board's own line, printed under the number |

Nothing was weakened to get here — the draw, the rejection sampling and the
health gate are exp129's, unchanged. What changed is that **an audience is now
trusting a renderer**, and no amount of correctness in the firmware addresses
that.

The answer this experiment gives is not a stronger promise. It is a second
view: the page prints the exact line the board emitted, underneath the big
number it parsed out of it, and below that **every other line the board sends**.
Two views of one event, on one screen, comparable by anyone standing there.
That is the whole mechanism.

The page also carries `Copy` and `Copy as JSON`, the second of which produces
byte-for-byte what `yi26 log --json` produces. That is how evidence leaves a
phone: paste it at whoever is helping from a machine that has never seen this
board. The parser is exp116's, extracted between markers, and `check.sh` runs
it over the same committed fixture the Rust side is diffed against — two
implementations of one format, neither of them the authority.

The log pane arrived late and by way of two other experiments.
[exp131](../exp131-the-volume-is-the-app-drawer/) put a separate log page on
the volume beside this one and could not open it — an interface has exactly
one owner and this page already had it.
[exp132](../exp132-one-owner-or-two/) measured the architectural alternative,
found that a second interface really does give two owners, and then found that
a phone cannot use it: Android offers no way to put two pages side by side. So
the second view belongs **in the page holding the port**, and it costs one
function and three clusters.

## The bit exp126 left clear

exp126's volume was writable, and an Android phone created a **`LOST.DIR`** on
it within a minute of mounting — its storage layer does that to removable
media. Harmless there, since the volume is SRAM and the write dies at the next
reset. Not harmless as a habit.

This volume declares itself read-only, in the one byte that says so:

```rust
out[2] = 0x80;   // MODE SENSE(6), device-specific parameter, bit 7 = WRITE PROTECT
```

And the interesting part is what that does:

```text
$ lsblk -o NAME,RO,SIZE,LABEL /dev/sda
NAME RO  SIZE LABEL
sda   1   64K YI26 DRAW

$ touch "/media/cyline/YI26 DRAW/PROBE.TXT"
touch: cannot touch ...: Read-only file system
```

**The write failed at the host, not at the device.** The firmware never saw a
`WRITE(10)` at all, because the kernel had already been told and did not try.
A declaration is not a lock — it is a statement a well-behaved host acts on,
and the device-side refusal underneath it is a backstop that a well-behaved
host never reaches. Both halves have to exist: declaring read-only and then
accepting writes would be a lie a host has no way to catch.

## Proving the page came off the board

A page opened from the board's volume and a stale copy saved on the phone
weeks ago **look identical in the address bar** — both are `content://` URIs
from a file manager. That is a real way to be fooled, and it is not detectable
by looking.

So the firmware announces its page build at boot and the page knows its own:

```text
[      39 ms] exp130 up. 64 KiB read-only volume, carrying its own draw page.
[      39 ms] page build a2
```

The page reads that line and compares. Matching says so; differing says
**"you are looking at a copy from somewhere else — open INDEX.HTM from the
board's drive"**. `check.sh` guards the pair, because two constants that drift
apart would make the warning fire against the *right* page, and a guard that
cries wolf gets ignored exactly when it matters.

## Three interfaces, three owners, at once

This is the composite exp122 argued for and exp126 built: the kernel's
`usb-storage` holds the MSC interface while something else holds CDC. Here
both are in use simultaneously and for real work — the volume is being read to
serve the page, and the draw is travelling over the serial interface.

On a phone, the browser is the second owner rather than a kernel driver, and
the same per-interface claiming applies.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp126's SCSI and FAT12, exp129's
  fetch-test-draw order, and the write-protect bit with its refusal underneath.
- [`draw.html`](./draw.html) — the page. It sends a range and parses one line;
  it does not choose anything.
- [`crates/draw`](../../crates/draw/) — the rejection sampling, with tests that
  count preimages over 2³².

## Two ways to do it

```sh
./run.sh      # guided: flash, see the volume refuse writes, draw, then open the page
./check.sh    # verdict: everything except the page, which needs a human's tap
```

## Expected output

Captured from a Pico 2. `yi26 log` straight after flashing:

```text
[      39 ms] exp130 up. 64 KiB read-only volume, carrying its own draw page.
[      39 ms] page build a2
[      39 ms] 125 clusters; INDEX.HTM is 10871 bytes, chained across 22 of them
[     103 ms] warmed up: 2048 bits through the health tests
[    1456 ms] INQUIRY  -> 36 bytes: yi26 / exp130 draw
[    1458 ms] TEST UNIT READY  -> ok
[    1458 ms] READ CAPACITY  -> last LBA 127, 512 bytes each = 64 KiB
[    1459 ms] READ(10) lba 0 +1 blocks
[    1460 ms] MODE SENSE(6)  -> READ-ONLY (WP set), no pages
```

Draws, with the volume mounted the whole time:

```text
[   66397 ms] draw #3: 2456  in 2100-2567 (468 values)
[   68446 ms] draw #4: 2481  in 2100-2567 (468 values)
[   70467 ms] draw #5: 2361  in 2100-2567 (468 values)
[   72526 ms] not a range: "hello"
[   74575 ms] 2567-2100 is empty — lo must not be above hi
```

`./check.sh` against that board:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the draw crate's tests pass
PASS  the fat12 crate's tests pass
PASS  compiles (150892 byte ELF)
PASS  converts to UF2 (83968 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  auto-reboot is compiled in (a phone can reflash this without a button)
PASS  firmware and page agree on the build string (a2)
PASS  MODE SENSE sets the write-protect bit
PASS  WRITE(10) is refused with DATA PROTECT / WRITE PROTECTED
PASS  board is running exp130
PASS  the host created a block device (/dev/sda)
PASS  the host marked the device read-only, because MODE SENSE said so
PASS  the volume mounts at /media/cyline/YI26 DRAW
PASS  INDEX.HTM on the board is byte-identical to draw.html (10871 bytes)
PASS  README.TXT is there beside it
PASS  a write to the volume fails (the host refuses before the device is asked)
PASS  the board still draws while the volume is mounted (draw #1: 2465  in 2100-2567)
PASS  the drawn number 2465 is inside 2100-2567
NOTE  the page itself is a human's job — the WebUSB picker is a native
      dialog behind a required user gesture. Everything above is what
      can be checked without one.
```

### On a phone, 2026-08-03

Captured on a Google Pixel 9a with an OTG cable, against **page build a1** —
before the log pane was added. The sizes below are that page's; today's is
10871 bytes. Nothing else in the capture changed. The board was put into BOOTSEL
from [exp117](../exp117-webusb-reboot/)'s page — no button — the `.uf2` dragged
onto the drive that appeared, and then `INDEX.HTM` opened **from the board's
own volume** via the Files app.

Two draws, two ranges:

| Shown large | Beneath it | The board's own line, printed by the page |
| --- | --- | --- |
| **2451** | `draw #1 · from 2100–2567` | `[   70287 ms] draw #1: 2451  in 2100-2567 (468 values)` |
| **247** | `draw #2 · from 20–256` | `[   88990 ms] draw #2: 247  in 20-256 (237 values)` |

The second range is a different width and the arithmetic follows it: 256 − 20 +
1 is 237, and the sequence number advanced rather than restarting. Both numbers
land inside the range that was asked for, and in both cases the parsed number
above and the device's own sentence below are on screen together.

And the box that matters most for a page nobody downloaded:

> Provenance: the firmware carries page build **a1** and this page is build
> **a1**. They match, so this is the page on the board's own volume.

That is the check earning its place. A page served off the board and a copy
saved on the phone last month are both `content://` URIs from a file manager
and cannot be told apart by looking — so the page stops relying on looking.

And the volume was left alone. Same phone, same file manager, one byte of
difference between the two firmwares:

| Volume | Write protect | What Android put on it |
| --- | --- | --- |
| exp126 | not declared | `LOST.DIR`, within a minute of mounting |
| exp130 | declared | nothing — `INDEX.HTM` and `README.TXT`, and that is all |

Two more numbers agreed without being asked to. The phone listed `INDEX.HTM`
as **9.58 KB**, which is the 9578 bytes the firmware reports at boot, and
`README.TXT` as **673 B**, the same size Linux reads off the volume. Both files
carried the FAT12 timestamps written by hand at boot rather than anything the
phone supplied.

One incidental thing worth knowing if you are naming a device. The phone titles
the volume **"Exp130 the board draws"** — the USB *product string*, not the FAT
label, which is `YI26 DRAW` and appears nowhere on screen. Android names the
mount from the descriptor. The eleven characters of a FAT label are what Linux
shows; the thirty-odd of a product string are what a phone user reads.

### The log pane on a phone, page build a3

Verified on the Pixel 9a with the export in place. The line the number was
parsed from came back as:

```text
[   19717 ms] (+64 lines lost) draw #1: 2322  in 2100-2567 (468 values)
```

**`(+64 lines lost)`** is the marker worth stopping on. `crates/usb-log` holds
sixteen lines and drops the rest while nobody is reading, and this firmware
answers a `TEST UNIT READY` every two seconds — so by the time a phone has been
plugged in, tapped through a permission dialog and connected, dozens of lines
are already gone.

That is not a defect and it is not hidden. It is why `Copy as JSON` carries
`lost` as a field and a `lost_total` in its summary: a capture that quietly
dropped a third of its lines reads almost exactly like one that dropped none,
and somebody debugging from the JSON needs to be told which they have.

The log pane below it filled with what the board says when nothing is being
asked of it — `TEST UNIT READY -> ok`, and idle lines reporting
`364 blocks read, 0 written`, which is the read-only volume visible in the
firmware's own accounting.

## What is not verified here

**The `WRITE(10)` refusal has never fired.** Both hosts tried — Linux and
Android — read the write-protect bit and declined to write, so the refusal
underneath it was never asked for. That is the mechanism working, and it is
also why the backstop is untested: it is written, reasoned about, and never
exercised. Described here rather than in `Expected output`, because those are
captures. Producing it means a host that ignores MODE SENSE, and neither of
the two available here does.

**A vendor Android other than a Pixel.** Whether a third-party file manager
hands Chrome a usable `content://` URI, and whether the volume mounts at all
under a vendor's storage policy, is per-vendor and unconfirmed.

## Make it yours

1. Clear the write-protect bit and mount the volume on a phone. A `LOST.DIR`
   appears. That is one byte's difference and it is the whole argument.
2. Change one character in `draw.html` without bumping `PAGE_BUILD` in both
   places. `check.sh` fails, which is the guard doing its job.
3. Bump `PAGE_BUILD` in the firmware only, flash it, and open a saved copy of
   the old page. The provenance warning is what somebody at a real draw would
   need to see.
4. Put exp117's reboot page on the volume as a second file. Then the board
   serves both the thing it does and the way to replace it, and a phone needs
   nothing downloaded at all.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| The page says it cannot claim the interfaces | The kernel's `cdc_acm` owns them | `yi26 detach`, reload. On a phone this cannot happen |
| The page reports no WebUSB | Not a Chromium browser — or a `file://` URL on Android | Open from the Files app and choose Chrome |
| The provenance box warns about builds | You opened a saved copy, not the board's | Open `INDEX.HTM` from the board's drive |
| The volume will not mount | It is read-only; some mount helpers assume writable | `udisksctl mount -b /dev/sdX` handles it |
| Draws stop and the log says refused | The health tests failed | Real if it survives a reset — see exp114 |

## Next

Nothing on this road. exp129 established what can be checked about a draw and
this one established what changes when a screen gets involved; the remaining
work is under [Planned](../README.md#planned).
