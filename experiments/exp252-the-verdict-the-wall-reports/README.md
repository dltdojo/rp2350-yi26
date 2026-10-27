# exp252 — the verdict the wall reports

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

The last of three rounds. [exp228](../exp228-the-script-the-kernel-runs/) proved a Tapscript interpreter: 881
instructions that halt with the specification's verdict for every script it takes, whatever the shell's `HASH` and
`CHECKSIG` answer. [exp238](../exp238-the-call-the-monitor-checks/) proved a monitor that serves those two calls: it
checks every range against the box, forwards the call to a host, and returns. exp238's emulator cases run exp228's
kernel behind it; no theorem did. This is the audit's G5 for its third pair: **a kernel that makes service calls, on
a monitor that serves them.**

In Lean 4, on Lean's own axioms. The machine is at reset, with exp238's monitor at `0x80000000` and exp228's
kernel at `0x80010000` with its table, a script and a stack as exp228's `Input` describes them. Its world does not
serve `HASH` (`t0 = 0`). The host meets two conditions:

- asked for `HASHB` of `a1` bytes at `a0`, it writes `env.hash` of them;
- asked for `CHECKSIG` of the 32 bytes at `a0` and the 64 at `a1`, it answers 1 if `env.sig` says so, and 0.

Then **the monitor parks with exit code `verdict env scr st0`**, the specification's verdict with `env.hash` and
`env.sig`. **The last word the host hears is that verdict**, at the exit word.

Needs: **no board** at all, and no USB anywhere in it. It has no firmware of its own: it is about exp228's
`kernel.bin` and exp238's `monitor.bin`, which their own `check.sh` hold to their own proofs. Nothing here ran on
silicon or on the RTL.

## How this was decided

1. **The facts.**
   - Round 1 gave the Tier 2 model a host that sees memory and writes `HASHB`'s 32 bytes back. exp238 was re-proved
     with it.
   - Round 2 ([exp251](../exp251-the-calls-the-script-makes/)) showed that every call of exp228's run is `HALT`, or
     `HASHB` or `CHECKSIG` with its ranges in the box.
   - exp238's `monitor_hashb_ok`, `monitor_checksig_ok` and `monitor_halt` say what the monitor does with each, from
     the trap vector.
   - exp247 and exp250 joined kernels that call only `HALT` with lean/Rv32/Join.lean's `run_in_box` and
     `halt_in_box`.
2. **What was already answered.**
   - `run_in_box`: a Tier 1 run in the box is the Tier 2 run, from **the same core**.
   - `WxTwin.exec_twin`: two cores with the same `pc`, registers and loaded bytes execute an instruction alike.
3. **The contradictions.**
   - **After the first call the cores differ.** The monitor writes its own stack and the ports, outside the box. The
     Tier 2 core is no longer the Tier 1 core exp251 is about, so `run_in_box` does not apply from there. A Tier 1
     step in the box's region reads nothing outside it, though, so the two go on alike in the box (`BoxEq`,
     `step_boxEq`).
   - **The host's functions must be Tier 1's.** The model's host is any function, and exp228's world is any
     `env.hash` and `env.sig`. The join holds when they are the same functions, and that is what is asked of the host.
4. **What was decided without asking.**
   - **One Tier 1 step at a time.** A plain step is one Tier 2 step (`plain_in_box`). A `HASHB` is 44: the trap, the
     43 steps of `monitor_hashb_ok`. A `CHECKSIG` is 48. The `HALT` is 62.
   - **`env.hash` and `env.sig` name the host's functions.** Tier 2 never reads them: a U-mode `ecall` traps before
     it is executed, and the monitor makes none. The kernel's world is `env` with the box as its region.
   - **The host is asked through what it heard**: the four words of a `HASHB`, the three of a `CHECKSIG`.
5. **What was asked**, across the three rounds:
   - extend the Tier 2 model so the host writes back;
   - get the every-step facts from a halted run, not by rewriting exp228's proof;
   - three rounds, each merged on its own.

## What is proved

In the library, `lean/Rv32/Join.lean`:

| | says |
| :--- | :--- |
| `BoxEq`, `readLE_boxEq`, `fetched_boxEq` | two cores alike to a run in a region: the same `pc`, registers and bytes in the region; they read and fetch the same there |
| `step_boxEq` | **two cores alike in the region step alike**: a Tier 1 step that went on from one, not an `ecall`, goes on from the other, and they are alike after |
| `plain_in_box` | one Tier 1 step is one Tier 2 step, from a boxed state whose core is only alike in the box |
| `run_running_prefix`, `step_at_ecall`, `fetch_ok_of_running` | a run going after `i + d` steps was going after `i`; at a fetched `ecall` the step is the call; a step that went on fetched in the region |

And about this kernel and this monitor, in `proof/Wall.lean`:

| theorem | says |
| :--- | :--- |
| `at_trap` | at a Tier 1 `ecall`, one Tier 2 step to the trap vector: cause 8, `mepc` the `ecall`'s, `mpp` U-mode, the kernel's registers and memory |
| `sim_plain` | a plain step, one Tier 2 step, alike after |
| `sim_hashb` | a `HASHB`, 44 Tier 2 steps: the host's 32 bytes are `env.hash` of the input, as Tier 1's are |
| `sim_checksig` | a `CHECKSIG`, 48: `a0` is the host's answer, `env.sig`'s, as Tier 1's is |
| `sim_halt` | the `HALT`, 62: the monitor parks with the kernel's `a0`, the last word the host hears it, at the exit word |
| `verdict_behind_the_wall` | **from reset**: the monitor parks with `verdict env scr st0`, and the host's last word is that verdict |

