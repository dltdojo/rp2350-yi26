/-
SPDX-License-Identifier: Apache-2.0

# exp235 — the boundary the proof bridges

Formal proofs that Hazard3 privilege semantics (M-mode CSRs, 32-byte NAPOT PMP,
default-deny, illegal instruction traps) and U-mode execution refine Tier 1
Rv32.Machine semantics without a single modification to Rv32.Machine.
-/
import Rv32.Priv
import Rv32.Refinement

namespace Exp235
open Rv32
open Rv32.Priv
open Rv32.Refinement

/-! ## 1. Hazard3 Silicon Quirks and Privilege Semantics -/

/-- Hazard3 silicon property: NAPOT PMP address readback has bits [1:0] == 0b11 (exp209). -/
theorem pmp_napot_readback (csrs : PrivCSRs) (idx : Fin 4)
    (h : (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .NAPOT) :
    (readPmpAddr csrs idx &&& 3#32) = 3#32 :=
  pmp_readback_napot_low_bits csrs idx h

/-- Hazard3 silicon property: Default-deny for U-mode when all PMP entries are OFF. -/
theorem pmp_umode_default_deny
    (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (hOff : ∀ idx, (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .OFF) :
    pmpCheck csrs .U addr width acc = false :=
  umode_default_deny csrs addr width acc hOff

/-- Privilege boundary: Zicsr in U-mode always triggers illegal instruction trap. -/
theorem priv_umode_zicsr_traps (s : PrivMachine) (w : Word) (hMode : s.mode = .U) :
    execZicsr s w = raiseTrap s CAUSE_ILLEGAL_INSTR :=
  umode_zicsr_traps s w hMode

/-- Privilege boundary: MRET in U-mode always triggers illegal instruction trap. -/
theorem priv_umode_mret_traps (s : PrivMachine) (hMode : s.mode = .U) :
    execMret s = raiseTrap s CAUSE_ILLEGAL_INSTR :=
  umode_mret_traps s hMode

/-- Counter inhibit: bit 0 of mcountinhibit holds mcycle frozen. -/
theorem priv_mcountinhibit_mcycle (csrs : PrivCSRs) (hCY : csrs.mcountinhibit.cy = true) :
    (bumpCounters csrs).mcycle = csrs.mcycle :=
  mcountinhibit_holds_mcycle csrs hCY

/-- Counter inhibit: bit 2 of mcountinhibit holds minstret frozen. -/
theorem priv_mcountinhibit_minstret (csrs : PrivCSRs) (hIR : csrs.mcountinhibit.ir = true) :
    (bumpCounters csrs).minstret = csrs.minstret :=
  mcountinhibit_holds_minstret csrs hIR

/-- Counter progression: when ir = false, minstret increments by 1 on each step. -/
theorem priv_minstret_step (csrs : PrivCSRs) (hIR : csrs.mcountinhibit.ir = false) :
    (bumpCounters csrs).minstret = csrs.minstret + 1 :=
  bumpCounters_minstret_step csrs hIR

/-! ## 2. PMP Equivalence under UBoxed Configuration -/

/-- Under UBoxed configuration, PMP check succeeds iff access is entirely contained in [lo, hi). -/
theorem uboxed_pmp_iff
    (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi)
    (addr : Word) (width : Nat) (acc : AccessType) (hWidth : 0 < width) :
    pmpCheck s.csrs s.mode addr width acc = true ↔
    (lo ≤ addr.toNat ∧ addr.toNat + width ≤ hi) :=
  pmpCheck_uboxed_iff s lo hi hBox addr width acc hWidth

/-! ## 3. Single-step Refinement -/

/-- Under UBoxed and SafeUInstr, no privilege trap is generated. -/
theorem safe_step_no_trap
    (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi) :
    let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
    uModeTrapCause s w = none :=
  uModeTrapCause_eq_none_of_SafeUInstr s lo hi hBox hSafe

/-- PrivMachine single step directly executes Tier 1 instruction when safe. -/
theorem safe_step_executes
    (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi) :
    let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
    ∃ instr, Rv32.decode w = some instr ∧
      PrivMachine.step env s =
        match Rv32.exec env s.core instr with
        | .running core'  => { s with core := core', csrs := bumpCounters s.csrs }
        | .halted _ core' => { s with core := core', csrs := bumpCounters s.csrs, halted := true }
        | .fault _ _      => raiseTrap s CAUSE_ILLEGAL_INSTR :=
  PrivMachine.step_eq_of_safe env s lo hi hBox hSafe

/-- When instruction continues running, Tier 1 core state is precisely updated and mode remains U. -/
theorem safe_step_running_core
    (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi)
    {instr : Instr} (hDec : Rv32.decode (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = some instr)
    {core' : Rv32.Machine} (hExec : Rv32.exec env s.core instr = .running core') :
    toUMachine (PrivMachine.step env s) = core' ∧
    (PrivMachine.step env s).halted = false ∧
    (PrivMachine.step env s).mode = .U := by
  have ⟨hCore, hNotHalt, hMode, _⟩ := step_refines_running env s lo hi hBox hSafe hDec hExec
  exact ⟨hCore, hNotHalt, hMode⟩

/-- When instruction halts, Tier 1 core state is preserved and machine transitions to halted. -/
theorem safe_step_halted_core
    (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi)
    {instr : Instr} (hDec : Rv32.decode (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = some instr)
    {code : Word} {core' : Rv32.Machine} (hExec : Rv32.exec env s.core instr = .halted code core') :
    toUMachine (PrivMachine.step env s) = core' ∧
    (PrivMachine.step env s).halted = true ∧
    (PrivMachine.step env s).mode = .U := by
  have ⟨hCore, hHalt, hMode, _⟩ := step_refines_halted env s lo hi hBox hSafe hDec hExec
  exact ⟨hCore, hHalt, hMode⟩

/-! ## 4. Multi-step Execution and Hardware Counter Invariance -/

/-- Compositional execution: fuel split lemma holds for PrivMachine.run. -/
theorem priv_run_split (env : Rv32.Env) (m n : Nat) (s : PrivMachine) :
    PrivMachine.run env (m + n) s = PrivMachine.run env n (PrivMachine.run env m s) :=
  PrivMachine.run_add env m n s

end Exp235

#print axioms Exp235.pmp_napot_readback
#print axioms Exp235.pmp_umode_default_deny
#print axioms Exp235.priv_umode_zicsr_traps
#print axioms Exp235.priv_umode_mret_traps
#print axioms Exp235.priv_mcountinhibit_mcycle
#print axioms Exp235.priv_mcountinhibit_minstret
#print axioms Exp235.priv_minstret_step
#print axioms Exp235.uboxed_pmp_iff
#print axioms Exp235.safe_step_no_trap
#print axioms Exp235.safe_step_executes
#print axioms Exp235.safe_step_running_core
#print axioms Exp235.safe_step_halted_core
#print axioms Exp235.priv_run_split
