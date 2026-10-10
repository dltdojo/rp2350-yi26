import Dev.Spec
import Rv32.Blocks
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

theorem ofNat_eq_mod {a b : Nat} (h : a % 256 = b % 256) : BitVec.ofNat 8 a = BitVec.ofNat 8 b := by
  apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_ofNat]; exact h

theorem or80 : ∀ t < 128, BitVec.ofNat 8 (t + 128) = BitVec.ofNat 8 t ||| 0x80 := by decide

theorem ofNat_or128 {a b : Nat} (ha : a % 256 < 128) (hb : b % 256 = a % 256 + 128) :
    BitVec.ofNat 8 a ||| 128 = BitVec.ofNat 8 b := by
  rw [ofNat_eq_mod (b := a % 256) (by omega), show (128 : Byte) = 0x80 from rfl, ← or80 _ ha]
  exact ofNat_eq_mod (by omega)

/-- **The spec's `encode`, as ENCODE computes it.** -/
theorem encode_k (sg m : Nat) (hs : sg ≤ 1) (hm : m < 2 ^ 32) : encode (val sg m) = kenc sg m := by
  unfold encode kenc
  by_cases h0 : m = 0
  · subst h0; simp [val]
  have hv : val sg m ≠ 0 := by unfold val; split <;> omega
  have habs : (val sg m).natAbs = m := by unfold val; split <;> omega
  have hneg : (val sg m < 0) ↔ sg = 1 := by unfold val; split <;> omega
  simp only [hv, ↓reduceIte, habs, h0, hneg]
  have hk : (m < 2 ^ 8 ∧ nbytes m = 1) ∨ (2 ^ 8 ≤ m ∧ m < 2 ^ 16 ∧ nbytes m = 2) ∨
      (2 ^ 16 ≤ m ∧ m < 2 ^ 24 ∧ nbytes m = 3) ∨ (2 ^ 24 ≤ m ∧ nbytes m = 4) := by
    unfold nbytes; split <;> (try split) <;> (try split) <;> omega
  rcases (by omega : sg = 0 ∨ sg = 1) with rfl | rfl <;>
  rcases hk with ⟨h1, hn⟩ | ⟨h1, h2, hn⟩ | ⟨h1, h2, hn⟩ | ⟨h1, hn⟩ <;> rw [hn]
  all_goals
    first
      | rw [magBytes_bytes 0 m (by omega) (by simpa using h1) (by simp; omega)]
      | rw [magBytes_bytes 1 m (by omega) (by simpa using h2) (by simpa using h1)]
      | rw [magBytes_bytes 2 m (by omega) (by simpa using h2) (by simpa using h1)]
      | rw [magBytes_bytes 3 m (by omega) (by simpa using hm) (by simpa using h1)]
    simp only [bytesOf, List.length_cons, List.length_nil, Nat.zero_add, Nat.reduceAdd, Nat.reduceMul,
      Nat.reduceSub, Nat.reducePow, List.getD_cons_zero, List.getD_cons_succ, Nat.div_one, Nat.zero_mul,
      Nat.add_zero, Nat.one_mul, ne_eq, byte_80, BitVec.toNat_ofNat, Nat.mod_mod]
    repeat' split
    all_goals (try (exfalso; omega))
    all_goals simp only [List.cons_append, List.nil_append, List.take, List.cons.injEq, and_true]
    all_goals (try (simp at *; done))
    all_goals (repeat' constructor)
    all_goals first
      | exact ofNat_eq_mod (by omega)
      | exact ofNat_or128 (by omega) (by omega)

/-- CORE: two signed magnitudes added, the kernel's way. -/
def kcore (s1 m1 s2 m2 : Nat) : Nat × Nat :=
  if s1 = s2 then (s1, m1 + m2) else if m1 < m2 then (s2, m2 - m1) else (s1, m1 - m2)

theorem kcore_val (s1 m1 s2 m2 : Nat) (hs1 : s1 ≤ 1) (hs2 : s2 ≤ 1) :
    val (kcore s1 m1 s2 m2).1 (kcore s1 m1 s2 m2).2 = val s1 m1 + val s2 m2 := by
  unfold kcore val
  repeat' split
  all_goals simp_all
  all_goals omega

theorem kcore_le (s1 m1 s2 m2 : Nat) (hs1 : s1 ≤ 1) (hs2 : s2 ≤ 1) : (kcore s1 m1 s2 m2).1 ≤ 1 := by
  unfold kcore; repeat' split
  all_goals simp_all

theorem kcore_lt (s1 m1 s2 m2 : Nat) (h1 : m1 < 2 ^ 31) (h2 : m2 < 2 ^ 31) : (kcore s1 m1 s2 m2).2 < 2 ^ 32 := by
  unfold kcore; repeat' split
  all_goals simp_all
  all_goals omega

theorem val_flip (s m : Nat) (hs : s ≤ 1) : val (s ^^^ 1) m = - val s m := by
  rcases (by omega : s = 0 ∨ s = 1) with rfl | rfl <;> simp [val]

/-! ## The kernel's register arithmetic, on numbers -/

theorem w_addi_neg (a v : Nat) (ha : a < 2 ^ 32) (hv : 0 < v ∧ v ≤ 2048) (hva : v ≤ a) :
    BitVec.ofNat 32 a + (BitVec.ofNat 12 (4096 - v)).signExtend 32 = BitVec.ofNat 32 (a - v) := by
  rw [se_neg _ (by omega) (by omega)]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
  omega

theorem w_addi_pos (a v : Nat) (ha : a + v < 2 ^ 32) (hv : v < 2048) :
    BitVec.ofNat 32 a + (BitVec.ofNat 12 v).signExtend 32 = BitVec.ofNat 32 (a + v) := by
  rw [se_small _ hv]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
  omega

theorem w_srl (w k : Nat) (hw : w < 2 ^ 32) (hk : k < 32) :
    BitVec.ofNat 32 w >>> ((BitVec.ofNat 32 k).toNat % 32) = BitVec.ofNat 32 (w / 2 ^ k) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  rw [Nat.mod_eq_of_lt hw, Nat.mod_eq_of_lt (show k < 2 ^ 32 by omega), Nat.mod_eq_of_lt hk,
    Nat.mod_eq_of_lt (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw)]

theorem w_srli (w k : Nat) (hw : w < 2 ^ 32) :
    BitVec.ofNat 32 w >>> k = BitVec.ofNat 32 (w / 2 ^ k) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  rw [Nat.mod_eq_of_lt hw, Nat.mod_eq_of_lt (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw)]

theorem w_slli (n k : Nat) (h : n * 2 ^ k < 2 ^ 32) :
    BitVec.ofNat 32 n <<< k = BitVec.ofNat 32 (n * 2 ^ k) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_shiftLeft, BitVec.toNat_ofNat, Nat.shiftLeft_eq]
  have : n < 2 ^ 32 := Nat.lt_of_le_of_lt (Nat.le_mul_of_pos_right _ (Nat.pow_pos (by decide))) h
  rw [Nat.mod_eq_of_lt this, Nat.mod_eq_of_lt h]

