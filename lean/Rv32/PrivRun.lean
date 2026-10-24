/-
SPDX-License-Identifier: Apache-2.0

# Running loaded M-mode code on `PrivMachine`

What a proof about a piece of M-mode code needs, once: the words at an address are what
`step` fetches (`WordsAt`, `step_of_words'`); `psimp` and `psimpH` run an instruction with `simp`
(the second leaves `pmpCheck` to a lemma the caller brings, which keeps the proof terms shallow);
memory that agrees with the loaded image on the code stays that way through stores elsewhere
(`Agree`, `agree_writeLE_iff`); a four-byte read finds what a four-byte write left there
(`readLE_writeLE_self`, `readLE_writeLE_far`); an M-mode access outside the box the PMP fences
off is not refused (`pmpCheck_M_outside`). `exp236` states what the micro-monitor's own words do
in these terms, and a second piece of M-mode code would use the same lemmas.
-/
import Rv32.Priv
import Rv32.Proof

namespace Rv32.Priv
open Rv32

/-! ## The words at an address are what `step` fetches -/

/-- Memory holds the words `ws`, one after another from `base`. -/
def WordsAt (m : Word → Byte) (base : Word) (ws : List Word) : Prop :=
  ∀ k (h : k < ws.length), BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 (4 * k)) 4) = ws[k]

theorem step_of_words {env : Rv32.Env} {s : PrivMachine} {base : Word} {ws : List Word} {k : Nat}
    (hW : WordsAt s.core.mem base ws) (hk : k < ws.length)
    (hpc : s.core.pc = base + BitVec.ofNat 32 (4 * k)) :
    PrivMachine.step env s = PrivMachine.stepW env s ws[k] := by
  unfold PrivMachine.step
  rw [hpc, hW k hk]

