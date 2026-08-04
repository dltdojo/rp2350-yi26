# exp137-the-volume-that-changes — the signal works, and the file does not change

Every volume this repository has served was laid down once at boot and never
touched again. [`docs/platforms.md`](../../docs/platforms.md) says why, and
names the missing piece:

> Appending to a file after the host has mounted the volume means fighting the
> thing that makes mounting fast: the host caches sectors, so bytes the device
> writes afterwards are simply not read. Real devices answer that with a
> media-change signal — SCSI `UNIT ATTENTION` — which this repository has never
> sent and therefore cannot claim works.

This firmware sends it. `STATUS.TXT` carries a generation number; one byte on
the serial port lays the whole volume down again with the next one, and the
next SCSI command is refused with **`06/28` — NOT READY TO READY CHANGE,
MEDIUM MAY HAVE CHANGED**.

Needs: any RP2350 board, and the exp102 toolchain. No browser, and nobody in
the room — `udisksctl` scripts the mounting.

## The answer, in two parts that are easy to confuse

| | |
| --- | --- |
| Does the host **act on the signal**? | **Completely.** It asks why, is told `key 6 asc 28`, re-reads the capacity, then re-reads the boot sector, the FAT, the root directory and the data. |
| Does a **mounted file's contents change**? | **No.** `cat STATUS.TXT` returns the generation it returned before, from the page cache, and keeps doing so until the volume is unmounted. |

Both are true at once, and neither is a bug. That is the finding: **`UNIT
ATTENTION` is a notification, not an invalidation.** The block layer honours it
in full and the filesystem above it has already decided what those bytes say.

A fresh mount reads the new volume, which is what proves the bytes really
moved rather than the signal being cosmetic.

## What that means for the seam

`docs/platforms.md` wanted this for one reason: to let the log come **back**
from the board as a file, the way the `.uf2` goes out as one. On the evidence
here that route needs the reader to unmount and remount between reads, which
on a phone is a person pulling down a notification shade. It is not the
zero-friction return path that page was hoping for, and saying so is worth
more than another paragraph promising it.

What it does buy: a volume whose contents are correct **at every mount**, which
is a real capability the earlier firmwares did not have. exp126 through exp133
would have handed you the same bytes forever.

## What the board sees, which is the whole measurement

The host's side of this needs root to observe (`/dev/sda` is `root:disk`, and
`dmesg` is restricted). The board's side needs nothing: it is the device, and
it watches the host react.

```text
[    7778 ms] volume laid down again: generation 2, 125 clusters used
[    7778 ms] TEST UNIT READY  -> UNIT ATTENTION (06/28): the medium may have changed
[    7778 ms] REQUEST SENSE  -> key 6 asc 28
[    7784 ms] READ CAPACITY  -> last LBA 127, 512 bytes each = 64 KiB
[    7785 ms] READ(10) lba 0 +1 blocks
[    7785 ms] MODE SENSE(6)  -> READ-ONLY (WP set), no pages
[    7787 ms] READ(10) lba 0 +1 blocks
[    7790 ms] READ(10) lba 1 +7 blocks
[    7798 ms] READ(10) lba 24 +8 blocks
[    7803 ms] READ(10) lba 32 +8 blocks
[    7807 ms] READ(10) lba 64 +8 blocks
[    7812 ms] READ(10) lba 8 +8 blocks
```

Twelve lines, and every one of them is the host doing the right thing. The
signal went out on the very next command — a `TEST UNIT READY`, which is what
a host polls twice a second precisely to find out about media changes.

## Two commands are exempt, and it is not politeness

`INQUIRY` asks what the device *is*, which a medium change cannot affect, and
`REQUEST SENSE` is how the host collects the reason for a failure — failing
that one would hide the message being sent. Everything else is refused once,
and exactly once: a device that reported the change forever would be a device
the host gives up on.

## The whole volume is re-laid, on purpose

Not the one file that changed. `UNIT ATTENTION` is a claim about the *medium*,
and patching one file's clusters in place would be a smaller change than the
signal announces. The cost is that anything the host wrote is gone — which is
why this volume declares itself read-only, unlike the exp126 it grew from. One
cause for a change means one variable in the measurement.

## The instrument had to be fixed twice, and both are worth reading

