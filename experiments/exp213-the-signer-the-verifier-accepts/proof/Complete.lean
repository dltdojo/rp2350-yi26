/-
SPDX-License-Identifier: Apache-2.0

# exp213 — the signer the verifier accepts

Three binaries, one theorem. The key generator (`lean/Rv32/MssKeygen.lean`)
writes a tree; the signer (`lean/Rv32/MssSign.lean`), given that tree, writes
a signature; exp206's verifier (`lean/Rv32/Mss.lean`), given that signature,
halts with 0. Each is proved on its own in the library, for every input and
every HASH. What is here is the join: what each one's theorem says it leaves
is what the next one's needs, once the shell has copied the bytes across —
and the copying is all that is assumed. This file also writes `keygen.bin`
and `sign.bin`.
-/
import Rv32.MssKeygen
import Rv32.MssSign

open Rv32 Rv32.Wots Rv32.Mss

namespace Exp213

/-! ## The tree, as laid out, is the reference's tree -/

/-- Node `k` of level `j` is where the key generator put it: `lvl j + k`. -/
theorem flat_node (H : List Byte → Fin 32 → Byte) (seed : List Byte) {j k : Nat} (hj : j ≤ 4)
    (hk : k < 2 ^ (4 - j)) : Keygen.flat H seed (Sign.lvl j + k) = node H seed j k := by
  unfold Keygen.flat
  rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3 ∨ j = 4) with rfl | rfl | rfl | rfl | rfl
  · rw [show Sign.lvl 0 = 0 by decide, Nat.zero_add]
    rw [show (2 : Nat) ^ (4 - 0) = 16 by rfl] at hk
    rw [ifT (by omega)]
  · rw [show Sign.lvl 1 = 16 by decide]
    rw [show (2 : Nat) ^ (4 - 1) = 8 by rfl] at hk
    rw [ifF (by omega), ifT (by omega), show 16 + k - 16 = k by omega]
  · rw [show Sign.lvl 2 = 24 by decide]
    rw [show (2 : Nat) ^ (4 - 2) = 4 by rfl] at hk
    rw [ifF (by omega), ifF (by omega), ifT (by omega), show 24 + k - 24 = k by omega]
  · rw [show Sign.lvl 3 = 28 by decide]
    rw [show (2 : Nat) ^ (4 - 3) = 2 by rfl] at hk
    rw [ifF (by omega), ifF (by omega), ifF (by omega), ifT (by omega),
      show 28 + k - 28 = k by omega]
  · rw [show Sign.lvl 4 = 30 by decide]
    rw [show (2 : Nat) ^ (4 - 4) = 1 by rfl] at hk
    rw [ifF (by omega), ifF (by omega), ifF (by omega), ifF (by omega),
      show 30 + k - 30 = k by omega]

/-- For a leaf below 16, the sibling at level `j < 4` is a node of that level. -/
theorem sib_lt {l j : Nat} (hl : l < 16) (hj : j < 4) : sib (l / 2 ^ j) < 2 ^ (4 - j) := by
  unfold sib
  rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3) with rfl | rfl | rfl | rfl <;>
    simp only [Nat.reducePow, Nat.reduceSub, Nat.div_one] <;> split <;> omega

/-! ## The digits are the message's, wherever the message is -/

