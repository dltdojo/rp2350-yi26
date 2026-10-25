/-
SPDX-License-Identifier: Apache-2.0

# Two machines, one payload: a W^X box sees only the box

Two machines in U-mode in the same W^X box (`WXBoxed`, the same six bounds), with the same `pc`, the same registers,
the same bytes in the box -- the code, the data and the stack -- and the same CSRs that a payload's run reads or moves
(`mstatus`, `mepc`, `mcause`, the counters and their inhibit, `mscratch`), take the same steps: up to the first trap they
stay in U-mode and stay twins, `pc` and all, and at it they trap together, each to its own trap vector, still twins.
Nothing outside the box, nothing about the other CSRs -- the trap vector, entry 3 while it is silent -- reaches the
payload.

  * `wx_pmp_same`: the PMP says the same of every access in both, because `wx_check` is a formula in the bounds alone;
  * `exec_twin`: two cores with the same `pc` and registers, and the same value at a load's address, come out of an
    instruction the same way, and bytes that agreed still agree;
  * `wx_twin_step`, `wx_twin_run`: one step, and any number up to the first trap.

What makes the monitors of exp240 and exp245 the same to a payload (exp246).
-/
import Rv32.WxBox
import Rv32.Place

namespace Rv32.Priv
open Rv32 Rv32.Refinement

/-- The bytes a payload in the box can reach at all: the code, the data and the stack. -/
def WxVis (cLo cHi dLo dHi kLo kHi : Nat) (x : Word) : Prop :=
  (cLo ≤ x.toNat ∧ x.toNat < cHi) ∨ (dLo ≤ x.toNat ∧ x.toNat < dHi) ∨ (kLo ≤ x.toNat ∧ x.toNat < kHi)

/-- What of two machines a payload's run reads or moves, the same in both, `pc` aside: the registers as they read --
    `x0` reads 0 whatever its slot holds, which boot never writes -- the bytes of `V`,
    privilege, the CSRs a step or a trap reads or writes but the trap vector and the PMP, and the host and its events. -/
structure Twin (V : Word → Prop) (s t : PrivMachine) : Prop where
  regs     : ∀ r, s.core.reg r = t.core.reg r
  mem      : ∀ x, V x → s.core.mem x = t.core.mem x
  mode     : s.mode = t.mode
  halted   : s.halted = t.halted
  mstatus  : s.csrs.mstatus = t.csrs.mstatus
  mepc     : s.csrs.mepc = t.csrs.mepc
  mcause   : s.csrs.mcause = t.csrs.mcause
  minstret : s.csrs.minstret = t.csrs.minstret
  mcycle   : s.csrs.mcycle = t.csrs.mcycle
  inhibit  : s.csrs.mcountinhibit = t.csrs.mcountinhibit
  mscratch : s.csrs.mscratch = t.csrs.mscratch
  io       : s.io = t.io
  host     : s.host = t.host

theorem Twin.symm {V : Word → Prop} {s t : PrivMachine} (h : Twin V s t) : Twin V t s :=
  ⟨fun r => (h.regs r).symm, fun x hx => (h.mem x hx).symm, h.mode.symm, h.halted.symm, h.mstatus.symm, h.mepc.symm,
    h.mcause.symm, h.minstret.symm, h.mcycle.symm, h.inhibit.symm, h.mscratch.symm, h.io.symm, h.host.symm⟩

section
variable {cLo cHi dLo dHi kLo kHi : Nat}

