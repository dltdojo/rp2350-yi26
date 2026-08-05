# exp125-fat12-by-hand — a filesystem written by hand

exp124 offered 64 KiB of zeros and the host mounted nothing, because a sector
of zeros is not an empty filesystem — it is the absence of one. This writes
the bytes that make it a filesystem, and the volume mounts with a file on it.

**There is no filesystem driver here.** Nothing parses a path, allocates a
cluster or handles a `write()`. A boot sector, one FAT and a root directory
are laid into an array at boot, and the host does all the interpreting. That
is the claim worth taking away: a filesystem is an arrangement of bytes that
other software has agreed to read.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## The layout, and why every number depends on the others

```text
  sector 0        boot sector, carrying the BPB that describes all of this
  sector 1        the FAT: 12-bit entries, 341 of them in 512 bytes
  sector 2        root directory: 16 entries of 32 bytes = exactly 512
  sector 3..128   data, one cluster per sector, 125 of them
```

These are not independent choices. Reserved sectors, FAT count, sectors per
FAT and root entries together decide where the data area starts; what is left
divided by sectors per cluster is the cluster count.

And **the cluster count is what decides the format.** A host does not read the
string `"FAT12   "` in the boot sector to work out what this is — that string
is documentation for people. It does the arithmetic, and under 4085 clusters
means twelve-bit entries. This layout comes to 125, which the firmware prints
rather than a comment asserting:

```text
[      38 ms] exp125 up. 64 KiB formatted as FAT12 by hand.
[      38 ms] 125 clusters, which is under 4085 — that number is what makes it FAT12
```

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. This is the third
of a trio and the pay-off: [exp123](../exp123-bot-framing/) refuses and gets no
disk, [exp124](../exp124-msc-scsi/) answers and gets an unformatted one, and
this one gets a volume the operating system will open.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable.
  * Ubuntu. `cat`, `stty`, `lsblk` and `ls` are already there. No `yi26`.

1. UNPACK IT.

       unzip exp125-fat12-by-hand.zip
       cd exp125-fat12-by-hand

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go:

       cp firmware/exp125-fat12-by-hand.uf2 /media/$USER/RP2350/

3. WATCH A FILESYSTEM APPEAR, NOT JUST A DISK.

       sleep 8
       lsblk -f /dev/sda | tail -1

   Expect:

       sda  vfat  FAT12  YI26 EXP125  2635-1225  62K  1%  /media/cyline/YI26 EXP125

   Compare that with exp124's line, which had a size and nothing else. **Now
   there is a type, a label, a serial and a mount point**, and your desktop
   probably opened a window.

4. READ THE FILE OFF IT.

       ls -l "/media/$USER/YI26 EXP125/"
       cat "/media/$USER/YI26 EXP125/README.TXT"

   Expect one file of 324 bytes, and its first lines:

       exp125 - a FAT12 volume written by hand.

       There is no filesystem driver on this board. A boot sector, one FAT with
       12-bit entries, and a 16-entry root directory were laid into 64 KiB of RAM
       at boot, and your operating system agreed to call the result a disk.

   **That text came out of the board's RAM through a filesystem nobody
   implemented.** There is no FAT driver in this firmware. There are bytes,
   placed where the specification says a boot sector, a file allocation table
   and a root directory go, and your kernel did the rest.

5. READ WHY IT IS FAT12 AND NOT FAT16.

       stty -F /dev/ttyACM0 -icrnl
       timeout 5 cat /dev/ttyACM0

   The first two lines:

       [      38 ms] exp125 up. 64 KiB formatted as FAT12 by hand.
       [      38 ms] 125 clusters, which is under 4085 — that number is what makes it FAT12

   The choice is not a flag anywhere in the boot sector. **The cluster count
   is the format.** Under 4085 clusters means every FAT entry is twelve bits;
   at 4085 the same bytes would have to be read as sixteen. Nothing declares
   it and everything depends on it.

IF IT DOES NOT WORK
  * A disk appears with no filesystem — you are running exp124. Check the
    first log line.
  * The volume mounts but the file is empty or garbled — that is a real
    finding and worth reporting; it would mean the directory entry and the
    data clusters disagree.
  * Nothing mounts and your desktop offers to format — say no, and check the
    log for the cluster count line.
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.

## Expected output

The host's side, and the field that was empty in exp124:

```console
$ lsblk -o NAME,VENDOR,MODEL,SIZE,FSTYPE,LABEL,MOUNTPOINT
NAME VENDOR MODEL          SIZE FSTYPE LABEL       MOUNTPOINT
sda  yi26   exp125 fat12    64K vfat   YI26 EXP125 /media/cyline/YI26 EXP125
```