/-- Words stay where they are through a change of memory that leaves their bytes alone. -/
theorem WordsAt.congr {m m' : Word → Byte} {base : Word} {ws : List Word}
    (hfit : base.toNat + 4 * ws.length ≤ 2^32)
    (h : ∀ x : Word, base.toNat ≤ x.toNat → x.toNat < base.toNat + 4 * ws.length → m x = m' x)
    (hc : WordsAt m base ws) : WordsAt m' base ws := by
  intro k hk
  rw [← hc k hk]
  congr 1
  apply (readLE_four_congr _).symm
  intro d hd
  have := base.isLt
  apply h <;> simp only [BitVec.toNat_add, BitVec.toNat_ofNat] <;> omega

/-! ## One M-mode step -/

theorem run_succ_step (env : Rv32.Env) (n : Nat) (s : PrivMachine) (h : s.halted = false) :
    PrivMachine.run env (n + 1) s = PrivMachine.run env n (PrivMachine.step env s) := by
  simp [PrivMachine.run, h]

/-! ## An M-mode access outside the box is not refused -/

/-- The PMP is off, or one NAPOT entry fences off `[lo, hi)` and the other three are off. -/
def PmpFence (csrs : PrivCSRs) (lo hi : Nat) : Prop :=
  ((decodePmpCfgByte csrs.pmpcfg0 0).mode = .OFF ∨
     ((decodePmpCfgByte csrs.pmpcfg0 0).mode = .NAPOT ∧ decodeNapotRange csrs.pmpaddr0 = (lo, hi))) ∧
  (decodePmpCfgByte csrs.pmpcfg0 1).mode = .OFF ∧
  (decodePmpCfgByte csrs.pmpcfg0 2).mode = .OFF ∧
  (decodePmpCfgByte csrs.pmpcfg0 3).mode = .OFF

theorem pmpCheck_M_outside (csrs : PrivCSRs) (lo hi : Nat) (addr : Word) (width : Nat) (acc : AccessType)
    (hF : PmpFence csrs lo hi) (hout : addr.toNat + width ≤ lo ∨ hi ≤ addr.toNat) :
    pmpCheck csrs .M addr width acc = true := by
  obtain ⟨h0, h1, h2, h3⟩ := hF
  have e0 : matchPmpEntry csrs 0 addr width = .NoMatch := by
    rcases h0 with h | ⟨h, hr⟩
    · exact matchPmpEntry_off csrs 0 addr width h
    · unfold matchPmpEntry
      have hAddr0 : pmpAddrVal csrs 0 = csrs.pmpaddr0 := rfl
      simp [h, hAddr0, hr]
      omega
  have e1 := matchPmpEntry_off csrs 1 addr width h1
  have e2 := matchPmpEntry_off csrs 2 addr width h2
  have e3 := matchPmpEntry_off csrs 3 addr width h3
  unfold pmpCheck PMP_INDICES pmpCheckEntries
  rw [e0]; dsimp only
  unfold pmpCheckEntries
  rw [e1]; dsimp only
  unfold pmpCheckEntries
  rw [e2]; dsimp only
  unfold pmpCheckEntries
  rw [e3]; dsimp only
  unfold pmpCheckEntries
  decide

/-! ## Stepping loaded code with `simp` -/

theorem getD_eq_getElem' (ws : List Word) (i : Nat) (h : i < ws.length) : ws.getD i 0 = ws[i] := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]

/-- `step`, with the fetched word read as the entry of `ws` at `(pc - base) / 4`. -/
theorem step_of_words' {env : Rv32.Env} {s : PrivMachine} {base : Word} {ws : List Word}
    (hW : WordsAt s.core.mem base ws)
    (hlt : (s.core.pc - base).toNat / 4 < ws.length)
    (hal : (s.core.pc - base).toNat % 4 = 0) :
    PrivMachine.step env s = PrivMachine.stepW env s (ws.getD ((s.core.pc - base).toNat / 4) 0) := by
  have h : s.core.pc = base + BitVec.ofNat 32 (4 * ((s.core.pc - base).toNat / 4)) := by
    apply BitVec.eq_of_toNat_eq
    have h1 := (s.core.pc - base).isLt
    have h2 := s.core.pc.isLt
    have h3 := base.isLt
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_sub] at *
    omega
  rw [step_of_words hW hlt h, getD_eq_getElem' ws _ hlt]

@[simp] theorem setReg_x0 (s : Rv32.Machine) (v : Word) : s.setReg 0#5 v = s := by
  simp [Rv32.Machine.setReg]

/-- Memory agrees with `m0` on the bytes `[base, base + len)`. -/
def Agree (m0 m : Word → Byte) (base len : Nat) : Prop :=
  ∀ x : Word, base ≤ x.toNat → x.toNat < base + len → m x = m0 x

theorem Agree.refl (m0 : Word → Byte) (base len : Nat) : Agree m0 m0 base len := fun _ _ _ => rfl

/-- A four-byte store that does not touch `[base, base + len)` leaves the agreement. -/
theorem Agree.write {m0 m : Word → Byte} {base len : Nat} (h : Agree m0 m base len)
    (a : Word) (v : Nat) (hd : a.toNat + 4 ≤ base ∨ base + len ≤ a.toNat) (hwrap : a.toNat + 4 ≤ 2^32) :
    Agree m0 (writeLE m a v 4) base len := by
  intro x hx1 hx2
  rw [writeLE_apply m a v 4 (by decide) x]
  have : ¬ (x - a).toNat < 4 := by
    have := x.isLt; have := a.isLt
    simp only [BitVec.toNat_sub, Nat.reducePow]
    omega
  simp only [this, ↓reduceIte]
  exact h x hx1 hx2

theorem WordsAt.of_agree {m0 m : Word → Byte} {base : Word} {ws : List Word}
    (hfit : base.toNat + 4 * ws.length ≤ 2^32)
    (h : Agree m0 m base.toNat (4 * ws.length)) (hc : WordsAt m0 base ws) : WordsAt m base ws :=
  WordsAt.congr hfit (fun x h1 h2 => (h x h1 h2).symm) hc

/-- `simp` with everything it takes to run a loaded M-mode instruction: the step, its trap
    check, the decoder, the executor, the CSR file and the PMP. The caller adds what it
    knows about the state. -/
syntax (name := psimp) "psimp" " [" Lean.Parser.Tactic.simpLemma,* "]" (Lean.Parser.Tactic.location)? : tactic

macro_rules
  | `(tactic| psimp [$ls,*] $[$loc]?) =>
    `(tactic| simp [setReg_x0, Rv32.reg_setReg, pmpAddrVal, decodeNapotRange,
      countTrailingOnes32, countTrailingOnes32.loop, PrivMachine.run, bumpCounters, execZicsr,
      execMret, csrIllegal, csrImplemented, csrReadOnly, csrWrites, readCSR, writeCSR,
      PrivMachine.stepW, uModeTrapCause, pmpCheck, PMP_INDICES, pmpCheckEntries, matchPmpEntry,
      decodePmpCfgByte, isEcall, isMret, isZicsr, Rv32.decode, Rv32.decodeNat, Rv32.exec,
      IOp.ofF3, BrOp.ofF3, LdOp.ofF3, StOp.ofF3, ShOp.ofF, ROp.ofF, aluI, shiftI, aluR, taken,
      LdOp.size, StOp.size, LdOp.extend, raiseTrap, portRead, portWrites, isPort, PrivMode.ofBits, PrivMode.toBits, hasPermission,
      Rv32.Region.ok, $ls,*] $[$loc]?)

/-! ## Memory after stores -/

theorem agree_writeLE_iff {m0 m : Word → Byte} {base len : Nat} (a : Word) (v : Nat)
    (hd : a.toNat + 4 ≤ base ∨ base + len ≤ a.toNat) (hwrap : a.toNat + 4 ≤ 2^32) :
    Agree m0 (writeLE m a v 4) base len ↔ Agree m0 m base len := by
  constructor
  · intro h x hx1 hx2
    have := h x hx1 hx2
    rw [writeLE_apply m a v 4 (by decide) x] at this
    have hn : ¬ (x - a).toNat < 4 := by
      have := x.isLt; have := a.isLt
      simp only [BitVec.toNat_sub, Nat.reducePow]
      omega
    simp only [hn, ↓reduceIte] at this
    exact this
  · intro h
    exact Agree.write h a v hd hwrap

/-- A four-byte read of what four bytes were just written there. -/
theorem readLE_writeLE_self (m : Word → Byte) (a : Word) (v : Nat) :
    readLE (writeLE m a v 4) a 4 = v % 4294967296 := by
  rw [readLE_four]
  have e1 : ((a + 1) - a).toNat = 1 := by
    have : (a + 1) - a = 1 := by bv_omega
    rw [this]; rfl
  have e2 : ((a + 2) - a).toNat = 2 := by
    have : (a + 2) - a = 2 := by bv_omega
    rw [this]; rfl
  have e3 : ((a + 3) - a).toNat = 3 := by
    have : (a + 3) - a = 3 := by bv_omega
    rw [this]; rfl
  have e0 : (a - a).toNat = 0 := by simp
  rw [writeLE_apply _ a v 4 (by decide) a, writeLE_apply _ a v 4 (by decide) (a + 1),
    writeLE_apply _ a v 4 (by decide) (a + 2), writeLE_apply _ a v 4 (by decide) (a + 3)]
  simp only [e0, e1, e2, e3]
  simp only [Nat.reduceLT, ↓reduceIte, BitVec.toNat_ofNat, Nat.reducePow]
  omega

/-- A four-byte read away from a four-byte write is not changed by it. -/
theorem readLE_writeLE_far (m : Word → Byte) (a b : Word) (v : Nat)
    (hd : a.toNat + 4 ≤ b.toNat ∨ b.toNat + 4 ≤ a.toNat)
    (ha : a.toNat + 4 ≤ 2^32) (hb : b.toNat + 4 ≤ 2^32) :
    readLE (writeLE m b v 4) a 4 = readLE m a 4 := by
  apply readLE_four_congr
  intro d hd4
  rw [writeLE_apply m b v 4 (by decide)]
  have : ¬ ((a + BitVec.ofNat 32 d) - b).toNat < 4 := by
    have := a.isLt; have := b.isLt
    simp only [BitVec.toNat_sub, BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow]
    omega
  simp only [this, ↓reduceIte]

/-! ## Memory zeroed (from exp239: a monitor's loop that zeroes a range) -/

/-- `m'` is `m` with the bytes `[lo, hi)` zeroed and every other byte as it was. -/
def Zeroed (lo hi : Nat) (m m' : Word → Byte) : Prop :=
  ∀ x : Word, (lo ≤ x.toNat ∧ x.toNat < hi → m' x = 0) ∧ (¬ (lo ≤ x.toNat ∧ x.toNat < hi) → m' x = m x)

theorem zeroed_write (A : Word) (m : Word → Byte) (hw : A.toNat + 4 ≤ 4294967296) :
    Zeroed A.toNat (A.toNat + 4) m (writeLE m A 0 4) := by
  intro x
  rw [writeLE_apply m A 0 4 (by decide) x]
  simp only [BitVec.toNat_sub, Nat.reducePow, Nat.zero_div]
  have hx := x.isLt
  have ha := A.isLt
  constructor
  · intro h
    have : (4294967296 - A.toNat + x.toNat) % 4294967296 < 4 := by omega
    simp [this]
  · intro h
    have : ¬ (4294967296 - A.toNat + x.toNat) % 4294967296 < 4 := by omega
    simp [this]

theorem zeroed_trans {lo mid hi : Nat} {m0 m1 m2 : Word → Byte} (h1 : Zeroed lo mid m0 m1)
    (h2 : Zeroed mid hi m1 m2) (hlm : lo ≤ mid) (hmh : mid ≤ hi) : Zeroed lo hi m0 m2 := by
  intro x
  obtain ⟨a1, b1⟩ := h1 x
  obtain ⟨a2, b2⟩ := h2 x
  constructor
  · intro h
    by_cases hx : x.toNat < mid
    · rw [b2 (by omega)]; exact a1 ⟨h.1, hx⟩
    · exact a2 ⟨by omega, h.2⟩
  · intro h
    rw [b2 (by omega)]
    exact b1 (by omega)

/-- A four-byte read away from the zeroed bytes is what it was. -/
theorem readLE_zeroed {lo hi : Nat} {m m' : Word → Byte} (h : Zeroed lo hi m m') (a : Word)
    (ha : a.toNat + 4 ≤ lo ∨ hi ≤ a.toNat) (hw : a.toNat + 4 ≤ 4294967296) :
    readLE m' a 4 = readLE m a 4 := by
  apply readLE_four_congr
  intro d hd
  apply (h _).2
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow]
  have := a.isLt
  omega

/-- `psimp` without the PMP: the caller brings a lemma that settles `pmpCheck` for the
    configuration it has, instead of `simp` working it out from the registers each time. -/
syntax (name := psimpH) "psimpH" " [" Lean.Parser.Tactic.simpLemma,* "]" (Lean.Parser.Tactic.location)? : tactic

macro_rules
  | `(tactic| psimpH [$ls,*] $[$loc]?) =>
    `(tactic| simp [setReg_x0, Rv32.reg_setReg, PrivMachine.run, bumpCounters, execZicsr,
      execMret, csrIllegal, csrImplemented, csrReadOnly, csrWrites, readCSR, writeCSR,
      PrivMachine.stepW, uModeTrapCause, isEcall, isMret, isZicsr, Rv32.decode, Rv32.decodeNat,
      Rv32.exec, IOp.ofF3, BrOp.ofF3, LdOp.ofF3, StOp.ofF3, ShOp.ofF, ROp.ofF, aluI, shiftI,
      aluR, taken, LdOp.size, StOp.size, LdOp.extend, raiseTrap, portRead, portWrites, isPort, PrivMode.ofBits, PrivMode.toBits,
      hasPermission, Rv32.Region.ok, $ls,*] $[$loc]?)

end Rv32.Priv