/-- The PMP of two machines boxed by the same three entries says the same of every access. -/
theorem wx_pmp_same {s t : PrivMachine} (hs : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (ht : WXBoxed t cLo cHi dLo dHi kLo kHi) (a : Word) (w : Nat) (acc : AccessType) :
    pmpCheck s.csrs s.mode a w acc = pmpCheck t.csrs t.mode a w acc := by
  rw [wx_check hs, wx_check ht]

/-- Two cores with the same `pc` and registers, and the same value at a load's address, come out of an instruction that
    is not an `ecall` the same way: both running, with the same `pc` and registers, every byte that agreed agreeing
    still; or both faulting. -/
theorem exec_twin {env : Rv32.Env} {s t : Rv32.Machine} {i : Instr} (hi : i ≠ .ecall)
    (hpc : s.pc = t.pc) (hr : ∀ r, s.reg r = t.reg r)
    (hld : ∀ op rd rs1 imm, i = .ld op rd rs1 imm →
      readLE s.mem (s.reg rs1 + imm.signExtend 32) op.size = readLE t.mem (s.reg rs1 + imm.signExtend 32) op.size) :
    (∃ c d, Rv32.exec env s i = .running c ∧ Rv32.exec env t i = .running d ∧ c.pc = d.pc ∧ (∀ r, c.reg r = d.reg r) ∧
      ∀ x, s.mem x = t.mem x → c.mem x = d.mem x) ∨
    (∃ f g c d, Rv32.exec env s i = .fault f c ∧ Rv32.exec env t i = .fault g d) := by
  cases i with
  | ecall => exact absurd rfl hi
  | ld op rd rs1 imm =>
    have hv := hld op rd rs1 imm rfl
    simp only [Rv32.exec, hr] at hv ⊢
    generalize t.reg rs1 + imm.signExtend 32 = a at hv ⊢
    by_cases h1 : a.toNat % op.size ≠ 0
    · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h1), ite_eq_left_of_eq_true _ _ (eq_true h1)]
      exact ⟨_, _, _, _, rfl, rfl⟩
    · rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_right_of_eq_false _ _ (eq_false h1)]
      by_cases h2 : env.region.ok a op.size
      · rw [ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2)),
          ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2))]
        left
        refine ⟨_, _, rfl, rfl, by simp [hpc], fun x => by simp [reg_setReg, hr, hv], fun x hx => by simp [hx]⟩
      · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h2), ite_eq_left_of_eq_true _ _ (eq_true h2)]
        exact ⟨_, _, _, _, rfl, rfl⟩
  | st op rs1 rs2 imm =>
    simp only [Rv32.exec, hr]
    generalize t.reg rs1 + imm.signExtend 32 = a
    by_cases h1 : a.toNat % op.size ≠ 0
    · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h1), ite_eq_left_of_eq_true _ _ (eq_true h1)]
      exact ⟨_, _, _, _, rfl, rfl⟩
    · rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_right_of_eq_false _ _ (eq_false h1)]
      by_cases h2 : env.region.ok a op.size
      · rw [ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2)),
          ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2))]
        left
        refine ⟨_, _, rfl, rfl, by simp [hpc], fun x => by simp [Machine.next, Machine.setPc, Machine.reg] at hr ⊢; exact hr x, ?_⟩
        intro x hx
        simp only [next_mem]
        have hsz : op.size < 2^32 := by cases op <;> decide
        rw [writeLE_apply _ _ _ _ hsz x, writeLE_apply _ _ _ _ hsz x]
        split
        · rfl
        · exact hx
      · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h2), ite_eq_left_of_eq_true _ _ (eq_true h2)]
        exact ⟨_, _, _, _, rfl, rfl⟩
  | br op rs1 rs2 off =>
    left
    simp only [Rv32.exec, hr]
    by_cases hb : taken op (t.reg rs1) (t.reg rs2) = true <;> simp only [hb, ↓reduceIte, Bool.false_eq_true]
    · exact ⟨_, _, rfl, rfl, by simp [hpc], fun x => by simp [hr], fun x hx => by simp [hx]⟩
    · exact ⟨_, _, rfl, rfl, by simp [hpc], fun x => by simp [hr], fun x hx => by simp [hx]⟩
  | _ =>
    left
    simp only [Rv32.exec, hr]
    exact ⟨_, _, rfl, rfl, by simp [hpc], fun x => by simp [reg_setReg, hr, hpc], fun x hx => by simp [hx]⟩

