# exp251 — the calls the script makes

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The second of three rounds toward exp228's kernel behind [exp238](../exp238-the-call-the-monitor-checks/)'s
monitor. The first changed the Tier 2 model: the host now sees memory and writes `HASHB`'s digest back.

A monitor runs a kernel's Tier 1 steps as its own only while every `ecall` is one it serves. exp238 serves `HALT`,
`HASHB` and `CHECKSIG`, with their ranges in the box. Tier 1 serves one call more: `HASH` of whole 64-byte blocks
(`t0 = 0`). exp238 treats that call as a fault. So the join needs to know, at every step of
[exp228](../exp228-the-script-the-kernel-runs/)'s run, which call it makes. exp228's own proof says how the run
ends, not what each step does.

This round gets that fact without touching exp228's proof. In Lean 4, on Lean's own axioms:

- **A world says which calls its shell serves.** Tier 1's `Env` gains `servesHash`, true by default. In a world
  where it is false, `t0 = 0` faults like any call nobody serves.
- **A run that halted made only the calls its world serves.** A fault ends a Tier 1 run, so a run that halted
  faulted nowhere on the way (`calls_of_halted`).
- **exp228's kernel, in a world that does not serve `HASH`**, halts with the specification's verdict, as exp228
  proved for every world. Every `ecall` on the way is `HALT`, or `HASHB` or `CHECKSIG` with its ranges in the box.

Needs: **no board** at all, and no USB anywhere in it. No firmware of its own: the kernel is exp228's, held by
exp228's `check.sh`. Nothing here ran on silicon or on the RTL.

## How this was decided

1. **The facts.**
   - exp228's `kernel_verdict` is for every `env` with `Placed env base`: whatever `env.hash` and `env.sig` are.
   - Its kernel has three `ecall`s, each after `li t0, k`, k one of 1, 2, 3. It dispatches opcodes through a jump
     table in memory (`jalr`).
   - Its stack's length words live in memory, and some stores add them to a slot's address.
2. **What was already answered.**
   - lean/Rv32/Join.lean's `step_halted`: a Tier 1 step that halts is a `HALT`.
   - lean/Rv32/Ct.lean's and lean/Rv32/Reach.lean's checkers, which give every-step facts for kernels they accept.
3. **The contradictions.**
   - The checker cannot accept exp228:
     - it has no rule for `jalr`;
     - stores whose address depends on a length word in memory need memory invariants it does not have.
   - Rewriting exp228's proof to carry a property at every step would mean about 200 step sites in 5,900 lines,
     for one kernel.
   - **A Tier 1 fault is final**: `run` stops at it. A halted run therefore made only calls its world served, with
     the arguments that world asks for. Every Tier 1 world served `t0 = 0`, though, so this said nothing about it.
4. **What was decided without asking.**
   - **The field's default is true**, so every world written before means what it meant.
   - **The proofs that call `HASH` ask for it as an instance, `[Serves env]`**, so the lemmas they stand on pass it
     along without a change at any call site. Those proofs:
     - lean/Rv32/Walk, Wots, Mss, MssKeygen and MssSign;
     - exp204, exp205 and exp213.
   - The two worlds `run_within` and `step_same` relate must agree on the field too: their `hh` has a third
     conjunct.
   - Three things found on the way, put right here:
     - lean/lakefile.toml did not build `Sha256` by default, though exp228's proof imports it;
     - two of exp207's mutants no longer matched lean/Rv32/Ct.lean after exp249 changed it, so exp207's `check.sh`
       failed on them; their seds now match, and both are refused;
     - so did two of exp235's, against lean/Rv32/Priv.lean; the same.
5. **What was asked**, and answered:
   - round 1: extend the Tier 2 model so the host writes back;
   - for the every-step facts: first, rewriting exp228's proof. When this route was found, it was put to the user,
     who chose it.

## What is proved

In the library:

| | says |
| :--- | :--- |
| `Env.servesHash`, `Serves` | whether the world's shell serves `HASH` (`t0 = 0`); `syscall` serves it only if so |
| `Join.step_not_fault_of_halted` | a run that halted after `n` steps faulted at none of them |
| `Join.calls_of_halted` | **a halted run made only the calls its world serves**: in a world that does not serve `HASH`, every `ecall` before the halt is `HALT`, or `HASHB` or `CHECKSIG` with its ranges in the region |

And about exp228's kernel, in `proof/Calls.lean`:

| theorem | says |
| :--- | :--- |
| `calls_the_script_makes` | **in a world that does not serve `HASH`**, exp228's kernel halts with `verdict env scr st0`, and every `ecall` on the way is a call exp238's monitor serves (`Served`) |

`Calls.lean` is written by `proof/gen.py`: exp228's `proof/Script.lean` as exp228's `check.sh` holds it, then
`proof/tail.lean`.

## What is not proved, and what it rests on

- **The join.** That is round 3: exp228's run, step for step, as exp238's monitor runs it. That round has to tie
  Tier 1's `env.hash` and `env.sig` to what the host writes and answers.
- **How many calls there are.** The theorem says what each call is, not how many. The emulator counts them.
- **Only `t0 = 0` is new.** Tier 1 already faulted on any `t0` above 3, so `calls_of_halted` needed only the one
  field. A monitor serving fewer calls than `HALT`, `HASHB` and `CHECKSIG` would need more.
- **The model.** `Rv32.Machine`, the Tier 1 model: one hart, no interrupts, the region as Tier 1 checks it.

## The checks

1. `proof/Calls.lean` checks, every theorem it prints on Lean's own axioms.
2. **Six mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Four claims more than the run's**: no `HASHB` at all; a 64-byte output range; a 64-byte key; the verdict
     plus one.
   - **Two supports loosened in the library**: a world that serves `HASH` taken for one that does not; a shell that
     serves the first call whatever its world says.
3. `proof/Calls.lean` is what `proof/gen.py` writes.
4. `suite/calls.py`, on the emulator, a separate program from the model. exp228's kernel runs alone in its box, as
   exp238's suite runs it, on exp228's 34 scripts and 120 from its fuzzer. Every `ecall` is recorded: its `t0` and
   its ranges, and each run's verdict against script.py's.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
```
