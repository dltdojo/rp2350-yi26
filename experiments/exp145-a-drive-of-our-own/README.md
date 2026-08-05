# exp145-a-drive-of-our-own — the write the ROM's drive would not take

> **Verified on hardware, 2026-08-05.** A board running v2.0 from partition 1
> serves its own FAT12 volume. Drop an ordinary `v3.uf2` on it: 109 UF2 blocks
> arrive, 27,904 bytes are erased and programmed into **sectors 1..16** — the
> half that is not running — in 316 ms, and the board reboots into v3.0 from
> partition 0. Drop `v4.uf2` next and it goes back into sectors 17..32. The
> halves alternate on their own, each firmware writing the one that replaces it.
> See [Expected output](#expected-output).

[exp144](../exp144-one-file-either-half/) found the shape of the problem and
left it there: the ROM knows exactly which half of an A/B pair a dropped file
belongs in and will tell anyone who asks — and its own BOOTSEL drive refuses the
file outright once a partition table exists. This is the last item on the update
road, and the control it was always going to end at: serve the volume ourselves,
and do the thing the ROM declined to do.

Needs: any RP2350 board, and the exp102 toolchain. No browser. The volume mounts
like any USB stick, so the drop needs whatever mounts one — `udisksctl` here,
Finder or Explorer elsewhere.

## What this firmware is

Not a bootloader in the usual sense. It is an **ordinary application**, running
from one half of an A/B pair, that also presents a small volume. That
distinction is the whole finding at the end of this page, so it is worth
noticing before the code: nothing here runs before your firmware. It *is* your
firmware.

```text
   host                     this firmware                 flash
   ────                     ─────────────                 ─────
   cp v3.uf2 /media/…  ──►  WRITE(10) sectors  ──►  UF2 blocks staged in SRAM
                            (109 of them)
                            all blocks in?      ──►  erase + program the
                                                     other half, then reboot
                                                       │
                            the ROM boots the higher version ◄┘
```

## Three sectors of filesystem, and no disk

A FAT12 volume's bookkeeping is a boot sector, one FAT, and a root directory:
**three sectors**, whatever size the volume claims to be. So that is all this
firmware keeps. It declares 128 KiB and stores 1,536 bytes; every other sector
the host writes is read for a UF2 block and then dropped on the floor.

```rust
fat12::format_metadata(meta, DISK_BLOCKS as u16, b"DROP-A-UF2 ");
```

That function is new in [`crates/fat12`](../../crates/fat12/), and its test is
the claim it rests on: for an empty volume, the three sectors it writes are
byte-for-byte what `format` writes for a volume of the same declared size.

The volume label is the user interface. It is the only text a host shows before
anything has been dropped, so it says what to do: **DROP-A-UF2**.

## Knowing the file is complete, without being told

Nothing on the wire says a file was closed. [exp137](../exp137-the-volume-that-changes/)
is this repository's record of how little a host will tell a device, and a
receiver that waits for a "done" signal waits forever.

UF2 does not need one. Every 512-byte block carries `blockNo` and `numBlocks`,
so the last missing block announces itself:

```rust
if self.seen[word] & bit == 0 {
    self.seen[word] |= bit;
    self.taken += 1;
    self.expect = b.num_blocks;
}
if self.expect > 0 && self.taken >= self.expect {
    self.complete = true;
}
```

A bitmap, because hosts write the same sector twice and a count that trusted
them would finish early. The completion protocol is in the **file format**, not
in the transport — which is why this works over a filesystem nobody is
coordinating.

## Three refusals before anything is erased

Everything dangerous is in one function, and it checks before it writes:

| Check | Why |
| --- | --- |
| The ROM named a target partition | Without a table there is no other half; writing anyway would overwrite the running image |
| The target is **not** the running half | The one guaranteed way to brick this: erase the code you are executing |
| The image fits the slot | A partition is `first..last`; an image that overruns it writes into the next partition |

And on the way in, a sector is only taken as a UF2 block if all **three** magic
words match and the family ID is this chip's. Two magic words are easy to hit by
accident in a file that is not a UF2; the end marker at offset 508 is what makes
a mis-sized or half-written sector recognisable as not-a-block.

The failure mode that remains is honest and bounded: if the program step fails
halfway, the *other* half is corrupt and the running half is untouched, so the
board still boots — which is the same shape as
[exp143](../exp143-the-image-that-is-never-bought/)'s rollback, for the same
reason.

## Flash offsets, not addresses

`embassy-rp`'s flash driver says it in its own doc comment, and it is the kind
of thing that is invisible until it is a whole-chip miss:

```rust
let offset = first * SECTOR_BYTES;      // sector 1 -> 0x1000, not 0x10001000
flash.blocking_erase(offset, offset + span)?;
flash.blocking_write(offset, &stage.bytes[..span as usize])?;
```

The driver runs the erase and the program from RAM with interrupts off, because
the flash it is erasing is the flash the code would otherwise be fetched from.
That means **USB stops answering for the duration** — 316 ms here — so the write
happens between SCSI commands and never inside one, and the reboot follows a
second and a half later so the log has time to drain.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the volume, the sniffer, the three refusals,
  and the install.
- [`../../crates/fat12`](../../crates/fat12/) — `format_metadata`, and the test
  that says three sectors is a whole filesystem.
- [`../exp124-msc-scsi`](../exp124-msc-scsi/) — where the SCSI answers came
  from; most of this file is that file.

## Two ways to do it

```sh
./run.sh      # guided: flash a pair, drop v3.0, watch it install into the other
              # half, then drop v4.0 and watch the halves alternate
./check.sh    # verdict: the guards, the three-sector volume, and — if a board
              # is running exp145 — that the host sees the volume and the
              # firmware knows where a drop belongs. Drops nothing
```

## Expected output

Captured **2026-08-05**. A board running v2.0 from partition 1:

```text
exp145 up. v2.0, serving 128 KiB of volume out of 1536 bytes of filesystem.
I am version 2.0, running partition 1.
a dropped .uf2 goes to sectors 1..16 — the other half
drop a .uf2 on the DROP-A-UF2 volume and this firmware will install it.
idle: v2.0, partition 1, drop -> sectors 1..16, 0 blocks taken
```

`cp target/v3.uf2 /media/cyline/DROP-A-UF2/`:

```text
all 109 UF2 blocks arrived, 27904 bytes of image
installing 27904 bytes into partition sectors 1..16
  erase 0x1000..0x8000, then program
  written. Rebooting; the ROM boots whichever half has the higher version.
yi26: read failed: Broken pipe
```

The broken pipe is the reboot, seen from the host side — the same thing the
ROM's own drive does when it accepts a file, and for the same reason.

```text
exp145 up. v3.0, serving 128 KiB of volume out of 1536 bytes of filesystem.
I am version 3.0, running partition 0.
a dropped .uf2 goes to sectors 17..32 — the other half
```

Then `cp target/v4.uf2 …`, and the other half is written this time:

```text
all 109 UF2 blocks arrived, 27904 bytes of image
installing 27904 bytes into partition sectors 17..32
  erase 0x11000..0x18000, then program
  written. Rebooting; the ROM boots whichever half has the higher version.
```

```text
exp145 up. v4.0 …
I am version 4.0, running partition 1.
a dropped .uf2 goes to sectors 1..16 — the other half
```

v2.0 in partition 1, v3.0 in partition 0, v4.0 back in partition 1. Nobody chose
those slots: the ROM named each one, and the firmware that was running wrote it.

## What it cost, and what it cannot do

The road called for this to be built last, against a measured baseline, so the
comparison is a number rather than an assumption. Against the same firmware
without the volume ([exp144](../exp144-one-file-either-half/)):

| | Cost |
| --- | --- |
| Flash | ~4.5 KiB more image (27,904 bytes against 23,296) |
| SRAM | 67 KiB — 1.5 for the filesystem, 64 to stage the image |
| Source | ~390 lines over a plain firmware, most of them SCSI |
| Time to install | 316 ms of erase and program, USB silent throughout |

And the part that is not a number. **This updater lives inside the
application.** If the running firmware is broken — a bad build, a crash before
USB comes up, exp139's dark board — there is no volume, no SCSI, and no way in.
The ROM's BOOTSEL is there whatever you have done to flash, because it runs
before anything of yours does.

So the trade this whole road was built to price: a hand-rolled updater buys the
write the ROM refused, on the boards where the ROM refuses it, and costs the one
guarantee the ROM was giving away for free. Both halves of that sentence are
measured, and neither is a reason to skip the other.

## Make it yours

1. Write the image as **provisional**: flip bit 15 of the incoming IMAGE_DEF's
   image-type word as it is staged, and the new half boots on
   [exp143](../exp143-the-image-that-is-never-bought/)'s 16.8-second clock and
   rolls back unless it buys itself. The trade is that a dropped file only
   sticks if the firmware in it asks to stay.
2. Drop a `.uf2` built for a *different* chip and watch nothing happen — the
   family check refuses every block and the counter stays at zero. Then remove
   the family check and find out what a wrong-family image does to the other
   half.
3. Stage nothing: write each block into flash as it arrives, and lose the 64 KiB
   buffer. Work out what a power cut halfway through then costs you, and why the
   buffer was there.
4. Serve a `README.TXT` on the volume as well as the label. It needs a data
   cluster, which means storing more than three sectors — measure what it adds,
   and decide whether a filename is worth it.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No DROP-A-UF2 volume appears | The MSC interface did not come up, or the host auto-mount is off | `lsblk` for the 128 KiB device, then `udisksctl mount -b /dev/sdX` |
| The copy succeeds and nothing installs | The file is not a UF2, or is for another chip | The log's "blocks taken" stays at 0; check the family ID with `od -An -tx4 -j28 -N4 file.uf2` (expect `e48bff59`) |
| "install refused: the target IS the running half" | Only one partition, or no A/B link | exp142 covers the link; `get_b_partition(0)` must not be negative |
| "install refused: N bytes into an M byte slot" | The image outgrew the 16-sector slot | Widen the slots in `tools/partimg`, and remember `yi26 pflash` erases one contiguous span |
| The board reboots and comes back on the **old** version | The written half has the lower version | The ROM picks by version, not by recency — build the dropped image with a higher `EXP145_MAJOR` |

## Next

This closes the update road. What is left elsewhere: **PICOBOOT `WRITE` from a
browser** on the flashing road — `yi26 pflash` is the working reference for it —
and the standing note that **signing and secure boot are not on this road**,
because turning them on burns OTP and that is irreversible on a board this
project has two of.
