# exp245 — the bytes the proof blesses

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Status: TODO (scaffold).** The design is in [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) and the discussion in
[`WHY.zh-TW.md`](./WHY.zh-TW.md). Nothing here has been built, assembled or proved yet; the word counts below come from
assembling the design's snippets, and every step count waits for a capture.

## Overview

Engineers in Tokyo buy Kanda Myojin's *IT情報安全守護* charm: a card and stickers for their machines, sold since 2002
([IT Leaders](https://it.impress.co.jp/articles/-/27423)). In Taiwan's server rooms, a green pack of *Kuai Kuai* sits on
top of the machines so the light stays green. Both are tokens of comfort against crashes, leaks and failures.

A proof becomes the same kind of token when it is read as a badge rather than as a conditional statement. This
experiment builds bytes that are fetched and executed, backed by Lean 4 theorems on Lean's own axioms, and guarded by
mutants that Lean refuses. They do nothing for what the payload can do, and **that is proved in Lean too**: next to each
charm's own theorem sits an *exposure theorem*, stated from reset, which says the charm changes nothing.

The monitor is [exp240](../exp240-the-code-the-box-forbids-writing/)'s, with three charms added:

1. **The shrine seal** (18 words). Boot writes `0x4D414D4F` and `0x4941554B` at `0x80008010`, which read back as the
   bytes `"OMAMKUAI"`. Before reporting a HALT, the handler checks both words and reports a FAULT if either differs.
   - *Charm theorem* `halt_requires_shrine`: from any trap state, a HALT is reported only with the seal intact.
   - *Exposure* `shrine_always_intact`: the seal lies outside the data and stack entries, so `wx_run` keeps it, and boot
     rewrites it every round. In every round reachable from reset, the check passes.
2. **The shadowed entry** (2 more words). Boot sets PMP entry 3 read-only over the seed window
   `[0x80010100, 0x80010200)`, with `pmpaddr3 = 0x2000405f` and `pmpcfg0 = 0x191b1b1d`.
   - *Charm theorem* `entry3_forbids_seed_store`: `matchPmpEntry` on entry 3 is a `FullMatch` whose `hasPermission`
     for a U-mode store is `false`.
   - *Exposure* `pmpCheck_shadowed`, in `lean/Rv32/WxBox.lean`: an entry 3 that lies wholly inside entry 1 never
     decides, because the lowest-numbered matching entry does. exp240's `wx_store_allowed_data` then lets the store in.
3. **The ceremonial scrub** (7 words). Every exit zeroes a 32-byte slot at `[0x80010e00, 0x80010e20)` in the data.
   - *Charm theorem* `slot_zeroed_on_exit`: at park the slot is zero, and every other byte is as the payload left it.
   - *Exposure* `stack_reaches_next_round`: that frame, joined to exp240's `monitor_reentry`, carries a key the payload
     left on its stack at `0x8001ffc0` into the next round.

Two of the three restate prior work on purpose. Entry order is exp240's `entries_swapped` and
`pmp_entries_tried_backwards`. A frame that keeps secrets is the shape of exp239's own `monitor_scrub`.

A fourth charm was in the first draft: a service call that reads its own request word back as a pass. It is discussed
in WHY §4 and not built. exp238 already discloses it, exp240 serves only HALT, and on the emulator those bytes actually
fail closed: the placebo there is the theorem, not the bytes.

"Does nothing" means *in exp240's model*: one hart, a U-mode payload, and the host's writes between rounds. Act 1b of
the emulator suite writes the seal from outside that model, standing for a DMA channel or the other core, and there the
check turns a HALT into a FAULT.

Needs: **no board** (the scaffold, and the finished experiment).

## Documents in this directory

- [`WHY.zh-TW.md`](./WHY.zh-TW.md) — the charm and the Kuai Kuai, verification theater, why the fourth charm was
  dropped, and a checklist for reading a verification claim.
- [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) — memory map, the assembly of each charm, the charm and exposure theorems, the
  mutants, and the emulator acts.

## TODO

- [ ] `monitor.S`: exp240's plus the three charms. With them removed it must assemble to exp240's `monitor.bin`,
      byte for byte.
- [ ] `lean/Rv32/WxBox.lean`: `pmpCheck_shadowed`, and `WXBoxed` taking a shadowed entry 3.
- [ ] `proof/`: `gen.py`, `defs.lean`, `tail.lean`, generated `Bless.lean`; the three charm theorems, the three
      exposure theorems, and exp240's end-to-end and round theorems for this binary.
- [ ] `proof/mutants.txt`: the 13 charm mutants in DESIGN §4, plus exp240's for the words the two share.
- [ ] `suite/charms_audit.py`: Acts 1a, 1b, 2, 3 and the ablation (Act 4).
- [ ] `check.sh`, `run.sh`, `capture.txt`, and the index row moved from scaffold to done.
