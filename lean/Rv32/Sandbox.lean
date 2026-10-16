/-
SPDX-License-Identifier: Apache-2.0

# What a payload in U-mode can and cannot do

One step of `PrivMachine` from a state the PMP fences into `[lo, hi)` (`UBoxed`):

  * it stays in U-mode, still boxed, and only memory inside the box changes; or
  * it traps — the machine is in M-mode at the trap vector, with the registers and the memory
    the payload left, nothing else touched.

In both, the CSRs the monitor set (`mtvec`, `mscratch`, the PMP, `mcountinhibit`) are as they
were. `umode_run` is the same for any number of steps up to the first trap.

The box has to sit inside the 32-bit address space (`hi ≤ 2^32`), or a store at the top would
wrap around into the bottom.
-/
import Rv32.PrivRun
import Rv32.Refinement

namespace Rv32.Priv
open Rv32 Rv32.Refinement

/-- The CSRs the monitor set, and a payload cannot change. -/
def KeptCsrs (c c' : PrivCSRs) : Prop :=
  c'.mtvec = c.mtvec ∧ c'.mscratch = c.mscratch ∧ c'.mtval = c.mtval ∧ c'.pmpcfg0 = c.pmpcfg0 ∧
  c'.pmpaddr0 = c.pmpaddr0 ∧ c'.pmpaddr1 = c.pmpaddr1 ∧ c'.pmpaddr2 = c.pmpaddr2 ∧
  c'.pmpaddr3 = c.pmpaddr3 ∧ c'.mcountinhibit = c.mcountinhibit

theorem KeptCsrs.refl (c : PrivCSRs) : KeptCsrs c c := ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem KeptCsrs.trans {a b c : PrivCSRs} (h1 : KeptCsrs a b) (h2 : KeptCsrs b c) : KeptCsrs a c := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h1
  obtain ⟨b1, b2, b3, b4, b5, b6, b7, b8, b9⟩ := h2
  exact ⟨b1.trans a1, b2.trans a2, b3.trans a3, b4.trans a4, b5.trans a5, b6.trans a6, b7.trans a7,
    b8.trans a8, b9.trans a9⟩

theorem kept_bump (c : PrivCSRs) : KeptCsrs c (bumpCounters c) := ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem kept_trap (s : PrivMachine) (cause : Word) : KeptCsrs s.csrs (raiseTrap s cause).csrs :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem uboxed_of_kept {s s' : PrivMachine} {lo hi : Nat} (hBox : UBoxed s lo hi)
    (hk : KeptCsrs s.csrs s'.csrs) (hmode : s'.mode = .U) (hh : s'.halted = false) :
    UBoxed s' lo hi := by
  obtain ⟨_, _, _, k4, k5, k6, k7, k8, _⟩ := hk
  refine ⟨hmode, hh, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [k4]; exact hBox.cfg0Mode
  · rw [k4]; exact hBox.cfg0Read
  · rw [k4]; exact hBox.cfg0Write
  · rw [k4]; exact hBox.cfg0Exec
  · rw [k5]; exact hBox.addr0Range
  · intro i hi'; rw [k4]; exact hBox.otherOff i hi'

/-- Every outcome of `Rv32.exec` other than an `ecall`'s is a step or a fault. -/
theorem exec_no_halt {env : Rv32.Env} {s : Rv32.Machine} {i : Instr} (hi : i ≠ .ecall)
    {code : Word} {c : Rv32.Machine} : Rv32.exec env s i ≠ .halted code c := by
  intro h
  cases i with
  | ecall => exact absurd rfl hi
  | _ =>
    simp only [Rv32.exec] at h
    repeat' split at h
    all_goals simp at h

/-- An instruction that is not a store leaves memory alone. -/
theorem exec_mem_of_not_st {env : Rv32.Env} {s c : Rv32.Machine} {i : Instr}
    (hs : ∀ op rs1 rs2 imm, i ≠ .st op rs1 rs2 imm) (hi : i ≠ .ecall)
    (h : Rv32.exec env s i = .running c) : c.mem = s.mem := by
  cases i with
  | st op rs1 rs2 imm => exact absurd rfl (hs op rs1 rs2 imm)
  | ecall => exact absurd rfl hi
  | _ =>
    simp only [Rv32.exec] at h
    repeat' split at h
    all_goals first
      | (simp at h; done)
      | (injection h with e; subst e; simp)

theorem decode_ecall {w : Word} (h : Rv32.decode w = some .ecall) : isEcall w = true := by
  have := Rv32.encode_decode h
  simp only [isEcall, decide_eq_true_eq]
  rw [← this]
  rfl

/-- In U-mode, a word the trap check lets through is a plain instruction: not `ecall`, `mret`
    or `Zicsr`, and it decodes. -/
theorem trap_none_plain {s : PrivMachine} {w : Word} (hU : s.mode = .U)
    (h : uModeTrapCause s w = none) :
    isEcall w = false ∧ isMret w = false ∧ isZicsr w = false ∧ ∃ i, Rv32.decode w = some i := by
  unfold uModeTrapCause at h
  rw [hU] at h
  by_cases hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true
  · simp only [hf, not_true_eq_false, ↓reduceIte] at h
    by_cases he : isEcall w = true
    · simp [he] at h
    · have he' : isEcall w = false := by simpa using he
      simp only [he] at h
      by_cases hp : isMret w = true ∨ isZicsr w = true
      · simp [hp] at h
      · have hm : isMret w = false := by simpa using (not_or.mp hp).1
        have hz : isZicsr w = false := by simpa using (not_or.mp hp).2
        refine ⟨he', hm, hz, ?_⟩
        cases hd : Rv32.decode w with
        | none => rw [hd] at h; simp [hm, hz] at h
        | some i => exact ⟨i, rfl⟩
  · simp [hf] at h

/-- A store the trap check let through lands inside the box. -/
theorem st_in_box {s : PrivMachine} {w : Word} {lo hi : Nat}
    (hBox : UBoxed s lo hi) (h : uModeTrapCause s w = none)
    {op : StOp} {rs1 rs2 : Reg} {imm : BitVec 12} (hd : Rv32.decode w = some (.st op rs1 rs2 imm)) :
    let a := s.core.reg rs1 + imm.signExtend 32
    a.toNat % op.size = 0 ∧ lo ≤ a.toNat ∧ a.toNat + op.size ≤ hi := by
  intro a
  obtain ⟨he, hm, hz, _⟩ := trap_none_plain hBox.isUMode h
  unfold uModeTrapCause at h
  rw [hBox.isUMode] at h
  have hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true := by
    by_cases hf : pmpCheck s.csrs .U s.core.pc 4 .Fetch = true
    · exact hf
    · exfalso; simp [hf] at h
  simp only [hf, not_true_eq_false, ↓reduceIte, he, hm, hz, hd] at h
  by_cases hal : a.toNat % op.size = 0
  · have hal' : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
    by_cases hp : pmpCheck s.csrs .U a op.size .Store = true
    · have hpos : 0 < op.size := by cases op <;> decide
      have := (pmpCheck_uboxed_iff s lo hi hBox a op.size .Store hpos).mp (by simpa [hBox.isUMode] using hp)
      exact ⟨hal, this.1, this.2⟩
    · simp [hal', a, hp] at h
  · have : ¬ (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
    simp [this] at h

/-- One step of a boxed payload. -/
theorem umode_step (env : Rv32.Env) (s : PrivMachine) (lo hi : Nat) (hBox : UBoxed s lo hi)
    (hhi : hi ≤ 2^32) :
    KeptCsrs s.csrs (PrivMachine.step env s).csrs ∧ (PrivMachine.step env s).halted = false ∧
    (((PrivMachine.step env s).mode = .U ∧ UBoxed (PrivMachine.step env s) lo hi ∧
        ∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) →
          (PrivMachine.step env s).core.mem x = s.core.mem x) ∨
     ((PrivMachine.step env s).mode = .M ∧
        (PrivMachine.step env s).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
        (PrivMachine.step env s).core.regs = s.core.regs ∧
        (PrivMachine.step env s).core.mem = s.core.mem)) := by
  have trap : ∀ cause : Word, KeptCsrs s.csrs (raiseTrap s cause).csrs ∧ (raiseTrap s cause).halted = false ∧
      (raiseTrap s cause).mode = .M ∧ (raiseTrap s cause).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
      (raiseTrap s cause).core.regs = s.core.regs ∧ (raiseTrap s cause).core.mem = s.core.mem := by
    intro cause
    exact ⟨kept_trap s cause, hBox.notHalted, rfl, rfl, rfl, rfl⟩
  unfold PrivMachine.step PrivMachine.stepW
  rw [hBox.notHalted]
  simp only [Bool.false_eq_true, ↓reduceIte]
  generalize BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4) = w
  cases hc : uModeTrapCause s w with
  | some cause =>
    obtain ⟨t1, t2, t3, t4, t5, t6⟩ := trap cause
    exact ⟨t1, t2, Or.inr ⟨t3, t4, t5, t6⟩⟩
  | none =>
    obtain ⟨he, hm, hz, i, hd⟩ := trap_none_plain hBox.isUMode hc
    simp only [hm, hz, Bool.false_eq_true, ↓reduceIte, hd]
    have hne : i ≠ .ecall := by
      intro hi; subst hi; have := decode_ecall hd; rw [he] at this; exact absurd this (by decide)
    cases hx : Rv32.exec env s.core i with
    | halted code c => exact absurd hx (exec_no_halt hne)
    | fault f c =>
      dsimp only
      obtain ⟨t1, t2, t3, t4, t5, t6⟩ := trap CAUSE_ILLEGAL_INSTR
      exact ⟨t1, t2, Or.inr ⟨t3, t4, t5, t6⟩⟩
    | running c =>
      dsimp only
      have hk : KeptCsrs s.csrs (bumpCounters s.csrs) := kept_bump _
      refine ⟨hk, rfl, Or.inl ⟨hBox.isUMode, uboxed_of_kept hBox hk hBox.isUMode rfl, ?_⟩⟩
      intro x hx_out
      show c.mem x = s.core.mem x
      by_cases hst : ∃ op rs1 rs2 imm, i = .st op rs1 rs2 imm
      · obtain ⟨op, rs1, rs2, imm, rfl⟩ := hst
        obtain ⟨hal, hlo, hhi'⟩ := st_in_box hBox hc hd
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
            simp only [BitVec.toNat_sub, Nat.reducePow]
            omega
          simp only [hn, ↓reduceIte]
        · simp only [hreg] at hx
          simp at hx
      · have hs : ∀ op rs1 rs2 imm, i ≠ .st op rs1 rs2 imm := fun op rs1 rs2 imm h => hst ⟨op, rs1, rs2, imm, h⟩
        rw [exec_mem_of_not_st hs hne hx]

/-- Any number of steps of a boxed payload: up to the first trap it stays in the box and only
    writes inside it; at the trap the machine is in M-mode at the trap vector. -/
theorem umode_run (env : Rv32.Env) (lo hi : Nat) (hhi : hi ≤ 2^32) :
    ∀ (n : Nat) (s : PrivMachine), UBoxed s lo hi →
      ∃ k, k ≤ n ∧ KeptCsrs s.csrs (PrivMachine.run env k s).csrs ∧
        (PrivMachine.run env k s).halted = false ∧
        (∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) →
          (PrivMachine.run env k s).core.mem x = s.core.mem x) ∧
        ((k = n ∧ (PrivMachine.run env k s).mode = .U ∧ UBoxed (PrivMachine.run env k s) lo hi) ∨
         (0 < k ∧ (PrivMachine.run env k s).mode = .M ∧
          (PrivMachine.run env k s).core.pc = s.csrs.mtvec &&& ~~~3#32)) := by
  intro n
  induction n with
  | zero =>
    intro s hBox
    exact ⟨0, Nat.le_refl 0, KeptCsrs.refl _, hBox.notHalted, fun _ _ => rfl,
      Or.inl ⟨rfl, hBox.isUMode, hBox⟩⟩
  | succ n ih =>
    intro s hBox
    obtain ⟨hk, hh, hcase⟩ := umode_step env s lo hi hBox hhi
    rcases hcase with ⟨hmode, hBox', hmem⟩ | ⟨hmode, hpc, hregs, hmem⟩
    · obtain ⟨k, hkn, hk2, hh2, hmem2, hres⟩ := ih (PrivMachine.step env s) hBox'
      refine ⟨k + 1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env k s hBox.notHalted]; exact hk.trans hk2
      · rw [run_succ_step env k s hBox.notHalted]; exact hh2
      · intro x hx; rw [run_succ_step env k s hBox.notHalted, hmem2 x hx, hmem x hx]
      · rw [run_succ_step env k s hBox.notHalted]
        rcases hres with ⟨hkeq, hm, hb⟩ | ⟨hpos, hm, hpc⟩
        · exact Or.inl ⟨by omega, hm, hb⟩
        · exact Or.inr ⟨by omega, hm, by rw [hpc, hk.1]⟩
    · refine ⟨1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env 0 s hBox.notHalted]; exact hk
      · rw [run_succ_step env 0 s hBox.notHalted]; exact hh
      · intro x _; rw [run_succ_step env 0 s hBox.notHalted]; show (PrivMachine.step env s).core.mem x = _; rw [hmem]
      · rw [run_succ_step env 0 s hBox.notHalted]
        exact Or.inr ⟨by omega, hmode, hpc⟩

end Rv32.Priv