theorem digit_congr {m m' : Word → Byte} {base : Word}
    (h : ∀ d < 32, m (base + BitVec.ofNat 32 (MSG + d)) = m' (base + BitVec.ofNat 32 (MSG + d))) (i : Nat) :
    digit m base i = digit m' base i := by
  have hm : ∀ i < 64, msgDigit m base i = msgDigit m' base i := fun i hi => by
    unfold msgDigit; rw [h (i / 2) (by omega)]
  have hc : csumTo m base 64 = csumTo m' base 64 := by
    unfold csumTo; congr 1
    apply List.map_congr_left
    intro i hi; rw [hm i (List.mem_range.mp hi)]
  unfold digit; split
  · exact hm i ‹_›
  · rw [hc]

/-- Every chain is walked 15 steps between them: the signer's `Σ dᵢ` and the
verifier's `Σ (15 - dᵢ)` add up to `67 · 15`. -/
theorem hashes_add_up (m : Word → Byte) (base : Word) : Sign.dsum m base + steps m base = 1005 := by
  have : ∀ n, ((List.range n).map fun i => digit m base i).sum
      + ((List.range n).map fun i => 15 - digit m base i).sum = 15 * n := by
    intro n
    induction n with
    | zero => rfl
    | succ n ih =>
      simp only [List.range_succ, List.map_append, List.sum_append, List.map_cons, List.map_nil,
        List.sum_cons, List.sum_nil]
      have := digit_lt m base n
      omega
  exact this 67

/-! ## The join -/

/-- **Key generation, signing and verification, on machine states.** Run the
key generator from any state holding it. Run the signer from any state holding
it, the same seed, the tree the key generator left at `0x3000` copied to
`0x5000`, and an index below 16. Run the verifier from any state holding it
and the signer's region from `0x1000` to `0x4100` — the message, the index,
the signature, the path, the root. The verifier halts with 0: it accepts. And
each step takes exactly the count its own theorem gives. -/
theorem keygen_sign_verify {env : Env} {base : Word} (hp : Placed env base)
    (k : Machine) (hkpc : k.pc = base) (hkc : CodeAt k.mem base Keygen.kernel) :
    ∃ kf, run env 76456 k = .halted 0 kf ∧
    ∀ s : Machine, s.pc = base → CodeAt s.mem base Sign.kernel →
      Sign.seedOf s.mem base = Keygen.seedOf k.mem base →
      (∀ d < 992, s.mem (base + BitVec.ofNat 32 (Sign.TREE + d))
        = kf.mem (base + BitVec.ofNat 32 (Keygen.TREE + d))) →
      idx s.mem base < 16 →
    ∃ sf, run env (2284 + 3 * Sign.dsum s.mem base) s = .halted 0 sf ∧
    ∀ v : Machine, v.pc = base → CodeAt v.mem base kernel →
      (∀ c, 0x1000 ≤ c → c < 0x4100 → v.mem (base + BitVec.ofNat 32 c) = sf.mem (base + BitVec.ofNat 32 c)) →
    ∃ vf, run env (3295 + 3 * steps v.mem base) v = .halted 0 vf := by
  have fit := hp.fit
  obtain ⟨-, kf, ek, -, hnodes⟩ := Keygen.generates hp k hkpc hkc
  refine ⟨kf, ek, ?_⟩
  intro s hspc hsc hseed htree hl
  obtain ⟨-, sf, es, hout, hsig, hauth, hroot⟩ := Sign.signs hp s hspc hsc
  refine ⟨sf, es, ?_⟩
  intro v hvpc hvc hcopy
  obtain ⟨vf, ev, -⟩ := verifies hp v hvpc hvc
  -- the tree the signer read is the key generator's
  have tree : ∀ n < 31, readBytes s.mem (base + BitVec.ofNat 32 (Sign.TREE + 32 * n)) 32
      = Keygen.flat env.hash (Keygen.seedOf k.mem base) n := by
    intro n hn
    rw [← hnodes n hn]
    apply readBytes_shift
    intro d hd
    rw [off_add fit _ _ (by simp only [Sign.TREE]; omega), off_add fit _ _ (by simp only [Keygen.TREE]; omega),
      Nat.add_assoc, Nat.add_assoc]
    exact htree _ (by omega)
  -- below the PRF input, the signer changed nothing
  have below : ∀ c, c < Sign.PRF → sf.mem (base + BitVec.ofNat 32 c) = s.mem (base + BitVec.ofNat 32 c) :=
    fun c hc => hout.off fit (by decide) (by decide) (by simp only [Sign.PRF] at hc; omega) (by left; exact hc)
      (by left; simp only [Sign.PRF, SCR] at hc ⊢; omega)
  have vs : ∀ c n, 0x1000 ≤ c → c + n ≤ 0x4100 →
      readBytes v.mem (base + BitVec.ofNat 32 c) n = readBytes sf.mem (base + BitVec.ofNat 32 c) n := by
    intro c n h1 h2
    apply readBytes_congr
    intro d hd
    rw [off_add fit _ _ (by omega)]
    exact hcopy _ (by omega) (by omega)
  have hidx : idx v.mem base = idx s.mem base := by
    unfold idx; rw [hcopy _ (by decide) (by decide), below _ (by decide)]
  have hdig : ∀ i, digit v.mem base i = digit s.mem base i := digit_congr fun d hd => by
    rw [hcopy _ (by simp only [MSG]; omega) (by simp only [MSG]; omega),
      below _ (by simp only [MSG, Sign.PRF]; omega)]
  have hv : Verifies env.hash v.mem base := by
    refine accepts_signed env.hash v.mem base (Keygen.seedOf k.mem base) hl
      (by rw [hidx]; exact Nat.mod_eq_of_lt hl) ?_ ?_ ?_
    · intro i hi
      unfold sigAt
      rw [hdig, vs _ _ (by simp only [SIG]; omega) (by simp only [SIG]; omega)]
      have := hsig i hi
      unfold sigAt at this
      rw [this, hseed]
    · intro j hj
      unfold authAt
      rw [vs _ _ (by simp only [AUTH]; omega) (by simp only [AUTH]; omega)]
      have := hauth j hj
      unfold authAt at this
      have hs := sib_lt (j := j) hl hj
      have hlv : Sign.lvl j + 2 ^ (4 - j) ≤ 31 := by
        rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3) with rfl | rfl | rfl | rfl <;> decide
      rw [this, Sign.pathAt, tree _ (by omega), flat_node _ _ (by omega) hs]
      rfl
    · unfold rootAt
      rw [vs _ _ (by simp only [ROOT]; omega) (by simp only [ROOT]; omega)]
      unfold rootAt at hroot
      rw [hroot, Sign.rootIn, tree _ (by decide),
        show 30 = Sign.lvl 4 + 0 by decide, flat_node _ _ (by decide) (by decide)]
      rfl
  rw [ite_eq_left_of_eq_true _ _ (eq_true hv)] at ev
  exact ⟨vf, ev⟩

theorem boot_pc {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray) :
    (boot env.region img).pc = base := by simp [boot, hp.region]

theorem boot_mem {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray) :
    (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]

/-- **The three binaries.** `keygen.bin`, `sign.bin` and exp206's
`kernel.bin`, each at the start of its own image and run from the state the
shell builds. The key generator halts with 0. Given a signing image with the
same seed, the tree it left, and an index below 16, the signer halts with 0.
Given a verifying image holding what the signer left from `0x1000` to
`0x4100`, the verifier halts with 0: **it accepts what the signer signed** —
for every seed, message and index, and every HASH. -/
theorem three_binaries {env : Env} {base : Word} (hp : Placed env base)
    (imgK : ByteArray) (hK : 432 ≤ imgK.size) (hKb : ∀ d (h : d < 432), imgK.get d (by omega) = Keygen.bytes.getD d 0) :
    ∃ kf, run env 76456 (boot env.region imgK) = .halted 0 kf ∧
    ∀ imgS : ByteArray, (hS : 620 ≤ imgS.size) → (∀ d (h : d < 620), imgS.get d (by omega) = Sign.bytes.getD d 0) →
      Sign.seedOf (memOfImage base imgS) base = Keygen.seedOf (memOfImage base imgK) base →
      (∀ d < 992, memOfImage base imgS (base + BitVec.ofNat 32 (Sign.TREE + d))
        = kf.mem (base + BitVec.ofNat 32 (Keygen.TREE + d))) →
      idx (memOfImage base imgS) base < 16 →
    ∃ sf, run env (2284 + 3 * Sign.dsum (memOfImage base imgS) base) (boot env.region imgS) = .halted 0 sf ∧
    ∀ imgV : ByteArray, (hV : 752 ≤ imgV.size) → (∀ d (h : d < 752), imgV.get d (by omega) = bytes.getD d 0) →
      (∀ c, 0x1000 ≤ c → c < 0x4100 → memOfImage base imgV (base + BitVec.ofNat 32 c) = sf.mem (base + BitVec.ofNat 32 c)) →
    ∃ vf, run env (3295 + 3 * steps (memOfImage base imgV) base) (boot env.region imgV) = .halted 0 vf := by
  have fit := hp.fit
  obtain ⟨kf, ek, rest⟩ := keygen_sign_verify hp (boot env.region imgK) (boot_pc hp imgK)
    (by rw [boot_mem hp]; exact Keygen.code_of_image fit imgK hK hKb)
  refine ⟨kf, ek, ?_⟩
  intro imgS hS hSb hseed htree hl
  obtain ⟨sf, es, rest⟩ := rest (boot env.region imgS) (boot_pc hp imgS)
    (by rw [boot_mem hp]; exact Sign.code_of_image fit imgS hS hSb)
    (by rw [boot_mem hp, boot_mem hp]; exact hseed) (by rw [boot_mem hp]; exact htree)
    (by rw [boot_mem hp]; exact hl)
  rw [boot_mem hp] at es
  refine ⟨sf, es, ?_⟩
  intro imgV hV hVb hcopy
  obtain ⟨vf, ev⟩ := rest (boot env.region imgV) (boot_pc hp imgV)
    (by rw [boot_mem hp]; exact Mss.code_of_image fit imgV hV hVb) (by rw [boot_mem hp]; exact hcopy)
  rw [boot_mem hp] at ev
  exact ⟨vf, ev⟩

end Exp213

#print axioms Rv32.Mss.Keygen.bytes_words
#print axioms Rv32.Mss.Keygen.code_of_image
#print axioms Rv32.Mss.Keygen.chain_iter
#print axioms Rv32.Mss.Keygen.leaf_iter
#print axioms Rv32.Mss.Keygen.tree_iter
#print axioms Rv32.Mss.Keygen.generates
#print axioms Rv32.Mss.Sign.bytes_words
#print axioms Rv32.Mss.Sign.code_of_image
#print axioms Rv32.Mss.Sign.chain_iter
#print axioms Rv32.Mss.Sign.level_iter
#print axioms Rv32.Mss.Sign.signs
#print axioms Exp213.flat_node
#print axioms Exp213.hashes_add_up
#print axioms Exp213.keygen_sign_verify
#print axioms Exp213.three_binaries

/-- `lean --run Complete.lean KEYGEN SIGN` writes the two kernels' images —
`keygen.bin` and `sign.bin` — and prints their listings. -/
def main (args : List String) : IO Unit := do
  match args with
  | [kg, sg] =>
    IO.FS.writeBinFile kg Rv32.Mss.Keygen.image
    IO.FS.writeBinFile sg Rv32.Mss.Sign.image
  | _ => pure ()
  for (name, prog) in [("keygen", Rv32.Mss.Keygen.kernel), ("sign", Rv32.Mss.Sign.kernel)] do
    IO.println s!"{name}:"
    for (i, k) in prog.zipIdx do
      IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
