/-
SPDX-License-Identifier: Apache-2.0

# Words copied, one at a time

A copy loop's memory: after `i` words of `n` have gone from `base + src` to
`base + dst`, the first `4i` bytes at `dst` are the source's, and everything
else is as it was. exp203 wrote this for its sixty-byte kernel, at 0x1000 and
0x2000 and sixteen words; exp222's health-test kernel needed it second, for
1024, so here the places and the count are parameters.
-/
import Rv32.Kernel

namespace Rv32

/-- Memory after `i` words have been copied from `src` to `dst`: the first
`4i` bytes at `dst` from the source, everything else as in `m0`. -/
def copied (m0 : Word → Byte) (base : Word) (src dst i : Nat) : Word → Byte := fun x =>
  if (x - (base + BitVec.ofNat 32 dst)).toNat < 4 * i then m0 (x - BitVec.ofNat 32 (dst - src))
  else m0 x

theorem copied_zero (m0 : Word → Byte) (base : Word) (src dst : Nat) : copied m0 base src dst 0 = m0 := by
  funext x; simp [copied]

/-- **One word copied**: iteration `i`'s load from `src + 4i` and store to
`dst + 4i`, on memory that has had `i` words copied, gives memory that has
had `i + 1`. The source ends before the destination starts. -/
theorem copied_step {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte}
    {src dst n i : Nat} (hsd : src + 4 * n ≤ dst) (hd : dst + 4 * n ≤ 0x10000) (hi : i < n)
    (hm : ∀ x, m x = copied m0 base src dst i x) (x : Word) :
    writeLE m (base + BitVec.ofNat 32 (dst + 4 * i))
        (readLE m (base + BitVec.ofNat 32 (src + 4 * i)) 4) 4 x = copied m0 base src dst (i + 1) x := by
  have hx := x.isLt
  have hb := base.isLt
  rw [writeLE_apply _ _ _ _ (by decide) x]
  have hd' := toNat_sub_off hfit x (dst + 4 * i) (by omega)
  have he := toNat_sub_off hfit x dst (by omega)
  generalize (x - (base + BitVec.ofNat 32 (dst + 4 * i))).toNat = d at hd' ⊢
  generalize hE : (x - (base + BitVec.ofNat 32 dst)).toNat = e at he
  by_cases hlt : d < 4
  · simp only [hlt, ↓reduceIte]
    rw [readLE_four_byte _ _ _ hlt, hm]
    unfold copied
    have hxv : x.toNat = base.toNat + dst + 4 * i + d := by omega
    have heq : base + BitVec.ofNat 32 (src + 4 * i) + BitVec.ofNat 32 d
        = x - BitVec.ofNat 32 (dst - src) := by
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_add, toNat_off hfit _ (by omega), BitVec.toNat_sub, BitVec.toNat_ofNat,
        BitVec.toNat_ofNat]
      omega
    rw [heq, hE]
    have c1 : ¬ (x - BitVec.ofNat 32 (dst - src) - (base + BitVec.ofNat 32 dst)).toNat < 4 * i := by
      rw [BitVec.toNat_sub, BitVec.toNat_sub, toNat_off hfit _ (by omega), BitVec.toNat_ofNat]
      omega
    have c2 : e < 4 * (i + 1) := by omega
    simp only [c1, c2, ↓reduceIte]
  · simp only [hlt, ↓reduceIte]
    rw [hm]; unfold copied
    rw [hE]
    by_cases c : e < 4 * i
    · have c' : e < 4 * (i + 1) := by omega
      simp only [c, c', ↓reduceIte]
    · have c' : ¬ e < 4 * (i + 1) := by omega
      simp only [c, c', ↓reduceIte]

/-- Memory with `i` words copied is the original below `dst`: the source and
everything before it, the program among it, are untouched. -/
theorem copied_below {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte}
    {src dst i : Nat} (hd : dst < 0x10000) (hi : 4 * i ≤ 0x10000) {c : Nat} (hc : c < dst) :
    copied m0 base src dst i (base + BitVec.ofNat 32 c) = m0 (base + BitVec.ofNat 32 c) := by
  unfold copied
  have : ¬ (base + BitVec.ofNat 32 c - (base + BitVec.ofNat 32 dst)).toNat < 4 * i := by
    rw [BitVec.toNat_sub, toNat_off hfit _ (by omega), toNat_off hfit _ (by omega)]
    have := base.isLt
    rw [show 2 ^ 32 - (base.toNat + dst) + (base.toNat + c) = 2 ^ 32 - (dst - c) by omega,
      Nat.mod_eq_of_lt (by omega)]
    omega
  simp only [this, ↓reduceIte]

/-- And the words at `dst` are the source's, once copied. -/
theorem copied_word {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte}
    {src dst n : Nat} (hsd : src + 4 * n ≤ dst) (hd : dst + 4 * n ≤ 0x10000) {j : Nat} (hj : j < n) :
    readLE (copied m0 base src dst n) (base + BitVec.ofNat 32 (dst + 4 * j)) 4
      = readLE m0 (base + BitVec.ofNat 32 (src + 4 * j)) 4 := by
  apply readLE_four_eq
  intro d hd4
  revert d hd4
  show ∀ d < 4, _
  have byte : ∀ d < 4, copied m0 base src dst n (base + BitVec.ofNat 32 (dst + 4 * j) + BitVec.ofNat 32 d)
      = m0 (base + BitVec.ofNat 32 (src + 4 * j) + BitVec.ofNat 32 d) := by
    intro d hd4
    unfold copied
    rw [off_add hfit _ _ (by omega), off_add hfit _ _ (by omega)]
    have h1 : (base + BitVec.ofNat 32 (dst + 4 * j + d) - (base + BitVec.ofNat 32 dst)).toNat < 4 * n := by
      rw [BitVec.toNat_sub, toNat_off hfit _ (by omega), toNat_off hfit _ (by omega)]; omega
    have h2 : base + BitVec.ofNat 32 (dst + 4 * j + d) - BitVec.ofNat 32 (dst - src)
        = base + BitVec.ofNat 32 (src + 4 * j + d) := by
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_sub, toNat_off hfit _ (by omega), toNat_off hfit _ (by omega), BitVec.toNat_ofNat]
      omega
    simp only [h1, ↓reduceIte, h2]
  exact byte

end Rv32
