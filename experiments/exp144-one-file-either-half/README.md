# exp144-one-file-either-half — the ROM knows which half, and will not take the file

> **Verified on hardware, 2026-08-05, and it is half a yes.** Asked from a
> running firmware, the ROM answers the routing question exactly right: with
> partition 1 booted, `get_uf2_target_partition(rp2350-arm-s)` names partition 0
> — the other half — and `pick_ab_parition(0)` names the running one. Then the
> file is actually dropped on the BOOTSEL drive, and **nothing happens**: a
> board with a partition table does not consume a UF2 written to its drive. Not
> a bad table, not a bad address, not a bad host — erase the table and the
> identical file, same command, same cable, flashes. See
> [Expected output](#expected-output).

The question this road came from: a user drops **one** file and the correct half
of an A/B pair is written, with no `for_slotA` in the filename. The ROM has a
call that looks exactly like the answer — [exp138](../exp138-what-the-rom-already-knows/)
listed it — and [exp142](../exp142-two-images-one-version/) and
[exp143](../exp143-the-image-that-is-never-bought/) built the pair it would
write into. So this asks the call, and then does the drop.

Needs: any RP2350 board, and the exp102 toolchain. No browser. The drop half
uses the BOOTSEL drive, so it needs `udisksctl` — which is what every `yi26
flash` in this repository already uses.

## The two calls

Neither needs a drive, a host tool, or anything to have been dropped:

```rust
// Where would a dropped rp2350-arm-s .uf2 be written?
let mut target = [0u32; 2];                       // resident_partition_t
rom_data::get_uf2_target_partition(workarea, 4096, 0xe48b_ff59, target.as_mut_ptr());

// Which half of the pair holds the better image — the one that is running?
rom_data::pick_ab_parition(workarea, 4096, 0);
```

`get_uf2_target_partition`'s out parameter is **two words**, not a partition
index: a `resident_partition_t` of location and flags. Reading it as one `u32`
— which is what this experiment did first — returns `4227989505`, which looks
like nonsense and is in fact `0xfc020001`: first sector 1, last sector 16, all
six permissions. The ROM answers with *where in flash*, and the partition number
has to be recovered by matching that word against the table's own.

## Asking the table for a partition by number

Getting that match needed two flag values that are not in `embassy-rp`, and
guessing them wrong is quiet rather than loud — `0x0002` is *accepted* and
answers nothing. They were measured by asking a board with a known table:

| flags | returned | what it is |
| --- | --- | --- |
| `0x0001` | `0x00000001 0x00000102 0xffffe000 0xfc078000` | `PT_INFO`: 2 partitions, then the **unpartitioned** space's location and flags |
| `0x0002` | one word, `0x00000000` | accepted, answers nothing — not the flag |
| `0x0010` | `0x00000010 0xfc020001 0xfc020000 0xfc040011` | `PARTITION_LOCATION_AND_FLAGS`: a pair per partition |
| `0x8010` | `0x00008010 0xfc020001 0xfc020000` | `SINGLE_PARTITION`, partition 0 |
| `0x8010 \| (1<<24)` | `0x00008010 0xfc040011 0xfc020002` | partition 1 — and its flags end in `2`, the A/B link |

So the partition number goes in bits 24 and up, and partition 1's flags word
carries the `0x2` that [`crates/partition-table`](../../crates/partition-table/)
writes as `link::to_a(0)`. The table this repository builds and the table the
ROM reads back agree, word for word.

## What the drop actually does

Four attempts, one host, one cable, one command (`yi26 flash`, which is a
1200-baud touch, a mount, and a copy — drag-and-drop with a script instead of a
mouse):

| board state | file dropped | result |
| --- | --- | --- |
| A/B pair, table present | `v3.uf2`, addressed `0x10000000` | **refused** |
| A/B pair, table present | the same image shifted to `0x10001000`, partition 0's own start | **refused** |
| one partition (exp139's table) | `v2.uf2`, addressed `0x10000000` | **refused** |
| **no table at all** | `v3.uf2`, addressed `0x10000000` | **flashed**, board came back as v3.0 |

"Refused" has a specific shape, and it is the one exp137 taught this repository
to recognise: the copy succeeds, the file appears in the directory listing, and
after `udisksctl unmount` + `mount` it is **gone**. The host's FAT cache was
showing a write the board never took. The board stays in BOOTSEL; a UF2 the ROM
accepts is consumed and the board reboots.

So the answer to the road's question, on this board, is:

- **The ROM knows the right half.** It will tell any firmware that asks, and the
  answer is correct — the half that is not running.
- **The drive will not take the file.** Not when there is a partition table,
  which is exactly when the routing would have mattered. Whatever a partition
  table does to the bootrom's UF2 download path, it stops it.

That also revises something this repository wrote down earlier: exp139 recorded
that "a bad partition table makes the bootrom reject the drive's writes
outright". The table here is good — it boots, the ROM enumerates it, A/B
selection works off it. It is refused anyway. The word "bad" was the wrong half
of that sentence.

**And it is why the flashing road exists.** `yi26 pflash` writes the same bytes
over PICOBOOT and never touches the drive, which is why every partitioned board
in exp139, exp142 and exp143 was flashed that way without anyone noticing that
the drive had stopped working.

## What was not tested

One configuration is out of reach without a hand on the board: **a BOOTSEL
entered by unplugging, holding the button, and plugging back in, with a
partition table present.** Every refusal above was in a BOOTSEL entered by the
1200-baud touch — which is also how the successful no-table control got there,
so the variable is matched between them. But this repository has already
recorded that entry path can matter (`yi26 nuke` says so in its own output: a
PICOBOOT reboot leaves a BOOTSEL that does not consume a UF2), so a
button-entered BOOTSEL is a real gap, not a formality. It is not claimed either
way here.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the two ROM calls, the partition-by-number
  query, and no slot letter anywhere.
- [`build.rs`](./build.rs) — the version, twice: as consts for the `IMAGE_DEF`
  and as a `rustc-env` string so the USB product descriptor carries it.
- [`../../tools/partimg`](../../tools/partimg/) — `ab` mode, unchanged.

## Two ways to do it

```sh
./run.sh      # guided: flash a pair, ask the ROM, drop a file, then erase the
              # table and drop the same file again — the control
./check.sh    # verdict: asks the ROM's two answers and checks they disagree
              # about which half. Drops nothing; the drop is destructive
```

## Expected output

Captured **2026-08-05**. The board is running the A/B pair, v1.0 in partition 0
and v2.0 in partition 1, so the ROM boots partition 1:

```text
exp144 up. version 2.0.
I am version 2.0. I do not know which half I am in.
get_partition_table_info(PT_INFO) -> 4 words, 2 partitions
  partition 0: sectors 1..16, flags 0xfc020000
  partition 1: sectors 17..32, flags 0xfc020002
get_uf2_target_partition(rp2350-arm-s) -> rc 0
  location 0xfc020001 = partition 0, sectors 1..16
pick_ab_parition(0) -> 1 (the half holding the better image)
  running 1, next drop goes to 0 — the other half
idle: v2.0, running partition 1, next drop -> partition 0
```

Then `yi26 flash target/v3.uf2` — an ordinary v3.0 image, no placement, no slot
in the name:

```text
yi26: the board did not come back as a serial port after flashing
      try: some firmwares have no USB at all (exp103) — check the LED instead
```

`yi26 state` says `bootsel`, and the drive still lists the file until it is
remounted:

```text
-rw-r--r--  1 cyline cyline 46592  8月   5 08:23 v3.uf2
=== after remount ===
INDEX.HTM
INFO_UF2.TXT
```

The control, which is what makes that a finding: erase the table, put a plain
image on over PICOBOOT so something runs, and drop the *identical* file with the
*identical* command:

```text
erased 65536 bytes of flash from offset 0 over PICOBOOT. The partition table is gone.
flashed 23296 bytes to 0x10000000 over PICOBOOT (6 sectors erased), and rebooted into it.
{"product":"exp144 v1.0", ...}
flashed target/v3.uf2 (46592 bytes), running at /dev/ttyACM0
{"product":"exp144 v3.0", ...}
```

Same everything, minus a partition table, and it flashes.

## Make it yours

1. Give partition 0 a family the file does not have (`family::RP2350_RISCV`
   instead of `RP2350_ARM_S` in `partimg`) and ask again. The routing answer
   should move to the other partition, or go negative — the table is the whole
   input to that call.
2. Swap the versions so partition 0 is the one running, and check that the
   routing answer follows: it should name partition 1 without anything else
   changing.
3. Drop a file with the **wrong family ID** onto a table-less board and watch
   `yi26 flash` refuse it before the copy — the ROM would ignore it silently,
   which looks exactly like a board that did not come back.
4. Work out what a host tool would do with the answer this experiment gets. It
   is the same thing `picotool load --partition` does: read the target's start
   sector, rewrite the UF2's addresses, and write it there. The ROM's call is
   for *tools*, not for the drive.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| A dropped `.uf2` does nothing and the board stays in BOOTSEL | There is a partition table on the board | Use `yi26 pflash` — that is the whole point of exp141's road |
| `yi26 flash` refuses with "the lowest flash address is 0x10001000" | The image is addressed inside a partition, so nothing sits at flash offset 0 | Correct for a board with no table; on a partitioned board, `--force` — and then it is refused by the ROM anyway |
| The file is still on the drive after copying | The host's FAT cache, not the board | `udisksctl unmount` and mount again; if it vanishes, the board never took it |
| `get_uf2_target_partition` returns a huge number | It was read as one word | It is a `resident_partition_t`: two words, location then flags |
| `pick_ab_parition` returns a negative number | No A/B pair, or no table | Check `get_b_partition(0)` first — exp142 covers the link |

## Next

The road's last item is the hand-rolled bootloader as the measured control — a
custom USB volume that accepts a file and writes it. This experiment sharpened
what that control is *for*: not "can the ROM do A/B" (it can), but that the
ROM's own drive stops accepting files exactly when a table exists, so anything
that wants a drop-a-file update on a partitioned board has to serve the volume
itself. [exp137](../exp137-the-volume-that-changes/) established what a
device-served volume can make a host re-read, and that is the constraint it
inherits.
