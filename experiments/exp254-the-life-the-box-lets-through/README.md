# exp254 — the life the box lets through

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The second of three rounds toward [exp225](../exp225-the-life-every-beat-proved/)'s Rule 30 kernel behind
[exp240](../exp240-the-code-the-box-forbids-writing/)'s monitor, round after round.

exp240's monitor boxes its payload so that no byte is both writable and runnable:

- a 128-byte code entry, read and execute;
- a 4 KiB data entry, read and write, with the code carved out of it;
- a stack entry;
- the rest of the 64 KiB a guard.

exp240 proved that the monitor boots, runs whatever the payload is up to its first trap, and parks. It proved nothing
of what exp225's kernel does there: that was checked on the emulator. [exp253](../exp253-the-cells-the-kernel-touches/)
proved where every step of exp225's run fetches, loads and stores. This round joins the three.

In Lean 4, on Lean's own axioms. The machine is at reset, or has any CSRs that lock no PMP entry. exp240's monitor is
at `0x80000000` and exp225's kernel at `0x80010000`; the seed, at `0x80010100`, is any word. Then:

- **Every step of the kernel is one the box lets through.** The fetch is in the code entry. The load is in the data
  entry, past the code. Each store is in the data entry, outside the code. So the kernel's 3079 steps are the Tier 2
  steps one for one.
- **After exactly 61 + 3079 + 57 steps the monitor is parked with HALT 0**, and every register is zero.
- **Memory is exp225's `lived`**, but for the monitor's stack and report words. The 1024 bytes from `0x80010200` are
  generations 1 to 256 of Rule 30 from the seed. Every other byte is as it was.
- **The host has heard the HALT report**: the tag, `a0 = 0`, 3081 instructions and 3081 cycles, then 0 at the exit
  word. Nothing came before.

Needs: **no board** at all, and no USB anywhere in it. There is no firmware of its own. It is about exp225's
`kernel.bin` and exp240's `monitor.bin`, which their own `check.sh` hold to their own proofs. Nothing here ran on
silicon or on the RTL.

## How this was decided

1. **The facts.**
   - exp240's `monitor_boot`: from reset, 61 steps leave the machine W^X-boxed at `0x80010000`, with the CSRs
     `csrsBooted` and memory untouched.
   - exp240's `monitor_traps`: from the trap vector, whatever trapped, the monitor parks.
   - exp225's `to_the_ecall`: 3078 instructions, then the `ecall` that halts with 0 and the history.
   - exp253's `life_whole`: every state of that run is `Good`, at one of the 19 instructions, its load the seed and
     its store a cell of the history.
2. **What was already answered.**
   - lean/Rv32/Join.lean's `run_in_box` and `halt_in_box`: a Tier 1 run in a box is the Tier 2 run. exp247 and exp250
     joined their kernels with these.
   - lean/Rv32/WxBox.lean's `wx_check`: what the three entries make of any access.
3. **The contradictions.**
   - **`run_in_box` is for one RWX entry.** In a box of one entry, any access inside the region passes. In exp240's
     box an access inside the region may not: a store into the code is refused, and so is a fetch from the data, or
     anything in the guard. So the bridge needs to know of each step where it touches, not only that it stays in the
     region.
   - **A load that straddles the code's edge is refused**, though each of its bytes is in the code or the data. The
     first entry that touches an access decides. So what a load may touch is wholly the code, or wholly outside it and
     in the data or the stack (`WxReadable`).
4. **What was decided without asking.**
   - **The bridge takes one fact per step, `WxOk`**: the fetch in the code, a load `WxReadable`, a store `WxWritable`.
     `wxOk_of_good` gets it from `Reach.Good` and three facts about where the program and its two windows lie.
   - **The cores are the same.** exp240's monitor serves no call but HALT, so nothing writes outside the box before the
     trap. Unlike exp252, `BoxEq` is not needed.
   - **The counters are stated.** Boot leaves 2 and the kernel adds 3079, so the report is 3081; exp240's suite
     checks the same number.
5. **What was asked**, and answered:
   - the next pair: exp240 with exp225, including any number of rounds;
   - three rounds, each merged on its own. This is the second.

## What is proved

In the library:

| | says |
| :--- | :--- |
| `WxBox.WxWritable`, `WxReadable` | what a store and a load may touch in a W^X box |
| `WxBox.wx_store_allowed`, `wx_load_allowed` | every such store and load passes the PMP |
| `Join.WxOk` | what a W^X box asks of one step: the fetch in the code, a load readable, a store writable |
| `Join.wx_plain` | **a Tier 1 step the box lets through is one Tier 2 step**: the same core, the counters bumped, nothing else changed |
| `Join.wx_ecall_trap` | an `ecall` in the code traps, cause 8 |
| `Join.wx_run_in_box`, `wx_halt_in_box` | `run_in_box` and `halt_in_box` for a W^X box: a Tier 1 run every step of which the box lets through is the Tier 2 run, and its HALT the trap |
| `Join.wxOk_of_good` | a `Good` state of a kernel whose code, load window and store window lie where the box allows takes a step it lets through |

And about this kernel and this monitor, in `proof/Box.lean`:

| theorem | says |
| :--- | :--- |
| `wx_ok` | every step exp253 vouches for is one exp240's box lets through |
| `life_traps` | **the payload's run, to its trap**: from where boot leaves the machine, 3079 Tier 2 steps, U-mode before the last; at the trap vector, cause 8, `t0 = 1`, `a0 = 0`, both counters 3081, memory exp225's `lived` |
| `life_behind_the_box` | **from reset**: after 61 + 3079 + 57 steps, parked with HALT 0, memory `lived` but for the monitor's stack and report words, and the host has heard HALT, 0, 3081, 3081, then 0 |

