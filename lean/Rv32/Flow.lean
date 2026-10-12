/-
SPDX-License-Identifier: Apache-2.0

# Control flow, a step at a time

A branch taken or not, `jal x0` and `jal ra`, `jalr x0` back through a
register, and the HALT `ecall` — each one instruction of any program at `base`,
with where it leaves `pc` worked out from the offset the encoding carries. The
offsets are checked by `jump`, which asks `decide` about numbers only: asking
it to evaluate a negative `signExtend` runs Lean out of memory. `regsimp`
settles which `if` a register lemma took for a literal register.

From exp228's proof, the second kernel to need them being exp229's.
-/
import Rv32.Blocks

namespace Rv32

variable {env : Env} {base : Word} {prog : List Instr}

theorem exec_jal {s : Machine} {rd : Reg} {off : BitVec 20} :
    exec env s (.jal rd off) = .running ((s.setReg rd (s.pc + 4)).setPc (s.pc + (off ++ 0#1).signExtend 32)) := rfl

theorem exec_jalr {s : Machine} {rd rs1 : Reg} {imm : BitVec 12} :
    exec env s (.jalr rd rs1 imm) =
      .running ((s.setReg rd (s.pc + 4)).setPc ((s.reg rs1 + imm.signExtend 32) &&& ~~~1#32)) := rfl

/-- What a jump's offset sign-extends to, as a number: `decide` cannot be
asked, since evaluating `signExtend` on a negative value runs Lean out of
memory (lean/Rv32/Blocks.lean's `se_neg` says the same). -/
theorem se_val {w : Nat} (off : BitVec w) (hw : w + 1 ≤ 32) :
    ((off ++ 0#1).signExtend 32).toNat
      = if 2 * off.toNat < 2 ^ w then 2 * off.toNat else 2 ^ 32 - 2 ^ (w + 1) + 2 * off.toNat := by
  have hlt := off.isLt
  have hv : (off ++ 0#1).toNat = 2 * off.toNat := by
    rw [BitVec.toNat_append]; simp [Nat.shiftLeft_eq]; omega
  have hm : (off ++ 0#1).msb = decide (2 ^ w ≤ 2 * off.toNat) := by
    rw [BitVec.msb_eq_decide, hv]; simp
  have hw2 : 2 ^ (w + 1) = 2 * 2 ^ w := by rw [Nat.pow_succ]; omega
  have h32 : 2 ^ (w + 1) ≤ 2 ^ 32 := Nat.pow_le_pow_right (by decide) hw
  rw [BitVec.toNat_signExtend, BitVec.toNat_setWidth, hm, hv, Nat.mod_eq_of_lt (by omega)]
  by_cases h : 2 * off.toNat < 2 ^ w
  · rw [ite_eq_left_of_eq_true _ _ (eq_true h), show decide (2 ^ w ≤ 2 * off.toNat) = false by simp; omega]; simp
  · rw [ite_eq_right_of_eq_false _ _ (eq_false h), show decide (2 ^ w ≤ 2 * off.toNat) = true by simp; omega]; simp; omega

/-- A jump from instruction `k` to `k'`, checked by `decide` on numbers. -/
theorem jump_ok {w : Nat} (off : BitVec w) (hw : w + 1 ≤ 32) (k k' : Nat) (hk : 4 * k < 2 ^ 31)
    (h : (if 2 * off.toNat < 2 ^ w then 4 * k + 2 * off.toNat else 4 * k + 2 * off.toNat - 2 ^ (w + 1)) = 4 * k')
    (h2 : 2 ^ w ≤ 2 * off.toNat → 2 ^ (w + 1) ≤ 4 * k + 2 * off.toNat) :
    BitVec.ofNat 32 (4 * k) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * k') := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_add, se_val off hw, BitVec.toNat_ofNat, BitVec.toNat_ofNat]
  have hlt := off.isLt
  have hw2 : 2 ^ (w + 1) = 2 * 2 ^ w := by rw [Nat.pow_succ]; omega
  have h32 : 2 ^ (w + 1) ≤ 2 ^ 32 := Nat.pow_le_pow_right (by decide) hw
  by_cases hc : 2 * off.toNat < 2 ^ w
  · rw [ite_eq_left_of_eq_true _ _ (eq_true hc)] at h ⊢; omega
  · rw [ite_eq_right_of_eq_false _ _ (eq_false hc)] at h ⊢; have := h2 (by omega); omega

/-- A jump's target: from instruction `k` to `k'`, by an offset the encoding
carries — checked once per jump by `decide`. -/
theorem jump_to (base : Word) {k k' : Nat} {w : Word}
    (h : BitVec.ofNat 32 (4 * k) + w = BitVec.ofNat 32 (4 * k')) :
    base + BitVec.ofNat 32 (4 * k) + w = base + BitVec.ofNat 32 (4 * k') := by
  rw [BitVec.add_assoc, h]

/-- A branch, taken or not: on to `k'` or to `k + 1`. -/
theorem brStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {op : BrOp} {rs1 rs2 : Reg} {off : BitVec 12} (hi : prog.getD k .ecall = .br op rs1 rs2 off)
    {k' : Nat} (hoff : BitVec.ofNat 32 (4 * k) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * k'))
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧
      s'.pc = (if taken op (s.reg rs1) (s.reg rs2) then base + BitVec.ofNat 32 (4 * k')
               else base + BitVec.ofNat 32 (4 * (k + 1)))
      ∧ s'.mem = s.mem ∧ ∀ r, s'.reg r = s.reg r := by
  by_cases ht : taken op (s.reg rs1) (s.reg rs2) = true
  · refine ⟨_, (stepK hp k hk hcode hpc hi (exec_br_taken ht) 0 hlen).trans (run_zero _ _), ?_, rfl,
      fun r => rfl⟩
    simp only [ht, ↓reduceIte, setPc_pc, hpc]; exact jump_to base hoff
  · have hf : taken op (s.reg rs1) (s.reg rs2) = false := by simpa using ht
    refine ⟨_, (stepK hp k hk hcode hpc hi (exec_br_not hf) 0 hlen).trans (run_zero _ _), ?_, rfl,
      fun r => rfl⟩
    simp only [hf, Bool.false_eq_true, ↓reduceIte, next_pc, hpc]; exact pc_next hp.fit k (by omega)

/-- `jal x0`: on to `k'`. -/
theorem jStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {off : BitVec 20} (hi : prog.getD k .ecall = .jal 0 off)
    {k' : Nat} (hoff : BitVec.ofNat 32 (4 * k) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * k'))
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * k')
      ∧ s'.mem = s.mem ∧ ∀ r, s'.reg r = s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi exec_jal 0 hlen).trans (run_zero _ _),
    by simp only [setPc_pc, hpc]; exact jump_to base hoff, by simp [Machine.setReg],
    fun r => by simp [reg_setReg]⟩

/-- `jal ra`: on to `k'`, with `ra` the instruction after. -/
theorem callStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {off : BitVec 20} (hi : prog.getD k .ecall = .jal 1 off)
    {k' : Nat} (hoff : BitVec.ofNat 32 (4 * k) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * k'))
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * k')
      ∧ s'.mem = s.mem ∧ ∀ r, s'.reg r = if r = 1 then base + BitVec.ofNat 32 (4 * (k + 1)) else s.reg r := by
  refine ⟨_, (stepK hp k hk hcode hpc hi exec_jal 0 hlen).trans (run_zero _ _), ?_, ?_, ?_⟩
  · simp only [setPc_pc, hpc]; exact jump_to base hoff
  · simp [Machine.setReg]
  · intro r
    rw [show ((s.setReg 1 (s.pc + 4)).setPc (s.pc + (off ++ 0#1).signExtend 32)).reg r
        = (s.setReg 1 (s.pc + 4)).reg r from rfl, reg_setReg]
    by_cases h : r = 1
    · subst h; simp only [and_true, ↓reduceIte, hpc, show (1 : Reg) ≠ 0 by decide, ne_eq, not_false_eq_true]
      exact pc_next hp.fit k (by omega)
    · simp only [h, false_and, ↓reduceIte]

theorem clear_low' (x : BitVec 32) (h : x.toNat % 2 = 0) : x &&& ~~~1#32 = x := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_and, show (~~~1#32).toNat = (2^31 - 1) * 2^1 by decide]
  have hx := x.isLt
  generalize x.toNat = n at *
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_and, Nat.testBit_mul_two_pow, Nat.testBit_two_pow_sub_one]
  rcases i with _ | i
  · simp [Nat.testBit_zero]; omega
  · by_cases hi : i < 31
    · rw [show decide (1 ≤ i + 1) = true by simp, show decide (i + 1 - 1 < 31) = true by simp; omega]
      simp
    · have : n.testBit (i + 1) = false := Nat.testBit_lt_two_pow (by
        calc n < 2 ^ 32 := hx
          _ ≤ 2 ^ (i + 1) := Nat.pow_le_pow_right (by decide) (by omega))
      simp [this]

/-- An address `base + 4k` has its low bit clear. -/
theorem clear_low (hp : Placed env base) (c : Nat) (hc : c < 0x10000) (h4 : c % 4 = 0) :
    (base + BitVec.ofNat 32 c) &&& ~~~1#32 = base + BitVec.ofNat 32 c :=
  clear_low' _ (by have := align_off hp.align hp.fit c hc h4; omega)

/-- `jalr x0, rs, 0` to `base + 4k'`. -/
theorem jalrStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {rs : Reg} (hi : prog.getD k .ecall = .jalr 0 rs 0)
    {k' : Nat} (hrs : s.reg rs = base + BitVec.ofNat 32 (4 * k')) (hk' : 4 * k' < 0x10000)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * k')
      ∧ s'.mem = s.mem ∧ ∀ r, s'.reg r = s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi exec_jalr 0 hlen).trans (run_zero _ _),
    by simp only [setPc_pc, hrs, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]
       exact clear_low hp _ hk' (by omega),
    by simp [Machine.setReg], fun r => by simp [reg_setReg]⟩

/-- HALT: `ecall` with `t0 = 1`. -/
theorem haltStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (hi : prog.getD k .ecall = .ecall) (h1 : s.reg T0 = 1)
    (hlen : 4 * prog.length < 0x10000 := by decide) (n : Nat) :
    run env (n + 1) s = .halted (s.reg A0) s := by
  have : prog[k] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk]
  exact run_code_halt n hk hcode hpc
    (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (this ▸ exec_halt h1)

/-- `addi r, r, -1` on a counter `n > 0`: `n - 1`. -/
theorem count_down (n : Nat) (h0 : 0 < n) (h : n < 2 ^ 32) :
    BitVec.ofNat 32 n + BitVec.signExtend 32 (0xfff : BitVec 12) = BitVec.ofNat 32 (n - 1) := by
  have := dec_one (n - 1) (by omega)
  rwa [Nat.sub_add_cancel h0] at this

/-- A counter as `bne r, zero` reads it: not zero exactly when its number is not. -/
theorem ofNat_ne_zero (n : Nat) (h : n < 2 ^ 32) : (BitVec.ofNat 32 n != (0 : Word)) = decide (n ≠ 0) := by
  by_cases e : n = 0
  · subst e; decide
  · have ne : BitVec.ofNat 32 n ≠ 0 := fun h' => e (by
      have := congrArg BitVec.toNat h'
      rwa [BitVec.toNat_ofNat, Nat.mod_eq_of_lt h] at this)
    rw [decide_eq_true e]
    exact bne_iff_ne.mpr ne

/-- A register outside a list is outside every list of its members. -/
theorem not_mem_of {r : Reg} {L L' : List Reg} (h : r ∉ L) (hs : L'.all (· ∈ L) = true) : r ∉ L' :=
  fun h' => h (by have := List.all_eq_true.1 hs r h'; simpa using this)

end Rv32

/-- A jump's offset, checked: `jump_ok` with `decide` for the numbers. -/
macro "jump" : tactic => `(tactic| exact Rv32.jump_ok _ (by decide) _ _ (by decide) (by decide) (by decide))

/-- After `rw [rK r]` with a literal register: decide which `if` it is. -/
macro "regsimp" : tactic => `(tactic| simp (config := { decide := true }) only
  [ite_true, ite_false, true_and, false_and, and_true, and_false, ne_eq, not_false_eq_true, not_true_eq_false])
