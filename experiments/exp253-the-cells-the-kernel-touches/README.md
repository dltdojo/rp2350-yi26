# exp253 — the cells the kernel touches

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The first of three rounds toward [exp225](../exp225-the-life-every-beat-proved/)'s Rule 30 kernel behind
[exp240](../exp240-the-code-the-box-forbids-writing/)'s monitor, round after round. exp240 boxes its payload so that no
byte is both writable and runnable:

- a 128-byte code entry, read and execute;
- a 4 KiB data entry, read and write, with the code carved out of it;
- a stack entry;
- a guard that matches nothing.

exp225 proved how its kernel's run ends, in a 64 KiB region: from any seed, HALT 0 after exactly 3079 instructions,
with generations 1 to 256 of Rule 30 at `+0x200`. A Tier 1 step that went on in that region says nothing of whether
exp240's PMP lets it through. A store into the code is legal there, and so is a fetch from the data. The box needs
every step.

In Lean 4, on Lean's own axioms, from the kernel's first word, wherever it is `Hosted`:

- **Every fetch is one of its 19 instructions**, the 76 bytes from `base`.
- **Every load is the seed**, the word at `[base + 0x100, base + 0x104)`.
- **Every store is a cell of the history**, inside `[base + 0x200, base + 0x600)`. Memory outside it is as it was.
- **The only call is HALT**, with `t0 = 1`.
- **With exp225's own theorem**, the whole run: HALT 0 after 3079 instructions with Rule 30's history, and every
  state on the way as above.

Needs: **no board** at all, and no USB anywhere in it. No firmware of its own: the kernel is exp225's, held by
exp225's `check.sh`. Nothing here ran on silicon or on the RTL.

## How this was decided

1. **The facts.**
   - exp240's README says it plainly: the kernel's correctness is not joined to the monitor's proof. That the kernel
     runs in the W^X box without touching a PMP rule is checked on the emulator, a hundred rounds.
   - exp225's `lives` is a Tier 1 theorem, about where the run ends.
2. **What was already answered.**
   - lean/Rv32/Ct.lean's checker, and lean/Rv32/Reach.lean's reading of it (`reach`, `frame`), which exp248 and exp249
     used for exp223.
3. **The contradictions.**
   - None in the checker, this time. The kernel is one loop with one pointer affine in one counter, the kind of program
     the checker was first written for, and it is accepted as it stands.
   - The question is not whether the kernel is correct, which exp225 answered, but where it goes.
4. **What was decided without asking.**
   - One loop head, at instruction 4: `t1 = base + 0x600 - 4 · t2`, with `t2` the generations to go, 1 to 256.
   - Every place public: for one run nothing is secret.
5. **What was asked**, and answered:
   - the next pair: exp240 with exp225, including any number of rounds;
   - three rounds, each merged on its own. This is the first.

## What is proved

In `proof/Cells.lean`:

| theorem | says |
| :--- | :--- |
| `accepted`, `windows`, `halts_only` | the kernel through the checker, by `decide`: one loop head, loads in the seed, stores in the history, every `ecall` at `t0 = 1` |
| `life_reach` | **every step**: from the kernel's first word, wherever `Hosted`, every state of the run is `Good` -- at one of the 19 instructions, the kernel in memory, a load only of the seed, a store only into the history, an `ecall` only with `t0 = 1` |
| `life_whole` | **exp225's run and every step of it**: in its own 64 KiB, HALT 0 after 3079 instructions with the history Rule 30's, every state on the way `Good`, and memory outside the history as it was |

`Cells.lean` is written by `proof/gen.py`: exp225's `proof/Life.lean` as exp225's `check.sh` holds it, then
`proof/tail.lean`.

## What is not proved, and what it rests on

- **The join with exp240's monitor.** That is round 2: a Tier 1 step the checker vouches for, in exp240's W^X box, as
  the Tier 2 step. The fetches here are in the code entry, the loads in the data, the stores in the data and outside
  the code, so every one of them is one exp240's PMP lets through. Then the round from reset to the park.
- **Rounds.** Round 3: any number of rounds, with the host's writes between them.
- **The model.** `Rv32.Machine`, the Tier 1 model: one hart, no interrupts, the region as Tier 1 checks it.

## The checks

1. `proof/Cells.lean` checks, every theorem it prints on Lean's own axioms.
2. **Five mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Four claims other than the kernel's**:
     - a history a word short;
     - no load at all;
     - a loop head admitting one generation too many, so the pointer may be one word below the history;
     - a pointer a word on.
   - **The checker made unsound**: a load window that is not checked. exp248's mutants already loosen the store
     window and the jumps.
3. `proof/Cells.lean` is what `proof/gen.py` writes.
4. `suite/cells.py`, on the emulator, a separate program from the model. exp225's kernel runs alone in a box of junk,
   with exp248's recorder, on 104 seeds: 0, 1, one live cell, all ones, and 100 drawn from a fixed seed. For each:
   - every pc is one of the 19 instructions, and all 19 are reached;
   - the one load is the seed;
   - 256 stores, each history word once;
   - one call, HALT 0, after 3079 instructions;
   - the history is rule30.py's, and every other byte of the box as it was.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp253 — the cells the kernel touches ===
recorded at 2026-10-27T07:17:52Z from commit 5cc5f56

>>> the formal theorems, and what they rest on
'Exp253.accepted' depends on axioms: [propext, Quot.sound]
'Exp253.windows' depends on axioms: [propext, Quot.sound]
'Exp253.halts_only' depends on axioms: [propext, Quot.sound]
'Rv32.Reach.reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Reach.frame' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp253.life_reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp253.life_whole' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and a wrong checker: each must be refused
history_short         claim: the kernel stores only up to +0x5fc, one word short of the history                                   refused in windows
no_load               claim: the kernel loads nothing, not even the seed                                                          refused in windows
head_count_257        claim: at the loop's head 1 to 257 generations are left, so the pointer may be one word below the history   refused in windows
head_pointer_word_on  claim: at the loop's head the pointer is a word further on                                                  refused in accepted
load_unchecked        the load window is not checked at all                                                                       refused in windowed_ld

>>> exp225 alone on the emulator, every access recorded
PASS  104 seeds -- 0, 1, one live cell, all ones, and 100 from seed 253 -- exp225's kernel alone in a box
      of junk, every access recorded: every pc one of its 19 instructions, all reached; one load, the seed at
      +0x100; 256 stores, each history word in [+0x200, +0x600) once; one call, HALT 0 with t0 = 1, after 3079;
      the history rule30.py's, every other byte of the box as it was

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Cells.lean checks, with no errors and no warnings
PASS  all 7 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  history_short: the proof refuses a version where claim: the kernel stores only up to +0x5fc, one word short of the history
PASS  no_load: the proof refuses a version where claim: the kernel loads nothing, not even the seed
PASS  head_count_257: the proof refuses a version where claim: at the loop's head 1 to 257 generations are left, so the pointer may be one word below the history
PASS  head_pointer_word_on: the proof refuses a version where claim: at the loop's head the pointer is a word further on
PASS  load_unchecked: the proof refuses a version where the load window is not checked at all
PASS  proof/Cells.lean is what proof/gen.py writes, from exp225's Life.lean and tail.lean
PASS  104 seeds -- 0, 1, one live cell, all ones, and 100 from seed 253 -- exp225's kernel alone in a box
      of junk, every access recorded: every pc one of its 19 instructions, all reached; one load, the seed at
      +0x100; 256 stores, each history word in [+0x200, +0x600) once; one call, HALT 0 with t0 = 1, after 3079;
      the history rule30.py's, every other byte of the box as it was
```
