# exp249 — the words the hash touches

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The second of three rounds toward exp223's kernel behind [exp239](../exp239-the-scratch-the-monitor-scrubs/)'s
monitor. [exp248](../exp248-the-samples-the-front-reads/) ran exp223's front through the reach checker. This round runs
its SHA-256: [exp208](../exp208-the-hash-the-kernel-computes/)'s 252-instruction kernel, which exp223 places at +0x1000.

exp208 proved how the run ends: after exactly 4990 + 4873 · n instructions it halts with 0, and SHA-256 of the
message is at +0x1140. A monitor's box needs every step on the way. In Lean 4, on Lean's own axioms, for a
4096-byte message, from the kernel's first word wherever it sits (its own 64 KiB, or partway into a box):

- **Every store lands in `[base + 0x1140, base + 0x1440)`**: the digest, H, the schedule and the padding block.
  Memory outside that is as it was.
- **Every load lands in `[base + 0x400, base + 0x3040)`.** The run's own loads, on the emulator, are
  `[+0x1000, +0x3000)`. The checker's bound is wider; see below.
- **The only call is HALT**, with `t0 = 1`.
- **With exp208's own theorem, the whole run:** it halts with the digest, and every state on the way has the facts
  above.

At exp223's +0x1000, these windows are `[box + 0x2140, box + 0x2440)` for stores and `[box + 0x1400, box + 0x4040)`
for loads, both well inside the 64 KiB box.

Needs: **no board** at all, and no USB anywhere in it. No firmware of its own: the kernel is exp208's, held by
`lean/Rv32/Sha.lean` and by exp208's and exp223's own checks. Nothing here ran on silicon or on the RTL.

## How this was decided

1. **The facts.** exp248's emulator suite recorded SHA-256's run inside exp223 before any of this was written: loads
   `[+0x1000, +0x3000)` and stores `[+0x1140, +0x1440)` from SHA-256's base. Three things defeated the checker as it
   stood:
   - **the block count comes from memory**: `lw t0, 0x120(s1)`, then `srli s6, t0, 6`;
   - **the message pointer is affine in two nested counters**: `s4 = R + d + 64·s5 − 4·s8` in the load loop;
   - **the padding block's pointer joins the message's** at the head of the block loop: `s4 = R + 0x400` against
     `R + 0x2000 + 64·s5`.

   And the counter `s8` is set three times, by `addi s8, zero, k`, which erased everything affine in it.
2. **What was already answered.**
   - `lean/Rv32/Ct.lean`, now with exits and `Hosted` (round 1).
   - `lean/Rv32/Reach.lean`'s reading of it: `windowed`, `Good`, `reach`, `frame`.
   - exp208's `Sha.computes`, the run's end, for any message length `64 · n`.
3. **The contradictions.**
   - A pointer with a range and no counter cannot carry a loop: each block moves `s4` 64 bytes, so a bare range only
     grows. It has to stay tied to `s5`.
   - Joining the padding path with the message path loses which one the run is on. The bound that results is wider
     than any run, which is why the load window starts at `+0x400` and not at K's `+0x1000`.
   - The checker proves facts for every message whose length word is 4096. exp208's theorem is for every length.
     This round is the length exp223 uses.
4. **What was decided without asking.**
   - **One general form replaces the affine value:** `lin r1 k1 r2 k2 lo hi`, two counters and an offset in a range.
     `aff r k c` is `lin r k 0 0 c c`, a `match_pattern` abbreviation, so exp207, exp229 and exp248 read as before.
   - **The block count's rules:** a constant word in memory (`Pub.consts`, with stores and HASH kept apart from it),
     and `srli` of a number.
   - **The loop exit:** a counter narrowed by an ordered comparison (`capLe`, only below 2³¹ where signed and
     unsigned agree).
   - **A counter pinned by a comparison is folded in** (`norm`), so setting it again loses nothing.
   - exp207, exp229, exp247 and exp248 still check, unchanged.