/-- A load the trap check let through lands wholly in the code, the data or the stack: bytes a payload can reach. -/
theorem wx_ld_ok {s : PrivMachine} {w : Word} (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (h : uModeTrapCause s w = none)
    {op : LdOp} {rd rs1 : Reg} {imm : BitVec 12} (hd : Rv32.decode w = some (.ld op rd rs1 imm)) :
    let a := s.core.reg rs1 + imm.signExtend 32
    (cLo ≤ a.toNat ∧ a.toNat + op.size ≤ cHi) ∨ (dLo ≤ a.toNat ∧ a.toNat + op.size ≤ dHi) ∨
      (kLo ≤ a.toNat ∧ a.toNat + op.size ≤ kHi) := by
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
    by_cases hp : pmpCheck s.csrs .U a op.size .Load = true
    · exact wx_load_ok hB a op.size (by simpa [hB.isUMode] using hp)
    · simp [hal', a, hp] at h
  · have : ¬ (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
    simp [this] at h

/-- Twins that trap for the same cause stay twins: each goes to its own trap vector. -/
theorem twin_trap {V : Word → Prop} {s t : PrivMachine} (hT : Twin V s t) (hpc : s.core.pc = t.core.pc)
    (cause : Word) : Twin V (raiseTrap s cause) (raiseTrap t cause) := by
  obtain ⟨r, m, mo, h, ms, e, c, mi, cy, inh, sc, io, ho⟩ := hT
  refine ⟨fun x => ?_, m, rfl, h, ?_, ?_, rfl, ?_, ?_, inh, sc, io, ho⟩ <;>
    simp [raiseTrap, bumpCounters, mo, ms, hpc, mi, cy, inh]
  exact r x

/-- **One step of twins in a W^X box.** Two machines boxed by the same three entries, with the same `pc` and the
    same of everything `Twin` names over the bytes the payload can reach, step to twins again: and while they are in
    U-mode their `pc`s are the same. -/
theorem wx_twin_step (env : Rv32.Env) {s t : PrivMachine} (hs : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (ht : WXBoxed t cLo cHi dLo dHi kLo kHi) (hc4 : cHi ≤ 2^32) (hd4 : dHi ≤ 2^32) (hk4 : kHi ≤ 2^32)
    (hpc : s.core.pc = t.core.pc) (hT : Twin (WxVis cLo cHi dLo dHi kLo kHi) s t) :
    Twin (WxVis cLo cHi dLo dHi kLo kHi) (PrivMachine.step env s) (PrivMachine.step env t) ∧
    ((PrivMachine.step env s).mode = .U → (PrivMachine.step env s).core.pc = (PrivMachine.step env t).core.pc) := by
  have hpU : ∀ a n acc, pmpCheck s.csrs .U a n acc = pmpCheck t.csrs .U a n acc := by
    intro a n acc
    have := wx_pmp_same hs ht a n acc
    rwa [hs.isUMode, ht.isUMode] at this
  have hr := hT.regs
  have tr : ∀ c, Twin (WxVis cLo cHi dLo dHi kLo kHi) (raiseTrap s c) (raiseTrap t c) ∧
      ((raiseTrap s c).mode = .U → (raiseTrap s c).core.pc = (raiseTrap t c).core.pc) :=
    fun c => ⟨twin_trap hT hpc c, fun h => by simp [raiseTrap] at h⟩
  unfold PrivMachine.step PrivMachine.stepW
  rw [hs.notHalted, ht.notHalted]
  simp only [Bool.false_eq_true, ↓reduceIte]
  by_cases hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true
  · -- the fetch passes, in the code: the same word in both
    have hcode := (wx_fetch_iff hs s.core.pc 4 (by decide)).mp (by rw [hs.isUMode]; exact hf)
    have hw : readLE t.core.mem t.core.pc 4 = readLE s.core.mem s.core.pc 4 := by
      rw [← hpc]
      apply readLE_four_congr
      intro d hd
      apply (hT.mem _ _).symm
      left
      have := s.core.pc.isLt
      simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow]
      omega
    rw [hw]
    generalize BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4) = w
    have hc : uModeTrapCause t w = uModeTrapCause s w := by
      simp only [uModeTrapCause, hs.isUMode, ht.isUMode, hpU, hpc, hr]
    rw [hc]
    cases hcs : uModeTrapCause s w with
    | some cause => exact tr cause
    | none =>
      obtain ⟨he, hm, hz, i, hdc⟩ := trap_none_plain hs.isUMode hcs
      simp only [hm, hz, Bool.false_eq_true, ↓reduceIte, hdc]
      have hne : i ≠ .ecall := by
        intro hi; subst hi; have := decode_ecall hdc; rw [he] at this; exact absurd this (by decide)
      have hld : ∀ op rd rs1 imm, i = .ld op rd rs1 imm →
          readLE s.core.mem (s.core.reg rs1 + imm.signExtend 32) op.size =
            readLE t.core.mem (s.core.reg rs1 + imm.signExtend 32) op.size := by
        intro op rd rs1 imm hi
        subst hi
        have hin := wx_ld_ok hs hcs hdc
        simp only at hin
        have hsz : op.size ≤ 4 := by cases op <;> decide
        generalize s.core.reg rs1 + imm.signExtend 32 = A at hin ⊢
        apply Rv32.readLE_congr
        intro d hd
        apply hT.mem
        have := A.isLt
        unfold WxVis
        simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow]
        omega
      rcases exec_twin (env := env) hne hpc hT.regs hld with ⟨c, d, h1, h2, ep, er, em⟩ | ⟨f, g, c, d, h1, h2⟩
      · rw [h1, h2]
        simp only [portRead_U s hs.isUMode, portRead_U t ht.isUMode, portWrites_U s hs.isUMode,
          portWrites_U t ht.isUMode, List.append_nil]
        obtain ⟨_, mem, mo, hh, ms, e, cc, mi, cy, inh, sc, io, ho⟩ := hT
        refine ⟨⟨er, fun x hx => em x (mem x hx), mo, rfl, ms, e, cc, ?_, ?_, inh, sc, io, ho⟩, fun _ => ep⟩
        · simp [bumpCounters, mi, inh]
        · simp [bumpCounters, cy, inh]
      · rw [h1, h2]
        exact tr _
  · -- the fetch is refused, in both
    have hf' : pmpCheck t.csrs .U t.core.pc 4 .Fetch = false := by rw [← hpU, ← hpc]; simpa using hf
    have hs1 : uModeTrapCause s (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = some CAUSE_FETCH_ACCESS_FAULT := by
      simp [uModeTrapCause, hs.isUMode, hf]
    have ht1 : uModeTrapCause t (BitVec.ofNat 32 (readLE t.core.mem t.core.pc 4)) = some CAUSE_FETCH_ACCESS_FAULT := by
      simp [uModeTrapCause, ht.isUMode, hf']
    rw [hs1, ht1]
    exact tr _

/-- **Any number of steps of twins in a W^X box.** As long as every step before the `n`-th was in U-mode, the two
    are twins after `n` steps; and if the `n`-th state is in U-mode too, both are boxed and their `pc`s the same.
    The payload's first trap comes at the same step in both, for the same cause, from the same state. -/
theorem wx_twin_run (env : Rv32.Env) (hc4 : cHi ≤ 2^32) (hd4 : dHi ≤ 2^32) (hk4 : kHi ≤ 2^32) :
    ∀ (n : Nat) (s t : PrivMachine), WXBoxed s cLo cHi dLo dHi kLo kHi → WXBoxed t cLo cHi dLo dHi kLo kHi →
      s.core.pc = t.core.pc → Twin (WxVis cLo cHi dLo dHi kLo kHi) s t →
      (∀ i, i < n → (PrivMachine.run env i s).mode = .U) →
      Twin (WxVis cLo cHi dLo dHi kLo kHi) (PrivMachine.run env n s) (PrivMachine.run env n t) ∧
      ((PrivMachine.run env n s).mode = .U →
        WXBoxed (PrivMachine.run env n s) cLo cHi dLo dHi kLo kHi ∧
        WXBoxed (PrivMachine.run env n t) cLo cHi dLo dHi kLo kHi ∧
        (PrivMachine.run env n s).core.pc = (PrivMachine.run env n t).core.pc) := by
  intro n
  induction n with
  | zero =>
    intro s t hs ht hpc hT _
    exact ⟨hT, fun _ => ⟨hs, ht, hpc⟩⟩
  | succ n ih =>
    intro s t hs ht hpc hT hU
    rw [run_succ_step env n s hs.notHalted, run_succ_step env n t ht.notHalted]
    obtain ⟨hT1, hpc1⟩ := wx_twin_step env hs ht hc4 hd4 hk4 hpc hT
    by_cases hm : (PrivMachine.step env s).mode = .U
    · obtain ⟨-, -, hcs⟩ := wx_step env s hs hd4 hk4
      obtain ⟨-, -, hct⟩ := wx_step env t ht hd4 hk4
      have hs1 : WXBoxed (PrivMachine.step env s) cLo cHi dLo dHi kLo kHi := by
        rcases hcs with ⟨_, hb, _⟩ | ⟨hM, _⟩
        · exact hb
        · rw [hM] at hm; exact absurd hm (by decide)
      have ht1 : WXBoxed (PrivMachine.step env t) cLo cHi dLo dHi kLo kHi := by
        rcases hct with ⟨_, hb, _⟩ | ⟨hM, _⟩
        · exact hb
        · rw [hT1.mode, hM] at hm; exact absurd hm (by decide)
      apply ih _ _ hs1 ht1 (hpc1 hm) hT1
      intro i hi
      have := hU (i + 1) (by omega)
      rwa [run_succ_step env i s hs.notHalted] at this
    · cases n with
      | zero => exact ⟨hT1, fun h => absurd h hm⟩
      | succ n =>
        exfalso
        have := hU 1 (by omega)
        rw [run_succ_step env 0 s hs.notHalted] at this
        exact hm this

end

end Rv32.Priv
