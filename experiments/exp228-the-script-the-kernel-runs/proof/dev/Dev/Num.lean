import Dev.Spec
set_option linter.unusedSimpArgs false

/-! # Numbers: the bit facts DECODE and ENCODE stand on, and the spec's
`decode` and `encode` for elements of at most four (five) bytes -/

set_option maxRecDepth 100000

namespace Exp228
open Rv32

/-- Bit 7, as a number. -/
theorem and_bit7 (y : Nat) : y &&& 128 = 128 * (y / 128 % 2) := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_and, show (128 : Nat) = 2 ^ 7 from rfl, Nat.testBit_two_pow,
    show 2 ^ 7 * (y / 2 ^ 7 % 2) = (y / 2 ^ 7 % 2) * 2 ^ 7 by rw [Nat.mul_comm], Nat.testBit_mul_two_pow]
  by_cases h : i = 7
  · subst h
    rw [Nat.testBit_eq_decide_div_mod_eq (i := 7), Nat.testBit_eq_decide_div_mod_eq (i := 7 - 7)]
    simp
  · have h2 : (7 = i) = False := by simp; omega
    simp only [h2, decide_false, Bool.and_false]
    by_cases h3 : 7 ≤ i
    · simp only [h3, decide_true, Bool.true_and]
      rw [Nat.testBit_eq_decide_div_mod_eq]
      have : y / 2 ^ 7 % 2 < 2 ^ (i - 7) := by
        have : 2 ≤ 2 ^ (i - 7) := by
          have := Nat.pow_le_pow_right (show 0 < 2 by decide) (show 1 ≤ i - 7 by omega); simpa using this
        omega
      rw [Nat.div_eq_of_lt this]; simp
    · simp only [h3, decide_false, Bool.false_and]

/-- Clearing bit `k` of a number below `2^(k+1)`, the kernel's way: with the
mask `2^k xor (2^32 - 1)`. -/
theorem clear_top (w k : Nat) (hk : k < 32) (hw : w < 2 ^ (k + 1)) :
    w &&& (2 ^ k ^^^ (2 ^ 32 - 1)) = w % 2 ^ k := by
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_and, Nat.testBit_xor, Nat.testBit_two_pow, Nat.testBit_two_pow_sub_one, Nat.testBit_mod_two_pow]
  by_cases h1 : i < k
  · simp [h1, show ¬ k = i by omega, show i < 32 by omega]
  · by_cases h2 : i = k
    · subst h2; simp [hk]
    · have : w.testBit i = false := Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le hw
        (Nat.pow_le_pow_right (by decide) (by omega)))
      simp [this, h1]

/-- A sign (0 or 1) and a magnitude, as a number. -/
def val (sg m : Nat) : Int := if sg = 1 then -(m : Int) else m

/-- What DECODE computes from an element's length `n` and its first word `w`:
a sign and a magnitude, or nothing. -/
def kdec (n w : Nat) : Option (Nat × Nat) :=
  if n = 0 then some (0, 0)
  else if 4 < n then none
  else if w / 2 ^ (8 * n - 8) % 128 = 0 ∧ (n = 1 ∨ w / 2 ^ (8 * n - 16) / 128 % 2 = 0) then none
  else some (w / 2 ^ (8 * n - 8) / 128, w % 2 ^ (8 * n - 1))

theorem byte_7f (b : Byte) : (b &&& 0x7f = 0) ↔ b.toNat % 128 = 0 := by
  constructor
  · intro h; have := congrArg BitVec.toNat h
    rw [BitVec.toNat_and, show (0x7f : Byte).toNat = 2 ^ 7 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod] at this
    simpa using this
  · intro h; apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and, show (0x7f : Byte).toNat = 2 ^ 7 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod]
    simpa using h

theorem byte_80 (b : Byte) : (b &&& 0x80 = 0) ↔ b.toNat / 128 % 2 = 0 := by
  constructor
  · intro h; have := congrArg BitVec.toNat h
    rw [BitVec.toNat_and, show (0x80 : Byte).toNat = 128 from rfl, and_bit7] at this
    simp at this; omega
  · intro h; apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_and, show (0x80 : Byte).toNat = 128 from rfl, and_bit7, h]; rfl

