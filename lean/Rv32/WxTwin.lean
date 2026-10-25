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

/-- What of two machines a payload's run reads or moves, the same in both, `pc` aside: the registers, the bytes of `V`,
    privilege, the CSRs a step or a trap reads or writes but the trap vector and the PMP, and the host and its events. -/
structure Twin (V : Word → Prop) (s t : PrivMachine) : Prop where
  regs     : s.core.regs = t.core.regs
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
    (hpc : s.pc = t.pc) (hreg : s.regs = t.regs)
    (hld : ∀ op rd rs1 imm, i = .ld op rd rs1 imm →
      readLE s.mem (s.reg rs1 + imm.signExtend 32) op.size = readLE t.mem (s.reg rs1 + imm.signExtend 32) op.size) :
    (∃ c d, Rv32.exec env s i = .running c ∧ Rv32.exec env t i = .running d ∧ c.pc = d.pc ∧ c.regs = d.regs ∧
      ∀ x, s.mem x = t.mem x → c.mem x = d.mem x) ∨
    (∃ f g c d, Rv32.exec env s i = .fault f c ∧ Rv32.exec env t i = .fault g d) := by
  obtain ⟨p, r, m1⟩ := s
  obtain ⟨p', r', m2⟩ := t
  simp only at hpc hreg
  subst hpc hreg
  -- the same `pc` and registers: what an instruction does to them is the same, and memory is carried
  have run : ∀ (f : Rv32.Machine → Rv32.Machine), (∀ m, (f ⟨p, r, m⟩).mem = m) →
      (∀ m m', (f ⟨p, r, m⟩).pc = (f ⟨p, r, m'⟩).pc ∧ (f ⟨p, r, m⟩).regs = (f ⟨p, r, m'⟩).regs) →
      (∃ c d, Outcome.running (f ⟨p, r, m1⟩) = .running c ∧ Outcome.running (f ⟨p, r, m2⟩) = .running d ∧
        c.pc = d.pc ∧ c.regs = d.regs ∧ ∀ x, m1 x = m2 x → c.mem x = d.mem x) := by
    intro f hm hpr
    exact ⟨_, _, rfl, rfl, (hpr m1 m2).1, (hpr m1 m2).2, fun x hx => by rw [hm, hm]; exact hx⟩
  have sr : ∀ (rd : Reg) (v : Word) (m : Word → Byte), (Rv32.Machine.setReg ⟨p, r, m⟩ rd v).mem = m ∧
      (∀ m', (Rv32.Machine.setReg ⟨p, r, m⟩ rd v).pc = (Rv32.Machine.setReg ⟨p, r, m'⟩ rd v).pc ∧
        (Rv32.Machine.setReg ⟨p, r, m⟩ rd v).regs = (Rv32.Machine.setReg ⟨p, r, m'⟩ rd v).regs) := by
    intro rd v m
    unfold Machine.setReg
    split <;> simp
  cases i with
  | ecall => exact absurd rfl hi
  | lui rd imm =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (imm ++ 0#12)).next) (fun m => (sr _ _ m).1)
      (fun m m' => by simp only [Machine.next, Machine.setPc]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
  | auipc rd imm =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (s.pc + (imm ++ 0#12))).next) (fun m => (sr _ _ m).1)
      (fun m m' => by simp only [Machine.next, Machine.setPc]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
  | jal rd off =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (s.pc + 4)).setPc (s.pc + (off ++ 0#1).signExtend 32))
      (fun m => (sr _ _ m).1) (fun m m' => by simp only [Machine.setPc]; rw [(sr rd _ m).2 m' |>.2]; simp)
  | jalr rd rs1 imm =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (s.pc + 4)).setPc ((s.reg rs1 + imm.signExtend 32) &&& ~~~1#32))
      (fun m => (sr _ _ m).1) (fun m m' => by simp only [Machine.setPc, Machine.reg]; rw [(sr rd _ m).2 m' |>.2]; simp)
  | br op rs1 rs2 off =>
    left; simp only [Rv32.exec]
    have e1 : Machine.reg ⟨p, r, m2⟩ rs1 = Machine.reg ⟨p, r, m1⟩ rs1 := rfl
    have e2 : Machine.reg ⟨p, r, m2⟩ rs2 = Machine.reg ⟨p, r, m1⟩ rs2 := rfl
    rw [e1, e2]
    generalize taken op (Machine.reg ⟨p, r, m1⟩ rs1) (Machine.reg ⟨p, r, m1⟩ rs2) = b
    cases b <;> simp only [Bool.false_eq_true, ↓reduceIte]
    all_goals refine ⟨_, _, rfl, rfl, ?_, ?_, ?_⟩
    all_goals first | rfl | (intro x hx; exact hx)
  | opi op rd rs1 imm =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (aluI op (s.reg rs1) (imm.signExtend 32))).next) (fun m => (sr _ _ m).1)
      (fun m m' => by simp only [Machine.next, Machine.setPc, Machine.reg]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
  | sh op rd rs1 sa =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (shiftI op (s.reg rs1) sa.toNat)).next) (fun m => (sr _ _ m).1)
      (fun m m' => by simp only [Machine.next, Machine.setPc, Machine.reg]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
  | op op rd rs1 rs2 =>
    left; simp only [Rv32.exec]
    exact run (fun s => (s.setReg rd (aluR op (s.reg rs1) (s.reg rs2))).next) (fun m => (sr _ _ m).1)
      (fun m m' => by simp only [Machine.next, Machine.setPc, Machine.reg]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
  | ld op rd rs1 imm =>
    have hv := hld op rd rs1 imm rfl
    simp only [Rv32.exec, Machine.reg] at hv ⊢
    generalize (if rs1 = 0 then 0 else r rs1) + imm.signExtend 32 = a at hv ⊢
    by_cases h1 : a.toNat % op.size ≠ 0
    · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h1), ite_eq_left_of_eq_true _ _ (eq_true h1)]; exact ⟨_, _, _, _, rfl, rfl⟩
    · rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_right_of_eq_false _ _ (eq_false h1)]
      by_cases h2 : env.region.ok a op.size
      · rw [ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2)), ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2))]
        left
        rw [hv]
        exact run (fun s => (s.setReg rd (op.extend (readLE m2 a op.size))).next) (fun m => (sr _ _ m).1)
          (fun m m' => by simp only [Machine.next, Machine.setPc]; rw [(sr rd _ m).2 m' |>.1, (sr rd _ m).2 m' |>.2]; simp)
      · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h2), ite_eq_left_of_eq_true _ _ (eq_true h2)]; exact ⟨_, _, _, _, rfl, rfl⟩
  | st op rs1 rs2 imm =>
    simp only [Rv32.exec, Machine.reg]
    generalize (if rs1 = 0 then 0 else r rs1) + imm.signExtend 32 = a
    by_cases h1 : a.toNat % op.size ≠ 0
    · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h1), ite_eq_left_of_eq_true _ _ (eq_true h1)]; exact ⟨_, _, _, _, rfl, rfl⟩
    · rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_right_of_eq_false _ _ (eq_false h1)]
      by_cases h2 : env.region.ok a op.size
      · rw [ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2)), ite_eq_right_of_eq_false _ _ (eq_false (not_not_intro h2))]
        left
        refine ⟨_, _, rfl, rfl, rfl, rfl, ?_⟩
        intro x hx
        simp only [Machine.next, Machine.setPc]
        have hsz : op.size < 2^32 := by cases op <;> decide
        rw [writeLE_apply _ _ _ _ hsz x, writeLE_apply _ _ _ _ hsz x]
        split
        · rfl
        · exact hx
      · right; rw [ite_eq_left_of_eq_true _ _ (eq_true h2), ite_eq_left_of_eq_true _ _ (eq_true h2)]; exact ⟨_, _, _, _, rfl, rfl⟩

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
  refine ⟨r, m, rfl, h, ?_, ?_, rfl, ?_, ?_, inh, sc, io, ho⟩ <;>
    simp [raiseTrap, bumpCounters, mo, ms, hpc, mi, cy, inh]

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
  have hr : ∀ r, s.core.reg r = t.core.reg r := fun r => by simp [Machine.reg, hT.regs]
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
