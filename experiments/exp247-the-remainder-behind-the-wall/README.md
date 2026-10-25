# exp247 — the remainder behind the wall

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

[exp229](../exp229-the-remainder-the-kernel-keeps/) proved a kernel: secp256k1's field, add, subtract and multiply,
in RV32IM, from its first word in its own 64 KiB, as a Tier 1 theorem on `Rv32.Machine`.
[exp236](../exp236-the-wall-the-monitor-holds/) proved a monitor: it boots, boxes a payload behind one PMP entry and,
from the trap vector, parks, as a Tier 2 theorem on `PrivMachine`. exp236's own emulator cases already run exp229's
kernel as the payload. No theorem did. The audit called this seam G5: **a proved kernel on a proved monitor, with
nothing proved about the two together.**

This experiment proves it, in Lean 4, on Lean's own axioms, for that pair. The machine starts at reset, with exp236's
monitor at `0x80000000` and exp229's kernel at `0x80010000`, p at PRIME, the operation at OPW and `a, b < p` at A and
B. Then:

- **The kernel traps at step `53 + count op`.** Boot is 53 steps, and the kernel's `count op` instructions end with its
  HALT `ecall`. The machine is at the trap vector with cause 8, an `ecall` from U-mode, and R holds `spec op a b`.
- **The monitor parks 57 steps later**, in M-mode, with every register zero, `a0` included.
- **From reset to the park, the host hears exactly five words**: `HALT`, the exit code 0, `minstret` and `mcycle`
  (both `2 + count op`), then 0 at the exit word. Boot writes nothing.

One thing joins the two proofs that neither says: **the kernel makes no service call before its HALT.** Tier 1 would
serve HASH or SIG and run on. exp236 serves neither and reports a FAULT. That fact comes from the constant-time checker
exp229 already passes, so exp229's proof is not touched.

Needs: **no board** at all, and no USB anywhere in it. It has no firmware of its own: it is about exp229's `kernel.bin`
and exp236's `monitor.bin`, which their own `check.sh` hold to their own proofs. Nothing here ran on silicon or on
the RTL.

## How this was decided

