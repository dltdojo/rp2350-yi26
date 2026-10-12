/-
SPDX-License-Identifier: Apache-2.0

# A ring of 32 cells, one bit a cell

Bit i of a word is cell i; its neighbours are cells i - 1 and i + 1, round
the ring. Moving the ring one cell, and counting its set cells, are what
exp230's fly and exp232's tissue both need. exp230 wrote them; exp232 needed
them second.
-/
import Rv32.Machine

namespace Rv32

/-- How many of `x`'s low `n` bits are set. -/
def pc (x : Word) : Nat → Nat
  | 0 => 0
  | n + 1 => pc x n + (x.getLsbD n).toNat

/-- `x` moved one cell up, round the ring: bit i is x's bit i - 1. -/
def up1 (x : Word) : Word := x <<< 1 ||| x >>> 31

/-- `x` moved one cell down: bit i is x's bit i + 1. -/
def dn1 (x : Word) : Word := x >>> 1 ||| x <<< 31

/-! ## Bits -/

theorem up1_bit (x : Word) (i : Nat) (hi : i < 32) : (up1 x).getLsbD i = x.getLsbD ((i + 31) % 32) := by
  rcases (by omega : i = 0 ∨ (0 < i ∧ i < 32)) with h | ⟨h0, h1⟩
  · subst h; simp [up1]
  · have b : (i + 31) % 32 = i - 1 := by omega
    simp [up1, b, h1, show ¬ i < 1 by omega, BitVec.getLsbD_of_ge x (31 + i) (by omega)]
    exact (BitVec.getLsbD_eq_getElem (by omega)).symm

theorem dn1_bit (x : Word) (i : Nat) (hi : i < 32) : (dn1 x).getLsbD i = x.getLsbD ((i + 1) % 32) := by
  rcases (by omega : i = 31 ∨ i < 31) with h | h
  · subst h; simp [dn1]
  · have a : (i + 1) % 32 = 1 + i := by omega
    simp [dn1, a, hi, show i < 31 from h]

/-! ## Counting bits -/

theorem pc_congr {a b : Word} : ∀ n, (∀ i < n, a.getLsbD i = b.getLsbD i) → pc a n = pc b n
  | 0, _ => rfl
  | n + 1, h => by simp only [pc]; rw [pc_congr n (fun i hi => h i (by omega)), h n (by omega)]

theorem pc_le (a : Word) : ∀ n, pc a n ≤ n
  | 0 => Nat.le_refl _
  | n + 1 => by simp only [pc]; have := pc_le a n; cases a.getLsbD n <;> simp <;> omega

/-- A word's set bits are those also in `b` and those not. -/
theorem pc_split (a b : Word) : ∀ n, n ≤ 32 → pc (a &&& ~~~b) n + pc (a &&& b) n = pc a n
  | 0, _ => rfl
  | n + 1, hn => by
    have ih := pc_split a b n (by omega)
    simp only [pc, BitVec.getLsbD_and, BitVec.getLsbD_not, show n < 32 by omega, decide_true, Bool.true_and]
    cases a.getLsbD n <;> cases b.getLsbD n <;> simp <;> omega

theorem pc_and_le (a b : Word) : ∀ n, pc (a &&& b) n ≤ pc a n
  | 0 => Nat.le_refl _
  | n + 1 => by
    have ih := pc_and_le a b n
    simp only [pc, BitVec.getLsbD_and]
    cases a.getLsbD n <;> cases b.getLsbD n <;> simp <;> omega

/-- No bit set below `n` and the count is zero, and back. -/
theorem pc_zero (a : Word) : ∀ n, pc a n = 0 → ∀ i < n, a.getLsbD i = false
  | 0, _, i, hi => absurd hi (Nat.not_lt_zero _)
  | n + 1, h, i, hi => by
    simp only [pc] at h
    rcases (by omega : i < n ∨ i = n) with h' | h'
    · exact pc_zero a n (by omega) i h'
    · subst h'; cases e : a.getLsbD i <;> simp_all

/-- Moving the ring one cell up keeps its count: the top cell comes round to the bottom. -/
theorem pc_up1 (x : Word) : pc (up1 x) 32 = pc x 32 := by
  have h : ∀ k, k < 32 → pc (up1 x) (k + 1) = (x.getLsbD 31).toNat + pc x k := by
    intro k
    induction k with
    | zero => intro _; simp only [pc]; rw [up1_bit x 0 (by decide)]; simp
    | succ k ih =>
      intro hk
      rw [show k + 1 + 1 = (k + 1) + 1 from rfl]
      simp only [pc] at ih ⊢
      rw [ih (by omega), up1_bit x (k + 1) hk, show (k + 1 + 31) % 32 = k by omega]
      omega
  have := h 31 (by decide)
  simp only [pc] at this ⊢
  omega

/-- And one cell down: the bottom cell comes round to the top. -/
theorem pc_dn1 (x : Word) : pc (dn1 x) 32 = pc x 32 := by
  have h : ∀ k, k < 32 → pc (dn1 x) k + (x.getLsbD 0).toNat = pc x (k + 1) := by
    intro k
    induction k with
    | zero => intro _; simp [pc]
    | succ k ih =>
      intro hk
      simp only [pc] at ih ⊢
      rw [dn1_bit x k (by omega), show (k + 1) % 32 = k + 1 by omega]
      have := ih (by omega)
      omega
  have h31 := h 31 (by decide)
  simp only [pc] at h31 ⊢
  rw [dn1_bit x 31 (by decide), show (31 + 1) % 32 = 0 from rfl]
  omega

/-! ## Moving the ring commutes with every cell-by-cell operation -/

theorem up1_and (a b : Word) : up1 (a &&& b) = up1 a &&& up1 b := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [up1_bit _ i hi, BitVec.getLsbD_and]

theorem up1_or (a b : Word) : up1 (a ||| b) = up1 a ||| up1 b := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [up1_bit _ i hi, BitVec.getLsbD_or]

theorem up1_not (a : Word) : up1 (~~~a) = ~~~(up1 a) := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [up1_bit _ i hi, BitVec.getLsbD_not, show (i + 31) % 32 < 32 by omega, hi, decide_true, Bool.true_and]

theorem up1_dn1 (a : Word) : up1 (dn1 a) = dn1 (up1 a) := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  rw [up1_bit _ i hi, dn1_bit _ _ (by omega), dn1_bit _ i hi, up1_bit _ _ (by omega)]
  congr 1; omega

theorem up1_eq_zero (a : Word) : up1 a = 0 ↔ a = 0 := by
  constructor
  · intro h; apply BitVec.eq_of_getLsbD_eq; intro i hi
    have := congrArg (fun x => x.getLsbD ((i + 1) % 32)) h
    simp only [up1_bit _ _ (show (i + 1) % 32 < 32 by omega), show ((i + 1) % 32 + 31) % 32 = i by omega] at this
    simpa using this
  · intro h; subst h; decide

end Rv32
