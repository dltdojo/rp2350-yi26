/-
SPDX-License-Identifier: Apache-2.0

# A payload in a W^X box

Three PMP entries, tried in order, fence a U-mode payload into a box that has no byte it can both write and run:

  * entry 0, the **code**: `NAPOT`, read and execute, no write, `[cLo, cHi)`;
  * entry 1, the **data**: `NAPOT`, read and write, no execute, `[dLo, dHi)`;
  * entry 2, the **stack**: `NAPOT`, read and write, no execute, `[kLo, kHi)`;
  * entry 3 off.

The entries are not disjoint, and need not be: the lowest-numbered entry that touches an access decides it, so
the code, listed first, carves its bytes out of a data entry that surrounds it. What lies between the data and the
stack, or past the stack, matches nothing, and U-mode that matches nothing is refused: a guard region.

`WXBoxed` says the machine is in U-mode with that configuration. From it:

  * `wx_fetch_iff`, `wx_store_ok`, `wx_load_ok`: an instruction fetch passes exactly inside the code; a store passes only
    wholly outside the code and wholly inside the data or the stack (`wx_store_allowed_*` say every such store does); a
    load passes only wholly inside one of the three;
  * `wx_disjoint`, `wx_no_write_exec`: a fetch and a store that pass touch disjoint bytes;
  * `wx_step`, `wx_run`: a step, and any number of steps, up to the first trap, stay in U-mode, boxed, with the
    CSRs the monitor set unchanged, and change no byte `WxFrozen` names: the code, and everything outside the
    data and the stack. At the trap the machine is in M-mode at the trap vector with the registers and memory
    the payload left;
  * `wx_code_immutable`: the code's bytes are the same after any number of steps. Nothing in the payload's
    instructions is assumed; it is the PMP alone.

`pmpCheck_M_outside_in` is the other side: M-mode code outside the box is never refused, whatever the entries.
`pmpCheck_M_unlocked`: while no entry is locked, M-mode is refused nowhere, for an aligned word -- what a boot needs
that starts from whatever CSRs it finds.

The data and the stack have to sit inside the 32-bit address space (`dHi, kHi ≤ 2^32`), or a store at the top
would wrap round into the bottom.

`Sandbox.lean` is the same for one RWX entry (`UBoxed`); the proofs of `wx_step` and `wx_run` follow `umode_step` and
`umode_run` and use their lemmas for what a step that is not a store does.
-/
import Rv32.Sandbox

namespace Rv32.Priv
open Rv32 Rv32.Refinement

/-- An entry that matches only `[lo, hi)`: its match is `NoMatch` outside, `FullMatch cfg` for an access wholly
    inside, `PartialMatch` for one that straddles an edge. -/
theorem matchPmpEntry_napot (csrs : PrivCSRs) (idx : Fin 4) (addr : Word) (width lo hi : Nat) (cfg : PmpCfgEntry)
    (hc : decodePmpCfgByte csrs.pmpcfg0 idx = cfg) (hm : cfg.mode = .NAPOT)
    (hr : decodeNapotRange (pmpAddrVal csrs idx) = (lo, hi)) :
    matchPmpEntry csrs idx addr width =
      if addr.toNat + width ≤ lo ∨ hi ≤ addr.toNat then .NoMatch
      else if lo ≤ addr.toNat ∧ addr.toNat + width ≤ hi then .FullMatch cfg else .PartialMatch := by
  unfold matchPmpEntry
  rw [hc, hr]
  have : cfg.mode ≠ .OFF := by rw [hm]; decide
  simp [this]

def wxCodeCfg : PmpCfgEntry := { r := true, w := false, x := true, mode := .NAPOT, lock := false }
def wxDataCfg : PmpCfgEntry := { r := true, w := true, x := false, mode := .NAPOT, lock := false }

