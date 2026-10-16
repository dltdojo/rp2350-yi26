# Phase 2 Design Document: Two-Tiered Refinement and Bridge Theorems in Lean 4 (`lean/Rv32/Refinement.lean`)

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **Document Date**: 2026-10-15
* **Target Deliverable**: `lean/Rv32/Refinement.lean`
* **Hardware Dependency**: Needs 0 (Pure formal specification and mechanized proof in Lean 4; no board or RTL required)
* **Upstream Prerequisite**: `lean/Rv32/Priv.lean` ([Phase 1 Design Document](./phase1_priv_machine_design.md)) and `lean/Rv32/Machine.lean` (Tier 1 Unprivileged Core Model)
* **Parent Architecture Plan**: [RISC-V M-Mode Privileged Micro-Model and Verified Micro-Monitor Design Plan](./2026-10-14-0925-micro-monitor-in-lean4-design-zh-tw.md)

## 1. Executive Summary and Phase 2 Objective

### Bridging Tier 2 Privileged Execution (`PrivMachine`) and Tier 1 Pure Computation (`Rv32.Machine`)

Phase 1 (`lean/Rv32/Priv.lean`) established the Tier 2 privileged state machine (`PrivMachine`), modeling `M-mode` and `U-mode` execution, Hazard3-specific CSRs, 32-byte `NAPOT` Physical Memory Protection (`PMP`), and architectural traps. Phase 2 (`lean/Rv32/Refinement.lean`) proves the **Refinement Bridge Theorems** that mathematically connect Tier 2 (`PrivMachine`) to the existing Tier 1 unprivileged model (`lean/Rv32/Machine.lean`).

The central guarantee proved in `lean/Rv32/Refinement.lean` is:

> Whenever `PrivMachine` executes in `U-mode` with PMP Entry 0 configured in `NAPOT` mode to grant `R/W/X` access over physical memory `[lo, hi)`, every single-step and multi-step execution that stays within `[lo, hi)` is strictly equivalent to `Rv32.step` and `Rv32.run` on the projected `Rv32.Machine` state, while any out-of-bounds fetch, load, or store deterministically traps into the `M-mode` Micro-Monitor without mutating memory or general-purpose registers.

### Zero Proof Rewriting for Existing Verified Kernels (`exp208`, `exp228`, `exp229`)

Without a formal refinement bridge, upgrading the repository from an unprivileged `RV32IM` model to an `M/U-mode` privileged architecture would require re-proving all existing cryptographic and consensus kernels against the expanded `PrivMachine` state—triggering the exact Lean 4 `simp`/`decide` out-of-memory (OOM) failures observed in earlier experiments (`exp201`, `exp229`).

By factoring the verification obligation through `lean/Rv32/Refinement.lean`, Phase 2 achieves **100% reuse of existing binary and proof artifacts**:

| Existing Verified Asset | Tier 1 Theorem Scope (`Rv32.Machine`) | How Phase 2 (`lean/Rv32/Refinement.lean`) Lifts the Proof to Tier 2 (`PrivMachine`) |
| :--- | :--- | :--- |
| **`exp229` (256-bit Mod-$p$ Field Arithmetic)** | Pure `U-mode` register/SRAM computation ending in `ecall` (`t0 = 1`, `HALT`) | Lifted via `run_epoch_refines` (for the pure `RV32IM` computation body) composed with the `t0 = 1` halt trap specification |
| **`exp208` (SHA-256 Compression Core)** | Pure `U-mode` memory-to-memory hashing over bounded SRAM buffers | Lifted directly via `run_epoch_refines`; proves that `PrivMachine` computes the exact SHA-256 digest while `minstret` advances by the exact Tier 1 step count |
| **`exp228` (Bitcoin Script Interpreter)** | Multi-epoch `U-mode` execution interspersed with `ecall` syscalls (`t0 = 0/2` `HASH`, `t0 = 3` `CHECKSIG`, `t0 = 1` `HALT`) | Lifted via `run_complete_refines`, which alternates `run_epoch_refines` with the compositional `MonitorImplementsEnv` syscall forwarding contract |

## 2. State Projection and the `UBoxed` Sandbox Invariant

### Projection from `PrivMachine` to `Rv32.Machine`