`Wall.lean` is written by `proof/gen.py`: exp238's `proof/Calls.lean`, exp228's `proof/Script.lean` and exp251's
`proof/tail.lean`, as their own `check.sh` hold them, then `proof/tail.lean`. `check.sh` fails if the file is not what
`gen.py` writes.

## What is not proved, and what it rests on

- **That the host is SHA-256 and BIP340.** The theorem asks the host to compute `env.hash` and `env.sig`, whatever they
  are. That the emulator's host computes SHA-256 and exp228's verifier is tested, as exp238's README says.
- **How many steps.** The theorem says the monitor parks; the proof composes 53 + one per plain step + 44 per `HASHB`
  + 48 per `CHECKSIG` + 62. The emulator counts them.
- **What the host hears before the end.** The theorem names the last word only. exp238's `monitor_cycle` says each
  call is heard as `callIo` and nothing else.
- **`mcycle` is the model's**, as exp247 says.
- **The model.** Everything exp238's README says: one hart, interrupts not modelled, the model's reading of Hazard3,
  the MMIO words as memory, the host bounded and not modelled.

## The checks

1. `proof/Wall.lean` checks, every theorem it prints on Lean's own axioms.
2. **Six mutants** (`proof/mutants.txt`), each refused by Lean:
   - **Three claims other than the run's**: the verdict plus one; a `HASHB` one step shorter; the last word at the
     print port.
   - **The host asked to be something else**: hashing from the output pointer; checking the key and the signature
     the wrong way round.
   - **The bridge loosened**: two cores taken as alike whatever bytes the box holds, refused at its first use, `BoxEq.refl`.
3. `proof/Wall.lean` is what `proof/gen.py` writes.
4. `suite/verdict.py`, on the emulator, a separate program from the model. exp228's 34 scripts and 120 from its
   fuzzer run under exp238's monitor with the emulator's host, and each is also run alone. Each must:
   - park with `a0` script.py's verdict;
   - have the verdict as its last port write, at the exit word;
   - first reach the park word at step `53 + (n - 1 - h - c) + 44 h + 48 c + 62`, where `n` is the run alone's
     instruction count and `h` and `c` its `HASHB` and `CHECKSIG` calls. These are the steps the proof composes.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp252 — the verdict the wall reports ===
recorded at 2026-10-27T06:28:14Z from commit 8860ba2

>>> the formal theorems, and what they rest on
'Exp251.calls_the_script_makes' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_hashb_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_checksig_ok' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp238.monitor_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Join.plain_in_box' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp252.sim_plain' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp252.sim_hashb' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp252.sim_checksig' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp252.sim_halt' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp252.verdict_behind_the_wall' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims, a wrong host and a wrong bridge: each must be refused
verdict_plus_one     claim: the monitor parks with the verdict plus one                            refused in verdict_behind_the_wall
hashb_one_short      claim: a served HASHB takes 43 steps, not 44                                  refused in sim_hashb
exit_at_print        claim: the last word the host hears is at the print port, not the exit word   refused in sim_halt
host_hashes_output   the host is asked to hash from the output pointer, not the input              refused in sim_hashb
host_checks_swapped  the host is asked to check the key and the signature the wrong way round      refused in sim_checksig
alike_without_bytes  two cores are taken as alike in the box whatever bytes the box holds          refused in BoxEq.refl

>>> exp228 behind exp238 on the emulator, from reset to the park
PASS  154 scripts -- exp228's 34 by hand and 120 from its fuzzer -- as exp238's payload, from reset:
      each parks with a0 = script.py's verdict, the verdict the last port write, at the exit word;
      each first at step 53 + (n - 1 - h - c) + 44 h + 48 c + 62, the steps the proof composes (13 HASHB, 4 CHECKSIG)

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Wall.lean checks, with no errors and no warnings
PASS  all 10 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  verdict_plus_one: the proof refuses a version where claim: the monitor parks with the verdict plus one
PASS  hashb_one_short: the proof refuses a version where claim: a served HASHB takes 43 steps, not 44
PASS  exit_at_print: the proof refuses a version where claim: the last word the host hears is at the print port, not the exit word
PASS  host_hashes_output: the proof refuses a version where the host is asked to hash from the output pointer, not the input
PASS  host_checks_swapped: the proof refuses a version where the host is asked to check the key and the signature the wrong way round
PASS  alike_without_bytes: the proof refuses a version where two cores are taken as alike in the box whatever bytes the box holds
PASS  proof/Wall.lean is what proof/gen.py writes, from exp238's Calls.lean, exp228's Script.lean, exp251's tail and tail.lean
PASS  154 scripts -- exp228's 34 by hand and 120 from its fuzzer -- as exp238's payload, from reset:
      each parks with a0 = script.py's verdict, the verdict the last port write, at the exit word;
      each first at step 53 + (n - 1 - h - c) + 44 h + 48 c + 62, the steps the proof composes (13 HASHB, 4 CHECKSIG)
```