5. **What was asked**, in round 1, and stands: a general reach checker, built in three rounds.

## What is proved

In the library, `lean/Rv32/Ct.lean`:

| | says |
| :--- | :--- |
| `AV.lin`, `AV.aff` | a value `base + d + k₁·x₁ + k₂·x₂`, `d` in `[lo, hi]`, `xᵢ` counters' readings. `aff` is the one-counter, one-offset case |
| `fold`, `fold_val`, `fold_lin` | a value with every pinned counter folded into its range; what that says, and what a claim of that form asks. `rel_mono`, the loop-head check, is built on them |
| `Pub`, `Rel.consts1/2`, `apartK` | public places and **constant words**; every state keeps the constants, because no store or HASH may meet them |
| `ldAV`, `lock_ld` | a `lw` of exactly a constant's word loads its number |
| `shAV`, `sh_ok` | `srli` of a number in a range is a number in the range shifted |
| `capLe`, `rel_cap` | after `blt`/`bge`/`bltu`/`bgeu`, a number's range capped by the other's top, below 2³¹ |
| `norm`, `rel_norm` | after a comparison pins a counter, every value affine in it has it folded in |

And about exp208's kernel, in `proof/Hash.lean`:

| theorem | says |
| :--- | :--- |
| `accepted`, `windows`, `halts_only` | the kernel through the checker, by `decide`. Five loop heads: the block loop, where its two paths meet, the load loop, the schedule, the rounds. The length a constant; loads in `[0x400, 0x3040)`, stores in `[0x1140, 0x1440)`, every `ecall` at `t0 = 1` |
| `sha_reach` | **every step in its windows**: from the first word, wherever `Hosted`, with the length 4096 at `+0x1120`, every state of the run is `Good`, and memory outside the store window is as it was |
| `sha_whole` | **exp208's run and every step of it**: under exp208's own hypotheses for 4096 bytes, it halts with 0 after 4990 + 4873 · 64 instructions with the digest at `+0x1140`, and every state on the way is as `sha_reach` says |

## What is not proved, and what it rests on

- **The load window is the checker's, not the run's.** The run reads `[+0x1000, +0x3000)`; the checker proves
  `[+0x400, +0x3040)`, because joining the padding and message paths loses which one the run is on. For a box that
  is enough: both lie well inside it. It is not the run's exact footprint.
- **One length.** The checker knows the length word is 4096. Another length would need another constant, and
  another check.
- **The join with the front, and G5 for exp239.** That is round 3: exp248's front and this SHA-256 joined at the
  front's exit into one run of exp223's kernel, narrowed from exp223's 128 KiB world to the box, then exp247's
  bridge for exp239's monitor.
- **The model.** `Rv32.Machine`, the Tier 1 model: one hart, no interrupts, the region as Tier 1 checks it.

## The checks

1. `proof/Hash.lean` checks, every theorem it prints on Lean's own axioms.
2. **Eleven mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Five claims other than the run's**: a store window without the padding block; a load window without the
     message; the length not known; the length known a word on; a constant where the digest is written.
   - **Six checker rules made unsound**, each caught by the soundness proof it rests on:
     - an ordered comparison that narrows whatever the size;
     - a load of any size that reads a constant;
     - a store that need not miss the constants;
     - an arithmetic shift taken for a logical one;
     - a counter taken as pinned whatever its range;
     - a value that does not move when its second counter is stepped.
3. `suite/hash_reach.py`, on the emulator, a separate program from the model. SHA-256's run inside exp223's
   kernel, on exp222's eight healthy streams, every access recorded, offsets from SHA-256's base:
   - every access inside the windows, every `pc` one of its 252 instructions, its one call the HALT;
   - what the run touches, beside what the checker could prove;
   - every byte outside the store window as it was;
   - the digest, SHA-256 of the samples.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp249 — the words the hash touches ===
recorded at 2026-10-26T12:10:21Z from commit bc397ca

