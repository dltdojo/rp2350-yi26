/-
SPDX-License-Identifier: Apache-2.0

# MSS: the key generator

exp213's first kernel. From a 32-byte seed it computes all 16 one-time keys'
leaves — 67 chains each, walked 15 steps — and the Merkle tree over them, and
writes the whole tree: 31 nodes, level by level. The signer copies a leaf's
path out of it and the root, and exp206's verifier (`lean/Rv32/Mss.lean`)
accepts what the signer wrote: `lean/Rv32/MssSign.lean` and exp213's
`proof/Complete.lean` are the rest of that chain.
-/
import Rv32.Mss
import Rv32.Walk
import Rv32.Frame

set_option maxRecDepth 20000

namespace Rv32.Mss
open Rv32 Rv32.Wots

def S8 : Reg := 24
def S9 : Reg := 25
def S10 : Reg := 26
def S11 : Reg := 27

namespace Keygen

/-- Where everything is, from `auipc`; the seed into the PRF input; the zero
halves of the PRF input, the chain buffer and the ends. -/
def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S1 S0 T1,
  .lui T1 2, .op .add S2 S0 T1,
  .lui T1 3, .op .add S3 S0 T1,
  .opi .addi S4 S1 64, .opi .addi S5 S1 128,
  .opi .addi S6 S2 2047, .opi .addi S6 S6 97 ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 S1 (BitVec.ofNat 12 (4 * j)), .st .sw S4 T4 (BitVec.ofNat 12 (4 * j))]) ++
  (List.range 8).map (fun j => .st .sw S4 0 (BitVec.ofNat 12 (32 + 4 * j))) ++
  (List.range 8).map (fun j => .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j))) ++
  (List.range 8).map (fun j => .st .sw S6 0 (BitVec.ofNat 12 (4 * j))) ++
  [ .opi .addi T0 0 0, .opi .addi A1 0 64, .opi .addi S7 0 0 ]

/-- Leaf `l`: chain 0, the first end's place, `l` into the PRF input. -/
def leafStart : List Instr := [ .opi .addi S8 0 0, .opi .addi S9 S2 0, .st .sb S4 S7 32 ]

/-- Chain `i`: its secret, HASH of the seed, `l`, `i`; 15 steps along it; its
end after the ones before. -/
def chainBody : List Instr := [
  .st .sb S4 S8 33, .opi .addi A0 S4 0, .opi .addi A2 S5 0, .ecall,
  .opi .addi A0 S5 0, .opi .addi T3 0 15,
  .ecall, .opi .addi T3 T3 0xfff, .br .bne T3 0 0xffc ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 S5 (BitVec.ofNat 12 (4 * j)), .st .sw S9 T4 (BitVec.ofNat 12 (4 * j))]) ++
  [ .opi .addi S9 S9 32, .opi .addi S8 S8 1, .opi .addi T2 0 67, .br .bne S8 T2 0xfc8 ]

/-- The leaf: HASH of the 67 ends and 32 zeros, into the tree. -/
def leafEnd : List Instr := [
  .opi .addi A0 S2 0, .opi .addi A1 0 1088, .op .add A1 A1 A1, .opi .addi A2 S3 0, .ecall,
  .opi .addi A1 0 64, .opi .addi S3 S3 32, .opi .addi S7 S7 1, .opi .addi T2 0 16, .br .bne S7 T2 0xfae ]

