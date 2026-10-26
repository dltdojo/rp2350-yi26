# exp250 — the digest the wall keeps

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The last of three rounds. [exp223](../exp223-the-digest-the-kernel-withholds/) proved a kernel: SP 800-90B's two
health tests over 1024 samples, then SHA-256 of them, or HALT 1 and nothing written.
[exp239](../exp239-the-scratch-the-monitor-scrubs/) proved a monitor: it boots, boxes a payload behind one PMP entry
and, from the trap vector, parks with the payload's confidential scratch zeroed, and its digest window too unless the
exit code is 0. exp239's own emulator cases run exp223's kernel as the payload. No theorem did: this is the audit's
G5 for its second pair, after [exp247](../exp247-the-remainder-behind-the-wall/) closed it for the first.

[exp248](../exp248-the-samples-the-front-reads/) and [exp249](../exp249-the-words-the-hash-touches/) built what this
pair needed and exp247's did not: facts about every step of exp223's run. This round joins them. In Lean 4, on Lean's
own axioms, the machine at reset with exp239's monitor at `0x80000000` and exp223's kernel at `0x80010000`, K, IV and
the length 4096 in its data:

- **Healthy samples:** the kernel traps after boot and `j + 1` steps, `j < 334284`, at the trap vector with cause 8,
  an `ecall` from U-mode, with SHA-256 of the samples at `+0x2140`. The monitor parks with exit code 0, **the digest
  still there**, the confidential scratch `[+0x2200, +0x4000)` zero.
- **Unhealthy samples:** the trap after `j + 1` steps, `j < 17425`, and the park with exit code 1, **the scratch and
  the digest window both zero**, every other byte but the monitor's stack and its port words as it was at reset.
- **Both:** from reset to the park, the host hears exactly five words: `HALT`, the exit code, `minstret` and `mcycle`
  (both `3 + j`), then the exit code at the exit word. Boot writes nothing.

Needs: **no board** at all, and no USB anywhere in it. It has no firmware of its own: it is about exp223's
`kernel.bin` and exp239's `monitor.bin`, which their own `check.sh` hold to their own proofs. Nothing here ran on
silicon or on the RTL.

## How this was decided