>>> the formal theorems, and what they rest on
'Exp249.accepted' depends on axioms: [propext, Quot.sound]
'Exp249.windows' depends on axioms: [propext, Quot.sound]
'Exp249.halts_only' depends on axioms: [propext, Quot.sound]
'Rv32.Reach.reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Reach.frame' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp249.sha_reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp249.sha_whole' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and a wrong checker: each must be refused
stores_short          claim: the stores stay below +0x1400, the padding block left out                              refused in windows
loads_short           claim: the loads stay below +0x2000, the message left out                                     refused in windows
length_unknown        the length word is not known to be a constant: the block count is not known                   refused in accepted
length_elsewhere      the constant is declared a word on, at +0x1124, not where the kernel reads the length         refused in accepted
constant_digest       claim: the digest's first word is a constant too, though the kernel writes it                 refused in accepted
cap_signed_any        an ordered comparison narrows a range whatever its size, where signed and unsigned disagree   refused in rel_cap
const_any_size        a load of any size that starts at a constant's offset reads the constant                      refused in lock_ld
store_over_constant   a store need not miss the constants                                                           refused in lock_st
srai_as_srli          an arithmetic shift right of a number is taken for a logical one                              refused in sh_ok
pinned_range          a counter is taken as pinned to its lowest value whatever its range                           refused in exactIdx_val
second_counter_still  stepping a value's second counter does not move the value                                     refused in regs_write

>>> SHA-256 inside exp223, on the emulator, every access recorded
PASS  SHA-256 inside exp223's kernel, on the 8 healthy streams of exp222, every access recorded,
      offsets from SHA-256's base: every load inside [+0x400, +0x3040), every store inside
      [+0x1140, +0x1440), every pc one of its 252 instructions, its one call the HALT with t0 = 1
      what the run touches: loads [0x1000, 0x3000) (26017 of them), stores [0x1140, 0x1440) (4741):
      the store window exactly; the loads inside the checker's wider bound
PASS  the frame: when SHA-256 halts, every byte of the box outside its store window is as it was when
      it began; and the digest at +0x1140 is SHA-256 of the 4096 sample bytes

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Hash.lean checks, with no errors and no warnings
PASS  all 7 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  stores_short: the proof refuses a version where claim: the stores stay below +0x1400, the padding block left out
PASS  loads_short: the proof refuses a version where claim: the loads stay below +0x2000, the message left out
PASS  length_unknown: the proof refuses a version where the length word is not known to be a constant: the block count is not known
PASS  length_elsewhere: the proof refuses a version where the constant is declared a word on, at +0x1124, not where the kernel reads the length
PASS  constant_digest: the proof refuses a version where claim: the digest's first word is a constant too, though the kernel writes it
PASS  cap_signed_any: the proof refuses a version where an ordered comparison narrows a range whatever its size, where signed and unsigned disagree
PASS  const_any_size: the proof refuses a version where a load of any size that starts at a constant's offset reads the constant
PASS  store_over_constant: the proof refuses a version where a store need not miss the constants
PASS  srai_as_srli: the proof refuses a version where an arithmetic shift right of a number is taken for a logical one
PASS  pinned_range: the proof refuses a version where a counter is taken as pinned to its lowest value whatever its range
PASS  second_counter_still: the proof refuses a version where stepping a value's second counter does not move the value
PASS  SHA-256 inside exp223's kernel, on the 8 healthy streams of exp222, every access recorded,
      offsets from SHA-256's base: every load inside [+0x400, +0x3040), every store inside
      [+0x1140, +0x1440), every pc one of its 252 instructions, its one call the HALT with t0 = 1
      what the run touches: loads [0x1000, 0x3000) (26017 of them), stores [0x1140, 0x1440) (4741):
      the store window exactly; the loads inside the checker's wider bound
PASS  the frame: when SHA-256 halts, every byte of the box outside its store window is as it was when
      it began; and the digest at +0x1140 is SHA-256 of the 4096 sample bytes
```
