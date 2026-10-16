# exp235 — the boundary the proof bridges

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Hazard3 privilege semantics and U-mode refinement, proved in Lean 4. Without
modifying a single line of Tier 1 `lean/Rv32/Machine.lean`, a Tier 2 privileged
micro-model (`PrivMachine`) formalizes RP2350 Hazard3's M-mode CSRs, 32-byte
NAPOT PMP address matching, hardware readback quirks (bits `[1:0] == 0b11`),
default-deny protection, and trap handling. A bridge theorem proves that, with
the PMP box inside the Tier 1 region, `n` safe U-mode steps end in exactly the
state `Rv32.run` ends in (running or halted), the box configuration survives
every step, and `minstret` rises by exactly `n`. Thirteen wrong privilege models
and claims in `proof/mutants.txt` are refused, each in the theorem that states
the property it breaks.**

Needs: **no board**. The foundational bridge connecting the unprivileged
cryptographic proofs of `exp229` to the verified physical monitor of `exp236`
and `exp237`.

## Architecture: Two-Tier Privilege Separation

This repository already holds extensive proofs about unprivileged RV32IM execution
(`exp201` through `exp234`), culminating in `exp229`'s 458-instruction secp256k1
field arithmetic kernel. Rather than polluting `Rv32.Machine` with privileged
state:

```
  Tier 2: Privileged Micro-Model (lean/Rv32/Priv.lean)
  ┌─────────────────────────────────────────────────────────────┐
  │ PrivMachine: mode (M/U), CSRs, PMP cfg/addr, mcountinhibit   │
  │ - pmpCheck: 32-byte NAPOT matching & default-deny           │
  │ - uModeTrapCause: PMP faults, CSR traps, MRET traps         │
  │ - bumpCounters: mcycle, minstret                            │
  └──────────────────────────────┬──────────────────────────────┘
                                 │ Refinement (lean/Rv32/Refinement.lean)
                                 │ - toUMachine (projects core)
                                 │ - UBoxed s lo hi
                                 │ - SafeUInstr s lo hi
  Tier 1: Core Semantics         ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ Rv32.Machine (lean/Rv32/Machine.lean)                       │
  │ - Untouched: 0 lines modified since 70ca711 (check.sh)      │
  │ - Deterministic instruction execution (Rv32.exec)           │
  └─────────────────────────────────────────────────────────────┘
```

## Silicon Quirks Modeled

1. **Hazard3 NAPOT Readback Quirk (`exp209`)**:
   In Hazard3, writing a NAPOT address into `pmpaddr0..3` always reads back with
   bits `[1:0]` set to `0b11` (hardware granularity $G=3$, minimum 32 bytes).
   Theorem `pmp_napot_readback` formally verifies that for any effective address,
   `readPmpAddr csrs idx &&& 3#32 = 3#32`.

2. **Default-Deny for U-Mode**:
   When all PMP entries are `OFF`, U-mode access to any byte in the 4GB address
   space is denied. Theorem `pmp_umode_default_deny` proves that under this
   configuration, `pmpCheck csrs .U addr width acc = false` for all addresses.

3. **Privilege Traps**:
   Attempting to execute `Zicsr` instructions (`priv_umode_zicsr_traps`) or
   `MRET` (`priv_umode_mret_traps`) from U-mode immediately raises an illegal
   instruction trap (`mcause = 2`), transferring execution to M-mode at `mtvec`.
   For `Zicsr` this is a fact about the model, which has no `mcounteren`; on the
   chip it holds while `mcounteren` is 0, and nothing here checks that.

4. **CSR access rule**:
   An M-mode `Zicsr` access to a CSR the model does not have
   (`priv_zicsr_unimplemented_traps`), or a write to a read-only one — address
   bits `[11:10] = 11` (`priv_zicsr_readonly_write_traps`) — raises illegal
   instruction. This is the RISC-V rule, not a measurement on the chip.