`Box.lean` is written by `proof/gen.py`. It holds exp240's `proof/Wx.lean`, exp225's `proof/Life.lean` and exp253's
`proof/tail.lean`, as their own `check.sh` hold them, then `proof/tail.lean`. `check.sh` fails if the file is not what
`gen.py` writes.

## What is not proved, and what it rests on

- **Rounds.** That is round 3, [exp255](../exp255-the-lives-round-after-round/): any number of rounds, with the host
  writing the next seed between them, each round's history Rule 30 of its seed. `life_traps` starts from where boot
  leaves the machine, and exp240's `monitor_reentry` says every round's boot leaves it there.
- **`mcycle` is the model's**, as exp247 says. On Hazard3 a cycle is not an instruction.
- **The model.** Everything exp240's README says: one hart, interrupts not modelled, the model's reading of Hazard3,
  the MMIO words as memory.

## The checks

1. `proof/Box.lean` checks, every theorem it prints on Lean's own axioms.
2. **Seven mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Five claims other than the run's**:
     - the park a step sooner;
     - the trap a step sooner;
     - U-mode at the trap too;
     - memory at the park with no history;
     - the host hearing 3080 instructions.
   - **The bridge loosened**:
     - a store into the code taken as one the box lets through;
     - a fetch from anywhere taken as one the box lets through.

     Each is refused where the PMP is asked about it.
3. `proof/Box.lean` is what `proof/gen.py` writes.
4. `suite/life.py`, on the emulator, a separate program from the model. It uses 104 seeds: 0, 1, one live cell, all
   ones, and 100 drawn from a fixed seed. Each runs in 256 KiB of junk as exp240's payload, from reset; every other one
   starts from a reset that leaves junk in the CSRs. Each must:
   - first reach the park word at step 61 + 3079 + 57;
   - be in U-mode from step 61 to the trap, with one trap, the `ecall`;
   - park in M-mode, every register zero, exit 0;
   - print the words HALT, 0, 3081, 3081;
   - leave rule30.py's history at `+0x200`, and every other byte as it was but the monitor's 16 stack bytes.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp254 — the life the box lets through ===
recorded at 2026-10-27T07:55:16Z from commit 8a0c6e8

>>> the formal theorems, and what they rest on
'Exp240.monitor_boot' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp240.monitor_traps' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp225.to_the_ecall' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp253.life_whole' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.wx_plain' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.wx_run_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.wx_halt_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.wxOk_of_good' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp254.wx_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp254.life_traps' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp254.life_behind_the_box' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and a wrong bridge: each must be refused
park_one_sooner  claim: the monitor parks one step sooner, after 61 + 3079 + 56             refused in life_behind_the_box
trap_one_sooner  claim: the kernel's run traps after 3078 Tier 2 steps, not 3079            refused in life_traps
user_at_trap     claim: the machine is still in U-mode after the trap                       refused in life_traps
no_history       claim: memory at the park is what it was at reset, with no history in it   refused in life_behind_the_box
heard_3080       claim: the host hears 3080 instructions, not 3081                          refused in life_behind_the_box
store_into_code  a store into the code is taken as one the box lets through                 refused in wx_store_allowed
fetch_anywhere   a fetch from anywhere is taken as one the box lets through                 refused in wx_plain

>>> exp225 behind exp240 on the emulator, from reset to the park
PASS  104 seeds -- 0, 1, one live cell, all ones, and 100 from seed 254 -- exp225's kernel as exp240's
      payload in 256 KiB of junk, from reset, every other one from a reset that leaves junk in the CSRs:
      each first at the park word at step 61 + 3079 + 57, in U-mode from step 61 to the trap, one trap,
      the ecall; parked in M-mode, every register zero, exit 0; the print words HALT, 0, 3081, 3081;
      memory rule30.py's history at +0x200 and every other byte as it was, but the monitor's 16 stack bytes

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Box.lean checks, with no errors and no warnings
PASS  all 11 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  park_one_sooner: the proof refuses a version where claim: the monitor parks one step sooner, after 61 + 3079 + 56
PASS  trap_one_sooner: the proof refuses a version where claim: the kernel's run traps after 3078 Tier 2 steps, not 3079
PASS  user_at_trap: the proof refuses a version where claim: the machine is still in U-mode after the trap
PASS  no_history: the proof refuses a version where claim: memory at the park is what it was at reset, with no history in it
PASS  heard_3080: the proof refuses a version where claim: the host hears 3080 instructions, not 3081
PASS  store_into_code: the proof refuses a version where a store into the code is taken as one the box lets through
PASS  fetch_anywhere: the proof refuses a version where a fetch from anywhere is taken as one the box lets through
PASS  proof/Box.lean is what proof/gen.py writes, from exp240's Wx.lean, exp225's Life.lean, exp253's tail and tail.lean
PASS  104 seeds -- 0, 1, one live cell, all ones, and 100 from seed 254 -- exp225's kernel as exp240's
      payload in 256 KiB of junk, from reset, every other one from a reset that leaves junk in the CSRs:
      each first at the park word at step 61 + 3079 + 57, in U-mode from step 61 to the trap, one trap,
      the ecall; parked in M-mode, every register zero, exit 0; the print words HALT, 0, 3081, 3081;
      memory rule30.py's history at +0x200 and every other byte as it was, but the monitor's 16 stack bytes
```
