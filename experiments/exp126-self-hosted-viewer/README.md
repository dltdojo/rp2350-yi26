# exp126-self-hosted-viewer — the board carries its own debug interface

Plug this board into anything with a browser and a file manager, and the page
that reads its log is already on it. No download, no repository, no second
computer — `INDEX.HTM` on a volume the firmware synthesises out of its own
SRAM.

Needs: any RP2350 board, the exp102 toolchain, and a Chromium browser for the
last step.

## This closes a loop that opened in exp101

The `RP2350` drive that appears when you hold BOOTSEL is not a real disk. The
bootrom synthesises a FAT volume on the fly, complete with `INFO_UF2.TXT` and
an `INDEX.HTM` that points at Raspberry Pi's documentation. ARM's DAPLink
firmware does the same thing with `MBED.HTM`.

exp101 met that drive on its first page and used it without asking what it
was. **This is what it was.** The trick that made the first experiment work is
the one the last experiment builds.

## What this needed that exp125 did not

A chain.

exp125's file was 324 bytes. It fitted in one cluster, so its directory entry
pointed at the only cluster it had and the file allocation table was never
asked a question. This page is **19,309 bytes — thirty-eight clusters** — and
a directory entry holds only the *first* one.

```text
[      40 ms] exp126 up. 64 KiB of SRAM, carrying its own debug page.
[      40 ms] 125 clusters; INDEX.HTM is 19309 bytes, chained across 38 of them
```

Following the other thirty-seven is what the table is for, and it is why
`crates/fat12` grew tests for chains, for two files not colliding, and for
refusing a file that does not fit. **A volume whose chain is wrong in one link
still mounts, and still shows a file of exactly the right length.** The only
check that settles it is reading the bytes back:

```console
$ cmp "/media/cyline/YI26 EXP126/INDEX.HTM" \
      experiments/exp116-webusb-cdc-log/cdc-log-viewer.html
$ echo $?
0
```

## The page is exp116's, byte for byte

Not a copy:

```rust
const INDEX_HTM: &[u8] =
    include_bytes!("../../exp116-webusb-cdc-log/cdc-log-viewer.html");
```

Two copies of a nineteen-kilobyte page would drift, and the one on the board
is the copy nobody would think to check. Whatever exp116's page does, this one
does, because it is that file — including the agent banner, which is now
carried on the hardware.

## Expected output

The volume, as the host sees it:

```console
$ lsblk -o NAME,MODEL,SIZE,FSTYPE,LABEL,MOUNTPOINT
NAME MODEL          SIZE FSTYPE LABEL       MOUNTPOINT
sda  exp126 viewer   64K vfat   YI26 EXP126 /media/cyline/YI26 EXP126

$ ls -la "/media/cyline/YI26 EXP126"
-rw-r--r-- 1 cyline cyline 19309 8月  2 20:00 INDEX.HTM
-rw-r--r-- 1 cyline cyline   611 8月  2 20:00 README.TXT
```

And then the part worth doing once: open `INDEX.HTM` from that drive — the
file manager, not a terminal — and press **Connect and stream**.

```text
[      40 ms] exp126 up. 64 KiB of SRAM, carrying its own debug page.
[      40 ms] 125 clusters; INDEX.HTM is 19309 bytes, chained across 38 of them
[    1462 ms] INQUIRY  -> 36 bytes: yi26 / exp126 viewer
[    1466 ms] READ CAPACITY  -> last LBA 127, 512 bytes each = 64 KiB
[    1467 ms] READ(10) lba 0 +1 blocks
[    1477 ms] READ(10) lba 0 +8 blocks
[  135041 ms] idle: 135 commands, 130 blocks read, 2 written
```

That was read **in the page the board served**. The bytes of the viewer came
out of the chip's SRAM, through thirty-eight hand-chained clusters, through
SCSI replies this firmware writes, through the kernel's `usb-storage` and its
FAT driver, into a browser — which then claimed a different interface on the
same cable and streamed the log back.

`130 blocks read` includes the thirty-eight that are the page itself. **The
board reported, through the page it served, how it served the page.**

## Three functions, one cable

| Interface | Class | Who drives it |
| --- | --- | --- |
| 0 and 1 | CDC-ACM | the kernel, or a browser after `yi26 detach` |
| 2 | Mass Storage | the kernel's `usb-storage`, always |

The volume stays mounted while the browser holds the serial interfaces. They
are separate interfaces on one device, and exp121 is where that stopped being
a claim.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp124's SCSI and exp125's layout, with two
  files instead of one and the page embedded from exp116.
- [`crates/fat12`](../../crates/fat12/) — where the chains live, with tests
  that run on any machine.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, mount, open the board's own page
./check.sh    # verdict: mounts the volume and diffs INDEX.HTM against exp116's
```

## What this is not

A web server. Nothing here speaks HTTP; the page is a **file** on a volume,
opened as `file://`, which is why it works on a phone where a local server
cannot. exp115's README works through that decision at length.

It is also not persistent. The volume is SRAM: write to it and the changes are
real until the next reset, and then the firmware lays the original bytes down
again. A board that needs to keep what you wrote would put the volume in
flash, which is a different experiment and a considerably more dangerous one.

## Make it yours

1. Put a third file on the volume. The root directory has sixteen slots and
   the label takes one, so there is room — and `fat12` will refuse rather than
   overflow, which is a test in that crate.
2. Replace `INDEX.HTM` with exp117's page and the board can reboot itself from
   a page it served. Then try exp120's, and notice which of them needs a
   firmware that reads the OUT endpoint.
3. Make the volume 16 MiB and watch the cluster count cross 4085. Nothing in
   the boot sector changes and the host starts calling it FAT16.
4. Add `INFO_UF2.TXT` with the same fields the bootrom writes. At that point
   the imitation is close enough to be worth comparing side by side.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `INDEX.HTM` is the right size but the browser shows nothing | A wrong link in the cluster chain | `cmp` it against exp116's page; the length will still match |
| The page loads but cannot claim | `cdc_acm` still owns the interfaces | `yi26 detach`, then reload |
| The drive does not appear | The volume did not mount | `lsblk`; `udisksctl mount -b /dev/sdX` |
| Changes to files vanish | The volume is SRAM | Expected — see above |

## Next

Nothing, on this track. The destination it was built toward — **debugging
firmware with a phone** — is reachable: exp117 flashes the board from a page,
exp120 talks to it, exp116 reads its log, and exp126 means the page for all
three can come off the board itself.

**One word of that was too strong, and it took until exp131 to notice.** The
claim below that the local machine then needs nothing it did not already have
is false by one file: to flash the *next* firmware, a phone needs exp117's
page, and this volume does not carry it. [exp131](../exp131-the-volume-is-the-app-drawer/) puts it on the drive and
makes carrying it a rule.

What remains in this repository is listed under
[Planned](../README.md#planned), and none of it is on this road.