**`TEST UNIT READY` is no longer logged.** The first run of this firmware
buried its own measurement: the host polls that command about twice a second,
the log queue is sixteen lines deep, and the capture came back as
`(+135 lines lost)` with nothing useful in it. Independent prior work on this
ground had a comment recording the same thing — *polled continuously by hosts
for media-change detection, never log it* — and this firmware had to rediscover
it the expensive way. It is counted now, and reported in the idle line.

**A log line said `writable` while the bytes said read-only.** The WP bit was
set in `mode_sense6` and the line beside it was not updated, so the firmware
spent one build telling the truth to the host and a lie to the reader. exp120
caught the same class of thing; this repository keeps finding it because it
keeps looking.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — `lay_down()` is the whole change: one
  function for the volume at boot and the volume after a change, because two
  would drift and both would still mount.
- The dispatch, where the media change is reported before the command is even
  looked at, and where two opcodes are exempt.

## Two ways to do it

```sh
./run.sh      # guided: mount it, change it under the host, watch both answers
./check.sh    # verdict: both questions, asserted separately
```

## Expected output

Captured from a Pico 2. `./check.sh`:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the fat12 crate's tests pass (the layout, with no board)
PASS  compiles (216488 byte ELF)
PASS  converts to UF2 (119296 bytes)
PASS  the volume carries FLASH.HTM — the way back is on the device
PASS  boot and re-lay go through one function
PASS  board is running exp137
PASS  the host created a block device (/dev/sda)
PASS  the host marked it read-only, because MODE SENSE said so
PASS  the volume mounts at /media/cyline/YI26 EXP137
PASS  STATUS.TXT is readable (generation 4)
PASS  the firmware laid the volume down again while it was mounted
PASS  the next command was refused with UNIT ATTENTION (06/28)
PASS  the host asked why, and was told: key 6, asc 28
PASS  the host re-read the capacity — it acted on the signal
PASS  and re-read the layout: boot sector, FAT, root directory
PASS  and the mounted file did NOT change (generation 4) — the cache answered
PASS  a fresh mount reads the new volume (generation 5) — the bytes really moved
NOTE  the two answers above are the experiment: the host honours the
      signal completely, and it still does not make a mounted file change
```

And by hand, which is the same thing said slowly:

```text
$ cat "/media/cyline/YI26 EXP137/STATUS.TXT"
generation 1
laid down at 38 ms since boot

$ yi26 send b                       # the volume is laid down again, mounted
$ cat "/media/cyline/YI26 EXP137/STATUS.TXT"
generation 1                        ← unchanged, from the cache
laid down at 38 ms since boot

$ udisksctl unmount -b /dev/sda && udisksctl mount -b /dev/sda
$ cat "/media/cyline/YI26 EXP137/STATUS.TXT"
generation 2                        ← the bytes were there all along
```

## What is not verified here

**Any host but this one.** Whether a media change invalidates a mounted
filesystem's cache is the host's decision, not the bus's — exp135 measured a
different question and found two host libraries disagreeing about it. Android,
macOS and Windows may each answer differently, and `check.sh` prints a NOTE
rather than a FAIL if yours re-reads, because that is a finding and not a
failure.

**Anything about a writable volume.** This one declares itself read-only. A
device changing bytes underneath a host that also writes them is a different
experiment, and a harder one.

## Make it yours

1. Change the volume twice between two reads. The generation jumps by two and
   the host is told once — a notification is not a queue.
2. Remove the `INQUIRY` exemption and watch a host decide the device is gone.
3. Put a growing file on the volume instead of a generation number, then read
   it with unmount/remount between each read. That is the log-as-a-file route,
   at its real cost.
4. Set `MEDIA_CHANGED` without laying the volume down again. The host does all
   the same work and finds the same bytes, which is what the signal costs when
   it is wrong.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `STATUS.TXT` never changes, even after a remount | The `b` never arrived | Watch for `asked for a new volume` in the log |
| The volume will not mount | It is read-only and some helpers assume writable | `udisksctl mount -b /dev/sdX` handles it |
| The log is all `READ(10)` | Something is reading the volume | That is the host; the interesting lines are around the change |
| `check.sh` says the block device is missing | The volume did not enumerate | `yi26 doctor --json` |

## Next

Nothing on this road, and the reason is the finding: the return path this was
built to open needs an unmount, and an unmount needs a person. What that
leaves open is under [Planned](../README.md#planned).
