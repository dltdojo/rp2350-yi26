# exp245 — the bytes the proof blesses

<!-- SPDX-License-Identifier: Apache-2.0 -->

The design is in [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) and the discussion in [`WHY.zh-TW.md`](./WHY.zh-TW.md). What
follows is what was built; where it differs from the design, it says so.

## Overview

Engineers in Tokyo buy Kanda Myojin's *IT情報安全守護* charm: a card and stickers for their machines, sold since 2002
([IT Leaders](https://it.impress.co.jp/articles/-/27423)). In Taiwan's server rooms, a green pack of *Kuai Kuai* sits on
top of the machines so the light stays green. Both are tokens of comfort against crashes, leaks and failures.

A proof becomes the same kind of token when it is read as a badge rather than as a conditional statement. This
experiment builds bytes that are fetched and executed, backed by Lean 4 theorems on Lean's own axioms, and guarded by
mutants that Lean refuses. They do nothing for what the payload can do, and **that is proved in Lean too**: next to each
charm's own theorem sits an *exposure theorem*, stated from reset, which says the charm changes nothing.

The monitor is [exp240](../exp240-the-code-the-box-forbids-writing/)'s, 151 words, with three charms added, 27 words, so
178 words, 712 bytes:

1. **The shrine seal** (18 words). Boot writes `0x4D414D4F` and `0x4941554B` at `0x80008010`, which read as the bytes
   `"OMAMKUAI"`. Before reporting a HALT, the handler checks both words and reports a FAULT if either differs.
   - *Charm theorems* `shrine_set_at_boot` and `halt_requires_shrine`: boot leaves the seal intact, and from **any**
     trap state an `ecall` with `t0 = 1` is a HALT with the payload's `a0` exactly when the seal is intact, and a FAULT
     with exit code 1 when it is not.
   - *Exposure* `shrine_always_intact`, `shrine_changes_nothing`: the shrine is outside the data and the stack, so the
     payload cannot write it, and boot writes it again every round. At every trap a round reaches the seal is intact,
     and the exit code is exp240's.
2. **The shadowed entry** (2 more words). Boot sets PMP entry 3 read-only over the seed window
   `[0x80010100, 0x80010200)`, with `pmpaddr3 = 0x2000405f` and `pmpcfg0 = 0x191b1b1d`.
   - *Charm theorems* `seed_entry_configured` and `entry3_forbids_seed_store`: after boot, entry 3 is NAPOT, read-only,
     over the window, and an access wholly inside the window is a full match of entry 3, whose permissions refuse a
     U-mode store.
   - *Exposure* `pmpCheck_shadowed`, in `lean/Rv32/WxBox.lean`, and `seed_store_allowed`: an entry 3 that lies wholly
     inside entry 1 never decides, because entry 1 is tried first; from reset, a U-mode store into the window passes.
3. **The ceremonial scrub** (7 words). Every exit zeroes a 32-byte slot at `[0x80010e00, 0x80010e20)` in the data.
   - *Charm theorem* `slot_zeroed_on_exit`: at the park loop the slot is zero, and every other byte but the monitor's
     stack and report words is as the payload left it.
   - *Exposure* `stack_reaches_next_round`: that frame, and boot's, carry the bytes the payload left on its stack at
     `[0x8001ffc0, 0x8001ffe0)` into the next round's payload.

Two of the three restate prior work on purpose. Entry order is exp240's `entries_swapped` and
`pmp_entries_tried_backwards`. A frame that keeps secrets is the shape of exp239's own `monitor_scrub`.

A fourth charm was in the first draft: a service call that reads its own request word back as a pass. It is discussed
in WHY §4 and not built. exp238 already discloses it, exp240 serves only HALT, and on the emulator those bytes actually
fail closed: the placebo there is the theorem, not the bytes.

"Does nothing" means *in exp240's model*: one hart, a U-mode payload, and the host's writes between rounds. Act 1b of
the emulator suite writes the seal from outside that model, standing for a DMA channel or the other core, and there the
check turns a HALT into a FAULT.

Needs: **no board** at all, and no USB anywhere in it. Nothing here ran on silicon or on the RTL.

## Documents in this directory

- [`WHY.zh-TW.md`](./WHY.zh-TW.md) — the charm and the Kuai Kuai, verification theater, why the fourth charm was
  dropped, and a checklist for reading a verification claim.
- [`DESIGN.zh-TW.md`](./DESIGN.zh-TW.md) — memory map, the assembly of each charm, the charm and exposure theorems, the
  mutants, and the emulator acts.

## What the monitor does

`monitor.S` is exp240's, word for word, with each charm marked: a block between `// [Charm N] {` and `// [Charm N] }` is
added, and a line ending `// [Charm N] exp240: X` is exp240's line `X` changed. `monitor.py` takes the marks away and
requires exp240's `monitor.bin` byte for byte with all three gone, and a different binary with any one gone alone.

```
0x80000040  _reset (boot, 71 steps)   exp240's boot, with entry 3 the seed window (pmpaddr3 0x2000405f,
                                      pmpcfg0 0x191b1b1d) [Charm 2], and after the CSRs the shrine's two
                                      words [Charm 1]; then the registers, mcountinhibit <- 0, mret
0x8000015c  trap_handler              exp240's
0x800001c0  the seal's check          both words, or the fault report [Charm 1]
0x800001e8  the HALT report           exp240's
0x80000210  scrub_exit                the saved words and mscratch, exp240's; then the slot zeroed
                                      [Charm 3]; then the registers and the exit word, exp240's
0x800002c0  halt_loop                 wfi, j halt_loop
```

Two places differ from the design, and neither changes what a charm does:

- **The shrine is written last of boot's CSRs**, before the registers, not right after `mscratch`. In the proof a run
  that steps on from a store needs a rewrite the model's `simp` does not reach in one pass; with the stores last, boot
  is two runs, each ending with one of them (`monitor_boot_config`, `monitor_boot_shrine`).
- **`pmpaddr3` is written where exp240 wrote it**, after `pmpcfg0`, not before. M-mode is not held to an entry that is
  not locked (`pmpCheck_M_unlocked`), so the order does not matter to the monitor, and the ablation stays a line for a
  line.

## What is proved

All on Lean's own axioms, in `proof/Bless.lean`, which `check.sh` holds against `monitor.S` assembled afresh. The proof
is exp240's at this monitor's addresses -- `tools/monitor/wx.py` writes both, and exp240's `Wx.lean` comes out of it
byte for byte -- with the charms' words added: two chunks for the seal's check, exp239's zeroing loop
(`chunks.zloop`) for the slot.

| theorem | says |
| :--- | :--- |
| `monitor_boot` | from reset (image loaded, `pc = 0x80000040`, M-mode, any CSRs that lock no PMP entry, any registers), 71 steps give `WXBoxed` with the three entries and entry 3 shadowed, `sp = 0x80020000`, every other register zero, the CSR file `csrsBooted`, and memory `shrined M0`: the shrine's two words written, every other byte as it was |
| `monitor_traps` | from the trap vector, whatever the payload left, five ways -- a HALT with the seal intact, the seal's first or second word wrong, an `ecall` for anything else, a fault -- `trapSteps` steps (95, 96, 100, 90, 87) to the park loop: `Parked` with `exitCode u`, the monitor's words in place, `SlotFrame`, the PMP as boot set it, the host having heard `trapIo u` |
| `payload_runs`, `monitor_end_to_end` | exp240's, for this binary: from reset, the payload boxed and its code the bytes it was loaded with, or trapped -- with the seal intact -- and parked |
| `monitor_reentry`, `ready_of_host`, `monitor_round_ready`, `monitor_rounds` | exp240's round after round: from any `Ready` machine a reset and boot leave the same CSRs and registers, and memory as it was but for the shrine, written again |
| `shrine_set_at_boot` | [Charm 1] `Sealed (shrined M0)`, whatever `M0` held there |
| `halt_requires_shrine` | [Charm 1] from **any** trap state, an `ecall` with `t0 = 1`: the seal intact, the host hears a HALT and `a0` is the payload's; the seal broken, a FAULT and `a0 = 1` |
| `shrine_always_intact`, `shrine_changes_nothing` | [Charm 1, exposed] at the first trap of every round from a `Ready` machine the seal is intact, so the exit code is exp240's |
| `seed_entry_configured`, `entry3_forbids_seed_store` | [Charm 2] after boot entry 3 is NAPOT, read-only, over `[0x80010100, 0x80010200)`; an access wholly inside it is entry 3's full match, and that refuses a U-mode store |
| `pmpCheck_shadowed` | [Charm 2, exposed] in the library: an entry 3 wholly inside entry 1 leaves `pmpCheck` the first three entries', for every privilege, address, width and access |
| `seed_store_allowed` | [Charm 2, exposed] from reset, a U-mode word store into the seed window passes the PMP |
| `slot_zeroed_on_exit` | [Charm 3] from the trap vector, whatever the payload did: the slot zero at the park loop, every other byte but the stack and report words as the payload left it |
| `stack_reaches_next_round` | [Charm 3, exposed] after a round, a reset and boot, the next payload starts with the bytes `[0x8001ffc0, 0x8001ffe0)` the last one left there at its trap |

`WXBoxed` in `lean/Rv32/WxBox.lean` now takes entry 3 off **or** shadowed (`Entry3Silent`), and every `wx_*` theorem of
exp240's holds for both: this monitor's box is exp240's box, which is the point of the second exposure.

## What is not proved, and what it rests on

Everything exp240's README says, for the same reasons; and:

- **The exposure theorems are about the model.** A writer the model does not have -- a DMA channel, the other core, a
  fault injected -- can change the shrine between boot and the trap. Act 1b does exactly that on the emulator, and the
  check then turns a HALT into a FAULT. Whether the chip has such a writer is a question about the threat model, not
  the proof.
- **`halt_requires_shrine` is true and says nothing about a round.** It is stated from any trap state, which is why
  Lean refuses `shrine_check_skipped`; `shrine_always_intact` says the states where the check would fire are not ones a
  round reaches.
- **The real fixes are not built**: the seed entry listed before the data entry, and a scrub of every byte U-mode can
  write (`wx_store_ok` names them: `[0x80010080, 0x80011000)` and `[0x8001f000, 0x80020000)`).

## The checks

1. `monitor.py --check`: `monitor.S` assembles to `monitor.bin` byte for byte, the SHA-256 matches, 178 ≤ 200 words,
   `monitorCode` is its words, and the charms taken away give exp240's `monitor.bin`.
2. `proof/Bless.lean` checks, every theorem it prints on Lean's own axioms.
3. **Sixty-eight mutants** (`proof/mutants.txt`, written by `gen.py`), each refused by Lean: thirteen of the charms --
   ten words and three claims that say more than a charm does (that an exit zeroes the stack, that the PMP refuses a
   store into the seed window, that a round reaches a broken seal) -- nine of exp240's ported to this monitor's words,
   and forty-six of exp240's as they are.
4. `proof/Bless.lean` and `proof/mutants.txt` are what `proof/gen.py` writes.
5. `suite/charms_audit.py`, on the emulator, reusing exp240's suite:
   - **Act 1a**: a payload overwrites its whole output and HALTs; the seal is intact.
   - **Act 1b**: the seal written from outside the model mid-run; exp245 FAULTs, exp240 HALTs.
   - **Act 2**: a store into the seed window goes in.
   - **Act 3**: a key left on the stack in round 1 is round 2's output, the slot zero at both parks.
   - **Act 4**: exp240, exp245 and exp245 with each charm taken away alone, under exp240's hostile payloads, Acts 1a,
     2 and 3, and 20 rounds of exp225's Rule 30 kernel: the same registers, reports, exit codes, traps and counters;
     memory different only in the monitor's words, the shrine and the slot, and entry 3 only where charm 2 is.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
(not yet recorded)
```