The interrogation, as [the repository asks](../README.md#every-new-experiment-starts-with-an-interrogation), before any
of it was built:

1. **The facts.**
   - exp236's `cases/normal_cases.py` runs exp229's `kernel.bin` behind exp236's monitor on the emulator. It checks R,
     the exit code and the scrubbed registers, and only on the emulator.
   - exp229's `field` gives the count and the result. Its proof is 2,400 lines, outcome only: it says the run halts,
     not what happens on the way.
   - exp236's box is `[0x80010000, 0x80020000)`, exactly the 64 KiB `Placed` puts a kernel in. But exp236's theorems
     run in `env.region = monRegion`, which is wider.
2. **What was already answered.**
   - `lean/Rv32/Refinement.lean` relates U-mode steps to Tier 1 steps, for safe non-`ecall` instructions (`SafeUEpoch`).
   - `lean/Rv32/Within.lean` (exp223) says a run in a smaller region is the same run in a larger one.
   - `lean/Rv32/Ct.lean` checks exp229's kernel for constant time, and its `ecall` rule admits only HASH (`t0 = 0`)
     and HALT (`t0 = 1`).
   - The audit ([docs](../../docs/2026-10-23-1116-emulator-verdicts-vs-theorems-audit-zh-tw.md)) names G5's gap: an
     `ecall` is a shell service in Tier 1 and a trap in Tier 2.
3. **The contradictions.**
   - **The service calls.** `SafeUEpoch` needs every step to be a non-`ecall`, and `field` cannot give that: in
     Tier 1, an `ecall` with `t0 = 0`, 2 or 3 is a service and the run goes on. Something has to rule out every
     `ecall` but the last. `Ct`'s invariant holds at every step, and the checker knows `t0` at each of the kernel's
     three `ecall`s, so it can.
   - **The region.** The kernel's proof is about a world whose region is the box. The monitor's is about `monRegion`.
     `run_within` carries one to the other.
   - **Self-modifying code** needs nothing. With one RWX entry, a store into the code is the same store, and the same
     next fetch, in both tiers.
4. **What was decided without asking.**
   - No-service-call comes from the `Ct` checker, not from a second pass over exp229's proof.
   - The join is library code (`lean/Rv32/Join.lean`), since nothing in it is about this kernel or this monitor.
   - One generated file holds both proofs as their own `check.sh` holds them.
   - Boot's steps are run again for the ports and the counters, so that "what the host hears" starts at reset.
5. **What was asked**, and answered:
   - the monitor: exp236, one RWX entry;
   - the kernel: exp229, the field;
   - the conclusion: from reset to the park, with the words the host hears.

## What is proved

The library half, in `lean/Rv32/Ct.lean` and the new `lean/Rv32/Join.lean`, is about any kernel the constant-time
checker accepts, and any box with one RWX PMP entry:

| theorem | says |
| :--- | :--- |
| `Ct.lock_run` | `run_lock`'s relation holds at every step, not only at the end: after `n` steps both runs are at one accepted instruction, related, or ended alike |
| `Ct.ecalls_halt` | **a run's `ecall`s are HALTs.** For a program the checker accepts, every `ecall` of which it reaches knowing `t0 = 1` (`haltsOnly`, by `decide`): every state the run reaches is at a program instruction, with the program in memory, and at an `ecall` `t0` is 1 |
| `Join.safe_of_step` | a step Tier 1 took in the box's own region, not an `ecall`, is one Tier 2 takes as it is (`SafeUInstr`): aligned, in the box, plain, its load or store in the box |
| `Join.step_halted` | a Tier 1 step that halts is an `ecall` at `t0 = 1`, with the code in `a0` |
| `Join.ecall_trap` | a boxed U-mode `ecall` in the box traps, cause 8 |
| `Join.run_in_box` | **a Tier 1 run inside the box is the Tier 2 run**: the same core, still boxed, the monitor's CSRs kept, both counters up by `n`, no port touched, memory outside the box as it was |
| `Join.halt_in_box` | **a kernel's HALT, inside the box, is the trap the monitor is proved from**: `n + 1` steps reach the trap vector in M-mode, cause 8, with the kernel's registers and memory, `t0 = 1`, `a0` the code |
| `Join.quiet_of_ct` | `Ct.ecalls_halt` in the form the two above ask for |

And about this kernel and this monitor, in `proof/Wall.lean`:

| theorem | says |
| :--- | :--- |
| `ports_config`, `ports_launch_1`..`5`, `boot_ports` | **boot is silent**: exp236's 53 steps write no port, ask the host nothing, and leave `minstret` and `mcycle` at 2 |
| `halts_only` | every `ecall` the checker reaches in exp229's kernel, it reaches knowing `t0 = 1`, by `decide` |
| `placed` | the box is a world exp229's proof is about |
| `remainder_behind_the_wall` | **from reset**: the trap at `53 + count op`, cause 8, R holding `spec op a b`; the park 57 steps later, every register zero; and the host has heard exactly `heard op` |

`Wall.lean` is written by `proof/gen.py`. It holds exp229's `proof/Field.lean` and exp236's `proof/Monitor.lean`, each
in its own namespace, as their own `check.sh` holds them, then `proof/tail.lean`. `check.sh` fails if the file is not
what `gen.py` writes.

## What is not proved, and what it rests on

- **R at the park.** The theorem says R holds the remainder when the kernel traps, not when the monitor parks.
  exp236's handler theorems carry the monitor's own words and the M-mode stack, not the box. The emulator shows R is
  still there at the park, and that is all that does.
- **`mcycle` is the model's.** `PrivMachine` counts one cycle per step, so `mcycle` equals `minstret` here. On Hazard3
  it would not: a load, a branch or a multiply takes more than one cycle. The `minstret` word is the one a chip would
  match.
- **One kernel, one monitor.** The library half is general, but `Ct.ecalls_halt` covers only kernels that call
  nothing but HALT. A kernel that calls HASH or CHECKSIG needs a monitor that serves the call, and a proof that the
  served answer is Tier 1's. exp238's and exp239's kernels are of that kind. The emulator's G5 verdicts for them, and
  for exp240's rounds, are still verdicts and not theorems.
- **The model.** Everything exp236's README says: one hart, interrupts not modelled, the model's reading of Hazard3,
  the MMIO words as memory.

## The checks

1. `proof/Wall.lean` checks, every theorem it prints on Lean's own axioms.
2. **Twelve mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Nine claims other than the run's**: `minstret` one short; exit code 1; a word at boot; boot's counters at 1;
     the trap one step early; the park one step early; the remainder at B; the trap's cause an M-mode `ecall`; the
     kernel's world 128 KiB.
   - **The join's two supports, taken away in the library**: the checker letting a HASH through as well as a HALT, and
     a bridge step that may be an `ecall`.
   - **One rule of the model loosened**: a U-mode `ecall` that does not trap.
3. `proof/Wall.lean` is what `proof/gen.py` writes.
4. `suite/behind_the_wall.py`, on the emulator, a separate program from the model:
   - **the theorem's run**, for every edge pair of every operation and 60 drawn from a fixed seed: the trap step, the
     cause, R, the park step, the registers, and every word the host heard, against the theorem's numbers. The
     numbers are read from exp229's own `count`.
   - **a call the monitor would not serve**: the same kernel with `li t0, 0` before its add path's `ecall`. That is a
     HASH, which Tier 1 would serve. exp236 reports a FAULT and exits 1.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp247 — the remainder behind the wall ===
recorded at 2026-10-25T05:20:48Z from commit 3276fa9

>>> the formal theorems, and what they rest on
'Exp229.field' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp236.monitor_boot' depends on axioms: [propext, Quot.sound]
'Exp236.monitor_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Ct.ecalls_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.run_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.halt_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.quiet_of_ct' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp247.boot_ports' depends on axioms: [propext, Quot.sound]
'Exp247.halts_only' depends on axioms: [propext, Quot.sound]
'Exp247.remainder_behind_the_wall' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and wrong models: each must be refused
heard_instret_short    claim: the host hears minstret as 1 + count op, not 2 + count op     refused in remainder_behind_the_wall
heard_exit_one         claim: the exit word the host hears is 1                             refused in remainder_behind_the_wall
boot_heard             claim: boot's first part writes a word to the print port             refused in ports_config
counters_one           claim: boot leaves minstret at 1                                     refused in ports_launch_5
trap_one_step_early    claim: the kernel has trapped one step sooner                        refused in remainder_behind_the_wall
park_one_step_early    claim: the monitor parks one step sooner                             refused in remainder_behind_the_wall
result_in_b            claim: the remainder is at B, not at R                               refused in remainder_behind_the_wall
trap_cause_m           claim: the trap's cause is an ecall from M-mode                      refused in remainder_behind_the_wall
box_128k               claim: the kernel's world is 128 KiB, past the PMP entry             refused in placed
ct_lets_hash           the checker's haltsOnly lets a HASH through as well as a HALT        refused in haltsOnly_at
bridge_any_word        the bridge takes any step Tier 1 took inside the box, an ecall too   refused in safe_of_step
umode_ecall_untrapped  a U-mode ecall does not trap: Tier 2 runs it as Tier 1 does          refused in trap_none_plain

>>> the kernel behind the wall, on the emulator
PASS  1143 cases -- every edge pair of each operation, and 60 drawn from seed 247 -- run from reset
      on exp236's monitor with exp229's kernel as its payload, each as the theorem says:
      add  traps at step 384 (53 + 331) from the ecall at 0x8001067c, parks at step 441, heard HALT 0 333 333, exit 0
      sub  traps at step 291 (53 + 238) from the ecall at 0x80010724, parks at step 348, heard HALT 0 240 240, exit 0
      mul  traps at step 1956 (53 + 1903) from the ecall at 0x8001058c, parks at step 2013, heard HALT 0 1905 1905, exit 0
      R holds (a op b) mod p at the trap and still at the park; every register zero; one trap
PASS  a call it would not serve: add, with li t0, 0 before its ecall at 0x8001067c -- a HASH, which Tier 1
      would serve and run on. exp236 traps it (mcause 8), reports FAULT and exits 1: the kernel's own
      theorem would still hold, and the run behind the wall would not be its run

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Wall.lean checks, with no errors and no warnings
PASS  all 10 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  heard_instret_short: the proof refuses a version where claim: the host hears minstret as 1 + count op, not 2 + count op
PASS  heard_exit_one: the proof refuses a version where claim: the exit word the host hears is 1
PASS  boot_heard: the proof refuses a version where claim: boot's first part writes a word to the print port
PASS  counters_one: the proof refuses a version where claim: boot leaves minstret at 1
PASS  trap_one_step_early: the proof refuses a version where claim: the kernel has trapped one step sooner
PASS  park_one_step_early: the proof refuses a version where claim: the monitor parks one step sooner
PASS  result_in_b: the proof refuses a version where claim: the remainder is at B, not at R
PASS  trap_cause_m: the proof refuses a version where claim: the trap's cause is an ecall from M-mode
PASS  box_128k: the proof refuses a version where claim: the kernel's world is 128 KiB, past the PMP entry
PASS  ct_lets_hash: the proof refuses a version where the checker's haltsOnly lets a HASH through as well as a HALT
PASS  bridge_any_word: the proof refuses a version where the bridge takes any step Tier 1 took inside the box, an ecall too
PASS  umode_ecall_untrapped: the proof refuses a version where a U-mode ecall does not trap: Tier 2 runs it as Tier 1 does
PASS  proof/Wall.lean is what proof/gen.py writes, from exp229's Field.lean, exp236's Monitor.lean and tail.lean
PASS  1143 cases -- every edge pair of each operation, and 60 drawn from seed 247 -- run from reset
      on exp236's monitor with exp229's kernel as its payload, each as the theorem says:
      add  traps at step 384 (53 + 331) from the ecall at 0x8001067c, parks at step 441, heard HALT 0 333 333, exit 0
      sub  traps at step 291 (53 + 238) from the ecall at 0x80010724, parks at step 348, heard HALT 0 240 240, exit 0
      mul  traps at step 1956 (53 + 1903) from the ecall at 0x8001058c, parks at step 2013, heard HALT 0 1905 1905, exit 0
      R holds (a op b) mod p at the trap and still at the park; every register zero; one trap
PASS  a call it would not serve: add, with li t0, 0 before its ecall at 0x8001067c -- a HASH, which Tier 1
      would serve and run on. exp236 traps it (mcause 8), reports FAULT and exits 1: the kernel's own
      theorem would still hold, and the run behind the wall would not be its run
```
