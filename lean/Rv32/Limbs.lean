/-
SPDX-License-Identifier: Apache-2.0

# Numbers of many words

A 256-bit number is eight 32-bit words in memory, least significant first.
`numAt` is the number the `n` words at an offset hold, and a store outside
them leaves it alone. The words themselves are combined by the RV32IM idioms
that carry: `add` and the `sltu` after it that catches the carry, `sub` and the
`sltu` that catches the borrow, `mul` and `mulhu` for the two halves of a
product. Each idiom's lemma states what it computes as natural numbers, so a
loop's invariant is arithmetic `omega` can check.

exp229 wrote these for its field kernel: the first kernel here to carry.
-/
import Rv32.Ct

namespace Rv32

/-! ## The carrying idioms -/

/-- What `sltu` writes: 1 or 0. -/
abbrev lt1 (a b : Word) : Word := if a.ult b then 1 else 0

theorem lt1_toNat (a b : Word) : (lt1 a b).toNat = if a.toNat < b.toNat then 1 else 0 := by
  unfold lt1; by_cases h : a.toNat < b.toNat
  · have : a.ult b = true := by simp [BitVec.ult, h]
    simp [this, h]
  · have : a.ult b = false := by simp [BitVec.ult, h]
    simp [this, h]

/-- One add and the `sltu` that catches its carry. -/
theorem carry_word (a b : Word) :
    (a + b).toNat + 2 ^ 32 * (lt1 (a + b) b).toNat = a.toNat + b.toNat ∧ (lt1 (a + b) b).toNat ≤ 1 := by
  have ha := a.isLt; have hb := b.isLt
  simp only [BitVec.toNat_add, lt1_toNat]
  constructor <;> split <;> omega

/-- A sum of words that stays below 2^32 is the sum of their numbers. -/
theorem toNat_add_small (a b : Word) (h : a.toNat + b.toNat < 2 ^ 32) :
    (a + b).toNat = a.toNat + b.toNat := by
  rw [BitVec.toNat_add, Nat.mod_eq_of_lt h]

/-- Add with carry in and out: `s = x + y; c1 = s <u y; s += c; c2 = s <u c; c' = c1 + c2`. -/
theorem add_word (x y c : Word) (hc : c.toNat ≤ 1) :
    ((x + y) + c).toNat + 2 ^ 32 * (lt1 (x + y) y + lt1 ((x + y) + c) c).toNat = x.toNat + y.toNat + c.toNat
    ∧ (lt1 (x + y) y + lt1 ((x + y) + c) c).toNat ≤ 1 := by
  have hx := x.isLt; have hy := y.isLt
  simp only [BitVec.toNat_add, lt1_toNat]
  constructor <;> split <;> split <;> simp_all <;> omega

/-- Subtract with borrow in and out: `d = x - y; b1 = x <u y; b2 = d <u b; d -= b; b' = b1 + b2`. -/
theorem sub_word (x y b : Word) (hb : b.toNat ≤ 1) :
    ((x - y) - b).toNat + y.toNat + b.toNat = x.toNat + 2 ^ 32 * (lt1 x y + lt1 (x - y) b).toNat
    ∧ (lt1 x y + lt1 (x - y) b).toNat ≤ 1 := by
  have hx := x.isLt; have hy := y.isLt
  simp only [BitVec.toNat_add, BitVec.toNat_sub, lt1_toNat]
  constructor <;> split <;> split <;> simp_all <;> omega

/-- A word chosen by a mask that is all ones or zero: `d ^ ((d ^ x) & mask)`. -/
theorem sel_word (x d : Word) (k : Bool) :
    d ^^^ ((d ^^^ x) &&& (if k then BitVec.allOnes 32 else 0)) = if k then x else d := by
  cases k
  · simp
  · simp only [ite_true, BitVec.and_allOnes, ← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]