/-- Fifteen nodes, each HASH of the two 64 bytes before it moves on: node
`16 + t` from nodes `2t` and `2t + 1`. Then HALT with 0. -/
def tree : List Instr := [
  .lui T1 3, .op .add A0 S0 T1, .opi .addi A2 S3 0, .opi .addi S8 0 15,
  .ecall, .opi .addi A0 A0 64, .opi .addi A2 A2 32, .opi .addi S8 S8 0xfff, .br .bne S8 0 0xff8,
  .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := setup ++ leafStart ++ chainBody ++ leafEnd ++ tree

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 108 := by rfl

/-! ## Where everything is -/

/-- The seed, 32 bytes: the only input. -/
def SEED : Nat := 0x1000
/-- The PRF input, 64 bytes: the seed, `l`, `i`, 30 zeros. -/
def PRF : Nat := 0x1040
/-- The chain buffer, 64 bytes: the value, then 32 zeros. -/
def BUF : Nat := 0x1080
/-- A leaf's 67 ends, and 32 zeros after them: 2176 bytes. -/
def ENDS : Nat := 0x2000
/-- The tree, 31 nodes of 32 bytes. -/
def TREE : Nat := 0x3000

/-- Where it writes: the PRF input and the chain buffer, and from the ends to
the tree's last byte. -/
abbrev Out (base : Word) (m m' : Word → Byte) : Prop := Within base PRF 128 ENDS 0x13e0 m m'

def seedOf (m : Word → Byte) (base : Word) : List Byte := readBytes m (base + BitVec.ofNat 32 SEED) 32

/-- Node `n` of the tree as it is laid out: the leaves at 0..15, then each
level after the one below it, the root at 30. -/
def flat (H : List Byte → Fin 32 → Byte) (seed : List Byte) (n : Nat) : List Byte :=
  if n < 16 then node H seed 0 n
  else if n < 24 then node H seed 1 (n - 16)
  else if n < 28 then node H seed 2 (n - 24)
  else if n < 30 then node H seed 3 (n - 28)
  else node H seed 4 (n - 30)

/-- Node `16 + t` is HASH of nodes `2t` and `2t + 1`. -/
theorem flat_step (H : List Byte → Fin 32 → Byte) (seed : List Byte) {t : Nat} (ht : t < 15) :
    flat H seed (16 + t) = hashL H (flat H seed (2 * t) ++ flat H seed (2 * t + 1)) := by
  unfold flat
  rcases (by omega : t < 8 ∨ (8 ≤ t ∧ t < 12) ∨ (12 ≤ t ∧ t < 14) ∨ t = 14) with h | h | h | h
  · rw [ifF (by omega), ifT (by omega), ifT (by omega), ifT (by omega),
      show 16 + t - 16 = t by omega]; rfl
  · rw [ifF (by omega), ifF (by omega), ifT (by omega), ifF (by omega), ifT (by omega),
      ifF (by omega), ifT (by omega), show 16 + t - 24 = t - 8 by omega,
      show 2 * t - 16 = 2 * (t - 8) by omega, show 2 * t + 1 - 16 = 2 * (t - 8) + 1 by omega]; rfl
  · rw [ifF (by omega), ifF (by omega), ifF (by omega), ifT (by omega), ifF (by omega),
      ifF (by omega), ifT (by omega), ifF (by omega), ifF (by omega), ifT (by omega),
      show 16 + t - 28 = t - 12 by omega, show 2 * t - 24 = 2 * (t - 12) by omega,
      show 2 * t + 1 - 24 = 2 * (t - 12) + 1 by omega]; rfl
  · subst h; rfl

/-! ## The bytes are the kernel, instruction by instruction -/

theorem at_seed : ∀ j < 8, kernel.getD (11 + 2 * j) .ecall = .ld .lw T4 S1 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (11 + 2 * j + 1) .ecall = .st .sw S4 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_zp : ∀ j < 8, kernel.getD (27 + j) .ecall = .st .sw S4 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem at_zb : ∀ j < 8, kernel.getD (35 + j) .ecall = .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem at_ze : ∀ j < 8, kernel.getD (43 + j) .ecall = .st .sw S6 0 (BitVec.ofNat 12 (0 + 4 * j)) := by
  decide
theorem at_store : ∀ j < 8, kernel.getD (66 + 2 * j) .ecall = .ld .lw T4 S5 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (66 + 2 * j + 1) .ecall = .st .sw S9 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide

/-! ## What holds from setup on -/

/-- The registers setup leaves that nothing after it changes. -/
structure KRegs (base : Word) (s : Machine) : Prop where
  s0 : s.reg S0 = base
  s2 : s.reg S2 = base + BitVec.ofNat 32 ENDS
  s4 : s.reg S4 = base + BitVec.ofNat 32 PRF
  s5 : s.reg S5 = base + BitVec.ofNat 32 BUF
  t0 : s.reg T0 = 0

/-- What holds of memory from the end of setup on: written only in its two
places, the seed at the start of the PRF input and 30 zeros at its end, the
chain buffer's zero half, and the 32 zeros after the ends. -/
structure KMem (base : Word) (m0 m : Word → Byte) : Prop where
  out : Out base m0 m
  seed : readBytes m (base + BitVec.ofNat 32 PRF) 32 = seedOf m0 base
  zp : readBytes m (base + BitVec.ofNat 32 (PRF + 34)) 30 = List.replicate 30 0
  zb : ∀ d < 32, m (base + BitVec.ofNat 32 (BUF + 32 + d)) = 0
  ze : readBytes m (base + BitVec.ofNat 32 (ENDS + 2144)) 32 = List.replicate 32 0

/-- The places a step may write without disturbing `KMem`: bytes 32 and 33
of the PRF input, the chain buffer's first half, the ends, the tree. -/
def Free (S N : Nat) : Prop :=
  (PRF + 32 ≤ S ∧ S + N ≤ PRF + 34) ∨ (BUF ≤ S ∧ S + N ≤ BUF + 32)
    ∨ (ENDS ≤ S ∧ S + N ≤ ENDS + 2144) ∨ (TREE ≤ S ∧ S + N ≤ TREE + 992)

theorem KMem.keeps {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m m' : Word → Byte}
    (h : KMem base m0 m) {S N : Nat} (hk : Keeps (base + BitVec.ofNat 32 S) N m m') (hin : Free S N) :
    KMem base m0 m' := by
  have hSN : S + N < 0x10000 := by unfold Free at hin; simp only [PRF, BUF, ENDS, TREE] at hin; omega
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · unfold Free at hin
    rcases hin with hin | hin | hin | hin
    · exact h.out.left hfit hk (by simp only [PRF] at hin ⊢; omega) (by simp only [PRF] at hin ⊢; omega) (by decide)
    · exact h.out.left hfit hk (by simp only [PRF, BUF] at hin ⊢; omega) (by simp only [PRF, BUF] at hin ⊢; omega)
        (by decide)
    · exact h.out.right hfit hk (by simp only [ENDS] at hin ⊢; omega) (by simp only [ENDS] at hin ⊢; omega)
        (by decide)
    · exact h.out.right hfit hk (by simp only [ENDS, TREE] at hin ⊢; omega)
        (by simp only [ENDS, TREE] at hin ⊢; omega) (by decide)
  · rw [hk.bytes hfit hSN (by simp only [PRF]; omega)
      (by unfold Free at hin; simp only [PRF, BUF, ENDS, TREE] at hin ⊢; omega)]
    exact h.seed
  · rw [hk.bytes hfit hSN (by simp only [PRF]; omega)
      (by unfold Free at hin; simp only [PRF, BUF, ENDS, TREE] at hin ⊢; omega)]
    exact h.zp
  · intro d hd
    rw [hk.off hfit hSN (by simp only [BUF]; omega)
      (by unfold Free at hin; simp only [PRF, BUF, ENDS, TREE] at hin ⊢; omega)]
    exact h.zb d hd
  · rw [hk.bytes hfit hSN (by simp only [ENDS]; omega)
      (by unfold Free at hin; simp only [PRF, BUF, ENDS, TREE] at hin ⊢; omega)]
    exact h.ze

theorem KMem.code {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte}
    (h : KMem base m0 m) (hc : CodeAt m0 base kernel) : CodeAt m base kernel :=
  h.out.code hfit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc

/-! ## Setup -/

/-- Fifty-four instructions: the pointers, the seed copied into the PRF input,
three runs of zeros. -/
theorem setup_run {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 54 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 54) ∧ KRegs base s'
      ∧ s'.reg S3 = base + BitVec.ofNat 32 TREE ∧ s'.reg S7 = 0 ∧ s'.reg A1 = BitVec.ofNat 32 64
      ∧ KMem base s.mem s'.mem := by
  have fit := hp.fit
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (i := .lui T1 1) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (i := .lui T1 2) (by decide) rfl
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide)
      (by rw [m4, m3, m2, m1]; exact hcode) p4 (i := .op .add S2 S0 T1) (by decide) rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide)
      (by rw [m5, m4, m3, m2, m1]; exact hcode) p5 (i := .lui T1 3) (by decide) rfl
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 6 (by decide)
      (by rw [m6, m5, m4, m3, m2, m1]; exact hcode) p6 (i := .op .add S3 S0 T1) (by decide) rfl
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 7 (by decide)
      (by rw [m7, m6, m5, m4, m3, m2, m1]; exact hcode) p7 (i := .opi .addi S4 S1 64) (by decide) rfl
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp 8 (by decide)
      (by rw [m8, m7, m6, m5, m4, m3, m2, m1]; exact hcode) p8 (i := .opi .addi S5 S1 128) (by decide) rfl
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp 9 (by decide)
      (by rw [m9, m8, m7, m6, m5, m4, m3, m2, m1]; exact hcode) p9 (i := .opi .addi S6 S2 2047) (by decide) rfl
  obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp 10 (by decide)
      (by rw [m10, m9, m8, m7, m6, m5, m4, m3, m2, m1]; exact hcode) p10 (i := .opi .addi S6 S6 97) (by decide) rfl
  have mem11 : s11.mem = s.mem := by rw [m11, m10, m9, m8, m7, m6, m5, m4, m3, m2, m1]
  have hc11 : CodeAt s11.mem base kernel := by rw [mem11]; exact hcode
  have v : s11.reg S0 = base ∧ s11.reg S1 = base + BitVec.ofNat 32 SEED ∧ s11.reg S2 = base + BitVec.ofNat 32 ENDS
      ∧ s11.reg S3 = base + BitVec.ofNat 32 TREE ∧ s11.reg S4 = base + BitVec.ofNat 32 PRF
      ∧ s11.reg S5 = base + BitVec.ofNat 32 BUF ∧ s11.reg S6 = base + BitVec.ofNat 32 (ENDS + 2144) := by
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [r11, r10, r9, r8, r7, r6, r5, r4, r3, r2, r1, hpc, S0, S1, S2, S3, S4, S5, S6, T1,
      aluR, aluI, SEED, PRF, BUF, ENDS, TREE, BitVec.add_assoc] <;> rfl
  obtain ⟨v0, v1, v2, v3, v4, v5, v6⟩ := v
  -- the seed into the PRF input
  obtain ⟨c1, ec1, pc1, mc1, rc1⟩ := (copy_words (prog := kernel) hp (k0 := 11) (rs := S1) (rd := S4) (t := T4)
    (src := SEED) (dst := PRF) at_seed (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide) (by decide)
    p11 hc11 v1 v4) 8 (Nat.le_refl _)
  have hcc1 : CodeAt c1.mem base kernel := by
    rw [mc1]; exact code_of_overlay fit hc11 (by rw [kernel_length]; decide) (by decide) _
  -- three runs of zeros
  obtain ⟨z1, ez1, pz1, mz1, rz1⟩ := (zero_words (prog := kernel) hp (k0 := 27) (rd := S4) (o := 32) (a := PRF)
    at_zp (by rw [kernel_length]; decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide)
    pc1 hcc1 (by rw [rc1 _ (by decide), v4])) 8 (Nat.le_refl _)
  have hcz1 : CodeAt z1.mem base kernel := by
    rw [mz1]; exact code_of_overlay fit hcc1 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨z2, ez2, pz2, mz2, rz2⟩ := (zero_words (prog := kernel) hp (k0 := 35) (rd := S5) (o := 32) (a := BUF)
    at_zb (by rw [kernel_length]; decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide)
    pz1 hcz1 (by rw [rz1, rc1 _ (by decide), v5])) 8 (Nat.le_refl _)
  have hcz2 : CodeAt z2.mem base kernel := by
    rw [mz2]; exact code_of_overlay fit hcz1 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨z3, ez3, pz3, mz3, rz3⟩ := (zero_words (prog := kernel) hp (k0 := 43) (rd := S6) (o := 0)
    (a := ENDS + 2144) at_ze (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    (by rw [kernel_length]; decide) pz2 hcz2 (by rw [rz2, rz1, rc1 _ (by decide), v6])) 8 (Nat.le_refl _)
  have hcz3 : CodeAt z3.mem base kernel := by
    rw [mz3]; exact code_of_overlay fit hcz2 (by rw [kernel_length]; decide) (by decide) _
  -- t0 = 0, a1 = 64, s7 = 0
  obtain ⟨u1, eu1, pu1, mu1, ru1⟩ := regStep (prog := kernel) hp 51 (by decide) hcz3 pz3
      (i := .opi .addi T0 0 0) (by decide) rfl
  obtain ⟨u2, eu2, pu2, mu2, ru2⟩ := regStep (prog := kernel) hp 52 (by decide) (by rw [mu1]; exact hcz3) pu1
      (i := .opi .addi A1 0 64) (by decide) rfl
  obtain ⟨u3, eu3, pu3, mu3, ru3⟩ := regStep (prog := kernel) hp 53 (by decide) (by rw [mu2, mu1]; exact hcz3) pu2
      (i := .opi .addi S7 0 0) (by decide) rfl
  have kept : ∀ r, r ≠ T4 → r ≠ T0 → r ≠ A1 → r ≠ S7 → u3.reg r = s11.reg r := fun r a b c d => by
    rw [reg_kept ru3 d, reg_kept ru2 c, reg_kept ru1 b, rz3, rz2, rz1, rc1 r a]
  -- the memory
  have M1 : c1.mem = overlay s.mem (base + BitVec.ofNat 32 PRF) 32
      (fun d => s.mem (base + BitVec.ofNat 32 (SEED + d))) := by rw [mc1, mem11]
  have K1 : Keeps (base + BitVec.ofNat 32 PRF) 32 s.mem c1.mem := by
    rw [M1]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by decide)
  have K2 : Keeps (base + BitVec.ofNat 32 (PRF + 32)) 32 c1.mem z1.mem := by
    rw [mz1]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by decide)
  have K3 : Keeps (base + BitVec.ofNat 32 (BUF + 32)) 32 z1.mem z2.mem := by
    rw [mz2]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by decide)
  have K4 : Keeps (base + BitVec.ofNat 32 (ENDS + 2144 + 0)) 32 z2.mem z3.mem := by
    rw [mz3]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by decide)
  have mem : KMem base s.mem u3.mem := by
    rw [mu3, mu2, mu1]
    refine ⟨?_, ?_, ?_, ?_, ?_⟩
    · exact (((Within.refl _ _ _ _ _ _).left fit K1 (by decide) (by decide) (by decide)).left fit K2
        (by decide) (by decide) (by decide) |>.left fit K3 (by decide) (by decide) (by decide)).right fit K4
        (by decide) (by decide) (by decide)
    · rw [K4.bytes fit (by decide) (by decide) (by decide), K3.bytes fit (by decide) (by decide) (by decide),
        K2.bytes fit (by decide) (by decide) (by decide), M1]
      apply readBytes_shift
      intro d hd
      rw [off_add fit _ _ (by simp only [PRF]; omega), overlay_off_in fit _ _ (by simp only [PRF]; omega)
        (by omega) (by omega), show PRF + d - PRF = d by omega]
      rw [off_add fit _ _ (by simp only [SEED]; omega)]
    · rw [K4.bytes fit (by decide) (by decide) (by decide), K3.bytes fit (by decide) (by decide) (by decide), mz1]
      exact readBytes_zeros fit _ (by simp only [PRF]; omega) (by simp only [PRF]; omega) (by decide)
    · intro d hd
      rw [K4.off fit (by decide) (by simp only [BUF]; omega) (by left; simp only [BUF, ENDS]; omega), mz2,
        overlay_off_in fit _ _ (by simp only [BUF]; omega) (by omega) (by omega)]
    · rw [mz3]
      exact readBytes_zeros fit _ (by simp only [ENDS]; omega) (by simp only [ENDS]; omega) (by decide)
  refine ⟨u3, ?_, pu3, ⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, mem⟩
  · have e11' : run env 11 s = .running s11 :=
      run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7
        (run_cons e8 (run_cons e9 (run_cons e10 e11)))))))))
    rw [show 54 = 11 + (2 * 8 + (8 + (8 + (8 + (1 + (1 + 1)))))) by rfl, run_add_running e11',
      run_add_running ec1, run_add_running ez1, run_add_running ez2, run_add_running ez3]
    exact run_cons eu1 (run_cons eu2 eu3)
  · rw [kept _ (by decide) (by decide) (by decide) (by decide), v0]
  · rw [kept _ (by decide) (by decide) (by decide) (by decide), v2]
  · rw [kept _ (by decide) (by decide) (by decide) (by decide), v4]
  · rw [kept _ (by decide) (by decide) (by decide) (by decide), v5]
  · rw [reg_kept ru3 (by decide), reg_kept ru2 (by decide), reg_wrote ru1 (by decide)]
    simp only [aluI, reg_zero]; decide
  · rw [kept _ (by decide) (by decide) (by decide) (by decide), v3]
  · rw [reg_wrote ru3 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_kept ru3 (by decide), reg_wrote ru2 (by decide)]; simp only [aluI, reg_zero]; decide

