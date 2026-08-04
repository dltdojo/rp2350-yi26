# exp138-what-the-rom-already-knows — the A/B machinery is in the chip, and unused

Every guide to dual-firmware updates on a microcontroller starts the same way:
*the boot ROM is fixed silicon, it has no idea which slot you want, so you must
hand-roll a bootloader that decides.* On most parts that is exactly right.

**On the RP2350 it is not**, and this experiment is the board saying so. It
asks the ROM three questions, writes nothing, and prints every answer raw
before interpreting it.

Needs: any RP2350 board, and the exp102 toolchain. No browser, nobody in the
room, and **no risk at all** — this firmware only reads.

## The three questions

| | ROM function | What it settles |
| --- | --- | --- |
| Is there a partition table? | `get_partition_table_info(PT_INFO)` | whether this board's flash is divided at all |
| What chip is this? | `get_sys_info(CHIP_INFO)` | that these calls reach a real ROM and come back |
| Does partition 0 have a B side? | `get_b_partition(0)` | **whether the ROM understands A/B at all** |

The third one is the point. A chip whose ROM cannot answer *"which partition is
the other half of this pair"* is a chip where A/B has to be built by hand. This
one answers it — it just has nothing to answer about yet.

## What is actually in the ROM

Not a rumour, and not the datasheet taken on trust: these are the bindings
`embassy-rp` ships, which exist because the functions do.

| Binding | What it is for |
| --- | --- |
| `rom_data::get_partition_table_info` | read the table |
| `rom_data::get_b_partition` | ask which partition is the B side of an A |
| `rom_data::pick_ab_parition` | **the ROM's own A/B chooser** (the typo is upstream) |
| `rom_data::explicit_buy` | confirm a *try-before-you-buy* image, so it stops being provisional |
| `block::Link::ToA { partition_idx }` | how a partition table says "these two are a pair" |
| `block::IMAGE_TYPE_TBYB` | the flag that makes an image provisional |
| `block::ITEM_1BS_VERSION` | the version the ROM compares when it picks |

So the parts a hand-rolled bootloader exists to provide — pick a slot, try it,
roll back if it is not confirmed — are **already in mask ROM**, below anything
this repository can break.

## Expected output

Captured from a Pico 2 that has never had a partition table written to it,
which is every board this repository has used:

```text
[      37 ms] exp138 up. Asking the ROM what it already knows, in 3 seconds.
[    3037 ms] get_partition_table_info(PT_INFO) -> 4
[    3037 ms]   word[0] = 0x00000001
[    3037 ms]   word[1] = 0x00000000
[    3037 ms]   word[2] = 0xffffe000
[    3037 ms]   word[3] = 0xfc078000
[    3037 ms] get_sys_info(CHIP_INFO) -> 4
[    3037 ms]   word[0] = 0x00000001
[    3037 ms]   word[1] = 0x00000001
[    3037 ms]   word[2] = 0x9b934884
[    3037 ms]   word[3] = 0x9952f83a
[    3038 ms] get_b_partition(0) -> -17
[    3038 ms]   negative: partition 0 has no B side, or there is no table
[    3038 ms] done. nothing was written; this firmware only reads.
```

### Decoding it by hand

The words are printed before they are interpreted on purpose. A decoded field
that is wrong reads like a fact; the word it came from reads like what it is.

**`get_partition_table_info(PT_INFO) -> 4`** — four words, and the return value
is the count rather than an error:

| Word | Value | What it is |
| --- | --- | --- |
| 0 | `0x00000001` | the flags, echoed back — this is the `PT_INFO` request |
| 1 | `0x00000000` | **the partition count: zero** |
| 2 | `0xffffe000` | unpartitioned space: first and last sector |
| 3 | `0xfc078000` | unpartitioned space: permissions and flags |

Word 2 decodes with the arithmetic `embassy_rp::block::UnpartitionedSpace`
uses — low 13 bits are the first sector, the next 13 are the last:

```text
0xffffe000 & 0x1fff        = 0       first sector
(0xffffe000 >> 13) & 0x1fff = 8191   last sector
8192 sectors × 4 KiB       = 32 MiB
```

**32 MiB is not this board's flash.** A Pico 2 has 4 MiB fitted. What the ROM
is reporting is the whole addressable XIP window as unpartitioned — which is
the correct answer to "how much of this is not in a partition" when nothing is.

**`get_b_partition(0) -> -17`** is the headline. It is a negative error code
because there is no table to look in, not because the ROM does not understand
the question. The same call on a board with an A/B pair returns the index.

**`get_sys_info(CHIP_INFO)`** is here as a control: if the two words that look
like a device identity came back as zeros, the calls would not be reaching the
ROM at all and neither would the answer above. Note that these are *not*
[exp113](../exp113-enumerable-seed/)'s `1f6ba31a` — that one is derived from
specific OTP rows, and these are a different field entirely. Two routes to
"identity" that are not the same number, which is worth knowing before either
is used for anything.

## So what does that make a hand-rolled bootloader?

A comparison, rather than a necessity — and this is the whole reason this arc
starts with a read-only experiment.

The standard advice for drag-and-drop updates with dual-firmware protection
says you must publish `v1.1_for_slotB.uf2` and `v1.2_for_slotA.uf2`, because
the ROM cannot know which slot to write. On this chip the ROM has a version
field it compares, an A/B link it follows, and a *try-before-you-buy* flag it
enforces. Whatever a hand-rolled bootloader is worth here, it is not that.

What it might still be worth — a volume the user drags onto without pressing
BOOTSEL, a protocol you control, an update path that works on a chip with no
such ROM — is a real question, and this arc measures it rather than assuming
it either way.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — `interrogate_task`. Three calls, and a
  `log!` after each that prints the raw words first.

## Two ways to do it

```sh
./run.sh      # guided: flash it and read the answers with the decoding beside them
./check.sh    # verdict: the calls return, and the board says what it found
```

## What is not verified here

**A board that *has* a partition table.** Everything above is the answer from
an unpartitioned board, which is the only kind this repository has. The next
experiment on this road is the one that changes that, and it is the first thing
here that writes to flash.

**The error code `-17` by name.** It is reported as the number the ROM
returned. Naming it means reading the datasheet's error list, and this
experiment does not depend on the name.

## Make it yours

1. Ask for a partition that does not exist — `get_partition_table_info` with a
   partition index in the high bits. The error is the ROM refusing precisely,
   which is what exp123 spent an experiment establishing about a different
   interface.
2. Call `get_b_partition(1)`, `(2)`, `(15)`. Same answer, and working out why
   from the words above is the point.
3. Read `get_sys_info` with the other flags in the datasheet's list. One of
   them reports the boot ROM's own version, which decides which of these
   functions exist at all.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No lines at all | The port was opened after the answers were said | Replug, then `yi26 log` within three seconds — or read the idle line |
| Every word is zero | The calls are not reaching the ROM | Check this is an RP2350 and not an RP2040 build |
| `-17` where you expected a partition | Correct on a stock board | That is the finding, not a fault |

## Next

The road this opens is under [Planned](../README.md#planned): write a partition
table, put two images in it, and let the ROM choose between them.
