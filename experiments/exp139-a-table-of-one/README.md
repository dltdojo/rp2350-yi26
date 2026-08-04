# exp139-a-table-of-one — a partition, and the image the ROM boots from it

> **Verified on hardware, 2026-08-04.** One partition table at flash offset 0,
> an ordinary image in the partition, and the ROM boots it: the board comes up
> as application firmware and `get_partition_table_info` now reports **one**
> partition where a stock board reports none. It took getting it wrong first —
> a board that went *dark* — to learn the one rule that makes it work: a
> partition image is linked at `0x10000000` like any other, because the ROM
> remaps the partition there. See [Expected output](#expected-output).

[exp138](../exp138-what-the-rom-already-knows/) asked a stock board what it knew
about firmware slots and got the same answer three ways: the machinery is in the
ROM, and there is nothing in it. This experiment puts the smallest something in
it — one partition, no A/B — and gets the ROM to boot a firmware from it.

Needs: any RP2350 board, and the exp102 toolchain. No browser. **A person only
if you change the image's link address** and it goes dark — see
[If it goes dark](#if-it-goes-dark). The version here does not: it boots.

## The thing nobody tells you first

The ROM looks for a block loop at **flash offset 0**. That is either your
firmware's `IMAGE_DEF` or a partition table. **They cannot both be there.** So a
table takes sector 0, and the image goes into a partition after it.

The trap is what "goes into a partition" means. It is **not** "link the image to
run where it physically sits." When the ROM boots a partition it sets up flash
address translation so the partition's physical start maps to `0x10000000`, the
XIP base — the *same* run address whichever partition it picked, which is exactly
what lets one binary boot from either an A or a B slot. So the image is built
**exactly like an ordinary firmware, linked at `0x10000000`**, and only its
*physical placement* changes.

```text
built (VMA)                     placed in flash (LMA)          the ROM, booting partition 0
┌──────────────────────────┐    ┌────────────┬──────────────┐  maps sector 1 → 0x10000000,
│ ordinary image           │    │ table      │ image        │  so the image runs at the
│ linked at 0x10000000     │    │ 0x10000000 │ 0x10001000 … │  address it was linked for.
└──────────────────────────┘    └────────────┴──────────────┘
                                  sector 0     sectors 1..1023
```

## The wrong turn that taught the most

The first version of this experiment did the obvious thing and it was wrong: it
used a `memory.x` to move the image's `FLASH ORIGIN` to `0x10001000`, so the
image would run *in place* at sector 1. Flashed with `yi26 pflash` — a raw
PICOBOOT write, table and image exactly where addressed — the board **went
dark**: no application firmware, and no BOOTSEL either.

That failure is worth keeping, because its shape is the diagnosis. A board that
finds *no* bootable image drops into BOOTSEL. This one did not — which means the
ROM found the image bootable, mapped the partition to `0x10000000`, jumped to it,
and it crashed before USB: every absolute address in an image linked for
`0x10001000` was off by `0x1000` once the ROM ran it at `0x10000000`. Launched,
then crashed, then dark. A crashed image is not a missing image, so the ROM never
fell back — and the recovery cost a physical BOOTSEL press, the one thing this
whole arc was built to avoid, arrived at honestly (see
[If it goes dark](#if-it-goes-dark)).

The fix is to stop moving the image. It is built normally at `0x10000000`; the
table and the placement into sector 1 are a separate, post-link step.

## The eight words, and why they are not typed in the firmware

```text
0xffffded3   start marker
0x0100040a   one partition, four words of item
0xfc078000   unpartitioned: all permissions, the ROM's own default families
0xfc7fe001   partition 0: sectors 1..1023, all permissions
0xfc020000   partition 0: accepts the rp2350-arm-s family
0x000004ff   last item, four words
0x00000000   link to the next block — a one-block loop links to itself
0xab123579   end marker
```

They live in [`crates/partition-table`](../../crates/partition-table/) with a
test that asserts these exact eight, and [`tools/partimg`](../../tools/partimg/)
reads them from there — the firmware no longer carries them at all. **A wrong
word here produces a board that does not boot and cannot say why** — no log, no
USB, just a device that draws power. It is the least debuggable failure in this
repository, so the check runs on a machine: `cargo test` in that crate covers the
item encoding, the sector arithmetic, the permission and family bits, and the
eight words as a unit.

### The words are well-formed, and now confirmed twice over

These eight are byte-for-byte what `embassy-rp`'s own encoder
(`PartitionTableBlock::add_partition_item`) emits for a minimal one-partition
table — no id, no name, no version, no hash. `picotool` adds a version and a
SHA-256; `embassy-rp`'s own test builds a working table without either, so they
are optional. The one field that once had no second source — the item's size
width — now has one: `picotool`'s own generated header `0x02000c0a` decodes only
as the two-byte layout, the same as this table's `0x0100040a`. The encoding was
never in doubt, and the dark board proved it from the other side: the ROM booted
*from the partition*, which it can only do from a table it parsed.

### One of those words was already measured

`0xfc078000` is not a value chosen here. exp138 read it out of
`get_partition_table_info(PT_INFO)` on a board that had never had a table written
to it. With the flag names in hand it decodes exactly: `0xfc000000` all six
permissions, `0x00078000` absolute + data + rp2350-arm-s + rp2350-riscv. So the
first table this repository writes describes its unpartitioned space **the way
the ROM already described it**. The test is `the_word_exp138_read_off_a_stock_board`.

### Sector 0 is deliberately outside the partition

The partition starts at sector 1. A partition that contained sector 0 would be a
partition that can erase the table describing it, by being written to normally.
The crate cannot prevent that — it does not know where the table went — so the
shape is a test case rather than a rule.

## Nothing external was installed to do this

`picotool partition create` is the usual way to make a table, and it has been
optional here for 138 experiments. It still is. Two ordinary pieces do the whole
job:

- The **table** is eight `u32`s from the `partition-table` crate — named
  permissions and families, tests pinning the result.
- The **assembly** is [`tools/partimg`](../../tools/partimg/), a few dozen lines:
  it reads the ordinary image's UF2, keeps every byte, shifts each block up one
  sector, and prepends the table at flash offset 0. It refuses an image not
  linked at `0x10000000`, because that is the exact mistake the dark board made.

So the flow is: build the image (ordinary, `0x10000000`) → `elf2flash` to a UF2 →
`partimg` to the partitioned UF2 → `yi26 pflash`. Raw physical writes, no drive
routing, then `REBOOT2` and the ROM boots the partition.

## If it goes dark

The version here boots. But if you change the image's link address — the one way
to reproduce the dark board — recovery is **not** a drag and **not** a plain
reboot. A crashed partition image leaves the board with no USB at all, so
PICOBOOT cannot reach it either:

1. Unplug, **hold BOOTSEL**, plug back in, release. The board returns as
   `2e8a:000f` and PICOBOOT can reach it again.
2. `yi26 nuke` — erase the first 64 KiB (table and image) over PICOBOOT.
3. `yi26 pflash ../exp138-what-the-rom-already-knows/target/exp138.uf2` — a
   known-good image back. (`pflash` needs no replug after `nuke`; it writes raw.)

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — an ordinary image, linked at `0x10000000`,
  no `#[link_section]` and no `memory.x`. It asks exp138's three questions
  unchanged, because the measurement has to be the same instrument.
- [`../../tools/partimg`](../../tools/partimg/) — the assembly: table at sector
  0, image at sector 1, with the address check and its own tests.
- [`../../crates/partition-table`](../../crates/partition-table/) — the words,
  and the tests that pin them.

## Two ways to do it

```sh
./run.sh      # guided: build, assemble, flash over PICOBOOT, ask the ROM again
./check.sh    # verdict: the static half needs no board; it also checks the
              # assembled UF2 has the table at sector 0 and the image at sector 1
```

## Expected output

Captured **2026-08-04** after `yi26 pflash` of the assembled `target/exp139.uf2`
and a `REBOOT2`. The board came up as application firmware — no dark board, no
button — and answered:

```text
[  37 ms] exp139 up. Running from a partition, with a hand-written table at flash 0.
[3037 ms] get_partition_table_info(PT_INFO) -> 4
[3038 ms]   word[0] = 0x00000001
[3038 ms]   word[1] = 0x00000101
[3038 ms]   word[2] = 0xffffe000
[3038 ms]   word[3] = 0xfc078000
[3038 ms] get_sys_info(CHIP_INFO) -> 4
          ...
[3038 ms] get_b_partition(0) -> -17
[3038 ms]   negative: partition 0 has no B side, or there is no table
```

Read against exp138, which had no table, the one word that matters changed:

```text
             stock exp138      exp139, from a partition
  word[1]    0x00000000        0x00000101
```

`word[1]`'s low byte is the **partition count**: `0` on a stock board, `1` now.
The `0x0100` bit above it is the ROM signalling that a partition table is loaded.
That is the whole result — the ROM boots this image *from* the partition, and
answers that there is one. `get_b_partition(0)` is still `-17`: partition 0 has
no B side, because one partition has no A/B. That negative is not a failure; it
is the **control** for the experiment after this, which gives partition 0 a B and
watches the number turn positive.

### The dark run, kept

Before it booted, the moved-image version went dark on the same `pflash`: the
board disconnected at the reboot and nothing came back — not `0x1209`, not
`0x2e8a:000f`. That is what the [wrong turn](#the-wrong-turn-that-taught-the-most)
looks like from the host, and why the address rule is the first thing this
experiment now teaches.

## Make it yours

1. Point `partimg` at an image built the old way — linked at `0x10001000` — and
   it refuses, naming the address. Then work out why no test on the *table* could
   have caught a mistake in the *image*.
2. Change the partition to start at sector 0 and re-run the crate's `cargo test`.
   It passes — the crate cannot know the table lives in sector 0. Then work out
   what would happen on hardware, and why no test can catch it for you.
3. Read `word[2]`/`word[3]` of the PT_INFO answer. They are the unpartitioned
   space, and they did **not** change from the stock board even though a
   partition now exists. Working out what PT_INFO summarises, versus what a
   per-partition query would report, is the thread into the next experiment.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `partimg` refuses with "must be linked at the XIP base" | The image was built at its physical offset (e.g. an old `memory.x` moving `FLASH ORIGIN`) | Build it as an ordinary image at `0x10000000`; the ROM does the remap |
| The board goes dark after flashing — no `0x1209`, no `0x2e8a:000f` | A partition image linked at the wrong address: the ROM launched it and it crashed before USB, and does **not** fall back to BOOTSEL | [If it goes dark](#if-it-goes-dark): a physical BOOTSEL press, then `yi26 nuke` + `yi26 pflash exp138.uf2` |
| `cargo test` fails in `partition-table` | A word was changed | That is the test doing its job — decide which is right before flashing |
| The ROM reports zero partitions after flashing | The table did not land at flash offset 0, or the board was not rebooted after it | Confirm `partimg` put the table block at `0x10000000`; `pflash` reboots for you |

## Next

Under [Planned](../README.md#planned): two images, one version number, and the
ROM choosing between them — where `get_b_partition(0)` stops being `-17`.
