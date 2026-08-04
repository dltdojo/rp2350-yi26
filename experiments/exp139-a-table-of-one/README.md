# exp139-a-table-of-one — the table takes flash offset 0, so the firmware moves

> **Flashed on hardware, 2026-08-04 — and the image did not boot.** The eight
> words are well-formed: they are byte-for-byte what `embassy-rp`'s own encoder
> produces for a minimal one-partition table (see
> [The words are not the fault](#the-words-are-not-the-fault)). They were
> written to flash offset 0, the board did not come back as application
> firmware, and its BOOTSEL drive then **refused every dragged `.uf2`** — which
> is how we know the ROM *honoured* the table rather than ignoring it. The
> recovery is **not** a drag-and-drop and **not** a plain BOOTSEL press; it is
> PICOBOOT (`yi26 nuke`, or exp141's `recover.html`). What is still open is
> *why* the image did not boot — and there is a real confound in that first
> run, named in [Before you flash this](#before-you-flash-this). See
> [Expected output](#expected-output) for exactly what was observed.

[exp138](../exp138-what-the-rom-already-knows/) asked a stock board what it
knew about firmware slots and got the same answer three ways: the machinery is
in the ROM, and there is nothing in it. This experiment puts something in it —
the smallest thing that can be there, one partition and no A/B.

Needs: any RP2350 board, and the exp102 toolchain. No browser. **No person even
if it goes wrong**: a board that finds no bootable image drops into BOOTSEL by
itself, and `yi26 nuke` recovers it over PICOBOOT — no hand on the button.

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

## The words are not the fault

When the image did not boot, the first suspicion was the one word this crate
could not confirm from a second source — the size field, `SIZE_FIELD_IS_UNCONFIRMED`.
It is the wrong suspicion, and the check is on this machine, not on a board.

`embassy-rp` ships its own partition-table encoder (`embassy_rp::block`,
`PartitionTableBlock::add_partition_item`). Expand it for one partition with no
id, no name and no extra families — the minimal case — and it emits, in order:
the start marker; an item header of `item_generic_2bs(count=1, len=4,
ITEM_2BS_PARTITION_TABLE)`; the unpartitioned flags; the partition's location
and flags words; `item_last(4)`; a self-link of `0`; the end marker. Eight
words. They are the eight this experiment flashes, value for value:

```text
0xffffded3  0x0100040a  0xfc078000  0xfc7fe001
0xfc020000  0x000004ff  0x00000000  0xab123579
```

So the table is not malformed and it is not missing a required item. `picotool`
adds a version and a SHA-256 to the tables it generates, but `embassy-rp`'s own
test builds a working table without either — they are optional. **Whatever kept
the image from booting, it was not the encoding of the table.** That narrows the
open question to the image-in-partition setup and the flash path, which is where
[Expected output](#expected-output) and [Before you flash this](#before-you-flash-this)
now point.

## Before you flash this

The board currently runs a firmware whose image starts at flash offset 0. After
this one, offset 0 is a table and the image is at 0x10001000. If the ROM
accepts the table and boots the image, USB comes back and everything continues
as normal. **If it does not, the board does not enumerate as application
firmware** — but it does not draw power in silence either. A board that finds
no bootable image drops into BOOTSEL on its own, so it comes back as `2e8a:000f`
with the bootrom's two doors, and PICOBOOT reaches it.

**Flash it with `yi26 pflash`, not `yi26 flash`.** This matters for reading the
result, not only for reliability. `yi26 flash` (and any drag-and-drop) hands the
UF2 to the bootrom's *drive*, which routes each block by UF2 family into
whichever partition accepts it — so a `rp2350-arm-s` image aimed at
`0x10000000` may not land where the bytes say. `yi26 pflash` drives PICOBOOT and
writes the UF2's absolute addresses **raw**, table and image both exactly where
they are addressed. The first hardware run used `yi26 flash`, and that is a
confound: "the image did not boot" is entangled with "the drive may have routed
it elsewhere." The clean test — the one that would make a non-boot mean the
image-in-partition setup is wrong rather than the flash path — is `yi26 pflash
target/exp139.uf2`.

The recovery is not a drag and not a plain BOOTSEL press. On the first run the
BOOTSEL **drive refused every dragged `.uf2`** while still appearing — the
honoured table made the bootrom reject the drive's writes. Only PICOBOOT still
reached the board, so recover with one of:

1. `yi26 nuke` — erases the first 64 KiB (the table and what follows) over
   PICOBOOT, on the command line. See [`tools/`](../../tools/README.md).
2. exp141's [`recover.html`](../exp141-two-doors-into-the-bootrom/recover.html)
   — the same erase from a browser, including a phone, with nothing installed.

Then flash a known-good image with `yi26 pflash` — for example
`../exp138-what-the-rom-already-knows/target/exp138.uf2`. That is the whole cost
of being wrong, and it is why this experiment exists before anything that writes
to flash from inside a running firmware.

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

There is no serial capture, because there was nothing to capture: the board did
not enumerate as application firmware, so its port never opened and the three
questions were never asked. The README always said that if it did not boot,
that too was a result and would go here in words. Here it is, from
**2026-08-04**.

`target/exp139.uf2` was flashed with `yi26 flash` — the drag-and-drop path, not
PICOBOOT — onto a board that had been running an ordinary offset-0 firmware.
What was observed, in order:

```text
- The board did not come back as 0x1209 (application firmware). No log, no CDC
  port. The image at 0x10001000 did not run.
- The board did present its BOOTSEL side: the RP2350 drive appeared.
- Dragging a known-good .uf2 onto that drive did nothing — no error, no reboot,
  the file just did not take. Every drag was refused, on more than one host.
- `yi26 nuke` (and, separately, exp141's recover.html from a phone) erased the
  first 64 KiB over PICOBOOT. After a replug the board was a stock board again
  and a dragged .uf2 flashed normally.
```

Two things that behaviour settles, and one it does not.

**It settles that the ROM read and honoured the table.** A table the ROM
ignored would have left offset 0 looking like a broken image, dropped the board
into BOOTSEL, and left the drive working normally. Instead the drive *refused*
writes — the bootrom was enforcing a partition layout, which it can only do from
a table it accepted. So the eight words parsed. That agrees with
[The words are not the fault](#the-words-are-not-the-fault): the encoding was
never the problem.

**It does not settle why the image did not boot**, because the first run used
`yi26 flash`. A `rp2350-arm-s` UF2 aimed at `0x10000000` goes to the drive,
which routes blocks by family into partitions rather than writing them where
they are addressed — so the image may never have reached `0x10001000` intact.
"The image did not boot" and "the drive put the image somewhere else" are not
distinguishable from this run. The test that separates them is `yi26 pflash`,
which writes the UF2's absolute addresses raw; see
[Before you flash this](#before-you-flash-this). Running that, and reading which
of exp138's three questions the board answers, is the next hardware step and the
one the goal — *an image booting from a partition* — actually turns on.

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
| The board does not enumerate as application firmware after flashing | No bootable image was found — but the board drops into BOOTSEL on its own, so it comes back as `2e8a:000f` | Recover with `yi26 nuke` or `recover.html` (a bad table makes the drag drive refuse writes), then reflash with `yi26 pflash` — see [Before you flash this](#before-you-flash-this) |
| …and you were about to blame the size field | The one value with no second source *looks* like the suspect, but the table matches `embassy-rp`'s own encoder byte for byte | It is not the encoding — see [The words are not the fault](#the-words-are-not-the-fault). Retest with `yi26 pflash`, which removes the drive's family routing, before changing any word |
| `cargo test` fails in `partition-table` | A word was changed | That is the test doing its job — decide which is right before flashing |

## Next

Under [Planned](../README.md#planned): two images, one version number, and the
ROM choosing between them.
