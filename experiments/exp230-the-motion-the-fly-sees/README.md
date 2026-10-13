# exp230 — the motion the fly sees

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A Hassenstein–Reichardt motion detector — the classic model of how a fly
sees motion — on exp225's ring of 32 cells, one bit a cell, in 41 RV32IM
instructions. Lean proves that the kernel computes the detector exactly, for
any frames, in exactly 70924 instructions (T1); that a frame moved one cell is
seen moving its way, unless it has period two, when no detector of this kind
could tell (T2); and that whatever the ring holds, the fly watching one
generation of Rule 30 sees it move up or not at all — never down (T3). So the
kernel shown exp225's life reports up at least down, at every step.**

Needs: **no board**. Plan C of exp225's
[NEXT.zh-TW.md](../exp225-the-life-every-beat-proved/NEXT.zh-TW.md), where T3
was a conjecture checked on 200,000 rings. A plain-language account is in
[WHY.zh-TW.md](./WHY.zh-TW.md).

## The detector

Two neighbouring receptors; the signal of one is delayed and multiplied by
the other's; the same the other way round; the difference is the direction.
With one bit a cell, multiplying is AND, and the delay is the frame before:

```
up   = popcount(rotl(before, 1) & now)    lit now, and lit one cell below before
down = popcount(rotr(before, 1) & now)    lit now, and lit one cell above before
```

"Up" is toward the higher bit, which exp225's Rule 30 calls left.

## The kernel

`kernel.py` writes it from labels into `proof/Fly.lean`. RV32IM has no rotate
(two shifts and an OR) and no popcount (one loop of 32 rounds counts both
words a bit at a time). The frames are what the fly sees, so nothing needs to
be hidden: unlike exp229 there is no constant-time claim.

```
0x0000  the kernel, 41 instructions
0x0100  UP     the total moved up
0x0104  DOWN   the total moved down
0x0200  the frames, 257 words: frame t at 0x200 + 4t
0x0800  the steps, 256: step t's up at 0x800 + 8t, its down at + 4
```

7 instructions to set up, 277 a step, 5 to finish: 70924, whatever the
frames. On the RTL, 70927 instructions retired and 71697 cycles, every case.

## The proof

`proof/Fly.lean`, on Lean's own axioms only:

- **T1, `detects`** (and `detects_boot`, from any image that begins with the
  kernel): after 70923 instructions the kernel is at its `ecall`, the next
  halts with 0, and memory holds `toUp` and `toDn` of every step, their
  totals, and the frames as they were.
- **T2, `shift_up` and `shift_dn`**: a frame `x` moved one cell up is seen
  moving up — `toDn x (up1 x) < toUp x (up1 x)` — provided `x` moved two cells
  is not `x` itself. That leaves out exactly four rings: 0, all ones,
  0x55555555 and 0xAAAAAAAA. A stripe of period two moved one cell up is the
  same as moved one cell down; the detector is right to see no direction.
- **T3, `life_moves_up`**: for every ring `x`, `toDn x (life x) ≤ toUp x (life x)`.
  Under Rule 30 what moved up is the cells whose lower neighbour was lit and
  upper neighbour dark; what moved down is a part of the cells whose upper
  neighbour was lit and lower dark. Round a ring the two kinds of cell are
  equally many, so up is at least down.
- **`watches_life`**: frames that are generations of Rule 30 — the kernel
  reports up at least down at every one of the 256 steps, and in total.
  **`watches_shift`**: frames each moved up a cell from the one before, none
  of period two — every step is seen moving up, strictly.

`up1`, `dn1`, the popcount `pc` and its lemmas, `pc_up1` among them, were
written here; when exp232 needed them second they moved to
[`lean/Rv32/Ring.lean`](../../lean/Rv32/Ring.lean). `Fly.lean` imports them
from there, and its kernel and mutants are what they were.

`run.sh` also counts T3 apart from the proof, over all 2^32 rings with Rule 30
written cell by cell: none is seen moving down, 4,870,848 are seen not moving.

`proof/mutants.txt` holds seven wrong versions, each refused: a bit loop of 31
rounds, a shift where the rotation should be, the down total adding the up
count, the rule mirrored (Rule 86, which the fly sees moving down), T3 claimed
strictly, T2 claimed for the period-two stripes, and a count one short.

## What the experiment found

- T3 was a conjecture with an argument in exp225's NEXT.zh-TW.md; the
  argument went into Lean almost as written: three lemmas about counting bits
  (a rotation keeps the count; a word's bits split by another word; an AND
  never counts more) and two identities about Rule 30, each checked bit by
  bit.
- T2 as first stated — "a moving stripe is seen moving its way" — is false for
  four rings. Writing the proof is what asked which.
- Of 257 Rule 30 frames from exp225's seed, the fly sees 255 steps move up and
  one not move; in total 2053 up and 1030 down.

The shared library gained what this proof and exp229's both needed:
`count_down`, `ofNat_ne_zero` and `not_mem_of` in `lean/Rv32/Flow.lean`, and
`code_write` in `lean/Rv32/Limbs.lean`; and `imm_off`, of which
`lean/Rv32/Sha.lean` had kept its own copy, is now in `Blocks.lean` once.