The interrogation, as [the repository asks](../README.md#every-new-experiment-starts-with-an-interrogation), before any
of it was built:

1. **The facts.**
   - exp239's `suite/kernel_cases.py` runs exp223's kernel under the monitor and alone, on exp222's fourteen streams:
     exit codes, instruction counts, the digest and the scrub, on the emulator only.
   - exp223's `conditions` is in `Wide`, a 128 KiB world from the kernel's base. exp239's box is 64 KiB.
   - exp248's `front_reach` and exp249's `sha_reach` say what every step reads, writes and calls, in the box.
   - exp239's monitor serves only HALT.
2. **What was already answered.**
   - exp247's `lean/Rv32/Join.lean`: a Tier 1 run in the box is the Tier 2 run (`run_in_box`), and its HALT is the
     trap the monitor is proved from (`halt_in_box`), given that every `ecall` is at `t0 = 1`.
   - exp247's boot lemmas: boot writes no port and leaves both counters at 2. exp239's boot is the same 53 steps.
   - `lean/Rv32/Within.lean`'s `run_within`, which carries a run to a **larger** region.
3. **The contradictions.**
   - **The region goes the wrong way.** exp223's theorem is about 128 KiB, the box is 64. `run_within` only widens.
     A run narrows only if no step asks for anything outside the box, and that is what exp248 and exp249 prove.
   - **The step count.** exp223 says the run has halted after 334284 steps (17425 unhealthy); `halt_in_box` asks for
     the step the HALT is. A run that has halted halted at one step before, so the theorem says `j < 334284`. The
     emulator says `j + 1` is the count exactly.
   - **No call but HALT.** exp247 took it from `Ct.ecalls_halt`, one program's. Here there are two, and the fact comes
     from the reach checker's `Good` instead.
   - **Boot's lemmas would be a second copy** of exp247's. The second copy is the moment to extract.
4. **What was decided without asking.**
   - The narrowing is library code, in `lean/Rv32/Reach.lean`: `step_same`, a `Good` step whose windows lie in the
     box is the same step in any region holding it, and `run_same`, a run of such steps is the same run.
     `run_halt_step` finds the halting step.
   - Boot's lemmas move to `tools/monitor/boot_ports.lean`. exp247's `gen.py` now splices them in, and its
     `Wall.lean` is the same bytes as before.
   - One generated file holds exp223's, exp248's, exp249's and exp239's proofs, each in its own namespace, as their
     own `check.sh` hold them.
   - The unhealthy case states memory against reset, because exp223's run writes nothing.
5. **What was asked**, and answered:
   - the pair: exp239 with exp223;
   - how to close its gaps: a general reach checker;
   - once its cost was known: three rounds, each merged on its own. This is the third.

## What is proved

In the library:

| | says |
| :--- | :--- |
| `Reach.WinIn`, `Reach.step_same` | **a `Good` step is the same step in a wider region**: its fetch, its load or store inside windows that lie in the box, and an `ecall` at `t0 = 1`, which neither region is asked about |
| `Reach.run_same` | a run whose every state, before the `n`-th, is one the two regions step alike, is the same run |
| `Reach.run_halt_step` | a run halted after `N` steps halted at one step `j + 1 ≤ N`, running before it |
| `Join.quiet_of_good` | a `Good` state at an `ecall` has `t0 = 1`: `halt_in_box`'s hypothesis, from the reach checker |

And about this kernel and this monitor, in `proof/Wall.lean`:

| theorem | says |
| :--- | :--- |
| `ports_config`, `ports_launch_1`..`5`, `boot_ports` | **boot is silent**: exp239's 53 steps write no port, ask the host nothing, and leave `minstret` and `mcycle` at 2. From `tools/monitor/boot_ports.lean`, shared with exp247 |
| `kernel_reach` | **every step of exp223's kernel, in the box**: the front's, as exp248 checked it, until the run reaches SHA-256; SHA-256's, as exp249 did, after |
| `kernel_same` | **the run exp223 proved is the run in the box**: in the 128 KiB world and in the box, the same outcome after any number of steps |
| `behind` | whatever exp223's run ends with: the trap after `j + 1` steps at the trap vector, cause 8, memory as the HALT left it; the park with that exit code, memory scrubbed as exp239 says, the host having heard `heard code j` |
| `digest_behind_the_wall` | **healthy**: `j < 334284`, the digest at `+0x2140` at the trap and at the park, the scratch zero, exit code 0 |
| `no_digest_behind_the_wall` | **unhealthy**: `j < 17425`, the scratch and the digest window zero, every other byte but the stack and the ports as at reset, exit code 1 |

`Wall.lean` is written by `proof/gen.py`: exp223's `proof/Condition.lean` as exp248's generator writes it, exp248's
and exp249's proofs, exp239's `proof/Scrub.lean`, then `proof/tail.lean` with the boot lemmas spliced in. `check.sh`
fails if the file is not what `gen.py` writes.

## What is not proved, and what it rests on

- **`j` exactly.** The theorems say the trap comes within exp223's count. exp223's theorem says the run has halted by
  then, not that it was running the step before. The emulator says `j + 1` is the count, 334284 and 17425, for every
  stream, and that is all that does.
- **`mcycle` is the model's.** `PrivMachine` counts one cycle per step, so `mcycle` equals `minstret` here. On Hazard3
  it would not. The `minstret` word is the one a chip would match.
- **One length.** exp249's checker knows the length word is 4096, exp223's.
- **Kernels that call more than HALT.** exp239's monitor serves nothing else. exp238's kernel calls HASH and needs a
  monitor that serves it, and a proof that the served answer is Tier 1's. exp240's rounds are still emulator verdicts.
- **The model.** Everything exp239's README says: one hart, interrupts not modelled, the model's reading of Hazard3,
  the MMIO words as memory.

## The checks

1. `proof/Wall.lean` checks, every theorem it prints on Lean's own axioms.
2. **Eleven mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Eight claims other than the run's**: `minstret` heard as `2 + j`; the exit word 0 whatever the code; the trap
     one step early; a healthy run trapping before step 334284 can; an unhealthy one before 17425; a healthy digest
     zeroed; the monitor's stack as at reset; exp223's world the 64 KiB box.
   - **Three supports loosened in the library**: a window that need only start inside the region; the checker
     letting a HASH through as well as a HALT; a U-mode `ecall` that does not trap.
3. `proof/Wall.lean` is what `proof/gen.py` writes.
4. `suite/digest_behind_the_wall.py`, on the emulator, a separate program from the model, on exp222's fourteen
   streams in exp239's seeded box (junk in every byte the kernel does not own): the trap step, the cause, the digest
   at the trap and at the park, the scrub, every other byte against reset, and every word the host heard, against
   the theorems' numbers.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp250 — the digest the wall keeps ===
recorded at 2026-10-26T13:51:38Z from commit 4d5eb9e

>>> the formal theorems, and what they rest on
'Rv32.Reach.step_same' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Reach.run_same' depends on axioms: [propext, Quot.sound]
'Rv32.Reach.run_halt_step' depends on axioms: [propext, Quot.sound]
'Rv32.Join.quiet_of_good' depends on axioms: [propext, Quot.sound]
'Rv32.Join.halt_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp223.conditions' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp248.front_reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp249.sha_reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp239.monitor_scrubs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp250.boot_ports' depends on axioms: [propext, Quot.sound]
'Exp250.kernel_reach' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp250.kernel_same' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp250.behind' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp250.digest_behind_the_wall' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp250.no_digest_behind_the_wall' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and wrong models: each must be refused
heard_instret_short    claim: the host hears minstret as 2 + j, not 3 + j                                      refused in behind
heard_exit_zero        claim: the exit word the host hears is 0, whatever the kernel's code                    refused in behind
trap_one_step_early    claim: the kernel has trapped one step sooner                                           refused in behind
healthy_sooner         claim: a healthy run traps before exp223's 334284th step                                refused in digest_behind_the_wall
unhealthy_sooner       claim: an unhealthy run traps before exp223's 17425th step                              refused in no_digest_behind_the_wall
healthy_digest_zeroed  claim: a healthy run's digest window is zeroed too                                      refused in digest_behind_the_wall
stack_as_at_reset      claim: an unhealthy run leaves the monitor's stack as it was at reset                   refused in no_digest_behind_the_wall
wide_is_box            claim: exp223's world is the 64 KiB box, not 128 KiB                                    refused in wide
window_start_only      a window need only start inside the region for the box's step to be the wider world's   refused in step_same
ct_lets_hash           the checker's haltsOnly lets a HASH through as well as a HALT                           refused in haltsOnly_at
umode_ecall_untrapped  a U-mode ecall does not trap: Tier 2 runs it as Tier 1 does                             refused in trap_none_plain

>>> exp223 behind exp239 on the emulator, from reset to the park
PASS  exp222's 14 streams, exp223's kernel as exp239's payload, from reset to the park:
      healthy: one trap, at step 334337 = 53 + 334284, to 0x80000114 with mcause 8; heard HALT 0 334286 334286,
      exit 0; SHA-256 of the samples at +0x2140 at the trap and at the park; the scratch zero
      unhealthy: one trap, at step 17478 = 53 + 17425, to 0x80000114 with mcause 8; heard HALT 1 17427 17427,
      exit 1; the scratch and the digest window zero, every other byte but the stack as at reset

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Wall.lean checks, with no errors and no warnings
PASS  all 15 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  heard_instret_short: the proof refuses a version where claim: the host hears minstret as 2 + j, not 3 + j
PASS  heard_exit_zero: the proof refuses a version where claim: the exit word the host hears is 0, whatever the kernel's code
PASS  trap_one_step_early: the proof refuses a version where claim: the kernel has trapped one step sooner
PASS  healthy_sooner: the proof refuses a version where claim: a healthy run traps before exp223's 334284th step
PASS  unhealthy_sooner: the proof refuses a version where claim: an unhealthy run traps before exp223's 17425th step
PASS  healthy_digest_zeroed: the proof refuses a version where claim: a healthy run's digest window is zeroed too
PASS  stack_as_at_reset: the proof refuses a version where claim: an unhealthy run leaves the monitor's stack as it was at reset
PASS  wide_is_box: the proof refuses a version where claim: exp223's world is the 64 KiB box, not 128 KiB
PASS  window_start_only: the proof refuses a version where a window need only start inside the region for the box's step to be the wider world's
PASS  ct_lets_hash: the proof refuses a version where the checker's haltsOnly lets a HASH through as well as a HALT
PASS  umode_ecall_untrapped: the proof refuses a version where a U-mode ecall does not trap: Tier 2 runs it as Tier 1 does
PASS  proof/Wall.lean is what proof/gen.py writes, from exp223's, exp248's, exp249's and exp239's proofs and tail.lean
PASS  exp222's 14 streams, exp223's kernel as exp239's payload, from reset to the park:
      healthy: one trap, at step 334337 = 53 + 334284, to 0x80000114 with mcause 8; heard HALT 0 334286 334286,
      exit 0; SHA-256 of the samples at +0x2140 at the trap and at the park; the scratch zero
      unhealthy: one trap, at step 17478 = 53 + 17425, to 0x80000114 with mcause 8; heard HALT 1 17427 17427,
      exit 1; the scratch and the digest window zero, every other byte but the stack as at reset
```
