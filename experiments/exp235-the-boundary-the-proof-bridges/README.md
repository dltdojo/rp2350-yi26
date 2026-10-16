# exp235 — the boundary the proof bridges

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Hazard3 privilege semantics and U-mode refinement, proved in Lean 4. Without
modifying a single line of Tier 1 `lean/Rv32/Machine.lean`, a Tier 2 privileged
micro-model (`PrivMachine`) formalizes RP2350 Hazard3's M-mode CSRs, 32-byte
NAPOT PMP address matching, hardware readback quirks (bits `[1:0] == 0b11`),
default-deny protection, and trap handling. A bridge theorem proves that under
`UBoxed` configuration, every safe U-mode instruction executes step-for-step
identically to Tier 1 unprivileged execution, while hardware counters
(`minstret`) track execution without drift. Six wrong privilege models and
claims in `proof/mutants.txt` are refused.**

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
  │ - Untouched: 0 lines modified (verified by check.sh)        │
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

4. **Hardware Performance Counters**:
   `mcountinhibit` controls whether `mcycle` (bit 0) and `minstret` (bit 2)
   advance. Theorems `priv_mcountinhibit_mcycle` and `priv_mcountinhibit_minstret`
   prove that inhibited counters remain frozen, while `priv_minstret_step`
   proves exact +1 progression on uninhibited steps.

## The Refinement Bridge

Under `UBoxed s lo hi`, PMP entry 0 is configured as NAPOT covering `[lo, hi)`
with `RWX` permissions, and all other entries are `OFF`.
- **`uboxed_pmp_iff`**: An access succeeds if and only if $[addr, addr + width) \subseteq [lo, hi)$.
- **`safe_step_no_trap`**: Instructions staying within the box never trigger privilege faults.
- **`safe_step_running_core`**: Running instructions step the Tier 1 core state identically,
  staying in U-mode with halted = false.
- **`safe_step_halted_core`**: Halting instructions transition to halted = true with the core
  state preserved.
- **`priv_run_split`**: Multi-step execution satisfies compositional fuel splitting:
  `PrivMachine.run env (m + n) s = PrivMachine.run env n (PrivMachine.run env m s)`.

## Expected output

From `./run.sh`, pasted from `capture.txt`; no board is involved.

```
=== exp235 — the boundary the proof bridges ===
recorded at 2026-10-16T00:43:50Z from commit cd9c650

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
'Exp235.priv_run_split' depends on axioms: [propext, Quot.sound]
exit 0

>>> wrong privilege semantics and wrong claims: each must be refused
napot_readback_zero     NAPOT readback claims bits [1:0] read as 00b instead of 11b                   refused in pmp_napot_readback
default_deny_inverted   default-deny claims U-mode access is granted when all PMP entries are OFF     refused in pmp_umode_default_deny
pmp_bounds_inverted     PMP UBoxed equivalence claims out-of-bounds addresses are accepted            refused in uboxed_pmp_iff
csr_umode_permitted     U-mode CSR execution is permitted without raising illegal instruction trap    refused in PrivMachine.step_eq_of_safe
mret_umode_permitted    U-mode MRET execution is permitted without raising illegal instruction trap   refused in umode_zicsr_traps
step_switches_to_mmode  Safe U-mode execution is claimed to escalate mode to M-mode                   refused in safe_step_running_core

>>> Python test vectors for Hazard3 NAPOT boundary logic
PASS  NAPOT encoding/decoding verified across 8 window sizes
PASS  PMP boundary containment and partial match cases verified

>>> the checks
PASS  no lifeline, and it says why: no firmware of its own
PASS  lean/Rv32/Machine.lean is completely untouched (0 lines modified)
PASS  Bridge.lean checks, with no errors and no warnings
PASS  all 13 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  napot_readback_zero: the proof refuses a version where NAPOT readback claims bits [1:0] read as 00b instead of 11b
PASS  default_deny_inverted: the proof refuses a version where default-deny claims U-mode access is granted when all PMP entries are OFF
PASS  pmp_bounds_inverted: the proof refuses a version where PMP UBoxed equivalence claims out-of-bounds addresses are accepted
PASS  csr_umode_permitted: the proof refuses a version where U-mode CSR execution is permitted without raising illegal instruction trap
PASS  mret_umode_permitted: the proof refuses a version where U-mode MRET execution is permitted without raising illegal instruction trap
PASS  step_switches_to_mmode: the proof refuses a version where Safe U-mode execution is claimed to escalate mode to M-mode
PASS  NAPOT encoding/decoding verified across 8 window sizes
PASS  PMP boundary containment and partial match cases verified
```