theorem w_sll1 (k : Nat) (hk : k < 32) :
    BitVec.ofNat 32 1 <<< ((BitVec.ofNat 32 k).toNat % 32) = BitVec.ofNat 32 (2 ^ k) := by
  rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show k < 2 ^ 32 by omega), Nat.mod_eq_of_lt hk, w_slli 1 k
    (by rw [Nat.one_mul]; exact Nat.pow_lt_pow_right (by decide) hk), Nat.one_mul]

theorem w_andi7f (x : Nat) (hx : x < 2 ^ 32) :
    BitVec.ofNat 32 x &&& (0x7f : BitVec 12).signExtend 32 = BitVec.ofNat 32 (x % 128) := by
  rw [show (0x7f : BitVec 12) = BitVec.ofNat 12 0x7f from rfl, se_small _ (by decide)]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hx]
  rw [show (0x7f % 2 ^ 32 : Nat) = 2 ^ 7 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod]
  omega

theorem w_andi80 (x : Nat) (hx : x < 2 ^ 32) :
    BitVec.ofNat 32 x &&& (0x80 : BitVec 12).signExtend 32 = BitVec.ofNat 32 (128 * (x / 128 % 2)) := by
  rw [show (0x80 : BitVec 12) = BitVec.ofNat 12 0x80 from rfl, se_small _ (by decide)]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hx]
  rw [show (0x80 % 2 ^ 32 : Nat) = 128 from rfl, and_bit7]
  omega

theorem w_xori1 (x : Nat) (hx : x < 2 ^ 32) :
    BitVec.ofNat 32 x ^^^ (0xfff : BitVec 12).signExtend 32 = BitVec.ofNat 32 (x ^^^ (2 ^ 32 - 1)) := by
  rw [show (0xfff : BitVec 12).signExtend 32 = BitVec.ofNat 32 (2 ^ 32 - 1) by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_xor, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hx]
  rw [Nat.mod_eq_of_lt (show 2 ^ 32 - 1 < 2 ^ 32 by decide)]
  exact (Nat.mod_eq_of_lt (Nat.xor_lt_two_pow hx (by decide))).symm

theorem w_and (x y : Nat) (hx : x < 2 ^ 32) (hy : y < 2 ^ 32) :
    BitVec.ofNat 32 x &&& BitVec.ofNat 32 y = BitVec.ofNat 32 (x &&& y) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hx, Nat.mod_eq_of_lt hy]
  exact (Nat.mod_eq_of_lt (Nat.lt_of_le_of_lt Nat.and_le_left hx)).symm

end Exp228