structure WXBoxed (s : PrivMachine) (cLo cHi dLo dHi kLo kHi : Nat) : Prop where
  isUMode   : s.mode = .U
  notHalted : s.halted = false
  cfg0      : decodePmpCfgByte s.csrs.pmpcfg0 0 = wxCodeCfg
  cfg1      : decodePmpCfgByte s.csrs.pmpcfg0 1 = wxDataCfg
  cfg2      : decodePmpCfgByte s.csrs.pmpcfg0 2 = wxDataCfg
  cfg3      : (decodePmpCfgByte s.csrs.pmpcfg0 3).mode = .OFF
  addr0     : decodeNapotRange s.csrs.pmpaddr0 = (cLo, cHi)
  addr1     : decodeNapotRange s.csrs.pmpaddr1 = (dLo, dHi)
  addr2     : decodeNapotRange s.csrs.pmpaddr2 = (kLo, kHi)

section
variable {s : PrivMachine} {cLo cHi dLo dHi kLo kHi : Nat}

theorem WXBoxed.e0 (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) :
    matchPmpEntry s.csrs 0 a w =
      if a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat then .NoMatch
      else if cLo ≤ a.toNat ∧ a.toNat + w ≤ cHi then .FullMatch wxCodeCfg else .PartialMatch :=
  matchPmpEntry_napot _ 0 a w cLo cHi _ hB.cfg0 (by decide) hB.addr0

theorem WXBoxed.e1 (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) :
    matchPmpEntry s.csrs 1 a w =
      if a.toNat + w ≤ dLo ∨ dHi ≤ a.toNat then .NoMatch
      else if dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi then .FullMatch wxDataCfg else .PartialMatch :=
  matchPmpEntry_napot _ 1 a w dLo dHi _ hB.cfg1 (by decide) hB.addr1

theorem WXBoxed.e2 (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) :
    matchPmpEntry s.csrs 2 a w =
      if a.toNat + w ≤ kLo ∨ kHi ≤ a.toNat then .NoMatch
      else if kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi then .FullMatch wxDataCfg else .PartialMatch :=
  matchPmpEntry_napot _ 2 a w kLo kHi _ hB.cfg2 (by decide) hB.addr2

theorem WXBoxed.e3 (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) :
    matchPmpEntry s.csrs 3 a w = .NoMatch :=
  matchPmpEntry_off _ 3 a w hB.cfg3

/-- What the three entries make of an access, in the order the hardware tries them: the first that touches the
    access decides, a partial overlap refuses, and U-mode that touches none is refused. -/
theorem wx_check (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) (acc : AccessType) :
    pmpCheck s.csrs s.mode a w acc =
      (if a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat then
        (if a.toNat + w ≤ dLo ∨ dHi ≤ a.toNat then
          (if a.toNat + w ≤ kLo ∨ kHi ≤ a.toNat then false
           else if kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi then hasPermission wxDataCfg .U acc else false)
         else if dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi then hasPermission wxDataCfg .U acc else false)
       else if cLo ≤ a.toNat ∧ a.toNat + w ≤ cHi then hasPermission wxCodeCfg .U acc else false) := by
  unfold pmpCheck PMP_INDICES
  simp only [pmpCheckEntries, hB.e0, hB.e1, hB.e2, hB.e3, hB.isUMode]
  by_cases h0 : a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat <;>
  by_cases f0 : cLo ≤ a.toNat ∧ a.toNat + w ≤ cHi <;>
  by_cases h1 : a.toNat + w ≤ dLo ∨ dHi ≤ a.toNat <;>
  by_cases f1 : dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi <;>
  by_cases h2 : a.toNat + w ≤ kLo ∨ kHi ≤ a.toNat <;>
  by_cases f2 : kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi <;>
  simp [h0, f0, h1, f1, h2, f2]

theorem wx_fetch_iff (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) (hw : 0 < w) :
    pmpCheck s.csrs s.mode a w .Fetch = true ↔ (cLo ≤ a.toNat ∧ a.toNat + w ≤ cHi) := by
  rw [wx_check hB]
  simp only [hasPermission, wxCodeCfg, wxDataCfg]
  split <;> split <;> simp <;> omega

