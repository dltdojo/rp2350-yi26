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

Needs: any RP2350 board, and the exp102 toolchain. No browser. **A person if it
goes wrong** — and it does go wrong, in a way this experiment first assumed it
would not. When the sector-1 image is actually launched and crashes, the board
goes *dark*: no application firmware, and no BOOTSEL either, so PICOBOOT cannot
reach it and only a physical BOOTSEL press brings it back. That is the sharpest
thing this experiment measured; see [Expected output](#expected-output).

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
this one, offset 0 is a table and the image is at 0x10001000. If the ROM accepts
the table and boots the image, USB comes back and everything continues as
normal. It did not, and the way it failed is the finding: **the board went
dark** — no application firmware, and no BOOTSEL either.

That is worth sitting with, because it is the opposite of what this experiment
assumed. The old expectation was that a board which cannot boot falls back to
BOOTSEL on its own, so PICOBOOT could always reach it and no button was ever
needed. On **2026-08-04** a clean `yi26 pflash` of `target/exp139.uf2` — a raw
PICOBOOT write of the table and image to their absolute addresses, then
`REBOOT2` — was followed by *no USB enumeration at all*. The kernel logged the
BOOTSEL device disconnecting at the reboot and nothing coming back. The most
likely reading: the ROM read the table, found the sector-1 image *bootable*,
handed control to it, and it crashed before bringing up USB — so the ROM never
fell back to BOOTSEL, because from its point of view the handoff succeeded. A
crashed image is not a missing image.

So the recovery is a **physical BOOTSEL press** — the one thing this whole arc
was built to avoid, arrived at honestly:

1. Unplug the USB cable.
2. **Hold BOOTSEL**, plug the cable back in, release. The board comes up as
   `2e8a:000f`, and PICOBOOT can reach it again.
3. `yi26 nuke` — erase the first 64 KiB (the table and the broken image) over
   PICOBOOT. See [`tools/`](../../tools/README.md).
4. `yi26 pflash ../exp138-what-the-rom-already-knows/target/exp138.uf2` — flash a
   known-good image back. (`pflash` needs no replug after `nuke`; it writes raw,
   not through the drive.)

Use `yi26 pflash`, not `yi26 flash`, to flash this in the first place — not only
because it is reliable, but because it removes a confound. `yi26 flash` hands the
UF2 to the bootrom's *drive*, which routes each block by UF2 family into whatever
partition accepts it, so a non-boot could mean "the drive put the image
elsewhere" rather than "the image cannot run where it is." `pflash` writes the
absolute addresses raw, so the image was exactly where the bytes said — and it
still did not run. That is what makes the non-boot a real image-in-partition
problem and not a flashing artifact. Where the problem most likely is:
[What is still open](#what-is-still-open).

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

There is no serial capture, because there was nothing to capture: the board
never enumerated, so its port never opened and the three questions were never
asked. The README always said that if it did not boot, that too was a result and
would go here in words. Here it is, from **2026-08-04**, across two runs — the
second one decisive.

**First run, `yi26 flash` (the drag drive).** The board did not come back as
`0x1209`, but it *did* keep its BOOTSEL side: the `RP2350` drive appeared, and
then refused every dragged `.uf2` — no error, no reboot, the file just did not
take, on more than one host. `yi26 nuke` (and, separately, exp141's
`recover.html` from a phone) erased the first 64 KiB over PICOBOOT and the board
was stock again. This run had a confound, though: the drive routes UF2 blocks by
family, so it was never certain the image had reached `0x10001000` intact — or
that it had been *launched* at all. The board sitting in BOOTSEL is consistent
with the image never running.

**Second run, `yi26 pflash` (PICOBOOT, raw).** This removes the confound —
`pflash` writes the UF2's absolute addresses directly, table to sector 0 and
image to sector 1, then `REBOOT2 NORMAL`. Observed:

```text
pflash: flashed 27136 bytes to 0x10000000 (7 sectors erased), and rebooted.
then: nothing. No 0x1209, no 0x2e8a:000f — the board went dark.
kernel log: the BOOTSEL device disconnected at the reboot; nothing enumerated after.
recovery: a physical BOOTSEL press, then `yi26 nuke` + `yi26 pflash exp138.uf2`.
```

Two things this settles, and one it hands to the next step.

**The table is read and honoured.** In the first run the drive enforced a
partition layout (it refused writes it would otherwise accept); in the second the
ROM booted *from the partition* at all. Both require the eight words to have
parsed. That agrees with [The words are not the fault](#the-words-are-not-the-fault).

**The non-boot is real, not a flashing artifact.** The clean raw write put the
image exactly where it is addressed and it still did not run. So this is an
image-in-partition problem, not a drive-routing one — the confound is closed.

**And it launched the image rather than rejecting it.** The board going dark,
instead of falling back to BOOTSEL, is the tell: the ROM found the sector-1 image
bootable, jumped to it, and it crashed before USB. Why a well-built image would
crash the instant it is booted *from a partition* is the open question — see
[What is still open](#what-is-still-open).

## What is still open

Why the image crashes on launch, when the same firmware boots fine from flash
offset 0. The leading hypothesis, not yet confirmed on hardware and the reason
the next flash is worth its BOOTSEL press:

**The image is linked for the wrong address.** `memory.x` here reserves 4 KiB
for the table and sets the image's `FLASH ORIGIN` to `0x10001000`, so the image
runs *in place* at sector 1. But a partition image is the unit A/B switching
moves between slots, and for one binary to boot from either slot the ROM has to
map the chosen partition's start to a fixed run address — `0x10000000`, the XIP
base. If the ROM does that here, then the image physically at `0x10001000` is
executed as though it were at `0x10000000`: every absolute address in it — the
vector table, function pointers, `.data` — is off by `0x1000`, and it faults on
the first one. That matches "launched, then crashed."

If that is right, the fix is a load-address / run-address split, not a move:
link the image for `0x10000000` (VMA) but place it physically at `0x10001000`
(LMA), so the UF2 writes sector 1 while the image's addresses assume the XIP
base — which is what the ROM's rolling window provides. `embassy-rp` even exposes
`item_rolling_window(delta)` for the explicit form. Confirming which mechanism
the ROM uses — automatic remap by partition, or an explicit rolling-window item
— is what the datasheet's boot chapter has to settle before the next attempt,
because each attempt now costs a physical BOOTSEL press.

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
| The board goes dark after flashing — no `0x1209`, no `0x2e8a:000f` | The ROM launched the sector-1 image and it crashed before USB; it does **not** fall back to BOOTSEL, so PICOBOOT cannot reach it | A physical BOOTSEL press (unplug, hold, replug), then `yi26 nuke` + `yi26 pflash exp138.uf2` — see [Before you flash this](#before-you-flash-this) and [What is still open](#what-is-still-open) |
| …and you were about to blame the size field | The one value with no second source *looks* like the suspect, but the table matches `embassy-rp`'s own encoder byte for byte | It is not the encoding — see [The words are not the fault](#the-words-are-not-the-fault). Retest with `yi26 pflash`, which removes the drive's family routing, before changing any word |
| `cargo test` fails in `partition-table` | A word was changed | That is the test doing its job — decide which is right before flashing |

## Next

Under [Planned](../README.md#planned): two images, one version number, and the
ROM choosing between them.