5. **Hardware Performance Counters**:
   `mcountinhibit` controls whether `mcycle` (bit 0) and `minstret` (bit 2)
   advance. Theorems `priv_mcountinhibit_mcycle` and `priv_mcountinhibit_minstret`
   prove that inhibited counters remain frozen, while `priv_minstret_step`
   proves exact +1 progression on uninhibited steps. A trapping instruction is
   counted too, as exp203 measured for `ecall` and an illegal instruction; the
   frontend effect exp203 also found (5 or 4 counts for the same instructions)
   is not modelled.

## The Refinement Bridge

Under `UBoxed s lo hi`, PMP entry 0 is configured as NAPOT covering `[lo, hi)`
with `RWX` permissions, and all other entries are `OFF`.
- **`uboxed_pmp_iff`**: An access succeeds if and only if $[addr, addr + width) \subseteq [lo, hi)$.
- **`safe_step_no_trap`**: Instructions staying within the box never trigger *privilege* faults
  (a Tier 1 `.fault` from `exec` still traps).
- **`safe_step_running_core`** / **`safe_step_halted_core`**: one step steps the Tier 1 core
  identically, stays in U-mode, and the counters are `bumpCounters`.
- **`safe_step_simulates_tier1`**: the same against Tier 1's own `Rv32.step`, with the box
  still in force afterwards. Tier 1 checks `env.region` on fetch, load and store, so the
  theorem needs `env.region` to contain `[lo, hi)`.
- **`safe_run_refines_tier1_running`**: if `SafeUEpoch` holds for `n` steps and
  `Rv32.run env n` is still running, `PrivMachine.run env n` has the same core, is still
  `UBoxed`, kept `mcountinhibit`, and `minstret` is up by exactly `n` (when not inhibited).
- **`safe_run_refines_tier1_halted`**: if `Rv32.run env n` halts, the Tier 2 machine halts
  with the same core, in U-mode.
- **`priv_run_split`**: fuel arithmetic, `run (m + n) = run n ∘ run m`. True in any mode; it
  says nothing about U-mode.

## What these theorems do not say

- A Tier 1 run that ends in a **fault** is not covered: Tier 2 traps into M-mode and goes on
  running the handler, so there is no common end state to compare.
- `SafeUInstr` is a hypothesis about each instruction. Nothing here derives it from a program;
  a caller who wants the 458-instruction kernel of exp229 has to establish it for each one.
- The model is not the chip. It omits `mcounteren` and the C extension, and traps on every CSR
  outside its list of 15 (stricter than the chip). A write to `mcycle`/`minstret` is kept, not
  overwritten by the instruction's own increment: the RISC-V rule, no theorem. It does not model
  exp203's frontend effect on `minstret`. The cause codes (4 and 6 for misaligned accesses, and
  the rest) are written down, not proved. `docs/micro-monitor/phase1_priv_machine_design.md`
  section 8 lists each of these with what it means for a proof.
- `test_vectors.py` checks the model's NAPOT decoding and U-mode load check against
  independent arithmetic on 1210 vectors; it does not check the CSR or trap code.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp235 — the boundary the proof bridges ===
recorded at 2026-10-16T00:59:19Z from commit ef2588c

>>> the theorems, and what they rest on
'Exp235.pmp_napot_readback' depends on axioms: [propext, Quot.sound]
'Exp235.pmp_umode_default_deny' depends on axioms: [propext, Quot.sound]
'Exp235.priv_umode_zicsr_traps' depends on axioms: [propext, Quot.sound]
'Exp235.priv_umode_mret_traps' depends on axioms: [propext, Quot.sound]
'Exp235.priv_mcountinhibit_mcycle' depends on axioms: [propext]
'Exp235.priv_mcountinhibit_minstret' depends on axioms: [propext]
'Exp235.priv_minstret_step' depends on axioms: [propext]
'Exp235.uboxed_pmp_iff' depends on axioms: [propext, Quot.sound]
'Exp235.safe_step_no_trap' depends on axioms: [propext, Quot.sound]
'Exp235.safe_step_executes' depends on axioms: [propext, Quot.sound]
'Exp235.safe_step_running_core' depends on axioms: [propext, Quot.sound]
'Exp235.safe_step_halted_core' depends on axioms: [propext, Quot.sound]
'Exp235.safe_step_simulates_tier1' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp235.safe_run_refines_tier1_running' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp235.safe_run_refines_tier1_halted' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp235.priv_run_split' depends on axioms: [propext, Quot.sound]
exit 0

