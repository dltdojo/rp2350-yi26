# exp246 — the run the charms do not change

<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

[exp245](../exp245-the-bytes-the-proof-blesses/) adds three charms to [exp240](../exp240-the-code-the-box-forbids-writing/)'s
monitor and proves, charm by charm, what each does not protect. What it could not say in one sentence is the thing its
ablation was about: **with the charms or without them, is it the same monitor?** That is a statement about two
binaries at once, and every proof in this repository so far was about one.

This experiment proves it, in Lean 4, on Lean's own axioms -- and the answer is *almost*:

- **One round is the same.** From two machines whose boxes hold the same bytes, a round under exp240's monitor and a
  round under exp245's: the payload takes the same steps, traps first at the same step for the same cause, the host
  hears the same words -- the same report, the same exit code -- and at the park the boxes hold the same bytes, but
  for exp245's slot, which is zero.
- **Any number of rounds are the same, if every exit leaves the slot zero.** The third charm's scrub is the one thing
  a payload can see: a payload that keeps a word in the slot finds it in the next round under exp240 and not under
  exp245. The theorem asks for the slot to be left zero, and the emulator shows the hypothesis is not idle.

Needs: **no board** at all, and no USB anywhere in it. It has no firmware of its own: it is about exp240's `monitor.bin`
and exp245's, which their own `check.sh` hold to their own proofs. Nothing here ran on silicon or on the RTL.

## How this was decided