## Running it

```sh
./check.sh        # the proof, the mutants, kernel.bin, the differential
./run.sh          # the same, T3 counted over all 2^32 rings, into capture.txt
```

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp230 — the motion the fly sees ===
recorded at 2026-10-13T05:46:20Z from commit c40873e

>>> the theorems, and what they rest on
'Exp230.life_moves_up' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.shift_up' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.shift_dn' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.bits' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.step_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.detects' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.detects_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.watches_life' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp230.watches_shift' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
rounds31       the bit loop runs 31 rounds: the top cell is never counted                                                               refused in step_run
not_round      the move up loses the top cell instead of bringing it round to the bottom: a shift, not a rotation                       refused in step_run
total_crossed  the down total adds the up count                                                                                         refused in step_run
mirror_life    the rule is mirrored, cell i taking cell i - 1 where Rule 30 takes cell i + 1: Rule 86, which the fly sees moving down   refused in up_life
always_up      the claim that the fly sees Rule 30 move up strictly, every step: 4,870,848 rings it sees not move                       refused in life_moves_up
no_alias       the claim that any frame moved up is seen moving up, the stripes of period two included                                  refused in shift_up
count_short    the kernel is claimed to halt one instruction sooner than it does                                                        refused in setup_run

>>> T3 by brute force, apart from the proof: every one of the 2^32 rings, one generation of Rule 30
PASS  all 4294967296 rings: 0 seen moving down, 4870848 not moving, 4290096448 moving up
PASS  rings that moved two cells are themselves: 4 — 00000000 55555555 aaaaaaaa ffffffff

>>> the model and the RTL against fly.py: the named stimuli, then 200 random
      life 0x00010000    up  2053  down  1030  up   steps: 255 up, 1 not moving, 0 down
      life 0x00000001    up  2053  down  1030  up   steps: 255 up, 1 not moving, 0 down
      life 0x8001a5c3    up  2080  down  1035  up   steps: 256 up, 0 not moving, 0 down
      stripe up          up  1024  down   512  up   steps: 256 up, 0 not moving, 0 down
      stripe down        up   512  down  1024  down   steps: 0 up, 0 not moving, 256 down
      period 2, up       up  4096  down  4096  no way   steps: 0 up, 256 not moving, 0 down
      flicker            up   768  down   768  no way   steps: 0 up, 256 not moving, 0 down
      still              up  1280  down  1280  no way   steps: 0 up, 256 not moving, 0 down
      dark               up     0  down     0  no way   steps: 0 up, 256 not moving, 0 down
PASS  209 stimuli on the model, the first 12 on the RTL too: each halts with 0 and leaves every step's counts and the totals fly.py computes — 0 wrong
PASS  one count whatever the frames: model ['70924']; RTL ['instret=70927 cycles=71697']

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Fly.lean checks, with no errors and no warnings
PASS  all 9 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  rounds31: the proof refuses a version where the bit loop runs 31 rounds: the top cell is never counted
PASS  not_round: the proof refuses a version where the move up loses the top cell instead of bringing it round to the bottom: a shift, not a rotation
PASS  total_crossed: the proof refuses a version where the down total adds the up count
PASS  mirror_life: the proof refuses a version where the rule is mirrored, cell i taking cell i - 1 where Rule 30 takes cell i + 1: Rule 86, which the fly sees moving down
PASS  always_up: the proof refuses a version where the claim that the fly sees Rule 30 move up strictly, every step: 4,870,848 rings it sees not move
PASS  no_alias: the proof refuses a version where the claim that any frame moved up is seen moving up, the stripes of period two included
PASS  count_short: the proof refuses a version where the kernel is claimed to halt one instruction sooner than it does
PASS  proof/Fly.lean's kernel is what kernel.py writes from its labels
PASS  kernel.bin is what proof/Fly.lean writes, 164 bytes, and kernel.sha256 is its hash
      life 0x00010000    up  2053  down  1030  up   steps: 255 up, 1 not moving, 0 down
      life 0x00000001    up  2053  down  1030  up   steps: 255 up, 1 not moving, 0 down
      life 0x8001a5c3    up  2080  down  1035  up   steps: 256 up, 0 not moving, 0 down
      stripe up          up  1024  down   512  up   steps: 256 up, 0 not moving, 0 down
      stripe down        up   512  down  1024  down   steps: 0 up, 0 not moving, 256 down
      period 2, up       up  4096  down  4096  no way   steps: 0 up, 256 not moving, 0 down
      flicker            up   768  down   768  no way   steps: 0 up, 256 not moving, 0 down
      still              up  1280  down  1280  no way   steps: 0 up, 256 not moving, 0 down
      dark               up     0  down     0  no way   steps: 0 up, 256 not moving, 0 down
PASS  29 stimuli on the model, the first 12 on the RTL too: each halts with 0 and leaves every step's counts and the totals fly.py computes — 0 wrong
PASS  one count whatever the frames: model ['70924']; RTL ['instret=70927 cycles=71697']
```
