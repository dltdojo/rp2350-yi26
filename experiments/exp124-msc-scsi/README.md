# exp124-msc-scsi — enough answers that the host agrees a disk is there

exp123 declared a mass-storage interface and refused everything, and the
kernel built a SCSI host with nothing in it. This one answers.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## Wrong answers are worse than refusals

exp123's risk was a host left waiting. This one's is the opposite: **a host
that believes you.**

Claim a size in `READ CAPACITY` and then fail to produce those blocks on
`READ(10)`, and the kernel retries, resets, and retries — while the device
enumerates fine, logs fine, and looks perfectly healthy. That is far harder to
diagnose than a device that plainly says no.

So nothing here is pretended. There is a real disk: 128 blocks of RAM, read
and written for real, out of the RP2350's SRAM. It forgets everything on
reset, and within one power cycle it behaves exactly as it claims to.

## The order of the questions is the answer

From the firmware's own log, in the second after the board enumerated:

```text
[      38 ms] exp124 up. 64 KiB of RAM, answering as a disk.
[    1448 ms] INQUIRY  -> 36 bytes: yi26 / exp124 ram disk
[    1450 ms] TEST UNIT READY  -> ok
[    1450 ms] READ CAPACITY  -> last LBA 127, 512 bytes each = 64 KiB
[    1451 ms] READ(10) lba 0 +1 blocks
[    1452 ms] MODE SENSE(6)  -> writable, no pages
[    1453 ms] TEST UNIT READY  -> ok
[    1454 ms] READ CAPACITY  -> last LBA 127, 512 bytes each = 64 KiB
[    1455 ms] PREVENT ALLOW MEDIUM REMOVAL  -> ok
[    1461 ms] READ(10) lba 0 +8 blocks
[    1466 ms] READ(10) lba 8 +8 blocks
[    1471 ms] READ(10) lba 24 +8 blocks
[   30038 ms] idle: 71 commands, 90 blocks read, 0 written
```

*What are you. Is there media. How big. Now show me sector zero.* Each
question is asked because the previous one was answered, which is exactly why
exp123 never got past the first one.

Ninety of the hundred and twenty-eight blocks were read. Sector zero is only
the beginning of what a host looks at before deciding what a disk contains.

## The host's side of the same event

```text
scsi 2:0:0:0: Direct-Access     yi26     exp124 ram disk  0001 PQ: 0 ANSI: 2
sd 2:0:0:0: [sda] 128 512-byte logical blocks: (65.5 kB/64.0 KiB)
sd 2:0:0:0: [sda] Write Protect is off
sd 2:0:0:0: [sda] Mode Sense: 03 00 00 00
sd 2:0:0:0: [sda] Attached SCSI removable disk
```

```console
$ lsblk -o NAME,VENDOR,MODEL,SIZE,RM,FSTYPE /dev/sda
NAME VENDOR MODEL            SIZE RM FSTYPE
sda  yi26   exp124 ram disk   64K  1
```

Every field there came out of this firmware. `VENDOR` and `MODEL` are the
INQUIRY strings; `RM` is bit 7 of the same response; `SIZE` is `READ CAPACITY`
having been believed. `Mode Sense: 03 00 00 00` is the four bytes of
`mode_sense6()` read back verbatim.

## What success looks like, and it is not what was predicted

This experiment was planned with the line *the host complaining that it cannot
read a partition table is what success looks like*. **It does not complain.**

Sector zero is 512 zero bytes. The kernel reads it, finds no partition table,
and says **nothing at all** — no warning, no error, no `sda: sda1` line. The
disk attaches, `FSTYPE` is empty, and that is the whole of it.

The prediction was wrong in a way worth keeping: an unformatted volume
produces *silence*, and knowing what absence looks like is part of reading a
system. The kernel messages that do mention partitions and FAT during a
flashing session belong to the **RP2350 bootloader's** drive, which is
formatted and disappears when the board reboots. Reading those as this
experiment's output would be reading somebody else's disk.

## Two byte orders in one packet

Worth knowing before reading the code, because it is a classic way to lose an
afternoon:

```text
CBW    53 55 42 43 | 01 00 00 00 | ...     'USBC', tag 1   — little-endian
        25 00 00 00 00 00 00 00 00 00      READ CAPACITY   — SCSI
reply  00 00 00 7f | 00 00 02 00           last LBA 127, 512 bytes — big-endian
```

The Bulk-Only Transport wrapper is little-endian: tag, transfer length,
residue. The SCSI command inside it, and every SCSI reply, is big-endian. One
packet, two conventions, and the compiler will not mention it.

The other trap in the same reply: `READ CAPACITY` reports the address of the
**last** block, not how many there are. `DISK_BLOCKS - 1`. Getting that wrong
gives you a disk one block too large, and the host finds out by reading off
the end.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — ten opcodes, a sense state so `REQUEST
  SENSE` can answer *why*, and a `[u8; 65536]` that is the disk. About 150
  lines of SCSI.

## Two ways to do it

```sh
./run.sh      # guided: the negotiation from both sides, and what silence means
./check.sh    # verdict: size, removability, no filesystem, real blocks served
```

## Make it yours

1. Change `DISK_BLOCKS - 1` to `DISK_BLOCKS` in `read_capacity`. The disk is
   now one block bigger than it is, and the host will eventually read the
   block that is not there. The out-of-range check catches it and says so in
   sense data — which is what that check is for.
2. Set the write-protect bit in `mode_sense6` (byte 2, `0x80`) and watch
   `lsblk` say `RO 1`.
3. Fill the disk with `0xAA` instead of zeros at boot, then look at what the
   kernel makes of a sector zero that is not a partition table but is also not
   empty.
4. Raise `DISK_BLOCKS` until the build stops fitting in SRAM, and notice that
   the failure is a link error rather than anything USB has an opinion about.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No block device appears | INQUIRY or READ CAPACITY was refused | The log names every command and its answer |
| The device appears and vanishes | The host is resetting after a bad reply | Check residue and status in the CSW |
| `[sdX] Attached` but the wrong size | The off-by-one in READ CAPACITY | It reports the last LBA, not the count |
| `/dev/ttyACM0` disappears | A reset loop is taking the whole device down | Compare exp123's note on refusing well |

## Next

**exp125** writes a FAT12 boot sector, a file allocation table and a root
directory into these blocks by hand. The volume mounts, with one file on it,
and the silence above turns into a `FSTYPE` of `vfat`.
