/-
SPDX-License-Identifier: Apache-2.0

# Memory that changed in two places

exp213's key generator and signer each write in a few places and read in
others. `Within` is the frame both their theorems state: outside two places,
memory is what it was. `Keeps.widen` and `Keeps.bytes` move a step's own
`Keeps` into it and past it. And what both kernels' first steps need: zeros
read back from an overlay of them, the PRF input `seed ‖ l ‖ i ‖ 0³⁰` read
back after `i` is stored into it, a small count stepped by `addi`.
-/
import Rv32.Blocks

namespace Rv32
variable {base : Word}

/-- A kept-to place inside a bigger one: what is kept outside the small one
is kept outside the big one. -/
theorem Keeps.widen (hfit : base.toNat + 0x10000 ≤ 2^32) {S N A NA : Nat} {m m' : Word → Byte}
    (h : Keeps (base + BitVec.ofNat 32 S) N m m') (hA : A ≤ S) (hN : S + N ≤ A + NA) (hAN : A + NA < 0x10000) :
    Keeps (base + BitVec.ofNat 32 A) NA m m' := by
  intro x hx
  apply h
  rw [toNat_sub_off hfit _ A (by omega)] at hx
  rw [toNat_sub_off hfit _ S (by omega)]
  have := x.isLt; have := base.isLt
  rw [wrapdist _ _ (by omega) (by omega)] at hx ⊢
  split at hx <;> split <;> omega

/-- Reading outside a kept-to place: the old bytes. -/
theorem Keeps.bytes (hfit : base.toNat + 0x10000 ≤ 2^32) {S N c n : Nat} {m m' : Word → Byte}
    (h : Keeps (base + BitVec.ofNat 32 S) N m m') (hSN : S + N < 0x10000) (hc : c + n ≤ 0x10000)
    (hout : c + n ≤ S ∨ S + N ≤ c) :
    readBytes m' (base + BitVec.ofNat 32 c) n = readBytes m (base + BitVec.ofNat 32 c) n := by
  apply readBytes_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit hSN (by omega) (by omega)

/-- `m'` is `m` outside two places: `NA` bytes from `A` and `NB` from `B`. -/
def Within (base : Word) (A NA B NB : Nat) (m m' : Word → Byte) : Prop :=
  ∀ x, ¬ (x - (base + BitVec.ofNat 32 A)).toNat < NA → ¬ (x - (base + BitVec.ofNat 32 B)).toNat < NB → m' x = m x

theorem Within.refl (base : Word) (A NA B NB : Nat) (m : Word → Byte) : Within base A NA B NB m m :=
  fun _ _ _ => rfl

theorem Within.left (hfit : base.toNat + 0x10000 ≤ 2^32) {A NA B NB S N : Nat} {m m' m'' : Word → Byte}
    (h : Within base A NA B NB m m') (hk : Keeps (base + BitVec.ofNat 32 S) N m' m'')
    (hA : A ≤ S) (hN : S + N ≤ A + NA) (hAN : A + NA < 0x10000) : Within base A NA B NB m m'' :=
  fun x h1 h2 => ((hk.widen hfit hA hN hAN) x h1).trans (h x h1 h2)

theorem Within.right (hfit : base.toNat + 0x10000 ≤ 2^32) {A NA B NB S N : Nat} {m m' m'' : Word → Byte}
    (h : Within base A NA B NB m m') (hk : Keeps (base + BitVec.ofNat 32 S) N m' m'')
    (hB : B ≤ S) (hN : S + N ≤ B + NB) (hBN : B + NB < 0x10000) : Within base A NA B NB m m'' :=
  fun x h1 h2 => ((hk.widen hfit hB hN hBN) x h2).trans (h x h1 h2)

theorem Within.trans {A NA B NB : Nat} {m1 m2 m3 : Word → Byte}
    (h1 : Within base A NA B NB m1 m2) (h2 : Within base A NA B NB m2 m3) : Within base A NA B NB m1 m3 :=
  fun x a b => (h2 x a b).trans (h1 x a b)

theorem Within.off (hfit : base.toNat + 0x10000 ≤ 2^32) {A NA B NB : Nat} {m m' : Word → Byte}
    (h : Within base A NA B NB m m') (hAN : A + NA < 0x10000) (hBN : B + NB < 0x10000) {c : Nat}
    (hc : c < 0x10000) (hA : c < A ∨ A + NA ≤ c) (hB : c < B ∨ B + NB ≤ c) :
    m' (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) := by
  have k : ∀ S N, S + N < 0x10000 → (c < S ∨ S + N ≤ c) →
      ¬ (base + BitVec.ofNat 32 c - (base + BitVec.ofNat 32 S)).toNat < N := by
    intro S N hSN hout
    rw [toNat_sub_off hfit _ S (by omega), toNat_off hfit c hc]
    have := base.isLt
    rw [wrapdist _ _ (by omega) (by omega)]
    split <;> omega
  exact h _ (k A NA hAN hA) (k B NB hBN hB)

theorem Within.bytes (hfit : base.toNat + 0x10000 ≤ 2^32) {A NA B NB : Nat} {m m' : Word → Byte}
    (h : Within base A NA B NB m m') (hAN : A + NA < 0x10000) (hBN : B + NB < 0x10000) {c n : Nat}
    (hc : c + n ≤ 0x10000) (hA : c + n ≤ A ∨ A + NA ≤ c) (hB : c + n ≤ B ∨ B + NB ≤ c) :
    readBytes m' (base + BitVec.ofNat 32 c) n = readBytes m (base + BitVec.ofNat 32 c) n := by
  apply readBytes_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit hAN hBN (by omega) (by omega) (by omega)

theorem Within.code {prog : List Instr} (hfit : base.toNat + 0x10000 ≤ 2^32) {A NA B NB : Nat} {m m' : Word → Byte}
    (h : Within base A NA B NB m m') (hAN : A + NA < 0x10000) (hBN : B + NB < 0x10000)
    (hA : 4 * prog.length ≤ A) (hB : 4 * prog.length ≤ B) (hc : CodeAt m base prog) : CodeAt m' base prog := by
  refine CodeAt.congr (by omega) (fun x h1 h2 => ?_) hc
  have hx : x = base + BitVec.ofNat 32 (x.toNat - base.toNat) := by
    apply BitVec.eq_of_toNat_eq; rw [toNat_off hfit _ (by omega)]; omega
  rw [hx]; exact (h.off hfit hAN hBN (by omega) (by omega) (by omega)).symm

/-- One byte, read back from where it was stored. -/
theorem readBytes_writeByte (m : Word → Byte) (a : Word) (v : Byte) : readBytes (writeByte m a v) a 1 = [v] := by
  simp [readBytes, writeByte]

theorem readBytes_one (m : Word → Byte) (a : Word) : readBytes m a 1 = [m a] := rfl

/-- An `if` whose condition holds, without the deprecated `if_pos`. -/
theorem ifT {α : Type} {c : Prop} [Decidable c] {a b : α} (h : c) : (if c then a else b) = a :=
  ite_eq_left_of_eq_true _ _ (eq_true h)
theorem ifF {α : Type} {c : Prop} [Decidable c] {a b : α} (h : ¬ c) : (if c then a else b) = b :=
  ite_eq_right_of_eq_false _ _ (eq_false h)

/-- Zeros, read back from where an overlay of zeros put them. -/
theorem readBytes_zeros {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c n c' k : Nat}
    (h1 : c ≤ c') (h2 : c' + k ≤ c + n) (hn : c + n < 0x10000) :
    readBytes (overlay m (base + BitVec.ofNat 32 c) n (fun _ => 0)) (base + BitVec.ofNat 32 c') k
      = List.replicate k 0 := by
  apply readBytes_const
  intro d hd
  rw [off_add hfit _ _ (by omega), overlay_off_in hfit _ _ (by omega) (by omega) (by omega)]

/-- The PRF input after `i` is stored at byte 33: the seed, `l`, `i`, zeros —
what `secret` hashes. -/
theorem prf_bytes {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {P : Nat}
    (hP : P + 64 ≤ 0x10000) {seed : List Byte} {l i : Nat}
    (hs : readBytes m (base + BitVec.ofNat 32 P) 32 = seed)
    (hl : m (base + BitVec.ofNat 32 (P + 32)) = BitVec.ofNat 8 l)
    (hz : readBytes m (base + BitVec.ofNat 32 (P + 34)) 30 = List.replicate 30 0) :
    readBytes (writeByte m (base + BitVec.ofNat 32 (P + 33)) (BitVec.ofNat 8 i)) (base + BitVec.ofNat 32 P) 64
      = seed ++ [BitVec.ofNat 8 l, BitVec.ofNat 8 i] ++ List.replicate 30 0 := by
  have K : Keeps (base + BitVec.ofNat 32 (P + 33)) 1 m (writeByte m (base + BitVec.ofNat 32 (P + 33)) (BitVec.ofNat 8 i)) :=
    keeps_writeByte hfit _ _ (Nat.le_refl _) (by omega) (by omega)
  rw [show (64 : Nat) = 32 + (1 + (1 + 30)) by rfl, readBytes_append, readBytes_append, readBytes_append,
    off_add hfit _ _ (by omega), off_add hfit _ _ (by omega), off_add hfit _ _ (by omega),
    K.bytes hfit (by omega) (by omega) (by left; omega), hs,
    K.bytes hfit (by omega) (by omega) (by left; omega), readBytes_one, hl,
    show P + 32 + 1 = P + 33 by omega, readBytes_writeByte,
    show P + 33 + 1 = P + 34 by omega, K.bytes hfit (by omega) (by omega) (by right; omega), hz]
  simp

/-- `addi r, r, c` on a small count. -/
theorem add_small (i c : Nat) (hc : c < 2048) :
    BitVec.ofNat 32 i + BitVec.signExtend 32 (BitVec.ofNat 12 c) = BitVec.ofNat 32 (i + c) := by
  rw [se_small c hc, BitVec.ofNat_add]

end Rv32
