# exp139-a-table-of-one — the table takes flash offset 0, so the firmware moves

> **Not yet verified on hardware.** Everything below the *Expected output*
> heading is missing on purpose: this experiment has been built and checked
> statically, and flashing it is the first thing on this road that can leave a
> board needing a hand on the BOOTSEL button. See
> [Before you flash this](#before-you-flash-this).

[exp138](../exp138-what-the-rom-already-knows/) asked a stock board what it
knew about firmware slots and got the same answer three ways: the machinery is
in the ROM, and there is nothing in it. This experiment puts something in it —
the smallest thing that can be there, one partition and no A/B.

Needs: any RP2350 board, and the exp102 toolchain. No browser. **A person only
if it goes wrong**, and the recovery is one BOOTSEL press.

## The thing nobody tells you first

The ROM looks for a block loop at **flash offset 0**. That is either your
firmware's `IMAGE_DEF` or a partition table. **They cannot both be there.**

So writing a partition table is never "adding a table". It is *moving your
firmware*, and a design that misses this produces a board that does not boot,
with nothing to read about why.

```text
before                          after
┌──────────────────────────┐    ┌────────────┬─────────────────────┐
│ image (IMAGE_DEF at 0)   │    │ table      │ image               │
│ 0x10000000 …             │    │ 0x10000000 │ 0x10001000 …        │
└──────────────────────────┘    └────────────┴─────────────────────┘
                                  sector 0     partition 0, sectors 1..1023
```

## Nothing new was installed to do this

The first question this experiment was created to answer was a tooling one:
**can a partition table be made with what this repository already has?** The
usual answer is `picotool partition create`, and `picotool` has been optional
here for 138 experiments.

It can. Two pieces, both of them ordinary:

**A `memory.x` of our own**, which overrides the one `rp2350-linker` injects
from its `build.rs`. It reserves 4 KiB at the start of flash for the table and
starts `FLASH` after it — otherwise it is that crate's script unchanged,
including the section ordering, which matters more than it looks: the first
attempt reordered it and the link failed with `.start_block` and `.text` at the
same address.

**A `[u32; 8]` in a `#[link_section]`**, because a table is eight words and a
linker section can hold words. `embassy-rp` has a `PartitionTableBlock` builder
and it cannot be used here — its contents are private with no accessor, which
is right for what it is for: firmware writing a table *while it runs*. A table
that has to exist before any firmware runs is a different problem.

The result, checked in the ELF rather than assumed:

```text
[1] .vector_table     PROGBITS  10001000 000114
[2] .partition_table  PROGBITS  10000000 000020
[3] .start_block      PROGBITS  10001114 000028
```

and the UF2 that comes out of `elf2flash` targets `0x10000000` first and runs
to `0x10006900`, so one drag writes both halves.

## The eight words, and why they are not typed here

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

They were typed, once, and then moved into
[`crates/partition-table`](../../crates/partition-table/) with a test that
asserts these exact eight. That is not tidiness. **A wrong word here produces a
board that does not boot and cannot say why** — no log, no USB, no error, just
a device that draws power. It is the least debuggable failure in this
repository, so it is the one place where the check has to run on a machine
rather than on hardware.

`cargo test` in that crate now covers the item encoding, the sector arithmetic,
the permission and family bits, and the eight words as a unit.

### Twelve of the values have a second source, and one does not

The words were mirrored from `embassy-rp`'s encoder and then checked against
the Pico SDK's own `picobin.h`. Both markers, all six permission bits and all
six family bits agree exactly.

**One field does not have a second source, and it is the one that decides
whether the board boots.** The SDK defines
`PICOBIN_BLOCK_ITEM_PARTITION_TABLE` as `0x0a` with no width in its name, while
its neighbours carry theirs (`ITEM_1BS_IMAGE_TYPE`, `ITEM_2BS_LAST`).
`embassy-rp` groups `0x0a` under *"these all have a 2-byte size"*, and this
experiment follows it:

```text
0x0100040a   two-byte size — what is flashed
0x0001040a   one-byte size — the alternative, if the first does not boot
```

Two bytes is the likelier reading for a structural reason rather than an
authority: a table can hold sixteen partitions of several words each, and a
one-byte length caps an item at 255 words. Both numbers are pinned by tests in
the crate, so switching is one edit rather than an afternoon with a datasheet.

### One of those words was already measured

`0xfc078000` is not a value chosen here. exp138 read it out of
`get_partition_table_info(PT_INFO)` on a board that had never had a table
written to it, and could only print it. With the flag names in hand it decodes
exactly:

```text
0xfc000000   all six permissions
0x00078000   absolute, data, rp2350-arm-s, rp2350-riscv
```

So the first table this repository writes describes its unpartitioned space
**the way the ROM already described it**, rather than guessing. The test that
says so is `the_word_exp138_read_off_a_stock_board`.

### Sector 0 is deliberately outside the partition

The partition starts at sector 1. A partition that contained sector 0 would be
a partition that can erase the table describing it, by being written to
normally. The crate cannot prevent that — it does not know where the table
went — so the shape is a test case rather than a rule.

## Before you flash this

The board currently runs a firmware whose image starts at flash offset 0. After
this one, offset 0 is a table and the image is at 0x10001000. If the ROM
accepts the table and boots the image, USB comes back and everything continues
as normal. **If it does not, the board does not enumerate**, and no software
route reaches it — `yi26 flash` needs a running firmware to send the 1200-baud
touch to.

The recovery is one press, and nothing has to be reinstalled:

1. Unplug the USB cable.
2. **Hold BOOTSEL**, plug the cable back in, release.
3. The `RP2350` drive appears.
4. Drag any known-good `.uf2` onto it — for example
   `../exp138-what-the-rom-already-knows/target/exp138.uf2`.

That is the whole cost of being wrong, and it is why this experiment exists
before anything that writes to flash from inside a running firmware.

## The code IS the walkthrough

- [`memory.x`](./memory.x) — the two changes to `rp2350-linker`'s script, with
  the reason written where the change is.
- [`src/main.rs`](./src/main.rs) — the `#[link_section]`, and exp138's three
  questions unchanged, because the measurement has to be the same instrument.
- [`../../crates/partition-table`](../../crates/partition-table/) — the words,
  and the tests that pin them.

## Two ways to do it

```sh
./run.sh      # guided: build, read the risk, flash, ask the ROM again
./check.sh    # verdict: the static half needs no board at all
```

## Expected output

**Pending.** This section stays empty until a board has run it, because a
predicted capture is the one thing this repository will not publish. See
[Nothing is pushed unverified](../README.md#nothing-is-pushed-unverified).

If it does not boot, that is also a result and it goes here in words: which
word was changed, and what the board did with each version. The one field
without a second source is named above, so that is where to start.

What it should contain when it is taken: exp138's three questions, answered
differently — a non-zero partition count, one partition covering sectors
1..1023, and `get_b_partition(0)` still negative, because one partition has no
B side. That last one is the point of stopping at one: it is the control for
the experiment after this.

## Make it yours

1. Change the partition to start at sector 0 and re-run `cargo test`. It
   passes — the crate cannot know the table is in sector 0. Then work out what
   would happen on hardware, and why no test can catch it for you.
2. Set the family to `RP2040` instead. The build succeeds, the table is
   well-formed, and a dragged `.uf2` lands nowhere.
3. Take the `.partition_table` section out of `memory.x` and rebuild. The image
   moves back to offset 0 and the table goes with it — the two really are
   competing for one address.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `.start_block` and `.text` overlap at link time | `memory.x` reordered the sections | Keep `rp2350-linker`'s ordering; only ORIGIN changes |
| The board does not enumerate after flashing | The ROM did not accept the table, or would not boot from sector 1 | The BOOTSEL sequence above, then try `ONE_BYTE_SIZE_ALTERNATIVE` — see below |
| …and you want to know which word to change first | The partition-table item's size field is the one value with no second source | `crates/partition-table`, `SIZE_FIELD_IS_UNCONFIRMED`. Change `item(1, 4, …)` to the one-byte layout and rebuild |
| `cargo test` fails in `partition-table` | A word was changed | That is the test doing its job — decide which is right before flashing |

## Next

Under [Planned](../README.md#planned): two images, one version number, and the
ROM choosing between them.