Because `PrivMachine` embeds the unmodified Tier 1 `core : Rv32.Machine` structure as a first-class field, state projection from Tier 2 to Tier 1 is a zero-cost field access (`PrivMachine.toUMachine`). No memory translation or register re-indexing occurs during projection.

```lean
import Rv32.Machine
import Rv32.Priv

namespace Rv32.Refinement

open Rv32
open Rv32.Priv

/-- Project a Tier 2 privileged machine state onto its Tier 1 unprivileged core. -/
@[inline]
def PrivMachine.toUMachine (s : PrivMachine) : Rv32.Machine :=
  s.core
```

### The `UBoxed` Sandbox Invariant and Well-Formed NAPOT Windows

To state when `PrivMachine` is properly sandboxed in `U-mode`, `lean/Rv32/Refinement.lean` pairs the `UBoxed` predicate introduced in Phase 1 with a well-formedness predicate `ValidNapotWindow lo hi` capturing the 32-byte (`PMP_GRAIN = 3`) alignment constraints of the RP2350 Hazard3 core:

```lean
/-- A physical address range [lo, hi) is a valid Hazard3 NAPOT window if its size
    is a power of two >= 32 bytes (2^5) and `lo` is naturally aligned to `size`. -/
def ValidNapotWindow (lo hi : UInt64) : Prop :=
  ∃ (k : Nat), 5 ≤ k ∧ k ≤ 32 ∧
    let size : UInt64 := (1 : UInt64) <<< k.toUInt64
    hi = lo + size ∧ (lo &&& (size - 1)) = 0

/-- Core sandbox invariant: PrivMachine is executing in U-mode, not halted,
    and PMP Entry 0 is configured in NAPOT mode covering [lo, hi) with R/W/X enabled. -/
structure UBoxed (s : PrivMachine) (lo hi : UInt64) : Prop where
  isUMode     : s.mode = .U
  notHalted   : s.core.halted = false
  cfg0Mode    : (decodePmpCfgByte s.csrs.pmpcfg0 ⟨0, by decide⟩).mode = .NAPOT
  cfg0Read    : (decodePmpCfgByte s.csrs.pmpcfg0 ⟨0, by decide⟩).r = true
  cfg0Write   : (decodePmpCfgByte s.csrs.pmpcfg0 ⟨0, by decide⟩).w = true
  cfg0Exec    : (decodePmpCfgByte s.csrs.pmpcfg0 ⟨0, by decide⟩).x = true
  addr0Range  : decodeNapotRange s.csrs.pmpaddr0 = (lo, hi)
  otherOff    : ∀ (i : Fin 4), i.val > 0 → (decodePmpCfgByte s.csrs.pmpcfg0 i).mode = .OFF
```

