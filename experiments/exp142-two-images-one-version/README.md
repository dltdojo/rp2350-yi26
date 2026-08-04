# exp142-two-images-one-version — the ROM picks the newer firmware

> **Verified on hardware, 2026-08-04.** Two firmwares in an A/B partition pair,
> one version `1.0` and one `2.0`. The board booted the `2.0` slot. Then the
> versions were swapped — the old `1.0` slot rebuilt as `3.0` — and without any
> other change the board booted *that* slot instead. The choice the standard
> advice says you must hand-roll a bootloader for is in the ROM. See
> [Expected output](#expected-output).

[exp138](../exp138-what-the-rom-already-knows/) asked a stock board what it knew
about A/B firmware slots and found the machinery in the ROM and nothing in it.
[exp139](../exp139-a-table-of-one/) put one partition in and booted a firmware
from it. This puts **two**, with different versions, and lets the ROM choose —
which is the whole point of the machinery exp138 found empty.

Needs: any RP2350 board, and the exp102 toolchain. No browser. A person only if
you break the image link address (exp139's dark board) — the versioned images
here boot.

## How the ROM chooses

Two partitions become an A/B pair when the B partition's table entry **links** to
A. The ROM then treats them as one slot with two halves, and picks between them
by **version**: each image carries a `VERSION` item in its own `IMAGE_DEF`, and
the ROM boots the partition whose image's version is higher. `get_b_partition(0)`,
which returned `-17` in exp139 (one partition, no B), now returns `1` — the ROM
reporting the pair.

The same binary boots from either slot, because — exp139's lesson — the ROM
remaps whichever partition it picks to the XIP base `0x10000000`. So the two
images are identical in structure; only a slot letter and a version differ.

## One source, two images

The A image and the B image are the same source, built twice. `EXP142_SLOT` and
`EXP142_MAJOR`/`EXP142_MINOR` are build inputs — [`build.rs`](./build.rs) turns
them into consts, so the version is a real number the `IMAGE_DEF` is built from,
not an afterthought:

```sh
EXP142_SLOT=A EXP142_MAJOR=1 cargo build --release   # image A, v1.0
EXP142_SLOT=B EXP142_MAJOR=2 cargo build --release   # image B, v2.0
```

## The versioned IMAGE_DEF

The version has to be *in the image*, in the block the ROM validates. `embassy-rp`
injects a default `IMAGE_DEF` with only an image type; its `imagedef-none` feature
turns that off so this firmware can supply its own, with a `VERSION` item added:

```rust
#[link_section = ".start_block"]
#[used]
static IMAGE_DEF: Block<3> = Block::new([
    item_image_type_exe(Security::Secure, Architecture::Arm),
    item_generic_2bs(0, 2, ITEM_1BS_VERSION),
    ((VERSION_MAJOR as u32) << 16) | VERSION_MINOR as u32,
]);
```

Checked in the built ELF rather than assumed — the seven words of image B's block:

```text
ffffded3   start marker
10210142   image type: a Secure Arm executable
00000248   VERSION item header (id 0x48, two words)
00020000   version 2.0   ← image A's differs here, and only here: 00010000
000003ff   last item, three words
00000000   self-loop link
ab123579   end marker
```

`Block`, `item_image_type_exe`, `item_generic_2bs` and `ITEM_1BS_VERSION` are all
`embassy-rp`'s own — the version word uses the same `(major << 16) | minor`
encoding as its partition-table `with_version`.

## The A/B table

Two partitions, the second linked to the first. The ten words live, with their
tests, in [`crates/partition-table`](../../crates/partition-table/) — the new
piece over exp139 is the **link** (`link::to_a(0)` in B's flags, `0x2`, checked
against `embassy-rp`'s encoding):

```text
0200060a   partition table item: two partitions
fc078000   unpartitioned: the ROM's default families
fc020001   A: sectors 1..16
fc020000   A: arm-s, no link
fc040011   B: sectors 17..32
fc020002   B: arm-s, linked to A(0)   ← the 0x2 is the whole A/B relationship
```

The slots are small (16 sectors each) and adjacent on purpose: real A/B slots are
half the flash, but the image B placement sector is also where `pflash` starts
writing, and a slot at sector 512 makes the assembled image span 2 MiB of mostly
`0xFF`, which a single `FLASH_ERASE` will not take. A/B selection does not depend
on slot size.

## Assembling and flashing

[`tools/partimg`](../../tools/partimg/) has an `ab` mode: it places the table at
flash offset 0, image A at sector 1, image B at sector 17 — both unchanged, both
linked at `0x10000000`.

```sh
partimg ab imageA.uf2 imageB.uf2 exp142.uf2
yi26 pflash exp142.uf2
```

`yi26 pflash`'s pre-flight passes (the table's block marker is at offset 0), it
writes the absolute addresses raw, and `REBOOT2` boots the pair — the higher
version.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the versioned `IMAGE_DEF`, and the same three
  questions exp139 asked, now expecting a B side.
- [`build.rs`](./build.rs) — slot and version as build inputs, so one source
  makes both images.
- [`../../crates/partition-table`](../../crates/partition-table/) — the A/B
  table and the link, tested.
- [`../../tools/partimg`](../../tools/partimg/) — `ab` mode, placing both images.

## Two ways to do it

```sh
./run.sh      # guided: build A and B, assemble, flash, watch B win — then swap
              # the versions and watch A win
./check.sh    # verdict: the static half needs no board; the board half, if a
              # board is running exp142, confirms the ROM sees the A/B pair
```

## Expected output

Captured **2026-08-04**, over two flashes.

**A = v1.0, B = v2.0 — the board boots B.** `lsusb` alone shows it, before the
log: `iProduct  exp142 slot B`. Then:

```text
exp142 up. slot B, version 2.0, running from a partition.
I am slot B, version 2.0.
  my IMAGE_DEF VERSION word = 0x00020000
  word[1] = 0x00000102          ← two partitions (low byte 2), a table is loaded
get_b_partition(0) -> 1
  partition 1 is the B side of partition 0 — this is an A/B pair
```

`get_b_partition(0)` is `1`, not exp139's `-17`: the ROM sees the A/B link. And
the slot that is *running* is the one with the higher version.

**The flip: rebuild A as v3.0 (above B's v2.0), reflash — the board boots A.**
`iProduct  exp142 slot A`, and:

```text
I am slot A, version 3.0.
  my IMAGE_DEF VERSION word = 0x00030000
get_b_partition(0) -> 1
```

Nothing changed but A's version number, and the ROM booted the other slot. That
is the experiment: the A/B choice is the ROM's, made by version, live.

## Make it yours

1. Give A and B the **same** version and reflash. The ROM has a tie to break —
   work out which slot it prefers, and why an A/B scheme gives the incumbent the
   tie (a downgrade should not happen by accident).
2. Put image B at sector 512 instead of 17 (edit `partimg`'s `B_FIRST`) and
   `pflash` it. The `FLASH_ERASE` is refused — the 2 MiB span is the cost of a
   sparse image through a tool that writes one contiguous region.
3. Read `word[1]` of `get_partition_table_info`: its low byte is the partition
   count, `2` here. exp139 was `1`, a stock board `0`. The count is the ROM
   confirming what the table said.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Both slots report the wrong one is running | The versions do not differ, or B's link is missing | Check the `VERSION` words differ and B's flags carry `0x2` (`crates/partition-table` tests) |
| `get_b_partition(0)` is negative | The B partition does not link to A | The link is B's `link::to_a(0)`; without it they are two unrelated partitions |
| The board goes dark after flashing | An image linked at the wrong address (exp139's bug) | `partimg` refuses a non-`0x10000000` image; if you forced it, BOOTSEL press + `yi26 nuke` |
| `pflash` refuses with `FLASH_ERASE: no acknowledgement` | The slots are too far apart — a huge sparse span to erase | Keep B's start sector low (adjacent to A), as `partimg` does |

## Next

Under [Planned](../README.md#planned): the image that is never bought —
try-before-you-buy, where an image boots, runs, and is put back at the next reset
unless it calls `explicit_buy`. The A/B pair here is the ground it stands on.