/-- A store passes only wholly outside the code entry, and wholly inside the data or the stack entry. -/
theorem wx_store_ok (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat)
    (h : pmpCheck s.csrs s.mode a w .Store = true) :
    (a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat) ∧
    ((dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi) ∨ (kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi)) := by
  rw [wx_check hB] at h
  simp only [hasPermission, wxCodeCfg, wxDataCfg] at h
  split at h <;> split at h <;> simp at h <;> omega

/-- A load passes only wholly inside the code, the data or the stack. -/
theorem wx_load_ok (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat)
    (h : pmpCheck s.csrs s.mode a w .Load = true) :
    (cLo ≤ a.toNat ∧ a.toNat + w ≤ cHi) ∨ (dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi) ∨
      (kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi) := by
  rw [wx_check hB] at h
  simp only [hasPermission, wxCodeCfg, wxDataCfg] at h
  split at h <;> split at h <;> simp at h <;> omega

/-- ... and every such store passes. -/
theorem wx_store_allowed_data (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat)
    (hc : a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat) (hd : dLo ≤ a.toNat ∧ a.toNat + w ≤ dHi) (hw : 0 < w) :
    pmpCheck s.csrs s.mode a w .Store = true := by
  rw [wx_check hB]
  simp only [hasPermission, wxCodeCfg, wxDataCfg]
  have hnd : ¬ (a.toNat + w ≤ dLo ∨ dHi ≤ a.toNat) := by omega
  simp [hc, hnd, hd]

theorem wx_store_allowed_stack (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat)
    (hc : a.toNat + w ≤ cLo ∨ cHi ≤ a.toNat) (hd : a.toNat + w ≤ dLo ∨ dHi ≤ a.toNat)
    (hk : kLo ≤ a.toNat ∧ a.toNat + w ≤ kHi) (hw : 0 < w) :
    pmpCheck s.csrs s.mode a w .Store = true := by
  rw [wx_check hB]
  simp only [hasPermission, wxCodeCfg, wxDataCfg]
  have hnk : ¬ (a.toNat + w ≤ kLo ∨ kHi ≤ a.toNat) := by omega
  simp [hc, hd, hnk, hk]