/-- `mul` and `mulhu` together are the 64-bit product. -/
theorem mul_mulhu (a b : Word) :
    (a * b).toNat + 2 ^ 32 * (mulHigh (a.toNat * b.toNat : Int)).toNat = a.toNat * b.toNat := by
  have ha := a.isLt
  have hb := b.isLt
  simp only [mulHigh, BitVec.toNat_mul, BitVec.extractLsb'_toNat, BitVec.toNat_ofInt]
  have hp : a.toNat * b.toNat < 2 ^ 64 := by
    have := Nat.mul_lt_mul'' ha hb
    simpa using this
  have hz : (0 : Int) ≤ (a.toNat * b.toNat : Nat) := Int.natCast_nonneg _
  have : (((a.toNat * b.toNat : Nat) : Int) % ((2 ^ 64 : Nat) : Int)).toNat = a.toNat * b.toNat := by
    rw [Int.emod_eq_of_lt hz (by exact_mod_cast hp)]; simp only [Int.toNat_natCast]
  simp_all
  omega

/-- Multiply and accumulate, the product given as its two halves `lo + 2^32·hi = P`:
`s = t + lo; c1 = s <u lo; s += c; c2 = s <u c; c' = hi + c1 + c2`. -/
theorem mac_word (t c lo hi : Word) (P : Nat) (hP : lo.toNat + 2 ^ 32 * hi.toNat = P)
    (hb : P ≤ (2 ^ 32 - 1) * (2 ^ 32 - 1)) :
    ((t + lo) + c).toNat + 2 ^ 32 * ((hi + lt1 (t + lo) lo) + lt1 ((t + lo) + c) c).toNat
      = t.toNat + P + c.toNat := by
  have ht := t.isLt; have hc := c.isLt; have hlo := lo.isLt; have hhi := hi.isLt
  simp only [BitVec.toNat_add, lt1_toNat]
  split <;> split <;> simp_all <;> omega

/-- A fold's word, `977·h` given as its two halves: `s = l + lo; c1 = s <u lo; s += p;
c2 = s <u p; s += c; c3 = s <u c; c' = hi + c1 + c2 + c3`. -/
theorem fold_word (l h p c lo hi : Word) (hP : lo.toNat + 2 ^ 32 * hi.toNat = 977 * h.toNat)
    (hc : c.toNat ≤ 980) :
    (((l + lo) + p) + c).toNat + 2 ^ 32 * (((hi + lt1 (l + lo) lo) + lt1 ((l + lo) + p) p)
        + lt1 (((l + lo) + p) + c) c).toNat
      = l.toNat + 977 * h.toNat + p.toNat + c.toNat
    ∧ (((hi + lt1 (l + lo) lo) + lt1 ((l + lo) + p) p) + lt1 (((l + lo) + p) + c) c).toNat ≤ 980 := by
  have hh := h.isLt
  obtain ⟨e1, b1⟩ := carry_word l lo
  obtain ⟨e2, b2⟩ := carry_word (l + lo) p
  obtain ⟨e3, b3⟩ := carry_word ((l + lo) + p) c
  have hhi : hi.toNat ≤ 976 := by omega
  generalize lt1 (l + lo) lo = c1 at *
  generalize lt1 ((l + lo) + p) p = c2 at *
  generalize lt1 (((l + lo) + p) + c) c = c3 at *
  have f1 : (hi + c1).toNat = hi.toNat + c1.toNat := toNat_add_small _ _ (by omega)
  have f2 : ((hi + c1) + c2).toNat = hi.toNat + c1.toNat + c2.toNat := by
    rw [toNat_add_small _ _ (by omega), f1]
  have f3 : (((hi + c1) + c2) + c3).toNat = hi.toNat + c1.toNat + c2.toNat + c3.toNat := by
    rw [toNat_add_small _ _ (by omega), f2]
  rw [f3]
  constructor <;> omega

/-- A fold's last two words: `y8 = p + c; y9 = y8 <u p`. -/
theorem tail_word (p c : Word) :
    (p + c).toNat + 2 ^ 32 * (lt1 (p + c) p).toNat = p.toNat + c.toNat := by
  have hp := p.isLt; have hc := c.isLt
  simp only [BitVec.toNat_add, lt1_toNat]
  split <;> omega

/-! ## Numbers in memory -/

variable {base : Word}

/-- The word at offset `o` past `base`. -/
def wordAt (m : Word → Byte) (base : Word) (o : Nat) : Nat := readLE m (base + BitVec.ofNat 32 o) 4

/-- The number the `n` words from offset `o` hold, least significant first. -/
def numAt (m : Word → Byte) (base : Word) (o : Nat) : Nat → Nat
  | 0 => 0
  | n + 1 => numAt m base o n + wordAt m base (o + 4 * n) * 2 ^ (32 * n)

theorem wordAt_lt (m : Word → Byte) (base : Word) (o : Nat) : wordAt m base o < 2 ^ 32 :=
  readLE_four_lt _ _

theorem numAt_lt (m : Word → Byte) (base : Word) (o : Nat) : ∀ n, numAt m base o n < 2 ^ (32 * n)
  | 0 => by simp [numAt]
  | n + 1 => by
    have ih := numAt_lt m base o n
    have hw := wordAt_lt m base (o + 4 * n)
    have e : 2 ^ (32 * (n + 1)) = 2 ^ 32 * 2 ^ (32 * n) := by
      rw [show 32 * (n + 1) = 32 + 32 * n by omega, Nat.pow_add]
    simp only [numAt, e]
    have := Nat.mul_le_mul_right (2 ^ (32 * n)) (show wordAt m base (o + 4 * n) ≤ 2 ^ 32 - 1 by omega)
    rw [Nat.sub_mul, Nat.one_mul] at this
    omega

/-- A number of \`n + k\` words is its first \`n\` and, above them, the next \`k\`. -/
theorem numAt_split (m : Word → Byte) (base : Word) (o n : Nat) :
    ∀ k, numAt m base o (n + k) = numAt m base o n + 2 ^ (32 * n) * numAt m base (o + 4 * n) k
  | 0 => by simp [numAt]
  | k + 1 => by
    rw [show n + (k + 1) = (n + k) + 1 by omega]
    simp only [numAt]
    rw [numAt_split m base o n k, show o + 4 * (n + k) = o + 4 * n + 4 * k by omega,
      show 32 * (n + k) = 32 * n + 32 * k by omega, Nat.pow_add, Nat.mul_add, Nat.mul_left_comm]
    omega

/-- Two memories that agree on the words read the same number. -/
theorem numAt_congr {m m' : Word → Byte} {o : Nat} :
    ∀ n, (∀ i < n, wordAt m base (o + 4 * i) = wordAt m' base (o + 4 * i)) → numAt m base o n = numAt m' base o n
  | 0, _ => rfl
  | n + 1, h => by
    simp only [numAt]
    rw [numAt_congr n (fun i hi => h i (by omega)), h n (by omega)]

/-- The word a store of four bytes at `w` left there. -/
theorem wordAt_write_same (m : Word → Byte) (w : Nat) {v : Nat} (hv : v < 2 ^ 32) :
    wordAt (writeLE m (base + BitVec.ofNat 32 w) v 4) base w = v := by
  unfold wordAt
  generalize base + BitVec.ofNat 32 w = a
  have hb : ∀ d < 4, (writeLE m a v 4 (a + BitVec.ofNat 32 d)).toNat = v / 256 ^ d % 256 := by
    intro d hd
    rw [writeLE_apply _ _ _ _ (by decide)]
    have e : (a + BitVec.ofNat 32 d - a).toNat = d := by
      have := a.isLt
      rw [BitVec.toNat_sub, BitVec.toNat_add, BitVec.toNat_ofNat]
      have : d % 2 ^ 32 = d := Nat.mod_eq_of_lt (by omega)
      rw [this]; omega
    simp only [e, hd, ↓reduceIte, BitVec.toNat_ofNat]
  rw [readLE_four]
  have h0 := hb 0 (by decide); have h1 := hb 1 (by decide)
  have h2 := hb 2 (by decide); have h3 := hb 3 (by decide)
  simp only [show a + BitVec.ofNat 32 0 = a by simp] at h0
  rw [h0, show a + 1 = a + BitVec.ofNat 32 1 from rfl, h1, show a + 2 = a + BitVec.ofNat 32 2 from rfl, h2,
    show a + 3 = a + BitVec.ofNat 32 3 from rfl, h3]
  simp only [Nat.pow_zero, Nat.div_one, show (256 : Nat) ^ 1 = 256 by decide,
    show (256 : Nat) ^ 2 = 65536 by decide, show (256 : Nat) ^ 3 = 16777216 by decide]
  omega

/-- A store of four bytes at `w` leaves the word at `o` alone when they do not meet. -/
theorem wordAt_write_out (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {w o : Nat} (v : Nat)
    (hw : w + 4 ≤ 0x10000) (ho : o + 4 ≤ 0x10000) (hout : o + 4 ≤ w ∨ w + 4 ≤ o) :
    wordAt (writeLE m (base + BitVec.ofNat 32 w) v 4) base o = wordAt m base o := by
  unfold wordAt
  apply Ct.readLE_congr 4
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact Ct.writeLE_out hfit m v (by decide) (by omega) hw (by omega) (by omega)

/-- And so the number at `o` when the store is outside all `n` of its words. -/
theorem numAt_write_out (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {w o n : Nat} (v : Nat)
    (hw : w + 4 ≤ 0x10000) (ho : o + 4 * n ≤ 0x10000) (hout : o + 4 * n ≤ w ∨ w + 4 ≤ o) :
    numAt (writeLE m (base + BitVec.ofNat 32 w) v 4) base o n = numAt m base o n :=
  numAt_congr n fun i hi => wordAt_write_out hfit m v hw (by omega) (by omega)

/-- A store of the next word on extends the number by it. -/
theorem numAt_write_next (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {o n : Nat} (v : Nat)
    (hv : v < 2 ^ 32) (ho : o + 4 * n + 4 ≤ 0x10000) :
    numAt (writeLE m (base + BitVec.ofNat 32 (o + 4 * n)) v 4) base o (n + 1) = numAt m base o n + v * 2 ^ (32 * n) := by
  simp only [numAt]
  rw [numAt_write_out hfit m v (by omega) (by omega) (Or.inl (by omega)), wordAt_write_same m _ hv]

/-- A store over word `k` of `n` changes the number by what changed in that word. -/
theorem numAt_write_mid (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {o : Nat} (v : Nat)
    (hv : v < 2 ^ 32) : ∀ {n k : Nat}, k < n → o + 4 * n ≤ 0x10000 →
    numAt (writeLE m (base + BitVec.ofNat 32 (o + 4 * k)) v 4) base o n + wordAt m base (o + 4 * k) * 2 ^ (32 * k)
      = numAt m base o n + v * 2 ^ (32 * k)
  | 0, _, h, _ => absurd h (Nat.not_lt_zero _)
  | n + 1, k, hk, ho => by
    simp only [numAt]
    by_cases e : k = n
    · subst e
      rw [numAt_write_out hfit m v (by omega) (by omega) (Or.inl (by omega)), wordAt_write_same m _ hv]
      omega
    · have ih := numAt_write_mid hfit m v hv (show k < n by omega) (show o + 4 * n ≤ 0x10000 by omega)
      rw [wordAt_write_out hfit m v (by omega) (by omega) (by omega)]
      omega

/-! ## Memory changed in one window only -/

/-- `m'` is `m` at every offset of the region outside `[lo, hi)`. -/
def Kept (m m' : Word → Byte) (base : Word) (lo hi : Nat) : Prop :=
  ∀ o < 0x10000, (o < lo ∨ hi ≤ o) → m' (base + BitVec.ofNat 32 o) = m (base + BitVec.ofNat 32 o)

theorem Kept.refl (m : Word → Byte) (base : Word) (lo hi : Nat) : Kept m m base lo hi := fun _ _ _ => rfl

theorem Kept.trans {m1 m2 m3 : Word → Byte} {lo hi : Nat} (h1 : Kept m1 m2 base lo hi)
    (h2 : Kept m2 m3 base lo hi) : Kept m1 m3 base lo hi :=
  fun o ho w => (h2 o ho w).trans (h1 o ho w)

theorem Kept.widen {m m' : Word → Byte} {lo hi lo' hi' : Nat} (h : Kept m m' base lo hi)
    (hl : lo' ≤ lo) (hh : hi ≤ hi') : Kept m m' base lo' hi' :=
  fun o ho w => h o ho (by omega)

/-- A store of four bytes inside the window keeps it kept. -/
theorem Kept.write (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte} {lo hi : Nat}
    (h : Kept m0 m base lo hi) {w : Nat} (v : Nat) (hlo : lo ≤ w) (hhi : w + 4 ≤ hi) (hw : w + 4 ≤ 0x10000) :
    Kept m0 (writeLE m (base + BitVec.ofNat 32 w) v 4) base lo hi := by
  intro o ho out
  rw [Ct.writeLE_out hfit m v (by decide) (by omega) hw ho (by omega)]
  exact h o ho out

/-- Outside the window, a word reads as it did. -/
theorem Kept.word (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} {lo hi : Nat}
    (h : Kept m m' base lo hi) {o : Nat} (ho : o + 4 ≤ 0x10000) (out : o + 4 ≤ lo ∨ hi ≤ o) :
    wordAt m' base o = wordAt m base o := by
  unfold wordAt
  apply Ct.readLE_congr 4
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h _ (by omega) (by omega)

/-- And so does a number. -/
theorem Kept.num (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} {lo hi : Nat}
    (h : Kept m m' base lo hi) {o n : Nat} (ho : o + 4 * n ≤ 0x10000) (out : o + 4 * n ≤ lo ∨ hi ≤ o) :
    numAt m' base o n = numAt m base o n :=
  numAt_congr n fun _ _ => h.word hfit (by omega) (by omega)

/-- The program, below the window, stays loaded. -/
theorem Kept.code (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr} {m m' : Word → Byte} {lo hi : Nat}
    (h : Kept m m' base lo hi) (hlo : 4 * prog.length ≤ lo) (hlen : 4 * prog.length < 0x10000)
    (hc : CodeAt m base prog) : CodeAt m' base prog :=
  Ct.code_keep hfit hlen (fun o' ho' => h o' (by omega) (Or.inl (by omega))) hc

/-- A store above the program keeps the program. -/
theorem code_write (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr} {m : Word → Byte}
    (hc : CodeAt m base prog) {c : Nat} (hlo : 4 * prog.length ≤ c) (hc' : c + 4 ≤ 0x10000)
    (hlen : 4 * prog.length < 0x10000) (v : Nat) : CodeAt (writeLE m (base + BitVec.ofNat 32 c) v 4) base prog :=
  Kept.code hfit (Kept.write hfit (Kept.refl _ _ c (c + 4)) _ (Nat.le_refl _) (Nat.le_refl _) hc') hlo hlen hc

/-! ## A loop's carry, as numbers -/

/-- One word more of a sum: the number so far and its carry, then the word and
the new carry — at weight `P`, the next word's. -/
theorem carry_step {A B C P t c' X Y : Nat} (h1 : A + C * P = B) (h2 : t + 2 ^ 32 * c' = X + Y + C) :
    A + t * P + c' * (2 ^ 32 * P) = B + X * P + Y * P := by
  have e : t * P + 2 ^ 32 * (c' * P) = X * P + Y * P + C * P := by
    rw [← Nat.mul_assoc, ← Nat.add_mul, h2, Nat.add_mul, Nat.add_mul]
  rw [Nat.mul_left_comm c' (2 ^ 32) P]
  omega

/-- One word more of a difference: what is written and what is taken away so
far, then the word and the new borrow. -/
theorem borrow_step {A B C P z c' X Y Yn : Nat} (h1 : A + Yn = B + C * P) (h2 : z + Y + C = X + 2 ^ 32 * c') :
    (A + z * P) + (Yn + Y * P) = (B + X * P) + c' * (2 ^ 32 * P) := by
  have e : z * P + Y * P + C * P = X * P + 2 ^ 32 * (c' * P) := by
    rw [← Nat.add_mul, ← Nat.add_mul, h2, Nat.add_mul, Nat.mul_assoc]
  rw [Nat.mul_left_comm c' (2 ^ 32) P]
  omega

/-- One word more of a fold \`L + 977·H + 2^32·H\`: what is written so far, with
the carry and the last word of H still to place, and then the word and the
new carry, with this word of H now the last. -/
theorem fold_step {Y L H c p P w c' l h : Nat}
    (h1 : Y + (c + p) * P = L + 977 * H + 2 ^ 32 * H) (h2 : w + 2 ^ 32 * c' = l + 977 * h + p + c) :
    (Y + w * P) + (c' + h) * (2 ^ 32 * P) = (L + l * P) + 977 * (H + h * P) + 2 ^ 32 * (H + h * P) := by
  have e : w * P + 2 ^ 32 * (c' * P) = l * P + 977 * (h * P) + p * P + c * P := by
    rw [← Nat.mul_assoc, ← Nat.add_mul, h2, Nat.add_mul, Nat.add_mul, Nat.add_mul, Nat.mul_assoc]
  have e1 : (c + p) * P = c * P + p * P := Nat.add_mul _ _ _
  rw [Nat.add_mul, Nat.mul_left_comm c' (2 ^ 32) P, Nat.mul_left_comm h (2 ^ 32) P, Nat.mul_add, Nat.mul_add]
  omega

end Rv32