/-! ## One chain -/

/-- At the top of chain `i` of leaf `l` — or, once `i` is 67, at the leaf's
HASH: the ends of chains `0..i-1` written one after another. -/
structure CInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (l i : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 67 then 57 else 86))
  rg : KRegs base s
  a1 : s.reg A1 = BitVec.ofNat 32 64
  s3 : s.reg S3 = base + BitVec.ofNat 32 (TREE + 32 * l)
  s7 : s.reg S7 = BitVec.ofNat 32 l
  s8 : s.reg S8 = BitVec.ofNat 32 i
  s9 : s.reg S9 = base + BitVec.ofNat 32 (ENDS + 32 * i)
  mem : KMem base m0 s.mem
  pl : s.mem (base + BitVec.ofNat 32 (PRF + 32)) = BitVec.ofNat 8 l
  tree : ∀ k < l, readBytes s.mem (base + BitVec.ofNat 32 (TREE + 32 * k)) 32 = leafRef H (seedOf m0 base) k
  ends : readBytes s.mem (base + BitVec.ofNat 32 ENDS) (32 * i)
    = cat (fun i => chain H (secret H (seedOf m0 base) l i) 15) i

local macro "bnd" : tactic => `(tactic| ((try simp only [PRF, BUF, ENDS, TREE, SEED]) <;> omega))

/-- **One chain**: 71 instructions — the secret, HASH of the seed, `l` and
`i`; 15 steps along its chain, in place; its end after the ones before. -/
theorem chain_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {l i : Nat} (hl : l < 16) (hi : i < 67) {s : Machine}
    (h : CInv env.hash base m0 l i s) :
    ∃ s', run env 71 s = .running s' ∧ CInv env.hash base m0 l (i + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 57) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  -- sb s8, 33(s4): i into the PRF input
  obtain ⟨t1, f1, q1, n1, u1⟩ := sbStep (prog := kernel) hp 57 (by decide) hcode hpc
    (rs1 := S4) (rs2 := S8) (imm := 33) (by decide) (PRF + 33)
    (by rw [h.rg.s4, show BitVec.signExtend 32 (33 : BitVec 12) = BitVec.ofNat 32 33 by decide,
      off_add fit _ _ (by bnd)]) (by bnd)
  have vi : BitVec.ofNat 8 (s.reg S8).toNat = BitVec.ofNat 8 i := by
    rw [h.s8, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
  rw [vi] at n1
  have K1 : Keeps (base + BitVec.ofNat 32 (PRF + 33)) 1 s.mem t1.mem := by
    rw [n1]; exact keeps_writeByte fit _ _ (Nat.le_refl _) (by omega) (by bnd)
  have mem1 : KMem base m0 t1.mem := h.mem.keeps fit K1 (by unfold Free; left; bnd)
  have hc1 : CodeAt t1.mem base kernel := mem1.code fit hc0
  -- addi a0, s4, 0; addi a2, s5, 0
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 58 (by decide) hc1 q1
    (i := .opi .addi A0 S4 0) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 59 (by decide) (by rw [n2]; exact hc1) q2
    (i := .opi .addi A2 S5 0) (by decide) rfl
  have k3 : ∀ r, r ≠ A0 → r ≠ A2 → t3.reg r = s.reg r := fun r a b => by
    rw [reg_kept u3 b, reg_kept u2 a, u1]
  have a0_3 : t3.reg A0 = base + BitVec.ofNat 32 PRF := by
    rw [reg_kept u3 (by decide), reg_wrote u2 (by decide), u1, h.rg.s4]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  have a2_3 : t3.reg A2 = base + BitVec.ofNat 32 BUF := by
    rw [reg_wrote u3 (by decide), reg_kept u2 (by decide), u1, h.rg.s5]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  have t0_3 : t3.reg T0 = 0 := by rw [k3 _ (by decide) (by decide), h.rg.t0]
  have a1_3 : t3.reg A1 = BitVec.ofNat 32 64 := by rw [k3 _ (by decide) (by decide), h.a1]
  -- ecall: the secret, into the buffer
  have hexec := exec_hash (env := env) (s := t3) t0_3 (by rw [a1_3]; rfl)
    (by rw [a0_3]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [a2_3]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [a0_3, a1_3]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [a2_3]; exact ok_off hp _ _ (by decide) (by decide))
  obtain ⟨t4, f4, ht4⟩ : ∃ t4, run env 1 t3 = .running t4 ∧
      t4 = ({ t3 with mem := writeBytes t3.mem (t3.reg A2) (env.hash (readBytes t3.mem (t3.reg A0) (t3.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 60 (by decide) (by rw [n3, n2]; exact hc1) q3 (i := .ecall) (by decide)
      hexec 0).trans (run_zero _ _), rfl⟩
  have mem4 : t4.mem = writeBytes t1.mem (base + BitVec.ofNat 32 BUF)
      (env.hash (seedOf m0 base ++ [BitVec.ofNat 8 l, BitVec.ofNat 8 i] ++ List.replicate 30 0)) := by
    rw [ht4, next_mem, a0_3, a1_3, a2_3, n3, n2, show (BitVec.ofNat 32 64).toNat = 64 from rfl, n1,
      prf_bytes fit (by bnd) h.mem.seed h.pl h.mem.zp]
  have q4 : t4.pc = base + BitVec.ofNat 32 (4 * 61) := by
    rw [ht4]; simp only [next_pc]; rw [q3]; exact pc_next fit 60 (by decide)
  have k4 : ∀ r, t4.reg r = t3.reg r := fun r => by rw [ht4]; rfl
  have K2 : Keeps (base + BitVec.ofNat 32 BUF) 32 t1.mem t4.mem := by
    rw [mem4]; exact keeps_writeBytes fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem4' : KMem base m0 t4.mem := mem1.keeps fit K2 (by unfold Free; right; left; bnd)
  have hc4 : CodeAt t4.mem base kernel := mem4'.code fit hc0
  have buf4 : readBytes t4.mem (base + BitVec.ofNat 32 BUF) 32 = chain env.hash (secret env.hash (seedOf m0 base) l i) 0 := by
    rw [mem4, readBytes_writeBytes]; rfl
  -- addi a0, s5, 0; addi t3, x0, 15
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 61 (by decide) hc4 q4
    (i := .opi .addi A0 S5 0) (by decide) rfl
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := kernel) hp 62 (by decide) (by rw [n5]; exact hc4) q5
    (i := .opi .addi T3 0 15) (by decide) rfl
  have mem6 : t6.mem = t4.mem := by rw [n6, n5]
  have hc6 : CodeAt t6.mem base kernel := by rw [mem6]; exact hc4
  have k6 : ∀ r, r ≠ A0 → r ≠ A2 → r ≠ T3 → t6.reg r = s.reg r := fun r a b c => by
    rw [reg_kept u6 c, reg_kept u5 a, k4, k3 r a b]
  have a0_6 : t6.reg A0 = base + BitVec.ofNat 32 BUF := by
    rw [reg_kept u6 (by decide), reg_wrote u5 (by decide), k4, k3 _ (by decide) (by decide), h.rg.s5]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  -- the walk: 15 steps
  obtain ⟨t7, f7, q7, K7, b7, k7⟩ := hash_walk (prog := kernel) hp (by rw [kernel_length]; decide)
    (k0 := 63) (B := BUF) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide) (by bnd) (by bnd)
    (by rw [kernel_length]; bnd) (M := t6.mem) hc6 (fun d hd => by rw [mem6]; exact mem4'.zb d hd)
    (x := secret env.hash (seedOf m0 base) l i) 15 (by decide) (by decide) 0 t6 q6
    (by rw [reg_wrote u6 (by decide)]; simp only [aluI, reg_zero]; decide)
    (by rw [k6 _ (by decide) (by decide) (by decide), h.rg.t0]) a0_6
    (by rw [k6 _ (by decide) (by decide) (by decide), h.a1])
    (by rw [reg_kept u6 (by decide), reg_kept u5 (by decide), k4, a2_3]) (Keeps.refl _ _ _)
    (by rw [mem6]; exact buf4)
  have K7' : Keeps (base + BitVec.ofNat 32 BUF) 32 t4.mem t7.mem := by rw [← mem6]; exact K7
  have mem7 : KMem base m0 t7.mem := mem4'.keeps fit K7' (by unfold Free; right; left; bnd)
  have hc7 : CodeAt t7.mem base kernel := mem7.code fit hc0
  have k7' : ∀ r, r ≠ A0 → r ≠ A2 → r ≠ T3 → t7.reg r = s.reg r := fun r a b c => by
    rw [k7 r c, k6 r a b c]
  -- the end, after the ones before
  obtain ⟨t8, f8, q8, n8, u8⟩ := (copy_words (prog := kernel) hp (k0 := 66) (rs := S5) (rd := S9) (t := T4)
    (src := BUF) (dst := ENDS + 32 * i) at_store (by rw [kernel_length]; decide) (by decide) (by decide)
    (by decide) (by bnd) (by bnd) (by bnd) (by bnd) (by rw [kernel_length]; bnd) (by left; bnd)
    (by rw [q7]) hc7 (by rw [k7' _ (by decide) (by decide) (by decide), h.rg.s5])
    (by rw [k7' _ (by decide) (by decide) (by decide), h.s9])) 8 (Nat.le_refl _)
  have K8 : Keeps (base + BitVec.ofNat 32 (ENDS + 32 * i)) 32 t7.mem t8.mem := by
    rw [n8]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem8 : KMem base m0 t8.mem := mem7.keeps fit K8 (by unfold Free; right; right; left; bnd)
  have hc8 : CodeAt t8.mem base kernel := mem8.code fit hc0
  have k8 : ∀ r, r ≠ A0 → r ≠ A2 → r ≠ T3 → r ≠ T4 → t8.reg r = s.reg r := fun r a b c d => by
    rw [u8 r d, k7' r a b c]
  -- addi s9, s9, 32; addi s8, s8, 1; addi t2, x0, 67
  obtain ⟨t9, f9, q9, n9, u9⟩ := regStep (prog := kernel) hp 82 (by decide) hc8 q8
    (i := .opi .addi S9 S9 32) (by decide) rfl
  obtain ⟨t10, f10, q10, n10, u10⟩ := regStep (prog := kernel) hp 83 (by decide) (by rw [n9]; exact hc8) q9
    (i := .opi .addi S8 S8 1) (by decide) rfl
  obtain ⟨t11, f11, q11, n11, u11⟩ := regStep (prog := kernel) hp 84 (by decide) (by rw [n10, n9]; exact hc8)
    q10 (i := .opi .addi T2 0 67) (by decide) rfl
  have mem11 : t11.mem = t8.mem := by rw [n11, n10, n9]
  have hc11 : CodeAt t11.mem base kernel := by rw [mem11]; exact hc8
  have k11 : ∀ r, r ≠ A0 → r ≠ A2 → r ≠ T3 → r ≠ T4 → r ≠ S9 → r ≠ S8 → r ≠ T2 → t11.reg r = s.reg r :=
    fun r a b c d e f g => by rw [reg_kept u11 g, reg_kept u10 f, reg_kept u9 e, k8 r a b c d]
  have v_s8 : t11.reg S8 = BitVec.ofNat 32 (i + 1) := by
    rw [reg_kept u11 (by decide), reg_wrote u10 (by decide), reg_kept u9 (by decide),
      k8 _ (by decide) (by decide) (by decide) (by decide), h.s8]
    simp only [aluI]; exact add_small i 1 (by decide)
  have v_t2 : t11.reg T2 = BitVec.ofNat 32 67 := by
    rw [reg_wrote u11 (by decide)]; simp only [aluI, reg_zero]; decide
  have ht : taken .bne (t11.reg S8) (t11.reg T2) = decide (i + 1 < 67) := by
    rw [v_s8, v_t2]; simp only [taken]
    by_cases hl' : i + 1 < 67
    · simp only [hl', decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega),
        Nat.mod_eq_of_lt (by decide)] at this
      omega
    · simp only [hl', decide_false, bne_eq_false_iff_eq]
      rw [show i + 1 = 67 by omega]
  -- what the branch leaves, whichever way it goes
  have finish : ∀ s4 : Machine, run env 1 t11 = .running s4 → (∀ r, s4.reg r = t11.reg r) →
      s4.mem = t11.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if i + 1 < 67 then 57 else 86)) →
      ∃ s', run env 71 s = .running s' ∧ CInv env.hash base m0 l (i + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ A0 → r ≠ A2 → r ≠ T3 → r ≠ T4 → r ≠ S9 → r ≠ S8 → r ≠ T2 → s4.reg r = s.reg r :=
      fun r a b c d e f g => by rw [b4, k11 r a b c d e f g]
    have mm : s4.mem = t8.mem := by rw [m4, mem11]
    refine ⟨s4, ?_, ⟨p4, ⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, by rw [b4, v_s8], ?_, by rw [mm]; exact mem8,
      ?_, ?_, ?_⟩⟩
    · have ew : run env 65 t6 = .running s4 := by
        rw [show 65 = 3 * 15 + (2 * 8 + (1 + (1 + (1 + 1)))) by rfl, run_add_running f7, run_add_running f8]
        exact run_cons f9 (run_cons f10 (run_cons f11 e4))
      exact run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 (run_cons f6 ew)))))
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s2]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s4]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s3]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s7]
    · rw [b4, reg_kept u11 (by decide), reg_kept u10 (by decide), reg_wrote u9 (by decide),
        k8 _ (by decide) (by decide) (by decide) (by decide), h.s9]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · rw [mm, K8.off fit (by bnd) (by bnd) (by left; bnd), K7'.off fit (by bnd) (by bnd) (by left; bnd),
        K2.off fit (by bnd) (by bnd) (by left; bnd), K1.off fit (by bnd) (by bnd) (by left; bnd)]
      exact h.pl
    · intro k hk
      rw [mm, K8.bytes fit (by bnd) (by bnd) (by right; bnd), K7'.bytes fit (by bnd) (by bnd) (by right; bnd),
        K2.bytes fit (by bnd) (by bnd) (by right; bnd), K1.bytes fit (by bnd) (by bnd) (by right; bnd)]
      exact h.tree k hk
    · rw [mm, show 32 * (i + 1) = 32 * i + 32 by omega, readBytes_append, off_add fit _ _ (by bnd)]
      simp only [cat]
      refine app_congr ?_ ?_
      · rw [K8.bytes fit (by bnd) (by bnd) (by left; bnd), K7'.bytes fit (by bnd) (by bnd) (by right; bnd),
          K2.bytes fit (by bnd) (by bnd) (by right; bnd), K1.bytes fit (by bnd) (by bnd) (by right; bnd)]
        exact h.ends
      · rw [← b7, n8]
        apply readBytes_shift
        intro d hd
        rw [off_add fit _ _ (by bnd), overlay_off_in fit _ _ (by bnd) (by omega) (by omega),
          show ENDS + 32 * i + d - (ENDS + 32 * i) = d by omega, off_add fit _ _ (by bnd)]
  by_cases hl' : i + 1 < 67
  · have e4 : run env 1 t11 = .running (t11.setPc (t11.pc + ((0xfc8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 85 (by decide) hc11 q11 (i := .br .bne S8 T2 0xfc8) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl', ↓reduceIte, setPc_pc, q11]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 t11 = .running t11.next :=
      (stepK (prog := kernel) hp 85 (by decide) hc11 q11 (i := .br .bne S8 T2 0xfc8) (by decide)
        (exec_br_not (by rw [ht]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl', ↓reduceIte, next_pc, q11]
    exact pc_next fit 85 (by decide)

/-- 67 chains, by induction: after `j` of them, the invariant holds for `j`. -/
theorem chain_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {l : Nat} (hl : l < 16) {s : Machine} (h : CInv env.hash base m0 l 0 s) :
    ∀ j ≤ 67, ∃ s', run env (71 * j) s = .running s' ∧ CInv env.hash base m0 l j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := chain_iter hp hc0 hl (by omega) hs'
    exact ⟨s'', by rw [show 71 * (j + 1) = 71 * j + 71 by omega, run_add_running e, e'], hs''⟩

/-! ## One leaf -/

/-- At the top of leaf `l` — or, once `l` is 16, at the tree: leaves
`0..l-1` written into the tree. -/
structure LInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (l : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if l < 16 then 54 else 96))
  rg : KRegs base s
  a1 : s.reg A1 = BitVec.ofNat 32 64
  s3 : s.reg S3 = base + BitVec.ofNat 32 (TREE + 32 * l)
  s7 : s.reg S7 = BitVec.ofNat 32 l
  mem : KMem base m0 s.mem
  tree : ∀ k < l, readBytes s.mem (base + BitVec.ofNat 32 (TREE + 32 * k)) 32 = leafRef H (seedOf m0 base) k

/-- Three instructions: chain 0, the first end's place, `l` into the PRF input. -/
theorem leaf_start {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {l : Nat} (hl : l < 16) {s : Machine} (h : LInv env.hash base m0 l s) :
    ∃ s', run env 3 s = .running s' ∧ CInv env.hash base m0 l 0 s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 54) := by rw [h.pc]; simp [hl]
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 54 (by decide) hcode hpc
    (i := .opi .addi S8 0 0) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 55 (by decide) (by rw [n1]; exact hcode) q1
    (i := .opi .addi S9 S2 0) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := sbStep (prog := kernel) hp 56 (by decide) (by rw [n2, n1]; exact hcode) q2
    (rs1 := S4) (rs2 := S7) (imm := 32) (by decide) (PRF + 32)
    (by rw [reg_kept u2 (by decide), reg_kept u1 (by decide), h.rg.s4,
      show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]) (by bnd)
  have vl : BitVec.ofNat 8 (t2.reg S7).toNat = BitVec.ofNat 8 l := by
    rw [reg_kept u2 (by decide), reg_kept u1 (by decide), h.s7, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
  rw [vl, n2, n1] at n3
  have K : Keeps (base + BitVec.ofNat 32 (PRF + 32)) 1 s.mem t3.mem := by
    rw [n3]; exact keeps_writeByte fit _ _ (Nat.le_refl _) (by omega) (by bnd)
  have kept : ∀ r, r ≠ S8 → r ≠ S9 → t3.reg r = s.reg r := fun r a b => by
    rw [u3, reg_kept u2 b, reg_kept u1 a]
  refine ⟨t3, run_cons f1 (run_cons f2 f3), ⟨by rw [q3]; rfl, ⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_, ?_,
    h.mem.keeps fit K (by unfold Free; left; bnd), ?_, ?_, by rw [Nat.mul_zero]; rfl⟩⟩
  · rw [kept _ (by decide) (by decide), h.rg.s0]
  · rw [kept _ (by decide) (by decide), h.rg.s2]
  · rw [kept _ (by decide) (by decide), h.rg.s4]
  · rw [kept _ (by decide) (by decide), h.rg.s5]
  · rw [kept _ (by decide) (by decide), h.rg.t0]
  · rw [kept _ (by decide) (by decide), h.a1]
  · rw [kept _ (by decide) (by decide), h.s3]
  · rw [kept _ (by decide) (by decide), h.s7]
  · rw [u3, reg_kept u2 (by decide), reg_wrote u1 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [u3, reg_wrote u2 (by decide), reg_kept u1 (by decide), h.rg.s2]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [n3]; simp [writeByte]
  · intro k hk
    rw [K.bytes fit (by bnd) (by bnd) (by right; bnd)]; exact h.tree k hk

/-- Ten instructions after the 67th chain: the leaf, HASH of the 2176 bytes of
ends and zeros, into the tree; and on to the next. -/
theorem leaf_end {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {l : Nat} (hl : l < 16) {s : Machine} (h : CInv env.hash base m0 l 67 s) :
    ∃ s', run env 10 s = .running s' ∧ LInv env.hash base m0 (l + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 86) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 86 (by decide) hcode hpc
    (i := .opi .addi A0 S2 0) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 87 (by decide) (by rw [n1]; exact hcode) q1
    (i := .opi .addi A1 0 1088) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 88 (by decide) (by rw [n2, n1]; exact hcode) q2
    (i := .op .add A1 A1 A1) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 89 (by decide) (by rw [n3, n2, n1]; exact hcode) q3
    (i := .opi .addi A2 S3 0) (by decide) rfl
  have mem4 : t4.mem = s.mem := by rw [n4, n3, n2, n1]
  have hc4 : CodeAt t4.mem base kernel := by rw [mem4]; exact hcode
  have k4 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → t4.reg r = s.reg r := fun r a b c => by
    rw [reg_kept u4 c, reg_kept u3 b, reg_kept u2 b, reg_kept u1 a]
  have a0_4 : t4.reg A0 = base + BitVec.ofNat 32 ENDS := by
    rw [reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), reg_wrote u1 (by decide),
      h.rg.s2]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  have a1_4 : t4.reg A1 = BitVec.ofNat 32 2176 := by
    rw [reg_kept u4 (by decide), reg_wrote u3 (by decide), reg_wrote u2 (by decide)]
    simp only [aluR, aluI, reg_zero]; decide
  have a2_4 : t4.reg A2 = base + BitVec.ofNat 32 (TREE + 32 * l) := by
    rw [reg_wrote u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.s3]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  have t0_4 : t4.reg T0 = 0 := by rw [k4 _ (by decide) (by decide) (by decide), h.rg.t0]
  have hexec := exec_hash (env := env) (s := t4) t0_4 (by rw [a1_4]; rfl)
    (by rw [a0_4]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [a2_4]; exact align_off hp.align fit _ (by bnd) (by bnd))
    (by rw [a0_4, a1_4]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [a2_4]; exact ok_off hp _ _ (by bnd) (by bnd))
  obtain ⟨t5, f5, ht5⟩ : ∃ t5, run env 1 t4 = .running t5 ∧
      t5 = ({ t4 with mem := writeBytes t4.mem (t4.reg A2) (env.hash (readBytes t4.mem (t4.reg A0) (t4.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 90 (by decide) hc4 q4 (i := .ecall) (by decide) hexec 0).trans (run_zero _ _), rfl⟩
  have hin : readBytes s.mem (base + BitVec.ofNat 32 ENDS) 2176
      = cat (fun i => chain env.hash (secret env.hash (seedOf m0 base) l i) 15) 67 ++ List.replicate 32 0 := by
    rw [show (2176 : Nat) = 32 * 67 + 32 by rfl, readBytes_append, off_add fit _ _ (by bnd), h.ends, h.mem.ze]
  have mem5 : t5.mem = writeBytes s.mem (base + BitVec.ofNat 32 (TREE + 32 * l))
      (env.hash (cat (fun i => chain env.hash (secret env.hash (seedOf m0 base) l i) 15) 67 ++ List.replicate 32 0)) := by
    rw [ht5, next_mem, a0_4, a1_4, a2_4, mem4, show (BitVec.ofNat 32 2176).toNat = 2176 from rfl, hin]
  have q5 : t5.pc = base + BitVec.ofNat 32 (4 * 91) := by
    rw [ht5]; simp only [next_pc]; rw [q4]; exact pc_next fit 90 (by decide)
  have k5 : ∀ r, t5.reg r = t4.reg r := fun r => by rw [ht5]; rfl
  have K : Keeps (base + BitVec.ofNat 32 (TREE + 32 * l)) 32 s.mem t5.mem := by
    rw [mem5]; exact keeps_writeBytes fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem5' : KMem base m0 t5.mem := h.mem.keeps fit K (by unfold Free; right; right; right; bnd)
  have hc5 : CodeAt t5.mem base kernel := mem5'.code fit hc0
  -- addi a1, x0, 64; addi s3, s3, 32; addi s7, s7, 1; addi t2, x0, 16
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := kernel) hp 91 (by decide) hc5 q5
    (i := .opi .addi A1 0 64) (by decide) rfl
  obtain ⟨t7, f7, q7, n7, u7⟩ := regStep (prog := kernel) hp 92 (by decide) (by rw [n6]; exact hc5) q6
    (i := .opi .addi S3 S3 32) (by decide) rfl
  obtain ⟨t8, f8, q8, n8, u8⟩ := regStep (prog := kernel) hp 93 (by decide) (by rw [n7, n6]; exact hc5) q7
    (i := .opi .addi S7 S7 1) (by decide) rfl
  obtain ⟨t9, f9, q9, n9, u9⟩ := regStep (prog := kernel) hp 94 (by decide) (by rw [n8, n7, n6]; exact hc5) q8
    (i := .opi .addi T2 0 16) (by decide) rfl
  have mem9 : t9.mem = t5.mem := by rw [n9, n8, n7, n6]
  have hc9 : CodeAt t9.mem base kernel := by rw [mem9]; exact hc5
  have k9 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ S3 → r ≠ S7 → r ≠ T2 → t9.reg r = s.reg r :=
    fun r a b c d e f => by rw [reg_kept u9 f, reg_kept u8 e, reg_kept u7 d, reg_kept u6 b, k5, k4 r a b c]
  have v_s7 : t9.reg S7 = BitVec.ofNat 32 (l + 1) := by
    rw [reg_kept u9 (by decide), reg_wrote u8 (by decide), reg_kept u7 (by decide), reg_kept u6 (by decide), k5,
      k4 _ (by decide) (by decide) (by decide), h.s7]
    simp only [aluI]; exact add_small l 1 (by decide)
  have v_t2 : t9.reg T2 = BitVec.ofNat 32 16 := by
    rw [reg_wrote u9 (by decide)]; simp only [aluI, reg_zero]; decide
  have ht : taken .bne (t9.reg S7) (t9.reg T2) = decide (l + 1 < 16) := by
    rw [v_s7, v_t2]; simp only [taken]
    by_cases hl' : l + 1 < 16
    · simp only [hl', decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega),
        Nat.mod_eq_of_lt (by decide)] at this
      omega
    · simp only [hl', decide_false, bne_eq_false_iff_eq]
      rw [show l + 1 = 16 by omega]
  have finish : ∀ s4 : Machine, run env 1 t9 = .running s4 → (∀ r, s4.reg r = t9.reg r) →
      s4.mem = t9.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if l + 1 < 16 then 54 else 96)) →
      ∃ s', run env 10 s = .running s' ∧ LInv env.hash base m0 (l + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ S3 → r ≠ S7 → r ≠ T2 → s4.reg r = s.reg r :=
      fun r a b c d e f => by rw [b4, k9 r a b c d e f]
    have mm : s4.mem = t5.mem := by rw [m4, mem9]
    refine ⟨s4, ?_, p4, ⟨?_, ?_, ?_, ?_, ?_⟩, ?_, ?_, by rw [b4, v_s7], by rw [mm]; exact mem5', ?_⟩
    · exact run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 (run_cons f6 (run_cons f7
        (run_cons f8 (run_cons f9 e4))))))))
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s2]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s4]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.t0]
    · rw [b4, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_kept u7 (by decide), reg_wrote u6 (by decide)]
      simp only [aluI, reg_zero]; decide
    · rw [b4, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_wrote u7 (by decide), reg_kept u6 (by decide),
        k5, k4 _ (by decide) (by decide) (by decide), h.s3]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · intro k hk
      rw [mm]
      by_cases hkl : k < l
      · rw [K.bytes fit (by bnd) (by bnd) (by left; bnd)]; exact h.tree k hkl
      · rw [show k = l by omega, mem5, readBytes_writeBytes]; rfl
  by_cases hl' : l + 1 < 16
  · have e4 : run env 1 t9 = .running (t9.setPc (t9.pc + ((0xfae : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 95 (by decide) hc9 q9 (i := .br .bne S7 T2 0xfae) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl', ↓reduceIte, setPc_pc, q9]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 t9 = .running t9.next :=
      (stepK (prog := kernel) hp 95 (by decide) hc9 q9 (i := .br .bne S7 T2 0xfae) (by decide)
        (exec_br_not (by rw [ht]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl', ↓reduceIte, next_pc, q9]
    exact pc_next fit 95 (by decide)

/-- **One leaf**: `3 + 67 · 71 + 10 = 4770` instructions. -/
theorem leaf_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {l : Nat} (hl : l < 16) {s : Machine} (h : LInv env.hash base m0 l s) :
    ∃ s', run env 4770 s = .running s' ∧ LInv env.hash base m0 (l + 1) s' := by
  obtain ⟨s1, e1, h1⟩ := leaf_start hp hc0 hl h
  obtain ⟨s2, e2, h2⟩ := chain_loop hp hc0 hl h1 67 (Nat.le_refl _)
  obtain ⟨s3, e3, h3⟩ := leaf_end hp hc0 hl h2
  exact ⟨s3, by rw [show 4770 = 3 + (71 * 67 + 10) by rfl, run_add_running e1, run_add_running e2, e3], h3⟩

theorem leaf_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : LInv env.hash base m0 0 s) :
    ∀ j ≤ 16, ∃ s', run env (4770 * j) s = .running s' ∧ LInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := leaf_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 4770 * (j + 1) = 4770 * j + 4770 by omega, run_add_running e, e'], hs''⟩

/-! ## The tree -/

/-- At the top of tree step `t` — or, once `t` is 15, at the end: nodes
`0..15+t` written, each the reference's. -/
structure TInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (t : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if t < 15 then 100 else 105))
  a0 : s.reg A0 = base + BitVec.ofNat 32 (TREE + 64 * t)
  a2 : s.reg A2 = base + BitVec.ofNat 32 (TREE + 512 + 32 * t)
  s8 : s.reg S8 = BitVec.ofNat 32 (15 - t)
  t0 : s.reg T0 = 0
  a1 : s.reg A1 = BitVec.ofNat 32 64
  out : Out base m0 s.mem
  nodes : ∀ n < 16 + t, readBytes s.mem (base + BitVec.ofNat 32 (TREE + 32 * n)) 32 = flat H (seedOf m0 base) n

/-- Four instructions from the last leaf to the first tree step. -/
theorem to_tree {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : LInv env.hash base m0 16 s) :
    ∃ s', run env 4 s = .running s' ∧ TInv env.hash base m0 0 s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 96) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 96 (by decide) hcode hpc
    (i := .lui T1 3) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 97 (by decide) (by rw [n1]; exact hcode) q1
    (i := .op .add A0 S0 T1) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 98 (by decide) (by rw [n2, n1]; exact hcode) q2
    (i := .opi .addi A2 S3 0) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 99 (by decide) (by rw [n3, n2, n1]; exact hcode) q3
    (i := .opi .addi S8 0 15) (by decide) rfl
  have mem4 : t4.mem = s.mem := by rw [n4, n3, n2, n1]
  refine ⟨t4, run_cons f1 (run_cons f2 (run_cons f3 f4)), ⟨by rw [q4]; rfl, ?_, ?_, ?_, ?_, ?_,
    by rw [mem4]; exact h.mem.out, ?_⟩⟩
  · rw [reg_kept u4 (by decide), reg_kept u3 (by decide), reg_wrote u2 (by decide), reg_wrote u1 (by decide),
      reg_kept u1 (by decide), h.rg.s0]
    simp only [aluR]; rfl
  · rw [reg_kept u4 (by decide), reg_wrote u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.s3]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [reg_wrote u4 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide),
      h.rg.t0]
  · rw [reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.a1]
  · intro n hn
    rw [mem4, h.tree n (by omega)]
    unfold flat; rw [ifT (by omega)]; rfl

/-- **One tree step**: five instructions, and node `16 + t` is HASH of nodes
`2t` and `2t + 1`. -/
theorem tree_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {t : Nat} (ht : t < 15) {s : Machine} (h : TInv env.hash base m0 t s) :
    ∃ s', run env 5 s = .running s' ∧ TInv env.hash base m0 (t + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 100) := by rw [h.pc]; simp [ht]
  have hcode : CodeAt s.mem base kernel :=
    h.out.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc0
  have hexec := exec_hash (env := env) (s := s) h.t0 (by rw [h.a1]; rfl)
    (by rw [h.a0]; exact align_off hp.align fit _ (by bnd) (by bnd))
    (by rw [h.a2]; exact align_off hp.align fit _ (by bnd) (by bnd))
    (by rw [h.a0, h.a1]; exact ok_off hp _ _ (by bnd) (by rw [show (BitVec.ofNat 32 64).toNat = 64 from rfl]; bnd))
    (by rw [h.a2]; exact ok_off hp _ _ (by bnd) (by bnd))
  obtain ⟨t1, f1, ht1⟩ : ∃ t1, run env 1 s = .running t1 ∧
      t1 = ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 100 (by decide) hcode hpc (i := .ecall) (by decide) hexec 0).trans (run_zero _ _), rfl⟩
  have hin : readBytes s.mem (base + BitVec.ofNat 32 (TREE + 64 * t)) 64
      = flat env.hash (seedOf m0 base) (2 * t) ++ flat env.hash (seedOf m0 base) (2 * t + 1) := by
    rw [show (64 : Nat) = 32 + 32 by rfl, readBytes_append, off_add fit _ _ (by bnd),
      show TREE + 64 * t = TREE + 32 * (2 * t) by omega, show TREE + 32 * (2 * t) + 32 = TREE + 32 * (2 * t + 1) by omega,
      h.nodes _ (by omega), h.nodes _ (by omega)]
  have mem1 : t1.mem = writeBytes s.mem (base + BitVec.ofNat 32 (TREE + 512 + 32 * t))
      (env.hash (flat env.hash (seedOf m0 base) (2 * t) ++ flat env.hash (seedOf m0 base) (2 * t + 1))) := by
    rw [ht1, next_mem, h.a0, h.a1, h.a2, show (BitVec.ofNat 32 64).toNat = 64 from rfl, hin]
  have q1 : t1.pc = base + BitVec.ofNat 32 (4 * 101) := by
    rw [ht1]; simp only [next_pc]; rw [hpc]; exact pc_next fit 100 (by decide)
  have k1 : ∀ r, t1.reg r = s.reg r := fun r => by rw [ht1]; rfl
  have K : Keeps (base + BitVec.ofNat 32 (TREE + 512 + 32 * t)) 32 s.mem t1.mem := by
    rw [mem1]; exact keeps_writeBytes fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have out1 : Out base m0 t1.mem := h.out.right fit K (by bnd) (by bnd) (by decide)
  have hc1 : CodeAt t1.mem base kernel :=
    out1.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc0
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 101 (by decide) hc1 q1
    (i := .opi .addi A0 A0 64) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 102 (by decide) (by rw [n2]; exact hc1) q2
    (i := .opi .addi A2 A2 32) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 103 (by decide) (by rw [n3, n2]; exact hc1) q3
    (i := .opi .addi S8 S8 0xfff) (by decide) rfl
  have mem4 : t4.mem = t1.mem := by rw [n4, n3, n2]
  have hc4 : CodeAt t4.mem base kernel := by rw [mem4]; exact hc1
  have v_s8 : t4.reg S8 = BitVec.ofNat 32 (15 - (t + 1)) := by
    rw [reg_wrote u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), k1, h.s8]
    simp only [aluI]
    rw [show 15 - t = (15 - (t + 1)) + 1 by omega]
    exact dec_one _ (by omega)
  have htk : taken .bne (t4.reg S8) (t4.reg 0) = decide (t + 1 < 15) := by
    rw [v_s8, reg_zero]; simp only [taken]
    by_cases hl' : t + 1 < 15
    · simp only [hl', decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this
      have : (0 : Word).toNat = 0 := rfl
      omega
    · simp only [hl', decide_false, bne_eq_false_iff_eq]
      rw [show 15 - (t + 1) = 0 by omega]; rfl
  have finish : ∀ s5 : Machine, run env 1 t4 = .running s5 → (∀ r, s5.reg r = t4.reg r) →
      s5.mem = t4.mem → s5.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 15 then 100 else 105)) →
      ∃ s', run env 5 s = .running s' ∧ TInv env.hash base m0 (t + 1) s' := by
    intro s5 e5 b5 m5 p5
    refine ⟨s5, run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 e5))), ⟨p5, ?_, ?_, by rw [b5, v_s8], ?_, ?_,
      by rw [m5, mem4]; exact out1, ?_⟩⟩
    · rw [b5, reg_kept u4 (by decide), reg_kept u3 (by decide), reg_wrote u2 (by decide), k1, h.a0]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · rw [b5, reg_kept u4 (by decide), reg_wrote u3 (by decide), reg_kept u2 (by decide), k1, h.a2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · rw [b5, reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), k1, h.t0]
    · rw [b5, reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), k1, h.a1]
    · intro n hn
      rw [m5, mem4]
      by_cases hnt : n < 16 + t
      · rw [K.bytes fit (by bnd) (by bnd) (by left; bnd)]; exact h.nodes n hnt
      · rw [show n = 16 + t by omega, show TREE + 32 * (16 + t) = TREE + 512 + 32 * t by omega, mem1,
          readBytes_writeBytes, flat_step _ _ ht]
        rfl
  by_cases hl' : t + 1 < 15
  · have e5 : run env 1 t4 = .running (t4.setPc (t4.pc + ((0xff8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 104 (by decide) hc4 q4 (i := .br .bne S8 0 0xff8) (by decide)
        (exec_br_taken (by rw [htk]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e5 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl', ↓reduceIte, setPc_pc, q4]
    rw [BitVec.add_assoc]
    congr 1
  · have e5 : run env 1 t4 = .running t4.next :=
      (stepK (prog := kernel) hp 104 (by decide) hc4 q4 (i := .br .bne S8 0 0xff8) (by decide)
        (exec_br_not (by rw [htk]; simp [hl'])) 0).trans (run_zero _ _)
    refine finish _ e5 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl', ↓reduceIte, next_pc, q4]
    exact pc_next fit 104 (by decide)

theorem tree_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : TInv env.hash base m0 0 s) :
    ∀ j ≤ 15, ∃ s', run env (5 * j) s = .running s' ∧ TInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := tree_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 5 * (j + 1) = 5 * j + 5 by omega, run_add_running e, e'], hs''⟩

/-! ## The whole kernel -/

/-- Everything up to the `ecall` that halts: 76455 instructions, whatever the
seed; then HALT with 0, the whole tree written, nothing outside the two
places changed. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env 76455 s = .running s1 ∧ run env 1 s1 = .halted 0 s2
      ∧ Out base s.mem s2.mem
      ∧ ∀ n < 31, readBytes s2.mem (base + BitVec.ofNat 32 (TREE + 32 * n)) 32 = flat env.hash (seedOf s.mem base) n := by
  have fit := hp.fit
  obtain ⟨s0, e0, p0, rg, h3, h7, ha1, mem⟩ := setup_run hp s hpc hcode
  have linv : LInv env.hash base s.mem 0 s0 :=
    ⟨by rw [p0]; rfl, rg, ha1, by rw [h3]; rfl, by rw [h7]; rfl, mem, fun k hk => absurd hk (by omega)⟩
  obtain ⟨sl, el, linv'⟩ := leaf_loop hp hcode linv 16 (Nat.le_refl _)
  obtain ⟨st, et, tinv⟩ := to_tree hp hcode linv'
  obtain ⟨sv, ev, tinv'⟩ := tree_loop hp hcode tinv 15 (Nat.le_refl _)
  have hpc' : sv.pc = base + BitVec.ofNat 32 (4 * 105) := by rw [tinv'.pc]; rfl
  have hc : CodeAt sv.mem base kernel :=
    tinv'.out.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hcode
  obtain ⟨u1, g1, o1, l1, v1⟩ := regStep (prog := kernel) hp 105 (by decide) hc hpc'
    (i := .opi .addi A0 0 0) (by decide) rfl
  obtain ⟨u2, g2, o2, l2, v2⟩ := regStep (prog := kernel) hp 106 (by decide) (by rw [l1]; exact hc) o1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : u2.reg T0 = 1 := by rw [reg_wrote v2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : u2.reg A0 = 0 := by
    rw [reg_kept v2 (by decide), reg_wrote v1 (by decide)]; simp only [aluI, reg_zero]; decide
  refine ⟨u2, u2, ?_, ?_, by rw [l2, l1]; exact tinv'.out, fun n hn => by rw [l2, l1]; exact tinv'.nodes n (by omega)⟩
  · rw [show 76455 = 54 + (4770 * 16 + (4 + (5 * 15 + (1 + 1)))) by rfl, run_add_running e0, run_add_running el,
      run_add_running et, run_add_running ev]
    exact run_cons g1 g2
  rw [← a0]
  exact (step_of_code (k := 107) (by rw [kernel_length]; decide) (by rw [l2, l1]; exact hc)
      (by rw [o2])
      (by rw [o2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [o2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[107]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-- **The key generator.** From `base`, with the kernel's 432 bytes there, it
halts with 0 after exactly 76456 instructions — the count is the same for
every seed — having written the tree of the seed at `0x3000`: node `n` the
reference's `flat n`, for all 31. Nothing outside the PRF input and chain
buffer (`0x1040`, 128 bytes) and the ends and tree (`0x2000` to `0x33e0`)
changes; the seed is outside both. -/
theorem generates {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    (∃ s1, run env 76455 s = .running s1) ∧
    ∃ s', run env 76456 s = .halted 0 s' ∧ Out base s.mem s'.mem
      ∧ ∀ n < 31, readBytes s'.mem (base + BitVec.ofNat 32 (TREE + 32 * n)) 32 = flat env.hash (seedOf s.mem base) n := by
  obtain ⟨s1, s2, e, e1, ho, hn⟩ := to_the_ecall hp s hpc hcode
  exact ⟨⟨s1, e⟩, s2, by rw [show 76456 = 76455 + 1 by rfl, run_add_running e, e1], ho, hn⟩

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction
`k`. 108 cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- Any image that begins with the kernel's 432 bytes holds the kernel. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 432 ≤ img.size)
    (himg : ∀ d (h : d < 432), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

end Keygen
end Rv32.Mss