/-- **No byte is both writable and executable.** A fetch and a store that pass the PMP touch disjoint bytes. -/
theorem wx_disjoint (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (f g : Word) (nf ng : Nat) (hnf : 0 < nf)
    (hF : pmpCheck s.csrs s.mode f nf .Fetch = true) (hS : pmpCheck s.csrs s.mode g ng .Store = true) :
    f.toNat + nf ≤ g.toNat ∨ g.toNat + ng ≤ f.toNat := by
  have h1 := (wx_fetch_iff hB f nf hnf).mp hF
  have h2 := (wx_store_ok hB g ng hS).1
  omega

/-- The same, at the width the machine uses: no address is fetchable as an instruction and storable as a word. -/
theorem wx_no_write_exec (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (a : Word) :
    ¬ (pmpCheck s.csrs s.mode a 4 .Fetch = true ∧ pmpCheck s.csrs s.mode a 4 .Store = true) := by
  intro ⟨hF, hS⟩
  have := wx_disjoint hB a a 4 4 (by decide) hF hS
  omega

/-- A byte the payload cannot change: one of the code, or one outside the data and the stack. -/
def WxFrozen (cLo cHi dLo dHi kLo kHi : Nat) (x : Word) : Prop :=
  (cLo ≤ x.toNat ∧ x.toNat < cHi) ∨ (¬ (dLo ≤ x.toNat ∧ x.toNat < dHi) ∧ ¬ (kLo ≤ x.toNat ∧ x.toNat < kHi))

theorem wxboxed_of_kept {s s' : PrivMachine} (hB : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (hk : KeptCsrs s.csrs s'.csrs) (hmode : s'.mode = .U) (hh : s'.halted = false) :
    WXBoxed s' cLo cHi dLo dHi kLo kHi := by
  obtain ⟨_, _, k4, k5, k6, k7, k8, _⟩ := hk
  refine ⟨hmode, hh, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [k4]; exact hB.cfg0
  · rw [k4]; exact hB.cfg1
  · rw [k4]; exact hB.cfg2
  · rw [k4]; exact hB.cfg3
  · rw [k5]; exact hB.addr0
  · rw [k6]; exact hB.addr1
  · rw [k7]; exact hB.addr2

/-- A store the trap check let through lands wholly in the data or the stack, and wholly outside the code. -/
theorem wx_st_ok {w : Word} (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (h : uModeTrapCause s w = none)
    {op : StOp} {rs1 rs2 : Reg} {imm : BitVec 12} (hd : Rv32.decode w = some (.st op rs1 rs2 imm)) :
    let a := s.core.reg rs1 + imm.signExtend 32
    a.toNat % op.size = 0 ∧ (a.toNat + op.size ≤ cLo ∨ cHi ≤ a.toNat) ∧
      ((dLo ≤ a.toNat ∧ a.toNat + op.size ≤ dHi) ∨ (kLo ≤ a.toNat ∧ a.toNat + op.size ≤ kHi)) := by
  intro a
  obtain ⟨he, hm, hz, _⟩ := trap_none_plain hB.isUMode h
  unfold uModeTrapCause at h
  rw [hB.isUMode] at h
  have hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true := by
    by_cases hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true
    · exact hf
    · exfalso; simp [hf] at h
  simp only [hf, not_true_eq_false, ↓reduceIte, he, hm, hz, hd] at h
  by_cases hal : a.toNat % op.size = 0
  · have hal' : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
    by_cases hp : pmpCheck s.csrs .U a op.size .Store = true
    · have := wx_store_ok hB a op.size (by simpa [hB.isUMode] using hp)
      exact ⟨hal, this.1, this.2⟩
    · simp [hal', a, hp] at h
  · have : ¬ (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
    simp [this] at h

/-- One step of a payload in a W^X box: it stays in U-mode, still boxed, and changes no frozen byte -- or it traps
    to the vector with the registers and memory as it left them. -/
theorem wx_step (env : Rv32.Env) (s : PrivMachine) (hB : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (hd : dHi ≤ 2^32) (hk : kHi ≤ 2^32) :
    KeptCsrs s.csrs (PrivMachine.step env s).csrs ∧ (PrivMachine.step env s).halted = false ∧
    (((PrivMachine.step env s).mode = .U ∧ WXBoxed (PrivMachine.step env s) cLo cHi dLo dHi kLo kHi ∧
        ∀ x : Word, WxFrozen cLo cHi dLo dHi kLo kHi x →
          (PrivMachine.step env s).core.mem x = s.core.mem x) ∨
     ((PrivMachine.step env s).mode = .M ∧
        (PrivMachine.step env s).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
        (PrivMachine.step env s).core.regs = s.core.regs ∧
        (PrivMachine.step env s).core.mem = s.core.mem)) := by
  have trap : ∀ cause : Word, KeptCsrs s.csrs (raiseTrap s cause).csrs ∧ (raiseTrap s cause).halted = false ∧
      (raiseTrap s cause).mode = .M ∧ (raiseTrap s cause).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
      (raiseTrap s cause).core.regs = s.core.regs ∧ (raiseTrap s cause).core.mem = s.core.mem := by
    intro cause
    exact ⟨kept_trap s cause, hB.notHalted, rfl, rfl, rfl, rfl⟩
  unfold PrivMachine.step PrivMachine.stepW
  rw [hB.notHalted]
  simp only [Bool.false_eq_true, ↓reduceIte]
  generalize BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4) = w
  cases hc : uModeTrapCause s w with
  | some cause =>
    obtain ⟨t1, t2, t3, t4, t5, t6⟩ := trap cause
    exact ⟨t1, t2, Or.inr ⟨t3, t4, t5, t6⟩⟩
  | none =>
    obtain ⟨he, hm, hz, i, hdc⟩ := trap_none_plain hB.isUMode hc
    simp only [hm, hz, Bool.false_eq_true, ↓reduceIte, hdc]
    have hne : i ≠ .ecall := by
      intro hi; subst hi; have := decode_ecall hdc; rw [he] at this; exact absurd this (by decide)
    cases hx : Rv32.exec env s.core i with
    | halted code c => exact absurd hx (exec_no_halt hne)
    | fault f c =>
      dsimp only
      obtain ⟨t1, t2, t3, t4, t5, t6⟩ := trap CAUSE_ILLEGAL_INSTR
      exact ⟨t1, t2, Or.inr ⟨t3, t4, t5, t6⟩⟩
    | running c =>
      dsimp only
      rw [portRead_U s hB.isUMode c i, portWrites_U s hB.isUMode i, List.append_nil]
      have hkc : KeptCsrs s.csrs (bumpCounters s.csrs) := kept_bump _
      refine ⟨hkc, rfl, Or.inl ⟨hB.isUMode, wxboxed_of_kept hB hkc hB.isUMode rfl, ?_⟩⟩
      intro x hx_out
      show c.mem x = s.core.mem x
      by_cases hst : ∃ op rs1 rs2 imm, i = .st op rs1 rs2 imm
      · obtain ⟨op, rs1, rs2, imm, rfl⟩ := hst
        obtain ⟨hal, hcode, hin⟩ := wx_st_ok hB hc hdc
        simp only [Rv32.exec] at hx
        have hok : ¬ (s.core.reg rs1 + imm.signExtend 32).toNat % op.size ≠ 0 := by simpa using hal
        simp only [hok, ↓reduceIte] at hx
        by_cases hreg : env.region.ok (s.core.reg rs1 + imm.signExtend 32) op.size
        · simp only [hreg] at hx
          injection hx with e
          subst e
          have hsz : op.size < 2^32 := by cases op <;> decide
          show writeLE s.core.mem (s.core.reg rs1 + imm.signExtend 32) (BitVec.toNat (s.core.reg rs2)) op.size x = s.core.mem x
          rw [writeLE_apply _ _ _ _ hsz x]
          have hn : ¬ (x - (s.core.reg rs1 + imm.signExtend 32)).toNat < op.size := by
            have := x.isLt
            have := (s.core.reg rs1 + imm.signExtend 32).isLt
            unfold WxFrozen at hx_out
            simp only [BitVec.toNat_sub, Nat.reducePow]
            omega
          simp only [hn, ↓reduceIte]
        · simp only [hreg] at hx
          simp at hx
      · have hs : ∀ op rs1 rs2 imm, i ≠ .st op rs1 rs2 imm := fun op rs1 rs2 imm h => hst ⟨op, rs1, rs2, imm, h⟩
        rw [exec_mem_of_not_st hs hne hx]

/-- Any number of steps of a payload in a W^X box: up to the first trap it stays in U-mode, boxed, and changes no
    frozen byte; at the trap the machine is in M-mode at the trap vector. -/
theorem wx_run (env : Rv32.Env) (cLo cHi dLo dHi kLo kHi : Nat) (hd : dHi ≤ 2^32) (hk : kHi ≤ 2^32) :
    ∀ (n : Nat) (s : PrivMachine), WXBoxed s cLo cHi dLo dHi kLo kHi →
      ∃ j, j ≤ n ∧ KeptCsrs s.csrs (PrivMachine.run env j s).csrs ∧
        (PrivMachine.run env j s).halted = false ∧
        (∀ x : Word, WxFrozen cLo cHi dLo dHi kLo kHi x →
          (PrivMachine.run env j s).core.mem x = s.core.mem x) ∧
        ((j = n ∧ (PrivMachine.run env j s).mode = .U ∧
            WXBoxed (PrivMachine.run env j s) cLo cHi dLo dHi kLo kHi) ∨
         (0 < j ∧ (PrivMachine.run env j s).mode = .M ∧
          (PrivMachine.run env j s).core.pc = s.csrs.mtvec &&& ~~~3#32)) := by
  intro n
  induction n with
  | zero =>
    intro s hB
    exact ⟨0, Nat.le_refl 0, KeptCsrs.refl _, hB.notHalted, fun _ _ => rfl,
      Or.inl ⟨rfl, hB.isUMode, hB⟩⟩
  | succ n ih =>
    intro s hB
    obtain ⟨hkc, hh, hcase⟩ := wx_step env s hB hd hk
    rcases hcase with ⟨hmode, hB', hmem⟩ | ⟨hmode, hpc, hregs, hmem⟩
    · obtain ⟨j, hjn, hk2, hh2, hmem2, hres⟩ := ih (PrivMachine.step env s) hB'
      refine ⟨j + 1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env j s hB.notHalted]; exact hkc.trans hk2
      · rw [run_succ_step env j s hB.notHalted]; exact hh2
      · intro x hx; rw [run_succ_step env j s hB.notHalted, hmem2 x hx, hmem x hx]
      · rw [run_succ_step env j s hB.notHalted]
        rcases hres with ⟨hkeq, hm, hb⟩ | ⟨hpos, hm, hpc⟩
        · exact Or.inl ⟨by omega, hm, hb⟩
        · exact Or.inr ⟨by omega, hm, by rw [hpc, hkc.1]⟩
    · refine ⟨1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env 0 s hB.notHalted]; exact hkc
      · rw [run_succ_step env 0 s hB.notHalted]; exact hh
      · intro x _; rw [run_succ_step env 0 s hB.notHalted]; show (PrivMachine.step env s).core.mem x = _; rw [hmem]
      · rw [run_succ_step env 0 s hB.notHalted]
        exact Or.inr ⟨by omega, hmode, hpc⟩

/-- **The code cannot be written.** However many steps the payload takes, up to its first trap, every byte of
    `[cLo, cHi)` is what it was -- by the PMP alone, whatever the payload's own instructions say. -/
theorem wx_code_immutable (env : Rv32.Env) (cLo cHi dLo dHi kLo kHi : Nat) (hd : dHi ≤ 2^32) (hk : kHi ≤ 2^32)
    (n : Nat) (s : PrivMachine) (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) :
    ∃ j, j ≤ n ∧ (PrivMachine.run env j s).halted = false ∧
      (∀ x : Word, cLo ≤ x.toNat → x.toNat < cHi → (PrivMachine.run env j s).core.mem x = s.core.mem x) ∧
      ((j = n ∧ (PrivMachine.run env j s).mode = .U) ∨ (0 < j ∧ (PrivMachine.run env j s).mode = .M)) := by
  obtain ⟨j, hj, _, hh, hmem, hres⟩ := wx_run env cLo cHi dLo dHi kLo kHi hd hk n s hB
  refine ⟨j, hj, hh, fun x h1 h2 => hmem x (Or.inl ⟨h1, h2⟩), ?_⟩
  rcases hres with ⟨h1, h2, _⟩ | ⟨h1, h2, _⟩
  · exact Or.inl ⟨h1, h2⟩
  · exact Or.inr ⟨h1, h2⟩

/-! ## M-mode is not refused outside the box -/

/-- Entry `i` is off, or fences off a range inside `[lo, hi)`. -/
def EntryIn (csrs : PrivCSRs) (i : Fin 4) (lo hi : Nat) : Prop :=
  (decodePmpCfgByte csrs.pmpcfg0 i).mode = .OFF ∨
    (∃ l h, decodeNapotRange (pmpAddrVal csrs i) = (l, h) ∧ lo ≤ l ∧ h ≤ hi)

theorem matchPmpEntry_noMatch_of_in {csrs : PrivCSRs} {i : Fin 4} {lo hi : Nat} (hE : EntryIn csrs i lo hi)
    (addr : Word) (width : Nat) (hout : addr.toNat + width ≤ lo ∨ hi ≤ addr.toNat) :
    matchPmpEntry csrs i addr width = .NoMatch := by
  rcases hE with h | ⟨l, h, hr, hl, hh⟩
  · exact matchPmpEntry_off csrs i addr width h
  · unfold matchPmpEntry
    by_cases hm : (decodePmpCfgByte csrs.pmpcfg0 i).mode = .OFF
    · simp [hm]
    · simp [hm, hr]
      omega

/-- M-mode code outside `[lo, hi)` is never refused when every entry is off or inside it: this is `PmpFence`
    for a monitor that fences the payload in with up to four entries. -/
theorem pmpCheck_M_outside_in (csrs : PrivCSRs) (lo hi : Nat) (addr : Word) (width : Nat) (acc : AccessType)
    (h0 : EntryIn csrs 0 lo hi) (h1 : EntryIn csrs 1 lo hi) (h2 : EntryIn csrs 2 lo hi) (h3 : EntryIn csrs 3 lo hi)
    (hout : addr.toNat + width ≤ lo ∨ hi ≤ addr.toNat) :
    pmpCheck csrs .M addr width acc = true := by
  unfold pmpCheck PMP_INDICES pmpCheckEntries
  rw [matchPmpEntry_noMatch_of_in h0 addr width hout]; dsimp only
  unfold pmpCheckEntries
  rw [matchPmpEntry_noMatch_of_in h1 addr width hout]; dsimp only
  unfold pmpCheckEntries
  rw [matchPmpEntry_noMatch_of_in h2 addr width hout]; dsimp only
  unfold pmpCheckEntries
  rw [matchPmpEntry_noMatch_of_in h3 addr width hout]; dsimp only
  unfold pmpCheckEntries
  decide

end

/-! ## M-mode is not refused anywhere while no entry is locked -/

/-- No entry of `pmpcfg0` is locked. M-mode is then held to none of them: what a reset leaves, and what a monitor
    that never sets `L` leaves for the next round. -/
def PmpUnlocked (cfg : Word) : Prop := ∀ i : Fin 4, (decodePmpCfgByte cfg i).lock = false

/-- The two ends of a NAPOT range are multiples of four. -/
theorem decodeNapotRange_mod4 (raw : Word) :
    (decodeNapotRange raw).1 % 4 = 0 ∧ (decodeNapotRange raw).2 % 4 = 0 := by
  unfold decodeNapotRange
  simp only [Nat.shiftLeft_eq, Nat.one_mul, Nat.pow_add]
  omega

/-- An aligned word either misses an entry or lies wholly inside it: it never straddles an edge. -/
theorem matchPmpEntry_aligned4 (csrs : PrivCSRs) (i : Fin 4) (addr : Word) (hal : addr.toNat % 4 = 0) :
    matchPmpEntry csrs i addr 4 = .NoMatch ∨
      matchPmpEntry csrs i addr 4 = .FullMatch (decodePmpCfgByte csrs.pmpcfg0 i) := by
  obtain ⟨h1, h2⟩ := decodeNapotRange_mod4 (pmpAddrVal csrs i)
  unfold matchPmpEntry
  generalize decodeNapotRange (pmpAddrVal csrs i) = p at h1 h2
  obtain ⟨lo, hi⟩ := p
  simp only at h1 h2 ⊢
  split
  · exact Or.inl rfl
  · split
    · exact Or.inl rfl
    · split
      · exact Or.inr rfl
      · exfalso; omega

/-- **Whatever the entries say, while none is locked, M-mode reads, writes and runs any aligned word.** A boot that
    starts from CSRs it did not set needs this for every word it runs before it has set the PMP. -/
theorem pmpCheck_M_unlocked (csrs : PrivCSRs) (addr : Word) (acc : AccessType)
    (hl : PmpUnlocked csrs.pmpcfg0) (hal : addr.toNat % 4 = 0) :
    pmpCheck csrs .M addr 4 acc = true := by
  have key : ∀ l : List (Fin 4), pmpCheckEntries csrs .M addr 4 acc l = true := by
    intro l
    induction l with
    | nil => simp [pmpCheckEntries]
    | cons i rest ih =>
      unfold pmpCheckEntries
      rcases matchPmpEntry_aligned4 csrs i addr hal with h | h <;> rw [h]
      · exact ih
      · simp [hasPermission, hl i]
  exact key _

end Rv32.Priv