Including `otherOff` (or relying on Entry 0's highest priority for in-bounds accesses and requiring entries `1..3` to be `OFF` or `M-mode`-only locked regions disjoint from `U-mode`) guarantees a clean biconditional characterization of `pmpCheck`: in `U-mode`, an access succeeds **if and only if** it falls completely inside `[lo, hi)`.

## 3. PMP Containment Equivalence and Out-of-Bounds Isolation Lemmas

Before reasoning about instruction execution, `lean/Rv32/Refinement.lean` proves three foundational lemmas about `pmpCheck` under `UBoxed s lo hi`. Discharging these lemmas once prevents downstream instruction proofs from ever unfolding `decodeNapotRange`, `countTrailingOnes32`, or `decodePmpCfgByte`.

### Lemma 1: Exact Characterization of `matchPmpEntry` on Entry 0

```lean
/-- Under UBoxed s lo hi, PMP entry 0 returns FullMatch if and only if
    the requested access [addr, addr + width) is completely contained in [lo, hi). -/
theorem matchPmpEntry0_full_iff
    (s : PrivMachine) (lo hi : UInt64) (hBox : UBoxed s lo hi)
    (addr width : UInt32) (hWidth : 0 < width.toNat) :
    (∃ cfg, matchPmpEntry s.csrs ⟨0, by decide⟩ addr width = .FullMatch cfg ∧
            cfg.r = true ∧ cfg.w = true ∧ cfg.x = true) ↔
    (lo ≤ addr.toUInt64 ∧ addr.toUInt64 + width.toUInt64 ≤ hi)
```

### Lemma 2: Biconditional `pmpCheck` Equivalence in `U-Mode`

Because Entry 0 has the highest static priority in `pmpCheck` and entries `1..3` are `OFF` under `UBoxed`, any memory access `[addr, addr + width)` in `U-mode` is permitted if and only if it lies entirely within `[lo, hi)`:

```lean
/-- Master PMP equivalence lemma: In a UBoxed state, pmpCheck succeeds for any
    access type (Fetch, Load, Store) iff [addr, addr + width) ⊆ [lo, hi). -/
theorem pmpCheck_uboxed_iff
    (s : PrivMachine) (lo hi : UInt64) (hBox : UBoxed s lo hi)
    (addr width : UInt32) (acc : AccessType) (hWidth : 0 < width.toNat) :
    pmpCheck s.csrs s.mode addr width acc = true ↔
    (lo ≤ addr.toUInt64 ∧ addr.toUInt64 + width.toUInt64 ≤ hi)
```

### Lemma 3: Out-of-Bounds and Boundary-Straddling Rejection

Any access that either falls completely outside `[lo, hi)` (`addr + width ≤ lo` or `addr ≥ hi`) or straddles the boundary (`PartialMatch`) evaluates `pmpCheck` to `false`:

```lean
/-- Any memory request not fully contained in [lo, hi) is rejected by pmpCheck in U-mode. -/
theorem pmpCheck_uboxed_deny_of_out_of_bounds
    (s : PrivMachine) (lo hi : UInt64) (hBox : UBoxed s lo hi)
    (addr width : UInt32) (acc : AccessType) (hWidth : 0 < width.toNat)
    (hOut : ¬(lo ≤ addr.toUInt64 ∧ addr.toUInt64 + width.toUInt64 ≤ hi)) :
    pmpCheck s.csrs s.mode addr width acc = false
```

## 4. Single-Step Refinement and Fault Containment Theorems

### Categorizing Single-Step Behaviors in `U-Mode`

When `PrivMachine` takes a single step from a state satisfying `UBoxed s lo hi`, exactly one of three mutually exclusive outcomes occurs depending on the instruction at `s.core.pc`. `lean/Rv32/Refinement.lean` captures this partition via an explicit classification predicate `StepOutcome`:

| Instruction Category at `s.core.pc` | Address Condition | Tier 2 (`PrivMachine.step`) Behavior | Tier 1 (`Rv32.step`) Relationship |
| :--- | :--- | :--- | :--- |
| **In-Bounds Unprivileged `RV32IM`** (`ALU`, `Branch`, `Jump`, `Load`, `Store`, `Mul/Div`) | Fetch `[pc, pc+4) ⊆ [lo, hi)` and Load/Store `[addr, addr+w) ⊆ [lo, hi)` | Executes instruction in `U-mode`, updates `s.core`, preserves `UBoxed`, increments counters | **Strict Equality**: `(PrivMachine.step s).core = Rv32.step env s.core` |
| **In-Bounds `U-Mode` `ecall`** (`0x00000073`) | Fetch `[pc, pc+4) ⊆ [lo, hi)` | Raises synchronous trap (`mcause = 8`, `mepc = pc`, `mode = .M`, `pc = mtvec_base`) | **Handled by Syscall Contract**: M-mode monitor executes syscall and returns via `mret` to match `Rv32.step env s.core` |
| **Faulting / Out-of-Bounds / Privileged Attempt** (`Zicsr`, `mret`, or OOB Fetch/Load/Store) | Fetch or data access $\not\subseteq [\text{lo}, \text{hi})$, or illegal opcode in `U-mode` | Raises synchronous trap (`mcause ∈ {1, 2, 4, 5, 6, 7}`, `mepc = pc`, `mode = .M`, `pc = mtvec_base`) | **Containment Guarantee**: `s.core.mem` and `s.core.regs` are 100% unmodified (`NoLeakageOnFault`) |

### Instruction Safety Predicate (`SafeUInstr`)

To state the single-step refinement theorem cleanly without exposing internal decoding details to callers, `lean/Rv32/Refinement.lean` defines `SafeUInstr (s : PrivMachine) (lo hi : UInt64) : Prop`:

```lean
/-- Predicate asserting that the instruction at s.core.pc is a valid unprivileged
    RV32IM instruction (excluding ecall) whose fetch and effective memory access
    (if any) lie completely within [lo, hi). -/
structure SafeUInstr (s : PrivMachine) (lo hi : UInt64) : Prop where
  fetchInBounds : lo ≤ s.core.pc.toUInt64 ∧ s.core.pc.toUInt64 + 4 ≤ hi
  isUnprivRv32  : isUnprivilegedNonEcall (fetchWord s.core.mem s.core.pc) = true
  memInBounds   : ∀ (addr width : UInt32) (acc : AccessType),
    effectiveMemAccess s.core (fetchWord s.core.mem s.core.pc) = some (addr, width, acc) →
    lo ≤ addr.toUInt64 ∧ addr.toUInt64 + width.toUInt64 ≤ hi
```

### Theorem 1: Single-Step Commutation (`step_refines_non_ecall`)

```lean
/-- Core Single-Step Bridge Theorem:
    Under UBoxed s lo hi and SafeUInstr s lo hi, PrivMachine.step commutes strictly
    with Tier 1 Rv32.step, preserves UBoxed (provided the next PC does not halt),
    and leaves all privileged configuration CSRs invariant. -/
theorem step_refines_non_ecall
    (env : Rv32.Env) (s : PrivMachine) (lo hi : UInt64)
    (hBox  : UBoxed s lo hi)
    (hSafe : SafeUInstr s lo hi) :
    let s' := PrivMachine.step s
    s'.core = Rv32.step env s.core ∧
    s'.mode = .U ∧
    s'.csrs = bumpCounters s.csrs ∧
    (s'.core.halted = false → UBoxed s' lo hi)
```

**Why `env : Rv32.Env` disappears for non-`ecall` steps**: In Tier 1 `lean/Rv32/Machine.lean`, the environment parameter `env : Rv32.Env` is only consulted when executing `ecall`. For all other `RV32IM` instructions, `Rv32.step env s.core` is independent of `env`, allowing `step_refines_non_ecall` to hold universally for any `env`.

### Theorem 2: Fault Containment and Memory Non-Mutation (`step_fault_containment`)

Equally critical for the hardware wallet's security boundary is proving what happens when an untrusted or compromised `U-mode` domain (such as Domain 2 running the USB/display stack) attempts to read private keys outside `[lo, hi)` or execute a privileged `Zicsr`/`mret` instruction:

```lean
/-- Fault Containment Theorem:
    Whenever a U-mode instruction violates SafeUInstr (either by fetching/loading/storing
    outside [lo, hi) or attempting a privileged/illegal opcode), PrivMachine.step traps
    into M-mode at mtvec while leaving general-purpose registers and memory untouched. -/
theorem step_fault_containment
    (s : PrivMachine) (lo hi : UInt64)
    (hBox : UBoxed s lo hi)
    (hFault : isFaultingUInstr s lo hi) :
    let s' := PrivMachine.step s
    s'.mode = .M ∧
    s'.core.pc = (s.csrs.mtvec &&& (~~~0x3 : UInt32)) ∧
    s'.core.regs = s.core.regs ∧
    s'.core.mem = s.core.mem ∧
    s'.csrs.mepc = s.core.pc ∧
    s'.csrs.mcause ∈ ({1, 2, 5, 7} : List UInt32)
```

## 5. Multi-Step Refinement and Compositional Syscall Forwarding

### Why Multi-Step Refinement Splits into Epochs and Syscall Transitions

A central architectural difference between Tier 1 (`Rv32.Machine`) and Tier 2 (`PrivMachine`) lies in how `ecall` is executed:

* **In Tier 1 (`Rv32.step env c`)**: An `ecall` instruction executes in **1 abstract step**, invoking `env` to either halt (`t0 = 1`) or compute SHA-256 (`t0 = 0/2`) / `CHECKSIG` (`t0 = 3`) and advance `c.pc ← c.pc + 4`.
* **In Tier 2 (`PrivMachine`)**: An `ecall` instruction in `U-mode` takes **1 step to trap** into `M-mode` (`mcause = 8`, `pc = mtvec`), followed by **`k_sys` steps of `M-mode` Micro-Monitor instructions** that validate buffer bounds against PMP, execute the operation, freeze/unfreeze `mcountinhibit`, set `mepc ← mepc + 4`, and execute `mret` to return to `U-mode`.

To bridge this 1-to-`(1 + k_sys)` step expansion cleanly without entangling Phase 2 with the specific assembly code of the Micro-Monitor (which belongs to Phase 3), `lean/Rv32/Refinement.lean` structures multi-step refinement into two composable layers:

1. **Pure `U-Mode` Epoch Refinement (`run_epoch_refines`)**: Covers any `n`-step contiguous sequence of non-`ecall` `U-mode` instructions (`1 : 1` lockstep with `Rv32.run`).
2. **Compositional Monitor Syscall Contract (`MonitorImplementsEnv`)**: Defines the exact formal interface that the Phase 3 Micro-Monitor proof (`proof/Monitor.lean`) satisfies, and proves that any monitor satisfying `MonitorImplementsEnv` refines full multi-epoch `Rv32.run` executions end-to-end.

### Theorem 3: Multi-Step Pure `U-Mode` Epoch Refinement (`run_epoch_refines`)

```lean
/-- Predicate asserting that a Tier 1 execution trace of `n` steps from `s.core`
    executes only in-bounds unprivileged non-ecall instructions within [lo, hi). -/
def SafeUEpoch (env : Rv32.Env) (s : PrivMachine) (lo hi : UInt64) : Nat → Prop
  | 0 => True
  | n + 1 =>
    SafeUInstr s lo hi ∧
    SafeUEpoch env (PrivMachine.step s) lo hi n

/-- Multi-Step Epoch Bridge Theorem:
    Over any n-step safe U-mode epoch, PrivMachine.run n s projects identically to
    Rv32.run n env s.core, preserves UBoxed, and advances minstret by exactly n
    (when mcountinhibit.ir is false). -/
theorem run_epoch_refines
    (env : Rv32.Env) (n : Nat) (s : PrivMachine) (lo hi : UInt64)
    (hBox   : UBoxed s lo hi)
    (hEpoch : SafeUEpoch env s lo hi n)
    (hNoInh : s.csrs.mcountinhibit.ir = false) :
    let s' := PrivMachine.run n s
    s'.core = Rv32.run n env s.core ∧
    s'.mode = .U ∧
    s'.csrs.minstret = s.csrs.minstret + n.toUInt32 ∧
    (s'.core.halted = false → UBoxed s' lo hi)
```

### Compositional Interface for Phase 3 (`MonitorImplementsEnv`)

To connect `ecall` traps in Phase 2 to the Micro-Monitor binary proved in Phase 3, `lean/Rv32/Refinement.lean` defines the `MonitorImplementsEnv` contract:

```lean
/-- Formal contract specifying that the M-mode Micro-Monitor loaded at `mtvec`
    correctly implements the Tier 1 `env : Rv32.Env` syscall ABI for a UBoxed domain. -/
structure MonitorImplementsEnv (env : Rv32.Env) (lo hi : UInt64) (s : PrivMachine) : Prop where
  /-- 1. Non-halting Syscall Forwarding (t0 ∈ {0, 2, 3}):
      When U-mode executes `ecall` with valid in-bounds arguments inside [lo, hi),
      the trap + monitor execution completes in `1 + k_sys` PrivMachine steps,
      returning to U-mode via `mret` with `.core = Rv32.step env s.core`,
      preserving `UBoxed`, and adding zero uninhibited `minstret` overhead
      (or the exact proved constant `c_mon` before/after `csrwi mcountinhibit, 5`). -/
  syscall_resume :
    isInBoundsNonHaltingEcall s lo hi →
    ∃ (k_sys : Nat),
      let s_after := PrivMachine.run (1 + k_sys) s
      s_after.core = Rv32.step env s.core ∧
      UBoxed s_after lo hi

  /-- 2. Halting Syscall & Zeroization (t0 = 1):
      When U-mode executes `ecall` with `t0 = 1` (HALT), the trap + monitor
      execution completes in `1 + k_halt` steps, recording the exit code from `a0`
      and zeroizing general-purpose registers `x1..x31` (except `a0`) and scratch SRAM. -/
  syscall_halt :
    isHaltingEcall s lo hi →
    ∃ (k_halt : Nat),
      let s_after := PrivMachine.run (1 + k_halt) s
      s_after.core.regs.read .a0 = (Rv32.step env s.core).regs.read .a0 ∧
      (∀ r : Reg, r ≠ .a0 → s_after.core.regs.read r = 0)
```

### Theorem 4: End-to-End Multi-Epoch Refinement (`run_complete_refines`)

Using `run_epoch_refines` and `MonitorImplementsEnv`, `lean/Rv32/Refinement.lean` proves by induction on the number of `U-mode` steps `N` that any Tier 1 execution `Rv32.run N env s.core` terminating in a halt (`t0 = 1`) corresponds to a concrete step count `N_priv` on `PrivMachine` that produces the identical output in `a0`, enforces `[lo, hi)` isolation on every intermediate step, and finishes in a zeroized state:

```lean
/-- End-to-End Compositional Refinement Theorem:
    Any Tier 1 computation of N steps that stays within [lo, hi) and terminates via
    a halting ecall refines to a concrete PrivMachine execution of N_priv steps
    producing the identical exit status in `a0` and zeroizing all other registers. -/
theorem run_complete_refines
    (env : Rv32.Env) (N : Nat) (s : PrivMachine) (lo hi : UInt64)
    (hBox  : UBoxed s lo hi)
    (hSafe : SafeUTrace env s.core lo hi N)
    (hMon  : ∀ st, ReachableAtEcall s st → MonitorImplementsEnv env lo hi st)
    (hHalt : (Rv32.run N env s.core).halted = true) :
    ∃ (N_priv : Nat),
      let s_final := PrivMachine.run N_priv s
      s_final.core.regs.read .a0 = (Rv32.run N env s.core).regs.read .a0 ∧
      (∀ r : Reg, r ≠ .a0 → s_final.core.regs.read r = 0)
```

## 6. Proof Engineering Strategy to Prevent Lean 4 OOM

Past experiments (`exp201`, `exp229`) showed that naive unfolding of `Rv32.step` inside a larger state wrapper causes Lean's kernel and `simp` engine to construct exponential term trees over 32-bit bitvectors and instruction decoders. `lean/Rv32/Refinement.lean` enforces four structural proof rules to keep memory usage flat and compilation under 5 seconds:

| Proof Hazard | Root Cause in Lean 4 | Mitigation Enforced in `lean/Rv32/Refinement.lean` |
| :--- | :--- | :--- |
| **Simultaneous Unfolding of Tier 1 and Tier 2 Decoders** | Expanding both `PrivMachine.step` and `Rv32.step` in the same goal duplicates the 40-way `RV32IM` opcode match tree | Factor `PrivMachine.step` in `Priv.lean` so Stage 4 literally calls `Rv32.step env s.core` after passing a standalone `checkMemAccess : PrivMachine → Instr → Option UInt32` gate |
| **Bitvector Explosion in `decodeNapotRange`** | Repeatedly simplifying `countTrailingOnes32` on symbolic `pmpaddr0` terms | Keep `decodeNapotRange s.csrs.pmpaddr0 = (lo, hi)` as an opaque hypothesis inside `UBoxed`; rewrite using `hBox.addr0Range` directly without unfolding `decodeNapotRange` |
| **Redundant CSR Record Updates** | Updating `s.csrs` fields inside every instruction branch | Factor counter increments into a single outer `bumpCounters` wrapper so `s'.csrs = bumpCounters s.csrs` is proved in one `rfl` step for all non-trapping `U-mode` instructions |
| **Deep Fuel Induction Blowup** | Unrolling `PrivMachine.run k` symbolically when `k > 50` | Prove `PrivMachine.run_add (m n : Nat) (s : PrivMachine) : PrivMachine.run (m + n) s = PrivMachine.run n (PrivMachine.run m s)` and compose epochs modularly via `rw [PrivMachine.run_add]` |

### Structural Factorization Required in `PrivMachine.step`

To make the proof of `step_refines_non_ecall` a 10-line proof rather than a 40-case enumeration, `PrivMachine.step` (from Phase 1) and `lean/Rv32/Refinement.lean` share the helper `uModePrecheck`:

```lean
/-- Returns `none` if the instruction at s.core.pc is permitted to execute via Tier 1
    Rv32.step, or `some mcause` if it must trap into M-mode. -/
def uModeTrapCause (s : PrivMachine) (instWord : UInt32) : Option UInt32 :=
  if !pmpCheck s.csrs s.mode s.core.pc 4 .Fetch then
    some CAUSE_FETCH_ACCESS_FAULT
  else if isEcall instWord then
    some (if s.mode == .U then CAUSE_ECALL_UMODE else CAUSE_ECALL_MMODE)
  else if isMretOrZicsr instWord then
    some CAUSE_ILLEGAL_INSTR  -- When called in U-mode
  else
    match effectiveMemAccess s.core instWord with
    | none => none
    | some (addr, width, acc) =>
      if pmpCheck s.csrs s.mode addr width acc then none
      else some (match acc with
                 | .Fetch => CAUSE_FETCH_ACCESS_FAULT
                 | .Load  => CAUSE_LOAD_ACCESS_FAULT
                 | .Store => CAUSE_STORE_ACCESS_FAULT)
```

With this factorization:
1. Lemma `uModeTrapCause_eq_none_of_SafeUInstr` proves `uModeTrapCause s instWord = none` in 8 lines using `pmpCheck_uboxed_iff`.
2. Theorem `step_refines_non_ecall` then rewrites `PrivMachine.step s` by `uModeTrapCause_eq_none_of_SafeUInstr` and discharges `s'.core = Rv32.step env s.core` by `rfl`—**zero 40-way case analysis over `RV32IM` ALU opcodes is ever performed**.

## 7. Direct Instantiation for Existing Kernels and Acceptance Criteria

### Lifting `exp229`, `exp208`, and `exp228` in Downstream Proofs

Once `lean/Rv32/Refinement.lean` is compiled, existing Tier 1 kernel proofs lift to `PrivMachine` as immediate corollaries:

```lean
/-- Example Corollary: Lifting exp229 (256-bit Mod-p multiplication/inversion)
    from Tier 1 Rv32.Machine to Tier 2 PrivMachine without modifying Exp229.lean. -/
theorem exp229_priv_correct
    (env : Rv32.Env) (s : PrivMachine) (lo hi : UInt64)
    (hBox   : UBoxed s lo hi)
    (hEpoch : SafeUEpoch env s lo hi Exp229.steps)
    (hNoInh : s.csrs.mcountinhibit.ir = false)
    (hPre   : Exp229.Precondition s.core) :
    Exp229.Postcondition (PrivMachine.run Exp229.steps s).core ∧
    (PrivMachine.run Exp229.steps s).csrs.minstret =
      s.csrs.minstret + Exp229.steps.toUInt32 := by
  have ⟨hCore, _, hInst, _⟩ := run_epoch_refines env Exp229.steps s lo hi hBox hEpoch hNoInh
  rw [hCore]
  exact ⟨Exp229.correct env s.core hPre, hInst⟩
```

### Phase 2 Acceptance Criteria and Verification Checklist

Before advancing from Phase 2 (`lean/Rv32/Refinement.lean`) to Phase 3 (`monitor.bin` and `proof/Monitor.lean`), the implementation must satisfy the following criteria:

* **Zero Modification to Tier 1 and Existing Kernel Proofs**: `git diff lean/Rv32/Machine.lean` and `git diff` across `exp208`, `exp228`, and `exp229` remain completely empty.
* **Zero `sorry` Axioms and Compact Proof Size**: `lean/Rv32/Refinement.lean` compiles cleanly with zero `sorry` declarations and stays under 350 lines of Lean 4 code.
* **Fast Compilation**: `lake build Rv32.Refinement` completes in under 5 seconds with no `maxHeartbeats` overrides required.
* **Required Exported Theorems in `lean/Rv32/Refinement.lean`**:
  * `pmpCheck_uboxed_iff`: Biconditional equivalence between `pmpCheck` in `U-mode` and `[addr, addr + width) ⊆ [lo, hi)`.
  * `step_refines_non_ecall`: Single-step commutation between `PrivMachine.step` and `Rv32.step` with `UBoxed` invariant preservation.
  * `step_fault_containment`: Proof that any out-of-bounds or privileged instruction in `U-mode` traps to `mtvec` with `s.core.regs` and `s.core.mem` untouched.
  * `PrivMachine.run_add`: Compositional fuel splitting (`PrivMachine.run (m + n) s = PrivMachine.run n (PrivMachine.run m s)`).
  * `run_epoch_refines`: Multi-step pure `U-mode` epoch equivalence and exact `minstret` advancement theorem.
  * `run_complete_refines`: End-to-end multi-epoch refinement modulo `MonitorImplementsEnv`.