/-- **The spec's `decode`, as DECODE computes it**, from the first word. -/
theorem decode_k (e : Elem) (w : Nat) (hw : e.length ≤ 4 → w = leNat e) :
    decode e = (kdec e.length w).map (fun p => val p.1 p.2) := by
  unfold decode kdec
  by_cases h4 : 4 < e.length
  · simp [h4, show e.length ≠ 0 by omega]
  obtain rfl := hw (by omega)
  simp only [h4, ↓reduceIte]
  rcases e with _ | ⟨b0, _ | ⟨b1, _ | ⟨b2, _ | ⟨b3, _ | ⟨b4, rest⟩⟩⟩⟩⟩
  · simp [val]
  · have := b0.isLt
    simp only [List.length_cons, List.length_nil, List.getD_cons_zero, List.getD_cons_succ, byte_7f, byte_80, leNat]
    repeat' split
    all_goals simp_all [val]
    all_goals try omega
  · have := b0.isLt; have := b1.isLt
    have hW : leNat [b0, b1] = b0.toNat + 256 * b1.toNat := by simp [leNat]; try omega
    simp only [List.length_cons, List.length_nil, Nat.zero_add, Nat.reduceAdd, Nat.reduceMul, Nat.reduceSub,
      Nat.reducePow, List.getD_cons_zero, List.getD_cons_succ, byte_7f, byte_80, Nat.div_one]
    rw [show leNat [b0, b1] / 256 = b1.toNat by omega]
    rw [show leNat [b0, b1] / 128 % 2 = b0.toNat / 128 % 2 by omega]
    have hs : (b1.toNat / 128 = 1) = (128 ≤ b1.toNat) := propext (by omega)
    simp only [val, hs]
    repeat' split
    all_goals simp_all
    all_goals try omega
  · have := b0.isLt; have := b1.isLt; have := b2.isLt
    have hW : leNat [b0, b1, b2] = b0.toNat + 256 * b1.toNat + 65536 * b2.toNat := by simp [leNat]; try omega
    simp only [List.length_cons, List.length_nil, Nat.zero_add, Nat.reduceAdd, Nat.reduceMul, Nat.reduceSub,
      Nat.reducePow, List.getD_cons_zero, List.getD_cons_succ, byte_7f, byte_80, Nat.div_one]
    rw [show leNat [b0, b1, b2] / 65536 = b2.toNat by omega]
    rw [show leNat [b0, b1, b2] / 256 / 128 % 2 = b1.toNat / 128 % 2 by omega]
    have hs : (b2.toNat / 128 = 1) = (128 ≤ b2.toNat) := propext (by omega)
    simp only [val, hs]
    repeat' split
    all_goals simp_all
    all_goals try omega
  · have := b0.isLt; have := b1.isLt; have := b2.isLt; have := b3.isLt
    have hW : leNat [b0, b1, b2, b3] = b0.toNat + 256 * b1.toNat + 65536 * b2.toNat + 16777216 * b3.toNat := by simp [leNat]; try omega
    simp only [List.length_cons, List.length_nil, Nat.zero_add, Nat.reduceAdd, Nat.reduceMul, Nat.reduceSub,
      Nat.reducePow, List.getD_cons_zero, List.getD_cons_succ, byte_7f, byte_80, Nat.div_one]
    rw [show leNat [b0, b1, b2, b3] / 16777216 = b3.toNat by omega]
    rw [show leNat [b0, b1, b2, b3] / 65536 / 128 % 2 = b2.toNat / 128 % 2 by omega]
    have hs : (b3.toNat / 128 = 1) = (128 ≤ b3.toNat) := propext (by omega)
    simp only [val, hs]
    repeat' split
    all_goals simp_all
    all_goals try omega
  · simp at h4

/-- The low `n` bytes of `W`, little-endian. -/
def bytesOf : Nat → Nat → Elem
  | _, 0 => []
  | W, n + 1 => BitVec.ofNat 8 (W % 256) :: bytesOf (W / 256) n

/-- How many bytes a nonzero magnitude below `2^32` takes. -/
def nbytes (m : Nat) : Nat := if m < 2 ^ 8 then 1 else if m < 2 ^ 16 then 2 else if m < 2 ^ 24 then 3 else 4

/-- What ENCODE leaves in the slot for a sign and a magnitude. -/
def kenc (sg m : Nat) : Elem :=
  if m = 0 then []
  else if m / 2 ^ (8 * nbytes m - 8) / 128 % 2 = 1 then bytesOf m (nbytes m) ++ [BitVec.ofNat 8 (sg * 128)]
  else bytesOf (m + sg * 2 ^ (8 * nbytes m - 1)) (nbytes m)

theorem magBytes_zero : magBytes 0 = [] := by rw [magBytes]; simp

theorem magBytes_succ (m : Nat) (h : m ≠ 0) : magBytes m = BitVec.ofNat 8 (m % 256) :: magBytes (m / 256) := by
  rw [magBytes]; simp [h]

theorem magBytes_bytes : ∀ n m, 0 < m → m < 256 ^ (n + 1) → 256 ^ n ≤ m → magBytes m = bytesOf m (n + 1)
  | 0, m, h0, h1, _ => by
    rw [magBytes_succ m (by omega), show m / 256 = 0 by simp at h1; omega, magBytes_zero]; rfl
  | n + 1, m, h0, h1, h2 => by
    have hp : 256 ^ (n + 1) = 256 ^ n * 256 := Nat.pow_succ ..
    have hq : 256 ^ (n + 2) = 256 ^ n * 256 * 256 := by rw [Nat.pow_succ, hp]
    have hpos : 0 < 256 ^ n := Nat.pow_pos (by decide)
    rw [magBytes_succ m (by omega), magBytes_bytes n (m / 256) (by
      rw [hp] at h2; exact Nat.div_pos (by have := Nat.le_mul_of_pos_left 256 hpos; omega) (by decide))
      (by rw [hq] at h1; rw [hp]; exact (Nat.div_lt_iff_lt_mul (by decide)).mpr h1)
      (by rw [hp] at h2; exact (Nat.le_div_iff_mul_le (by decide)).mpr h2)]
    rfl

theorem or80 : ∀ t < 128, BitVec.ofNat 8 (t + 128) = BitVec.ofNat 8 t ||| 0x80 := by decide

/-- **The spec's `encode`, as ENCODE computes it.** -/
theorem encode_k (sg m : Nat) (hs : sg ≤ 1) (hm : m < 2 ^ 32) : encode (val sg m) = kenc sg m := by
  unfold encode kenc
  by_cases h0 : m = 0
  · subst h0; simp [val]
  have hv : val sg m ≠ 0 := by unfold val; split <;> omega
  have habs : (val sg m).natAbs = m := by unfold val; split <;> omega
  have hneg : (val sg m < 0) ↔ sg = 1 := by unfold val; split <;> omega
  simp only [hv, ↓reduceIte, habs, h0]
  sorry

end Exp228