>>> wrong privilege semantics and wrong claims: each must be refused
napot_readback_zero         NAPOT readback claims bits [1:0] read as 00b instead of 11b                 refused in pmp_napot_readback
default_deny_inverted       default-deny claims U-mode access is granted when all PMP entries are OFF   refused in pmp_umode_default_deny
pmp_bounds_inverted         PMP UBoxed equivalence claims out-of-bounds addresses are accepted          refused in uboxed_pmp_iff
step_switches_to_mmode      Safe U-mode execution is claimed to escalate mode to M-mode                 refused in safe_step_running_core
minstret_claimed_one_extra  a run of n safe steps is claimed to count n + 1 instructions in minstret    refused in safe_run_refines_tier1_running
csr_umode_permitted         the model lets U-mode execute Zicsr instead of trapping                     refused in umode_zicsr_traps
mret_umode_permitted        the model lets U-mode execute MRET instead of trapping                      refused in umode_mret_traps
off_entry_matches           the model lets a PMP entry that is OFF match every access                   refused in matchPmpEntry_off
minstret_counted_twice      the model counts two instructions per step in minstret                      refused in bumpCounters_minstret_step
step_drops_core_update      a safe step leaves the Tier 1 core as it was                                refused in PrivMachine.step_eq_of_safe
step_escalates_to_mmode     a safe step leaves the machine in M-mode                                    refused in PrivMachine.step_eq_of_safe

>>> Python test vectors for Hazard3 NAPOT boundary logic
PASS  NAPOT encoding/decoding verified across 8 window sizes
PASS  PMP boundary containment and partial match cases verified
PASS  the Lean model agrees on all 1210 vectors (NAPOT range and U-mode load check)

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  lean/Rv32/Machine.lean is byte-for-byte what it was at 70ca711, before the privileged model (0 lines modified)
PASS  Bridge.lean checks, with no errors and no warnings
PASS  all 16 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  napot_readback_zero: the proof refuses a version where NAPOT readback claims bits [1:0] read as 00b instead of 11b
PASS  default_deny_inverted: the proof refuses a version where default-deny claims U-mode access is granted when all PMP entries are OFF
PASS  pmp_bounds_inverted: the proof refuses a version where PMP UBoxed equivalence claims out-of-bounds addresses are accepted
PASS  step_switches_to_mmode: the proof refuses a version where Safe U-mode execution is claimed to escalate mode to M-mode
PASS  minstret_claimed_one_extra: the proof refuses a version where a run of n safe steps is claimed to count n + 1 instructions in minstret
PASS  csr_umode_permitted: the proof refuses a version where the model lets U-mode execute Zicsr instead of trapping
PASS  mret_umode_permitted: the proof refuses a version where the model lets U-mode execute MRET instead of trapping
PASS  off_entry_matches: the proof refuses a version where the model lets a PMP entry that is OFF match every access
PASS  minstret_counted_twice: the proof refuses a version where the model counts two instructions per step in minstret
PASS  step_drops_core_update: the proof refuses a version where a safe step leaves the Tier 1 core as it was
PASS  step_escalates_to_mmode: the proof refuses a version where a safe step leaves the machine in M-mode
PASS  NAPOT encoding/decoding verified across 8 window sizes
PASS  PMP boundary containment and partial match cases verified
PASS  the Lean model agrees on all 1210 vectors (NAPOT range and U-mode load check)
```