The interrogation, as [the repository asks](../README.md#every-new-experiment-starts-with-an-interrogation), before any
of it was built:

1. **The facts.** The emulator, before anything was proved: a payload that stores a word in the slot in round 1 and
   HALTs with what the slot holds in round 2 exits `0x51075107` under exp240 and under exp245 without its third
   charm, and 0 under exp245 and under exp245 without its first or second. exp245's README and index row had said the
   charms change nothing a payload sees; they were corrected (exp245's Act 3b). The two proofs compile as one file, in
   two namespaces, in about two minutes.
2. **What was already answered.** exp240's `wx_run` says one payload in a W^X box changes no byte outside it;
   `Refinement.lean` relates a U-mode run to Tier 1's, one machine to its own projection. Neither is about two
   machines. The analysis of Anthropic's formal verification
   ([docs](../../docs/2026-10-23-1048-verification-at-scale-vs-rv32-bytes-zh-tw.md), recommendation 3) named this
   pair as the first case to try, and the audit's G5 -- a proved kernel on a proved monitor -- as the next.
3. **The contradictions.** "exp245 is exp240" is false over rounds (the slot). The two binaries differ in their words,
   their step counts, the trap vector and entry 3, so "the same" cannot be the same state: it has to be what a payload
   can reach and what the host hears. A run that never traps never reaches a comparison, so the payload half has to
   be lockstep, not end-to-end. And `x0`'s slot in the register file is never written by boot, so two machines need
   not agree on it: twins agree on the registers *as they read*.
4. **What was decided without asking.** A library theorem for the lockstep (`lean/Rv32/WxTwin.lean`), since nothing in
   it is about these two monitors; one generated file holding both proofs as their generators write them; boot's
   theorems made to say that boot writes no port, so that "the host hears the same" starts at reset.
5. **What was asked**, and answered: the scope (this pair only, G5 next); the rounds (a conditional theorem: the same
   while every exit leaves the slot zero); exp245 (corrected, with an act that shows the slot).

## What is proved

The library half, in `lean/Rv32/WxTwin.lean`, is about any two machines in U-mode boxed by the same three entries
(`WXBoxed`, the same six bounds). `Twin V s t` says they agree on the registers as they read, the bytes of `V`, the
privilege, `halted`, the CSRs a payload's run reads or moves (`mstatus`, `mepc`, `mcause`, the counters and their
inhibit, `mscratch`), what the host has heard and how it answers; the trap vector and the PMP CSRs are not in it.

| theorem | says |
| :--- | :--- |
| `wx_pmp_same` | the PMP of two machines boxed by the same entries says the same of every access -- entry 3 silent or off |
| `exec_twin` | two cores with the same `pc` and registers, and the same bytes at a load's address, come out of an instruction alike, and bytes that agreed agree still |
| `wx_ld_ok` | a load the trap check lets through reads only the code, the data or the stack |
| `twin_trap` | twins trapping for the same cause stay twins, each at its own trap vector |
| `wx_twin_step`, `wx_twin_run` | **a W^X box sees only the box**: twins at the same `pc`, agreeing on the box (`WxVis`), take the same steps, at the same `pc` while in U-mode, and trap together |

And about the two monitors, in `proof/Equiv.lean`:

| theorem | says |
| :--- | :--- |
| `boot_twins` | from two `Ready` machines whose boxes agree, each monitor's boot -- 61 steps of exp240's, 71 of exp245's -- leaves twins, boxed by the same entries, at the same `pc`; the shrine is outside the box |
| `trapped_iff` | twins in the box trap first at the same step |
| `payload_twins` | after boot, for as long as the payload has not trapped, the two are twins: a payload that never traps runs the same forever under either |
| `round_same` | **one round, either monitor, the same**: the host hears the same, the hosts are the same, and at the park the boxes agree but on the slot, which exp245 leaves zero |
| `round_exists` | for every round under one monitor there is one under the other |
| `round_agree` | if exp240's round leaves the slot zero, the parked machines agree again |
| `both_agree` | **any number of rounds, the same**: runs side by side (`Both`), a round under each whenever exp240's leaves the slot zero and the host's writes the same to the two boxes, stay `Ready` and agreeing |

`Equiv.lean` is written by `proof/gen.py` from exp240's `proof/Wx.lean` and exp245's `proof/Bless.lean`, in their own
namespaces, as their own generators write them, and `proof/tail.lean`; `check.sh` fails if it is not.

## What is not proved, and what it rests on

- **Both directions of a round, not of a run.** `round_exists` gives each monitor's round a partner; `both_agree`
  follows runs built round by round. It does not say a run under exp245 can always be matched once a slot was left
  non-zero -- it cannot, which is the point of the hypothesis.
- **The slot condition is on exp240's side.** It says what the payload left at its trap, as exp240's park keeps it; a
  condition on the payload's own code -- "never writes the slot" -- would need a statement about every step, and this
  one needs none.
- **The model.** Everything exp240's and exp245's READMEs say: one hart, interrupts not modelled, the model's reading
  of Hazard3. A writer outside the model -- exp245's Act 1b -- tells the monitors apart in round 1.
- **Not G5.** The proved kernels run on these monitors only on the emulator; joining Tier 1's kernel theorems to Tier
  2's monitor theorems is the next experiment, [exp247](../exp247-the-remainder-behind-the-wall/), for exp229's
  kernel on exp236's monitor.

## The checks

1. `proof/Equiv.lean` checks, every theorem it prints on Lean's own axioms.
2. **Ten mutants** (`proof/mutants.txt`), each refused by Lean: five claims that say more than the monitors do -- the
   rounds the same whatever the slot holds, the slots the same at the park, a trap one step later under exp245, the
   shrine in the payload's reach, a word from exp240's boot to the print port -- three twins that agree on less or
   claim more (the code out of view, the register file's `x0` slot, the same `pc` after a trap), and two rules of the
   model loosened (U-mode matching no entry passes; a straddling access passes).
3. `proof/Equiv.lean` is what `proof/gen.py` writes.
4. `suite/same_rounds.py`, on the emulator: a payload that keeps a word in the slot, whose second round tells the
   monitors apart; the same payload clearing the slot, whose rounds do not; and 200 random payloads from a fixed seed,
   two rounds each, every first round the same and every second round the same wherever the first left the slot zero.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp246 — the run the charms do not change ===
recorded at 2026-10-25T01:19:19Z from commit a454745

>>> the formal theorems, and what they rest on
'Rv32.Priv.wx_twin_step' depends on axioms: [propext, Classical.choice, Quot.sound]
'Rv32.Priv.wx_twin_run' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.boot_twins' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.trapped_iff' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.payload_twins' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.round_same' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.round_exists' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.round_agree' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp246.both_agree' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong claims and wrong models: each must be refused
slot_hypothesis_dropped    claim: any number of rounds stay the same, whether or not each exit leaves the slot zero                 refused in both_agree
slot_claimed_same          claim: at the park the two slots hold the same bytes too                                                 refused in round_same
trap_one_step_later        claim: under exp245's monitor the payload traps first one step later                                     refused in trapped_iff
shrine_in_view             claim: the bytes the payload can reach include the shrine                                                refused in vis_not_shrine
boot_heard                 claim: exp240's boot writes a word to the print port                                                     refused in monitor_boot
pcs_same_after_trap        claim: twins' pcs are the same after every step, a trap's too, though each goes to its own trap vector   refused in wx_twin_step
code_out_of_view           twins agree on the data and the stack, not the code: the payload fetches what they do not agree on       refused in wx_twin_step
register_file_twins        twins share the register file, x0's slot too, which boot never writes                                    refused in wx_twin_step
pmp_unmatched_user_passes  U-mode that matches no entry passes: the payload reaches outside the box                                 refused in umode_default_deny
pmp_partial_match_passes   an access that straddles an entry's edge passes                                                          refused in pmpCheck_uboxed_iff

>>> the two monitors on the emulator, round after round
PASS  the slot kept: round 1 the same under the two monitors; round 2 HALTs 0x51075107 under exp240's and 0
      under exp245's -- round 1 left the slot holding a word, and the theorem asks it not to
PASS  the slot cleared: round 1 zeroes the slot before its HALT; both rounds the same under the two monitors,
      round 2's box byte for byte
PASS  200 random payloads from seed 246, two rounds each: every round 1 the same under the two monitors,
      the slot aside; every round 2 the same when round 1 left the slot zero (180 of them); 20
      left something in the slot, and round 2 told the monitors apart for 0 of those
      round 1 ended: 136 HALT, 56 mcause 7, 8 mcause 5

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  Equiv.lean checks, with no errors and no warnings
PASS  all 9 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  slot_hypothesis_dropped: the proof refuses a version where claim: any number of rounds stay the same, whether or not each exit leaves the slot zero
PASS  slot_claimed_same: the proof refuses a version where claim: at the park the two slots hold the same bytes too
PASS  trap_one_step_later: the proof refuses a version where claim: under exp245's monitor the payload traps first one step later
PASS  shrine_in_view: the proof refuses a version where claim: the bytes the payload can reach include the shrine
PASS  boot_heard: the proof refuses a version where claim: exp240's boot writes a word to the print port
PASS  pcs_same_after_trap: the proof refuses a version where claim: twins' pcs are the same after every step, a trap's too, though each goes to its own trap vector
PASS  code_out_of_view: the proof refuses a version where twins agree on the data and the stack, not the code: the payload fetches what they do not agree on
PASS  register_file_twins: the proof refuses a version where twins share the register file, x0's slot too, which boot never writes
PASS  pmp_unmatched_user_passes: the proof refuses a version where U-mode that matches no entry passes: the payload reaches outside the box
PASS  pmp_partial_match_passes: the proof refuses a version where an access that straddles an entry's edge passes
PASS  proof/Equiv.lean is what proof/gen.py writes, from exp240's Wx.lean, exp245's Bless.lean and tail.lean
PASS  the slot kept: round 1 the same under the two monitors; round 2 HALTs 0x51075107 under exp240's and 0
      under exp245's -- round 1 left the slot holding a word, and the theorem asks it not to
PASS  the slot cleared: round 1 zeroes the slot before its HALT; both rounds the same under the two monitors,
      round 2's box byte for byte
PASS  200 random payloads from seed 246, two rounds each: every round 1 the same under the two monitors,
      the slot aside; every round 2 the same when round 1 left the slot zero (180 of them); 20
      left something in the slot, and round 2 told the monitors apart for 0 of those
      round 1 ended: 136 HALT, 56 mcause 7, 8 mcause 5
```