It mounted itself — the desktop's automounter saw a filesystem where exp124
had none. `LABEL` came out of the volume-label **directory entry**, not the
copy in the boot sector, which most software ignores; the layout writes both
and only one of them is believed.

And the file:

```console
$ ls -la "/media/cyline/YI26 EXP125"
-rw-r--r-- 1 cyline cyline 324 8月  2 20:00 README.TXT

$ cat "/media/cyline/YI26 EXP125/README.TXT"
exp125 - a FAT12 volume written by hand.

There is no filesystem driver on this board. A boot sector, one FAT with
12-bit entries, and a 16-entry root directory were laid into 64 KiB of RAM
at boot, and your operating system agreed to call the result a disk.

Everything you can see here is arithmetic over an array.
```

324 bytes, which is exactly the length of the byte string in the firmware.

### It is writable, too

```console
$ echo "hello from the host" > "/media/cyline/YI26 EXP125/HOST.TXT"
$ cat "/media/cyline/YI26 EXP125/HOST.TXT"
hello from the host
```

```text
idle: 96 commands, 91 blocks read, 5 written
```

Five blocks written: the host updated the FAT, the root directory and the data
cluster, and exp124's `WRITE(10)` path — which had served zero blocks until
now — carried them. The changes live in RAM and are gone at the next reset,
which is the honest limit of a volume made of SRAM.

## The timestamp is not the time that was written

The firmware stamps **12:00** into that directory entry. The listing above
shows **20:00**, on a machine at UTC+8.

FAT has no timezone field. It stores wall-clock digits and nothing about which
wall, so whatever reads the volume applies its own idea of an offset. The same
bytes show a different time on a different machine, and neither reading is
wrong. Worth knowing before treating a FAT timestamp as a fact.

## Two entries share three bytes

The part most likely to be wrong, and the reason the layout lives in
[`crates/fat12`](../../crates/fat12/) rather than in this experiment: it is a
crate with no dependencies, so its tests run on the machine you are reading
this on.

```rust
fn set_fat12(fat: &mut [u8], cluster: usize, value: u16) {
    let at = cluster * 3 / 2;
    if cluster % 2 == 0 {
        fat[at] = (value & 0xFF) as u8;
        fat[at + 1] = (fat[at + 1] & 0xF0) | ((value >> 8) & 0x0F) as u8;
    } else {
        fat[at] = (fat[at] & 0x0F) | ((value & 0x0F) << 4) as u8;
        fat[at + 1] = ((value >> 4) & 0xFF) as u8;
    }
}
```

Every even entry shares a byte with the odd one after it, so writing one must
preserve the other's nibble. Get it wrong and the volume still mounts — with a
file allocation table that points somewhere else. **A filesystem that mounts
and is wrong is worse than one that fails**, which is why this is tested
against the three bytes every FAT12 volume in the world begins with:

```rust
set_fat12(&mut fat, 0, 0x0FF8);
set_fat12(&mut fat, 1, 0x0FFF);
assert_eq!(&fat[0..3], &[0xF8, 0xFF, 0xFF]);
```

## Two ways to do it

```sh
./run.sh      # guided: test the arithmetic, flash, mount it, read the file
./check.sh    # verdict: runs the crate tests, then mounts and reads it back
```

## Make it yours

1. Change `SECTORS_PER_FAT` to 2 without changing anything else. The data area
   moves by one sector, the file's cluster now points at the wrong place, and
   the volume mounts with a file full of the wrong bytes. This is the failure
   mode worth seeing once.
2. Set `ROOT_ENTRIES` to 15. It is no longer a whole number of sectors, and
   `ROOT_SECTORS` rounds down to zero — arithmetic that is right about
   division and wrong about disks.
3. Add a second file. It needs its own cluster, its own FAT chain terminator,
   and a second directory entry, and nothing will remind you if you forget one.
4. Make the disk 16 MiB. At some cluster count the host stops calling it FAT12
   and starts calling it FAT16, without anything in the boot sector changing.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `FSTYPE` is empty | The boot sector is not recognised | Check the `55 AA` at offset 510 and the jump bytes at 0 |
| Mounts, but the file is garbage | The data area does not start where the BPB says | Recompute `DATA_START` from the same fields the host uses |
| The label is missing | The label directory entry is absent | The boot-sector copy is not what `lsblk` reads |
| `cargo test` fails on the crate | Run from the crate's own directory | `--manifest-path` picks the crate, not the configuration; this directory's `.cargo/config.toml` cross-compiles |

## Next

**exp126** puts exp116's page on this volume as `INDEX.HTM`. Plug the board
into anything with a browser and its debug interface is already there — which
closes a loop that opened in exp101, where the `RP2350` drive that appears in
BOOTSEL turned out to be a synthesised FAT volume doing exactly this.
