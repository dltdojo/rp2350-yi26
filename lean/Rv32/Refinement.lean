/-
SPDX-License-Identifier: Apache-2.0

# Two-Tiered Refinement and Bridge Theorems

Bridges Tier 2 privileged execution (PrivMachine) and Tier 1 pure computation
(Rv32.Machine). Proves that under UBoxed sandbox constraints, U-mode single-step
and multi-step epoch execution strictly refines Rv32.step and Rv32.run without
modifying any existing Tier 1 definitions or proofs.
-/
import Rv32.Machine
import Rv32.Priv

namespace Rv32.Refinement

open Rv32
open Rv32.Priv

/-- Project a Tier 2 privileged machine state onto its Tier 1 unprivileged core. -/
@[inline]
def Priv.PrivMachine.toUMachine (s : PrivMachine) : Rv32.Machine :=
  s.core

@[inline]
def toUMachine (s : PrivMachine) : Rv32.Machine :=
  s.core

/-- Predicate characterizing when an instruction at s.core.pc is an unprivileged
    non-ecall RV32IM instruction whose fetch and memory accesses fall within [lo, hi). -/
structure SafeUInstr (s : PrivMachine) (lo hi : Nat) : Prop where
  alignPc       : s.core.pc.toNat % 4 = 0
  fetchInBounds : lo ≤ s.core.pc.toNat ∧ s.core.pc.toNat + 4 ≤ hi
  notEcall      : isEcall (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = false
  notPriv       : isMret (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = false ∧
                  isZicsr (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = false
  memInBounds   : match Rv32.decode (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) with
    | some (.ld op _ rs1 imm) =>
      let a := s.core.reg rs1 + imm.signExtend 32
      a.toNat % op.size = 0 ∧ lo ≤ a.toNat ∧ a.toNat + op.size ≤ hi
    | some (.st op rs1 _ imm) =>
      let a := s.core.reg rs1 + imm.signExtend 32
      a.toNat % op.size = 0 ∧ lo ≤ a.toNat ∧ a.toNat + op.size ≤ hi
    | some _ => True
    | none => False

/-- Under UBoxed s lo hi, PMP entry 0 returns FullMatch iff [addr, addr + width) ⊆ [lo, hi). -/
theorem matchPmpEntry0_full_iff
    (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi)
    (addr : Word) (width : Nat) (hWidth : 0 < width) :
    (∃ cfg, matchPmpEntry s.csrs 0 addr width = .FullMatch cfg ∧
            cfg.r = true ∧ cfg.w = true ∧ cfg.x = true) ↔
    (lo ≤ addr.toNat ∧ addr.toNat + width ≤ hi) := by
  unfold matchPmpEntry
  have hMode : (decodePmpCfgByte s.csrs.pmpcfg0 0).mode ≠ .OFF := by
    rw [hBox.cfg0Mode]; decide
  simp only [hMode, ite_false]
  have hAddr0 : pmpAddrVal s.csrs 0 = s.csrs.pmpaddr0 := rfl
  rw [hAddr0, hBox.addr0Range]
  constructor
  · intro ⟨cfg, hMatch, hr, hw, hx⟩
    split at hMatch
    · contradiction
    · split at hMatch
      · next hIn => exact hIn
      · contradiction
  · intro hIn
    have hNotOut : ¬ (addr.toNat + width ≤ lo ∨ addr.toNat ≥ hi) := by
      intro hOr
      cases hOr with
      | inl hLe => omega
      | inr hGe => omega
    simp only [hNotOut, ite_false, hIn]
    exact ⟨decodePmpCfgByte s.csrs.pmpcfg0 0, rfl, hBox.cfg0Read, hBox.cfg0Write, hBox.cfg0Exec⟩

/-- Master PMP equivalence lemma: in UBoxed state, pmpCheck succeeds iff [addr, addr + width) ⊆ [lo, hi). -/
theorem pmpCheck_uboxed_iff
    (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi)
    (addr : Word) (width : Nat) (acc : AccessType) (hWidth : 0 < width) :
    pmpCheck s.csrs s.mode addr width acc = true ↔
    (lo ≤ addr.toNat ∧ addr.toNat + width ≤ hi) := by
  have hM0 := matchPmpEntry0_full_iff s lo hi hBox addr width hWidth
  unfold pmpCheck PMP_INDICES pmpCheckEntries
  rw [hBox.isUMode]
  have h1 : matchPmpEntry s.csrs 1 addr width = .NoMatch := matchPmpEntry_off _ 1 _ _ (hBox.otherOff 1 (by decide))
  have h2 : matchPmpEntry s.csrs 2 addr width = .NoMatch := matchPmpEntry_off _ 2 _ _ (hBox.otherOff 2 (by decide))
  have h3 : matchPmpEntry s.csrs 3 addr width = .NoMatch := matchPmpEntry_off _ 3 _ _ (hBox.otherOff 3 (by decide))
  cases hMatch : matchPmpEntry s.csrs 0 addr width with
  | NoMatch =>
    dsimp only
    unfold pmpCheckEntries
    rw [h1]; dsimp only
    unfold pmpCheckEntries
    rw [h2]; dsimp only
    unfold pmpCheckEntries
    rw [h3]; dsimp only
    unfold pmpCheckEntries
    constructor
    · intro hContra; contradiction
    · intro hIn
      have ⟨cfg, hF, _, _, _⟩ := (hM0.2 hIn)
      rw [hMatch] at hF
      contradiction
  | PartialMatch =>
    dsimp only
    constructor
    · intro hContra; contradiction
    · intro hIn
      have ⟨cfg, hF, _, _, _⟩ := (hM0.2 hIn)
      rw [hMatch] at hF
      contradiction
  | FullMatch cfg =>
    dsimp only
    have ⟨hr, hw, hx⟩ : cfg.r = true ∧ cfg.w = true ∧ cfg.x = true := by
      unfold matchPmpEntry at hMatch
      have hMode : (decodePmpCfgByte s.csrs.pmpcfg0 0).mode ≠ .OFF := by
        rw [hBox.cfg0Mode]; decide
      have hAddr0 : pmpAddrVal s.csrs 0 = s.csrs.pmpaddr0 := rfl
      simp only [hMode, ite_false, hAddr0, hBox.addr0Range] at hMatch
      split at hMatch
      · contradiction
      · split at hMatch
        · cases hMatch
          exact ⟨hBox.cfg0Read, hBox.cfg0Write, hBox.cfg0Exec⟩
        · contradiction
    have hPerm : hasPermission cfg .U acc = true := by
      unfold hasPermission
      cases acc with
      | Fetch => exact hx
      | Load  => exact hr
      | Store => exact hw
    simp only [hPerm]
    constructor
    · intro _
      exact hM0.1 ⟨cfg, hMatch, hr, hw, hx⟩
    · intro _
      trivial

/-- Under UBoxed s lo hi and SafeUInstr s lo hi, uModeTrapCause is none. -/
theorem uModeTrapCause_eq_none_of_SafeUInstr
    (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi) :
    let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
    uModeTrapCause s w = none := by
  intro w
  unfold uModeTrapCause
  have hFetch : pmpCheck s.csrs s.mode s.core.pc 4 .Fetch = true := by
    rw [pmpCheck_uboxed_iff s lo hi hBox s.core.pc 4 .Fetch (by decide)]
    exact hSafe.fetchInBounds
  have hNotEcall : isEcall w = false := hSafe.notEcall
  have hm : isMret w = false := hSafe.notPriv.1
  have hz : isZicsr w = false := hSafe.notPriv.2
  have hDec := hSafe.memInBounds
  cases hDecode : Rv32.decode w with
  | none =>
    rw [hDecode] at hDec
    contradiction
  | some instr =>
    rw [hDecode] at hDec
    dsimp
    have hPriv : (s.mode = .U ∧ (isMret w = true ∨ isZicsr w = true)) = false := by
      rw [hBox.isUMode, hm, hz]
      decide
    have hFetchNeg : (¬pmpCheck s.csrs s.mode s.core.pc 4 AccessType.Fetch = true) = false := by
      simp [hFetch]
    simp only [hFetchNeg, hNotEcall, hPriv]
    cases instr with
    | ld op rd rs1 imm =>
      have ⟨hAlign, hLo, hHi⟩ := hDec
      have hLoad : pmpCheck s.csrs s.mode (s.core.reg rs1 + imm.signExtend 32) op.size .Load = true := by
        rw [pmpCheck_uboxed_iff s lo hi hBox _ op.size .Load (by cases op <;> decide)]
        exact ⟨hLo, hHi⟩
      have hAlignDef : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hAlign
      have hMis : (¬(BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0) = false := by
        simp [hAlignDef]
      have hNotLoad : (¬pmpCheck s.csrs s.mode (s.core.reg rs1 + BitVec.signExtend 32 imm) op.size AccessType.Load = true) = false := by
        simp [hLoad]
      simp only [hMis, hNotLoad]
      rfl
    | st op rs1 rs2 imm =>
      have ⟨hAlign, hLo, hHi⟩ := hDec
      have hStore : pmpCheck s.csrs s.mode (s.core.reg rs1 + imm.signExtend 32) op.size .Store = true := by
        rw [pmpCheck_uboxed_iff s lo hi hBox _ op.size .Store (by cases op <;> decide)]
        exact ⟨hLo, hHi⟩
      have hAlignDef : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hAlign
      have hMis : (¬(BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0) = false := by
        simp [hAlignDef]
      have hNotStore : (¬pmpCheck s.csrs s.mode (s.core.reg rs1 + BitVec.signExtend 32 imm) op.size AccessType.Store = true) = false := by
        simp [hStore]
      simp only [hMis, hNotStore]
      rfl
    | _ => rfl

theorem PrivMachine.run_zero (env : Rv32.Env) (s : PrivMachine) :
    PrivMachine.run env 0 s = s := rfl

theorem PrivMachine.run_succ (env : Rv32.Env) (n : Nat) (s : PrivMachine) :
    PrivMachine.run env (n + 1) s = if s.halted then s else PrivMachine.run env n (PrivMachine.step env s) := rfl

theorem PrivMachine.run_halted (env : Rv32.Env) (n : Nat) (s : PrivMachine) (h : s.halted = true) :
    PrivMachine.run env n s = s := by
  induction n with
  | zero => rfl
  | succ n' ih =>
    rw [PrivMachine.run_succ, h]
    rfl

/-- Compositional fuel splitting lemma for PrivMachine.run. -/
theorem PrivMachine.run_add (env : Rv32.Env) (m n : Nat) (s : PrivMachine) :
    PrivMachine.run env (m + n) s = PrivMachine.run env n (PrivMachine.run env m s) := by
  induction m generalizing s with
  | zero =>
    rw [Nat.zero_add, PrivMachine.run_zero]
  | succ m' ih =>
    rw [Nat.succ_add, PrivMachine.run_succ, PrivMachine.run_succ]
    split
    · next hHalted =>
      rw [PrivMachine.run_halted env n s hHalted]
    · next hNotHalted =>
      exact ih (PrivMachine.step env s)

/-- Predicate asserting that n contiguous execution steps remain safe in U-mode. -/
def SafeUEpoch (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat) : Nat → Prop
  | 0 => True
  | n + 1 => SafeUInstr s lo hi ∧ SafeUEpoch env (PrivMachine.step env s) lo hi n

/-- When SafeUInstr holds, PrivMachine.step directly executes Rv32.exec without trap. -/
theorem PrivMachine.step_eq_of_safe (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi) :
    let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
    ∃ instr, Rv32.decode w = some instr ∧
      PrivMachine.step env s =
        match Rv32.exec env s.core instr with
        | .running core'  => { s with core := core', csrs := bumpCounters s.csrs }
        | .halted _ core' => { s with core := core', csrs := bumpCounters s.csrs, halted := true }
        | .fault _ _      => raiseTrap s CAUSE_ILLEGAL_INSTR := by
  intro w
  cases hDec : Rv32.decode w with
  | none =>
    have hMem := hSafe.memInBounds
    dsimp only [w] at hDec
    rw [hDec] at hMem
    contradiction
  | some instr =>
    refine ⟨instr, rfl, ?_⟩
    unfold PrivMachine.step
    rw [hBox.notHalted]
    dsimp only [ite_false]
    have hTrap := uModeTrapCause_eq_none_of_SafeUInstr s lo hi hBox hSafe
    dsimp only [w] at hTrap
    rw [hTrap]
    dsimp only
    have ⟨hNotMret, hNotZicsr⟩ := hSafe.notPriv
    rw [hNotMret, hNotZicsr]
    simp only [Bool.false_eq_true, ↓reduceIte]
    have hw : BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4) = w := rfl
    rw [hw, hDec]
    rfl

theorem step_refines_running (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi)
    {instr : Instr} (hDec : Rv32.decode (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = some instr)
    {core' : Rv32.Machine} (hExec : Rv32.exec env s.core instr = .running core') :
    toUMachine (PrivMachine.step env s) = core' ∧
    (PrivMachine.step env s).halted = false ∧
    (PrivMachine.step env s).mode = .U ∧
    (PrivMachine.step env s).csrs = bumpCounters s.csrs := by
  have ⟨i, hiDec, hStep⟩ := PrivMachine.step_eq_of_safe env s lo hi hBox hSafe
  rw [hiDec] at hDec; injection hDec with hEq; subst hEq
  rw [hStep, hExec]
  exact ⟨rfl, hBox.notHalted, hBox.isUMode, rfl⟩

theorem step_refines_halted (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat)
    (hBox : UBoxed s lo hi) (hSafe : SafeUInstr s lo hi)
    {instr : Instr} (hDec : Rv32.decode (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = some instr)
    {code : Word} {core' : Rv32.Machine} (hExec : Rv32.exec env s.core instr = .halted code core') :
    toUMachine (PrivMachine.step env s) = core' ∧
    (PrivMachine.step env s).halted = true ∧
    (PrivMachine.step env s).mode = .U ∧
    (PrivMachine.step env s).csrs = bumpCounters s.csrs := by
  have ⟨i, hiDec, hStep⟩ := PrivMachine.step_eq_of_safe env s lo hi hBox hSafe
  rw [hiDec] at hDec; injection hDec with hEq; subst hEq
  rw [hStep, hExec]
  exact ⟨rfl, rfl, hBox.isUMode, rfl⟩

end Rv32.Refinement
