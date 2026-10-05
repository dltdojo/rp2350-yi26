/-
SPDX-License-Identifier: Apache-2.0

# MSS: the signer

exp213's second kernel. Given a message, a leaf index `l`, the seed and the
tree the key generator (`lean/Rv32/MssKeygen.lean`) wrote, it writes a
signature where exp206's verifier (`lean/Rv32/Mss.lean`) reads one: chain `i`
of key `l` walked `dᵢ` steps at `0x2000 + 32 i`, the path's four siblings at
`0x4000` and the root at `0x4080`. Its first 46 instructions are exp205's —
setup, the message's digits and the checksum's, the chains' registers — so
the digits it signs are the ones the verifier computes.
-/
import Rv32.MssKeygen

set_option maxRecDepth 20000

namespace Rv32.Mss
open Rv32 Rv32.Wots

namespace Sign

/-- The seed into the PRF input, its zero half, `l` into byte 32 of it. -/
def seed : List Instr := [ .opi .addi S8 S3 64, .opi .addi S4 S3 128 ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 S8 (BitVec.ofNat 12 (4 * j)), .st .sw S4 T4 (BitVec.ofNat 12 (4 * j))]) ++
  (List.range 8).map (fun j => .st .sw S4 0 (BitVec.ofNat 12 (32 + 4 * j))) ++
  [ .ld .lbu S9 S3 32, .st .sb S4 S9 32, .opi .addi S8 0 0 ]

/-- Chain `i`: its secret into the buffer, `dᵢ` steps along it — none when the
digit is 0 — and the value into the signature. -/
def chainBody : List Instr := [
  .st .sb S4 S8 33, .opi .addi A0 S4 0, .ecall, .opi .addi A0 S5 0,
  .ld .lbu T3 A4 0, .br .beq T3 0 8,
  .ecall, .opi .addi T3 T3 0xfff, .br .bne T3 0 0xffc ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 S5 (BitVec.ofNat 12 (4 * j)), .st .sw S1 T4 (BitVec.ofNat 12 (4 * j))]) ++
  [ .opi .addi S1 S1 32, .opi .addi A4 A4 1, .opi .addi S8 S8 1, .br .bne A4 S7 0xfc8 ]

/-- The path: at level `j`, the sibling of `l`'s ancestor, `(l >> j) ^ 1`
nodes into the level, which starts `512 + 256 + ...` bytes into the tree;
then the root. Then HALT with 0. -/
def auth : List Instr := [
  .lui T1 5, .op .add S10 S0 T1, .lui T1 4, .op .add S2 S0 T1, .opi .addi S11 0 512,
  .opi .addi A3 S9 0, .opi .addi A6 0 4,
  .opi .xori T1 A3 1, .sh .slli T1 T1 5, .op .add A5 S10 T1 ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 A5 (BitVec.ofNat 12 (4 * j)), .st .sw S2 T4 (BitVec.ofNat 12 (4 * j))]) ++
  [ .opi .addi S2 S2 32, .op .add S10 S10 S11, .sh .srli S11 S11 1, .sh .srli A3 A3 1,
    .opi .addi A6 A6 0xfff, .br .bne A6 0 0xfd0 ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 S10 (BitVec.ofNat 12 (4 * j)), .st .sw S2 T4 (BitVec.ofNat 12 (4 * j))]) ++
  [ .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := (Wots.head.take 46) ++ seed ++ chainBody ++ auth

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 155 := by rfl

/-- The kernel starts with `head`'s first 46 instructions, so what
`lean/Rv32/Wots.lean` proves of them holds of it. -/
theorem starts : Starts 46 kernel where
  pre := by decide
  long := by rw [kernel_length]; decide
  below := by rw [kernel_length]; decide

/-! ## Where everything is

Offsets from `base`: exp205's message (`MSG`), signature (`SIG`) and scratch
(`SCR`), exp206's index (`IDX`), path (`AUTH`) and root (`ROOT`), and these. -/

/-- The seed, 32 bytes. -/
def SEED : Nat := 0x1040
/-- The PRF input, 64 bytes: the seed, `l`, `i`, 30 zeros. -/
def PRF : Nat := 0x1080
/-- The key generator's tree, 31 nodes of 32 bytes. -/
def TREE : Nat := 0x5000

/-- Where it writes: from the PRF input to the root's last byte, and scratch. -/
abbrev Out (base : Word) (m m' : Word → Byte) : Prop := Within base PRF 0x3080 SCR 131 m m'

def seedOf (m : Word → Byte) (base : Word) : List Byte := readBytes m (base + BitVec.ofNat 32 SEED) 32

/-- Where level `j` starts in the tree, in nodes: 0, 16, 24, 28, 30. -/
def lvl (j : Nat) : Nat := 32 - 32 / 2 ^ j

/-- The node the path takes at level `j` for index `l`, read from the tree. -/
def pathAt (m : Word → Byte) (base : Word) (l j : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (TREE + 32 * (lvl j + sib (l / 2 ^ j)))) 32

/-- The root, read from the tree. -/
def rootIn (m : Word → Byte) (base : Word) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (TREE + 32 * 30)) 32

/-- How many HASH calls the signer's walks make: `Σ dᵢ`. -/
def dsum (m : Word → Byte) (base : Word) : Nat :=
  ((List.range 67).map fun i => digit m base i).sum

/-! ## The bytes are the kernel, instruction by instruction -/

theorem at_seed : ∀ j < 8, kernel.getD (48 + 2 * j) .ecall = .ld .lw T4 S8 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (48 + 2 * j + 1) .ecall = .st .sw S4 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_zp : ∀ j < 8, kernel.getD (64 + j) .ecall = .st .sw S4 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem at_store : ∀ j < 8, kernel.getD (84 + 2 * j) .ecall = .ld .lw T4 S5 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (84 + 2 * j + 1) .ecall = .st .sw S1 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_path : ∀ j < 8, kernel.getD (114 + 2 * j) .ecall = .ld .lw T4 A5 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (114 + 2 * j + 1) .ecall = .st .sw S2 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_root : ∀ j < 8, kernel.getD (136 + 2 * j) .ecall = .ld .lw T4 S10 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (136 + 2 * j + 1) .ecall = .st .sw S2 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide

/-! ## What holds from the seed's copy on -/

local macro "bnd" : tactic =>
  `(tactic| ((try simp only [PRF, SEED, TREE, MSG, IDX, SIG, AUTH, ROOT, SCR]) <;> omega))

/-- Memory from the PRF input's setup on: written only in its two places,
the seed and 30 zeros in the PRF input, and exp205's scratch — the buffer's
zero half and the 67 digits. -/
structure SMem (base : Word) (m0 m : Word → Byte) : Prop where
  out : Out base m0 m
  seed : readBytes m (base + BitVec.ofNat 32 PRF) 32 = seedOf m0 base
  zp : readBytes m (base + BitVec.ofNat 32 (PRF + 34)) 30 = List.replicate 30 0
  tail : ∀ d < 32, m (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0
  dig : ∀ d < 67, m (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d

/-- Where a step may write without disturbing `SMem`: bytes 32 and 33 of the
PRF input, the buffer's first half, the signature, the path and the root. -/
def Free (S N : Nat) : Prop :=
  (PRF + 32 ≤ S ∧ S + N ≤ PRF + 34) ∨ (SCR ≤ S ∧ S + N ≤ SCR + 32)
    ∨ (SIG ≤ S ∧ S + N ≤ SIG + 2144) ∨ (AUTH ≤ S ∧ S + N ≤ ROOT + 32)

theorem SMem.keeps {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m m' : Word → Byte}
    (h : SMem base m0 m) {S N : Nat} (hk : Keeps (base + BitVec.ofNat 32 S) N m m') (hin : Free S N) :
    SMem base m0 m' := by
  unfold Free at hin
  simp only [PRF, SCR, SIG, AUTH, ROOT] at hin
  have hSN : S + N < 0x10000 := by omega
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · rcases hin with hin | hin | hin | hin
    · exact h.out.left hfit hk (by bnd) (by bnd) (by decide)
    · exact h.out.right hfit hk (by bnd) (by bnd) (by decide)
    · exact h.out.left hfit hk (by bnd) (by bnd) (by decide)
    · exact h.out.left hfit hk (by bnd) (by bnd) (by decide)
  · rw [hk.bytes hfit hSN (by bnd) (by bnd)]; exact h.seed
  · rw [hk.bytes hfit hSN (by bnd) (by bnd)]; exact h.zp
  · intro d hd
    rw [hk.off hfit hSN (by bnd) (by bnd)]; exact h.tail d hd
  · intro d hd
    rw [hk.off hfit hSN (by bnd) (by bnd)]; exact h.dig d hd

theorem SMem.code {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte}
    (h : SMem base m0 m) (hc : CodeAt m0 base kernel) : CodeAt m base kernel :=
  h.out.code hfit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc

/-- At the top of chain `i` — or, once `i` is 67, at the path: chains
`0..i-1` signed, each the secret walked its digit's steps. -/
structure SInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (i : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 67 then 75 else 104))
  s0 : s.reg S0 = base
  s4 : s.reg S4 = base + BitVec.ofNat 32 PRF
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR
  s7 : s.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67)
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SIG + 32 * i)
  a4 : s.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + i)
  s8 : s.reg S8 = BitVec.ofNat 32 i
  s9 : s.reg S9 = BitVec.ofNat 32 (idx m0 base)
  t0 : s.reg T0 = 0
  a1 : s.reg A1 = BitVec.ofNat 32 64
  a2 : s.reg A2 = base + BitVec.ofNat 32 SCR
  mem : SMem base m0 s.mem
  pl : s.mem (base + BitVec.ofNat 32 (PRF + 32)) = BitVec.ofNat 8 (idx m0 base)
  sig : ∀ k < i, sigAt s.mem base k = chain H (secret H (seedOf m0 base) (idx m0 base) k) (digit m0 base k)

theorem idx_lt (m : Word → Byte) (base : Word) : idx m base < 256 := (m (base + BitVec.ofNat 32 IDX)).isLt

/-- exp205's setup, digits and checksum, then 29 instructions: the seed into
the PRF input, its zero half, `l` into it — 416 in all, to the first chain. -/
theorem to_chains {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 416 s = .running s' ∧ SInv env.hash base s.mem 0 s' := by
  have fit := hp.fit
  obtain ⟨s22, e22, dinv, rg, h1, -, -⟩ := front starts hp s hpc hcode
  obtain ⟨sd, ed, dinv'⟩ := digits_loop starts hp
    (keeps_overlay hp.fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
    (code_of_overlay hp.fit hcode (by rw [kernel_length]; decide) (by decide) _) dinv 32 (Nat.le_refl _)
  obtain ⟨sm, em, pm, chm, frm⟩ := middle starts hp hcode dinv' rg h1
  have km : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → r ≠ S7 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 →
      sm.reg r = s22.reg r := frm
  have s3m : sm.reg S3 = base + BitVec.ofNat 32 MSG := by
    rw [km _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide), rg.s3]
  have s0m : sm.reg S0 = base := by
    rw [km _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide), rg.s0]
  have Km : Keeps (base + BitVec.ofNat 32 SCR) 131 s.mem sm.mem := chm.out
  have hcm : CodeAt sm.mem base kernel :=
    Km.code fit (by bnd) (by rw [kernel_length]; bnd) hcode
  -- addi s8, s3, 64; addi s4, s3, 128
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 46 (by decide) hcm pm
    (i := .opi .addi S8 S3 64) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 47 (by decide) (by rw [n1]; exact hcm) q1
    (i := .opi .addi S4 S3 128) (by decide) rfl
  have k2 : ∀ r, r ≠ S8 → r ≠ S4 → t2.reg r = sm.reg r := fun r a b => by rw [reg_kept u2 b, reg_kept u1 a]
  have hc2 : CodeAt t2.mem base kernel := by rw [n2, n1]; exact hcm
  have v_s4 : t2.reg S4 = base + BitVec.ofNat 32 PRF := by
    rw [reg_wrote u2 (by decide), reg_kept u1 (by decide), s3m]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (128 : BitVec 12) = BitVec.ofNat 32 128 by decide, off_add fit _ _ (by bnd)]; rfl
  -- the seed into the PRF input; its zero half
  obtain ⟨c1, ec1, pc1, mc1, rc1⟩ := (copy_words (prog := kernel) hp (k0 := 48) (rs := S8) (rd := S4) (t := T4)
    (src := SEED) (dst := PRF) at_seed (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide) (by decide)
    q2 hc2
    (by rw [reg_kept u2 (by decide), reg_wrote u1 (by decide), s3m]
        simp only [aluI]
        rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide, off_add fit _ _ (by bnd)]
        rfl) v_s4) 8 (Nat.le_refl _)
  have hcc1 : CodeAt c1.mem base kernel := by
    rw [mc1]; exact code_of_overlay fit hc2 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨z1, ez1, pz1, mz1, rz1⟩ := (zero_words (prog := kernel) hp (k0 := 64) (rd := S4) (o := 32) (a := PRF)
    at_zp (by rw [kernel_length]; decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide)
    pc1 hcc1 (by rw [rc1 _ (by decide), v_s4])) 8 (Nat.le_refl _)
  have hcz1 : CodeAt z1.mem base kernel := by
    rw [mz1]; exact code_of_overlay fit hcc1 (by rw [kernel_length]; decide) (by decide) _
  have K1 : Keeps (base + BitVec.ofNat 32 PRF) 32 t2.mem c1.mem := by
    rw [mc1]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have K2 : Keeps (base + BitVec.ofNat 32 (PRF + 32)) 32 c1.mem z1.mem := by
    rw [mz1]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem2 : t2.mem = sm.mem := by rw [n2, n1]
  -- lbu s9, 32(s3): the index
  have kz : ∀ r, r ≠ S8 → r ≠ S4 → r ≠ T4 → z1.reg r = sm.reg r := fun r a b c => by
    rw [rz1, rc1 r c, k2 r a b]
  obtain ⟨t3, f3, q3, n3, u3⟩ := lbuStep (prog := kernel) hp 72 (by decide) hcz1 pz1
    (rd := S9) (rs1 := S3) (imm := 32) (by decide) IDX
    (by rw [kz _ (by decide) (by decide) (by decide), s3m,
      show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]; rfl)
    (by bnd)
  have vidx : z1.mem (base + BitVec.ofNat 32 IDX) = s.mem (base + BitVec.ofNat 32 IDX) := by
    rw [K2.off fit (by bnd) (by bnd) (by left; bnd), K1.off fit (by bnd) (by bnd) (by left; bnd), mem2,
      Km.off fit (by bnd) (by bnd) (by left; bnd)]
  have v_s9 : t3.reg S9 = BitVec.ofNat 32 (idx s.mem base) := by
    rw [reg_wrote u3 (by decide), vidx]; rfl
  -- sb s9, 32(s4); addi s8, x0, 0
  obtain ⟨t4, f4, q4, n4, u4⟩ := sbStep (prog := kernel) hp 73 (by decide) (by rw [n3]; exact hcz1) q3
    (rs1 := S4) (rs2 := S9) (imm := 32) (by decide) (PRF + 32)
    (by rw [reg_kept u3 (by decide), rz1, rc1 _ (by decide), v_s4,
      show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]) (by bnd)
  have vb : BitVec.ofNat 8 (t3.reg S9).toNat = BitVec.ofNat 8 (idx s.mem base) := by
    rw [v_s9, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by have := idx_lt s.mem base; omega)]
  rw [vb, n3] at n4
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 74 (by decide)
    (by rw [n4]; exact code_of_writeByte fit hcz1 (by rw [kernel_length]; bnd) (by bnd) _) q4
    (i := .opi .addi S8 0 0) (by decide) rfl
  have K3 : Keeps (base + BitVec.ofNat 32 (PRF + 32)) 1 z1.mem t5.mem := by
    rw [n5, n4]; exact keeps_writeByte fit _ _ (Nat.le_refl _) (by omega) (by bnd)
  have k5 : ∀ r, r ≠ S8 → r ≠ S4 → r ≠ T4 → r ≠ S9 → t5.reg r = sm.reg r := fun r a b c d => by
    rw [reg_kept u5 a, u4, reg_kept u3 d, kz r a b c]
  have hk5 : ∀ r, r ≠ S8 → r ≠ S4 → r ≠ T4 → r ≠ S9 → r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → r ≠ S7 →
      r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → t5.reg r = s22.reg r := fun r a b c d e f g h i j k l m n => by
    rw [k5 r a b c d, km r e f g h i j k l m n]
  refine ⟨t5, ?_, ⟨by rw [q5]; rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ⟨?_, ?_, ?_, ?_, ?_⟩, ?_,
    fun k hk => absurd hk (by omega)⟩⟩
  · rw [show 416 = 22 + (11 * 32 + (13 + (1 + (1 + (2 * 8 + (8 + (1 + (1 + 1)))))))) by rfl,
      run_add_running e22, run_add_running ed, run_add_running em]
    have ew : run env 27 t2 = .running t5 := by
      rw [show 27 = 2 * 8 + (8 + (1 + (1 + 1))) by rfl, run_add_running ec1, run_add_running ez1]
      exact run_cons f3 (run_cons f4 f5)
    exact run_cons f1 (run_cons f2 ew)
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), s0m]
  · rw [reg_kept u5 (by decide), u4, reg_kept u3 (by decide), rz1, rc1 _ (by decide), v_s4]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.s5]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.s7]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.s1]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.a4]
  · rw [reg_wrote u5 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_kept u5 (by decide), u4, v_s9]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.t0]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.a1]
  · rw [k5 _ (by decide) (by decide) (by decide) (by decide), chm.a2]
  · exact ((((Within.refl _ _ _ _ _ _).right fit Km (by bnd) (by bnd) (by decide)).left fit
      (by rw [← mem2]; exact K1) (by bnd) (by bnd) (by decide)).left fit K2 (by bnd) (by bnd) (by decide)).left fit K3
      (by bnd) (by bnd) (by decide)
  · rw [K3.bytes fit (by bnd) (by bnd) (by left; bnd), K2.bytes fit (by bnd) (by bnd) (by left; bnd), mc1]
    unfold seedOf
    rw [← Km.bytes fit (by bnd) (by bnd) (by left; bnd), ← mem2]
    apply readBytes_shift
    intro d hd
    rw [off_add fit _ _ (by bnd), overlay_off_in fit _ _ (by bnd) (by omega) (by omega),
      show PRF + d - PRF = d by omega, off_add fit _ _ (by bnd)]
  · rw [K3.bytes fit (by bnd) (by bnd) (by right; bnd), mz1]
    exact readBytes_zeros fit _ (by bnd) (by bnd) (by bnd)
  · intro d hd
    rw [K3.off fit (by bnd) (by bnd) (by right; bnd), K2.off fit (by bnd) (by bnd) (by right; bnd),
      K1.off fit (by bnd) (by bnd) (by right; bnd), mem2]
    exact chm.tail d hd
  · intro d hd
    rw [K3.off fit (by bnd) (by bnd) (by right; bnd), K2.off fit (by bnd) (by bnd) (by right; bnd),
      K1.off fit (by bnd) (by bnd) (by right; bnd), mem2]
    exact chm.dig d hd
  · rw [n5, n4]; simp [writeByte]

/-! ## One chain -/

/-- **One chain**: `26 + 3 dᵢ` instructions — the secret, `dᵢ` steps along its
chain, the value into the signature. -/
theorem chain_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 67) {s : Machine} (h : SInv env.hash base m0 i s) :
    ∃ s', run env (26 + 3 * digit m0 base i) s = .running s' ∧ SInv env.hash base m0 (i + 1) s' := by
  have fit := hp.fit
  have hd := digit_lt m0 base i
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 75) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  -- sb s8, 33(s4): i into the PRF input
  obtain ⟨t1, f1, q1, n1, u1⟩ := sbStep (prog := kernel) hp 75 (by decide) hcode hpc
    (rs1 := S4) (rs2 := S8) (imm := 33) (by decide) (PRF + 33)
    (by rw [h.s4, show BitVec.signExtend 32 (33 : BitVec 12) = BitVec.ofNat 32 33 by decide,
      off_add fit _ _ (by bnd)]) (by bnd)
  have vi : BitVec.ofNat 8 (s.reg S8).toNat = BitVec.ofNat 8 i := by
    rw [h.s8, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
  rw [vi] at n1
  have K1 : Keeps (base + BitVec.ofNat 32 (PRF + 33)) 1 s.mem t1.mem := by
    rw [n1]; exact keeps_writeByte fit _ _ (Nat.le_refl _) (by omega) (by bnd)
  have mem1 : SMem base m0 t1.mem := h.mem.keeps fit K1 (by unfold Free; left; bnd)
  have hc1 : CodeAt t1.mem base kernel := mem1.code fit hc0
  -- addi a0, s4, 0; ecall: the secret, into the buffer
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 76 (by decide) hc1 q1
    (i := .opi .addi A0 S4 0) (by decide) rfl
  have a0_2 : t2.reg A0 = base + BitVec.ofNat 32 PRF := by
    rw [reg_wrote u2 (by decide), u1, h.s4]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  have k2 : ∀ r, r ≠ A0 → t2.reg r = s.reg r := fun r a => by rw [reg_kept u2 a, u1]
  have hexec := exec_hash (env := env) (s := t2) (by rw [k2 _ (by decide), h.t0])
    (by rw [k2 _ (by decide), h.a1]; rfl)
    (by rw [a0_2]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [k2 _ (by decide), h.a2]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [a0_2, k2 _ (by decide), h.a1]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [k2 _ (by decide), h.a2]; exact ok_off hp _ _ (by decide) (by decide))
  obtain ⟨t3, f3, ht3⟩ : ∃ t3, run env 1 t2 = .running t3 ∧
      t3 = ({ t2 with mem := writeBytes t2.mem (t2.reg A2) (env.hash (readBytes t2.mem (t2.reg A0) (t2.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 77 (by decide) (by rw [n2]; exact hc1) q2 (i := .ecall) (by decide)
      hexec 0).trans (run_zero _ _), rfl⟩
  have mem3 : t3.mem = writeBytes t1.mem (base + BitVec.ofNat 32 SCR)
      (env.hash (seedOf m0 base ++ [BitVec.ofNat 8 (idx m0 base), BitVec.ofNat 8 i] ++ List.replicate 30 0)) := by
    rw [ht3, next_mem, a0_2, k2 _ (by decide), k2 _ (by decide), h.a1, h.a2, n2,
      show (BitVec.ofNat 32 64).toNat = 64 from rfl, n1, prf_bytes fit (by bnd) h.mem.seed h.pl h.mem.zp]
  have q3 : t3.pc = base + BitVec.ofNat 32 (4 * 78) := by
    rw [ht3]; simp only [next_pc]; rw [q2]; exact pc_next fit 77 (by decide)
  have k3 : ∀ r, t3.reg r = t2.reg r := fun r => by rw [ht3]; rfl
  have K3 : Keeps (base + BitVec.ofNat 32 SCR) 32 t1.mem t3.mem := by
    rw [mem3]; exact keeps_writeBytes fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem3' : SMem base m0 t3.mem := mem1.keeps fit K3 (by unfold Free; right; left; bnd)
  have hc3 : CodeAt t3.mem base kernel := mem3'.code fit hc0
  -- addi a0, s5, 0; lbu t3, 0(a4): the digit
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 78 (by decide) hc3 q3
    (i := .opi .addi A0 S5 0) (by decide) rfl
  obtain ⟨t5, f5, q5, n5, u5⟩ := lbuStep (prog := kernel) hp 79 (by decide) (by rw [n4]; exact hc3) q4
    (rd := T3) (rs1 := A4) (imm := 0) (by decide) (SCR + 64 + i)
    (by rw [reg_kept u4 (by decide), k3, k2 _ (by decide), h.a4,
      show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _) (by bnd)
  have mem5 : t5.mem = t3.mem := by rw [n5, n4]
  have hc5 : CodeAt t5.mem base kernel := by rw [mem5]; exact hc3
  have k5 : ∀ r, r ≠ A0 → r ≠ T3 → t5.reg r = s.reg r := fun r a b => by
    rw [reg_kept u5 b, reg_kept u4 a, k3, k2 r a]
  have v_t3 : t5.reg T3 = BitVec.ofNat 32 (digit m0 base i) := by
    rw [reg_wrote u5 (by decide), n4, mem3'.dig i hi]
    simp only [dg, BitVec.toNat_ofNat]
    rw [Nat.mod_eq_of_lt (by omega)]
  have a0_5 : t5.reg A0 = base + BitVec.ofNat 32 SCR := by
    rw [reg_kept u5 (by decide), reg_wrote u4 (by decide), k3, k2 _ (by decide), h.s5]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  -- skip, or walk dᵢ steps
  obtain ⟨t6, f6, q6, K6, b6, k6⟩ := skip_or_walk_at (prog := kernel) hp (by rw [kernel_length]; decide)
    (k0 := 80) (B := SCR) (by decide) (by decide) (by decide) (by decide) (by rw [kernel_length]; decide)
    (by bnd) (by bnd) (by rw [kernel_length]; bnd) (M := t5.mem) hc5
    (fun d hd => by rw [Nat.add_assoc]; exact mem5 ▸ (by rw [← Nat.add_assoc]; exact mem3'.tail d hd))
    (x := secret env.hash (seedOf m0 base) (idx m0 base) i) (digit m0 base i) (by omega) q5 v_t3
    (by rw [k5 _ (by decide) (by decide), h.t0]) a0_5 (by rw [k5 _ (by decide) (by decide), h.a1])
    (by rw [k5 _ (by decide) (by decide), h.a2]) (Keeps.refl _ _ _)
    (by rw [mem5, mem3, readBytes_writeBytes]; rfl)
  have K6' : Keeps (base + BitVec.ofNat 32 SCR) 32 t3.mem t6.mem := by rw [← mem5]; exact K6
  have mem6 : SMem base m0 t6.mem := mem3'.keeps fit K6' (by unfold Free; right; left; bnd)
  have hc6 : CodeAt t6.mem base kernel := mem6.code fit hc0
  have k6' : ∀ r, r ≠ A0 → r ≠ T3 → t6.reg r = s.reg r := fun r a b => by rw [k6 r b, k5 r a b]
  -- the value, into the signature
  obtain ⟨t7, f7, q7, n7, u7⟩ := (copy_words (prog := kernel) hp (k0 := 84) (rs := S5) (rd := S1) (t := T4)
    (src := SCR) (dst := SIG + 32 * i) at_store (by rw [kernel_length]; decide) (by decide) (by decide)
    (by decide) (by bnd) (by bnd) (by bnd) (by bnd) (by rw [kernel_length]; bnd) (by right; bnd)
    (by rw [q6]) hc6 (by rw [k6' _ (by decide) (by decide), h.s5])
    (by rw [k6' _ (by decide) (by decide), h.s1])) 8 (Nat.le_refl _)
  have K7 : Keeps (base + BitVec.ofNat 32 (SIG + 32 * i)) 32 t6.mem t7.mem := by
    rw [n7]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have mem7 : SMem base m0 t7.mem := mem6.keeps fit K7 (by unfold Free; right; right; left; bnd)
  have hc7 : CodeAt t7.mem base kernel := mem7.code fit hc0
  have k7 : ∀ r, r ≠ A0 → r ≠ T3 → r ≠ T4 → t7.reg r = s.reg r := fun r a b c => by rw [u7 r c, k6' r a b]
  -- addi s1, s1, 32; addi a4, a4, 1; addi s8, s8, 1
  obtain ⟨t8, f8, q8, n8, u8⟩ := regStep (prog := kernel) hp 100 (by decide) hc7 q7
    (i := .opi .addi S1 S1 32) (by decide) rfl
  obtain ⟨t9, f9, q9, n9, u9⟩ := regStep (prog := kernel) hp 101 (by decide) (by rw [n8]; exact hc7) q8
    (i := .opi .addi A4 A4 1) (by decide) rfl
  obtain ⟨t10, f10, q10, n10, u10⟩ := regStep (prog := kernel) hp 102 (by decide) (by rw [n9, n8]; exact hc7) q9
    (i := .opi .addi S8 S8 1) (by decide) rfl
  have mem10 : t10.mem = t7.mem := by rw [n10, n9, n8]
  have hc10 : CodeAt t10.mem base kernel := by rw [mem10]; exact hc7
  have k10 : ∀ r, r ≠ A0 → r ≠ T3 → r ≠ T4 → r ≠ S1 → r ≠ A4 → r ≠ S8 → t10.reg r = s.reg r :=
    fun r a b c d e f => by rw [reg_kept u10 f, reg_kept u9 e, reg_kept u8 d, k7 r a b c]
  have v_a4 : t10.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + (i + 1)) := by
    rw [reg_kept u10 (by decide), reg_wrote u9 (by decide), reg_kept u8 (by decide),
      k7 _ (by decide) (by decide) (by decide), h.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by bnd), Nat.add_assoc]
  have v_s7 : t10.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67) := by
    rw [k10 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s7]
  have ht : taken .bne (t10.reg A4) (t10.reg S7) = decide (i + 1 < 67) := by
    rw [v_a4, v_s7]; simp only [taken]
    by_cases hl : i + 1 < 67
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by bnd), toNat_off fit _ (by bnd)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show i + 1 = 67 by omega]
  have finish : ∀ s4 : Machine, run env 1 t10 = .running s4 → (∀ r, s4.reg r = t10.reg r) →
      s4.mem = t10.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if i + 1 < 67 then 75 else 104)) →
      ∃ s', run env (26 + 3 * digit m0 base i) s = .running s' ∧ SInv env.hash base m0 (i + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ A0 → r ≠ T3 → r ≠ T4 → r ≠ S1 → r ≠ A4 → r ≠ S8 → s4.reg r = s.reg r :=
      fun r a b c d e f => by rw [b4, k10 r a b c d e f]
    have mm : s4.mem = t7.mem := by rw [m4, mem10]
    refine ⟨s4, ?_, ⟨p4, ?_, ?_, ?_, ?_, ?_, by rw [b4, v_a4], ?_, ?_, ?_, ?_, ?_, by rw [mm]; exact mem7,
      ?_, ?_⟩⟩
    · have ew : run env (16 + 4) t6 = .running s4 := by
        rw [show 16 + 4 = 2 * 8 + (1 + (1 + (1 + 1))) by rfl, run_add_running f7]
        exact run_cons f8 (run_cons f9 (run_cons f10 e4))
      have ew2 : run env ((1 + 3 * digit m0 base i) + (16 + 4)) t5 = .running s4 := by
        rw [run_add_running f6]; exact ew
      have := run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 ew2))))
      rwa [show (1 + 3 * digit m0 base i) + (16 + 4) + 1 + 1 + 1 + 1 + 1 = 26 + 3 * digit m0 base i by omega]
        at this
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s4]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s7]
    · rw [b4, reg_kept u10 (by decide), reg_kept u9 (by decide), reg_wrote u8 (by decide),
        k7 _ (by decide) (by decide) (by decide), h.s1]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · rw [b4, reg_wrote u10 (by decide), reg_kept u9 (by decide), reg_kept u8 (by decide),
        k7 _ (by decide) (by decide) (by decide), h.s8]
      simp only [aluI]; exact add_small i 1 (by decide)
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s9]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a2]
    · rw [mm, K7.off fit (by bnd) (by bnd) (by left; bnd), K6'.off fit (by bnd) (by bnd) (by left; bnd),
        K3.off fit (by bnd) (by bnd) (by left; bnd), K1.off fit (by bnd) (by bnd) (by left; bnd)]
      exact h.pl
    · intro k hk
      unfold sigAt
      rw [mm]
      by_cases hki : k < i
      · rw [K7.bytes fit (by bnd) (by bnd) (by left; bnd), K6'.bytes fit (by bnd) (by bnd) (by left; bnd),
          K3.bytes fit (by bnd) (by bnd) (by left; bnd), K1.bytes fit (by bnd) (by bnd) (by right; bnd)]
        exact h.sig k hki
      · rw [show k = i by omega, ← b6, n7]
        apply readBytes_shift
        intro d hd
        rw [off_add fit _ _ (by bnd), overlay_off_in fit _ _ (by bnd) (by omega) (by omega),
          show SIG + 32 * i + d - (SIG + 32 * i) = d by omega, off_add fit _ _ (by bnd)]
  by_cases hl : i + 1 < 67
  · have e4 : run env 1 t10 = .running (t10.setPc (t10.pc + ((0xfc8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 103 (by decide) hc10 q10 (i := .br .bne A4 S7 0xfc8) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, q10]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 t10 = .running t10.next :=
      (stepK (prog := kernel) hp 103 (by decide) hc10 q10 (i := .br .bne A4 S7 0xfc8) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, q10]
    exact pc_next fit 103 (by decide)

/-- The instructions the first `n` chains take: each `26 + 3 dᵢ`. -/
def loopCount (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 26 + 3 * digit m base i).sum

theorem loopCount_eq (m : Word → Byte) (base : Word) :
    loopCount m base 67 = 26 * 67 + 3 * dsum m base := by
  have : ∀ n, loopCount m base n = 26 * n + 3 * ((List.range n).map fun i => digit m base i).sum := by
    intro n
    induction n with
    | zero => simp [loopCount]
    | succ n ih =>
      simp only [loopCount, List.range_succ, List.map_append, List.sum_append, List.map_cons,
        List.map_nil, List.sum_cons, List.sum_nil] at *
      rw [ih]; omega
  exact this 67

theorem chain_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : SInv env.hash base m0 0 s) :
    ∀ j ≤ 67, ∃ s', run env (loopCount m0 base j) s = .running s' ∧ SInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := chain_iter hp hc0 (by omega) hs'
    refine ⟨s'', ?_, hs''⟩
    rw [show loopCount m0 base (j + 1) = loopCount m0 base j + (26 + 3 * digit m0 base j) by
      simp [loopCount, List.range_succ, List.sum_append], run_add_running e, e']

/-! ## The path -/

theorem xor_one : ∀ q < 256, q ^^^ 1 = sib q := by decide

theorem sib_le (q : Nat) : sib q ≤ q + 1 := by unfold sib; split <;> omega

/-- `xori t1, a3, 1; slli t1, t1, 5`: 32 times the sibling's number. -/
theorem sib_word (q : Nat) (hq : q < 256) :
    shiftI .slli (aluI .xori (BitVec.ofNat 32 q) (BitVec.signExtend 32 (1 : BitVec 12))) (5 : BitVec 5).toNat
      = BitVec.ofNat 32 (32 * sib q) := by
  simp only [shiftI, aluI]
  rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
    show (5 : BitVec 5).toNat = 5 from rfl]
  have hs := sib_le q
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_shiftLeft, BitVec.toNat_xor, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat,
    Nat.mod_eq_of_lt (show q < 2 ^ 32 by omega), Nat.mod_eq_of_lt (show 1 < 2 ^ 32 by decide), xor_one q hq,
    Nat.shiftLeft_eq, show (2 : Nat) ^ 5 = 32 by rfl, Nat.mod_eq_of_lt (show sib q * 32 < 2 ^ 32 by omega),
    Nat.mod_eq_of_lt (show 32 * sib q < 2 ^ 32 by omega)]
  omega

theorem lvl_le (j : Nat) : lvl j ≤ 32 := Nat.sub_le _ _

theorem lvl_step {j : Nat} (hj : j < 4) : 32 * lvl j + 512 / 2 ^ j = 32 * lvl (j + 1) := by
  rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3) with rfl | rfl | rfl | rfl <;> decide

theorem div_two_pow (n j : Nat) : n / 2 ^ j / 2 = n / 2 ^ (j + 1) := by
  rw [Nat.div_div_eq_div_mul, Nat.pow_succ]

/-- At the top of level `j` — or, once `j` is 4, at the root's copy: the
path's first `j` nodes written. -/
structure AInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (j : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if j < 4 then 111 else 136))
  s10 : s.reg S10 = base + BitVec.ofNat 32 (TREE + 32 * lvl j)
  s11 : s.reg S11 = BitVec.ofNat 32 (512 / 2 ^ j)
  a3 : s.reg A3 = BitVec.ofNat 32 (idx m0 base / 2 ^ j)
  a6 : s.reg A6 = BitVec.ofNat 32 (4 - j)
  s2 : s.reg S2 = base + BitVec.ofNat 32 (AUTH + 32 * j)
  t0 : s.reg T0 = 0
  out : Out base m0 s.mem
  sig : ∀ k < 67, sigAt s.mem base k = chain H (secret H (seedOf m0 base) (idx m0 base) k) (digit m0 base k)
  path : ∀ k < j, authAt s.mem base k = pathAt m0 base (idx m0 base) k

/-- Seven instructions: the tree's and the path's pointers, the level's size,
the index, the count. -/
theorem to_path {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : SInv env.hash base m0 67 s) :
    ∃ s', run env 7 s = .running s' ∧ AInv env.hash base m0 0 s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 104) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.mem.code fit hc0
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 104 (by decide) hcode hpc
    (i := .lui T1 5) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 105 (by decide) (by rw [n1]; exact hcode) q1
    (i := .op .add S10 S0 T1) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 106 (by decide) (by rw [n2, n1]; exact hcode) q2
    (i := .lui T1 4) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 107 (by decide) (by rw [n3, n2, n1]; exact hcode) q3
    (i := .op .add S2 S0 T1) (by decide) rfl
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 108 (by decide)
    (by rw [n4, n3, n2, n1]; exact hcode) q4 (i := .opi .addi S11 0 512) (by decide) rfl
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := kernel) hp 109 (by decide)
    (by rw [n5, n4, n3, n2, n1]; exact hcode) q5 (i := .opi .addi A3 S9 0) (by decide) rfl
  obtain ⟨t7, f7, q7, n7, u7⟩ := regStep (prog := kernel) hp 110 (by decide)
    (by rw [n6, n5, n4, n3, n2, n1]; exact hcode) q6 (i := .opi .addi A6 0 4) (by decide) rfl
  have mem7 : t7.mem = s.mem := by rw [n7, n6, n5, n4, n3, n2, n1]
  refine ⟨t7, run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 (run_cons f6 f7))))),
    ⟨by rw [q7]; rfl, ?_, ?_, ?_, ?_, ?_, ?_, by rw [mem7]; exact h.mem.out,
     fun k hk => by rw [mem7]; exact h.sig k hk, fun k hk => absurd hk (by omega)⟩⟩
  · rw [reg_kept u7 (by decide), reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide),
      reg_kept u3 (by decide), reg_wrote u2 (by decide), reg_wrote u1 (by decide), reg_kept u1 (by decide), h.s0]
    simp only [aluR]; rfl
  · rw [reg_kept u7 (by decide), reg_kept u6 (by decide), reg_wrote u5 (by decide)]
    simp only [aluI, reg_zero]; decide
  · rw [reg_kept u7 (by decide), reg_wrote u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide),
      reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.s9]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide, Nat.pow_zero, Nat.div_one]
    exact BitVec.add_zero _
  · rw [reg_wrote u7 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_kept u7 (by decide), reg_kept u6 (by decide), reg_kept u5 (by decide), reg_wrote u4 (by decide),
      reg_wrote u3 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.s0]
    simp only [aluR]; rfl
  · rw [reg_kept u7 (by decide), reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide),
      reg_kept u3 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide), h.t0]

/-- **One level**: 25 instructions — the sibling's place in the tree, its 32
bytes onto the path, and the pointers and the index on to the next level. -/
theorem level_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {j : Nat} (hj : j < 4) {s : Machine} (h : AInv env.hash base m0 j s) :
    ∃ s', run env 25 s = .running s' ∧ AInv env.hash base m0 (j + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 111) := by rw [h.pc]; simp [hj]
  have hcode : CodeAt s.mem base kernel :=
    h.out.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc0
  have hq : idx m0 base / 2 ^ j < 256 := by
    have := idx_lt m0 base; have := Nat.div_le_self (idx m0 base) (2 ^ j); omega
  have hsib := sib_le (idx m0 base / 2 ^ j)
  have hlv := lvl_le j
  have h512 := Nat.div_le_self 512 (2 ^ j)
  -- xori t1, a3, 1; slli t1, t1, 5; add a5, s10, t1
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 111 (by decide) hcode hpc
    (i := .opi .xori T1 A3 1) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 112 (by decide) (by rw [n1]; exact hcode) q1
    (i := .sh .slli T1 T1 5) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 113 (by decide) (by rw [n2, n1]; exact hcode) q2
    (i := .op .add A5 S10 T1) (by decide) rfl
  have mem3 : t3.mem = s.mem := by rw [n3, n2, n1]
  have hc3 : CodeAt t3.mem base kernel := by rw [mem3]; exact hcode
  have k3 : ∀ r, r ≠ T1 → r ≠ A5 → t3.reg r = s.reg r := fun r a b => by
    rw [reg_kept u3 b, reg_kept u2 a, reg_kept u1 a]
  have v_a5 : t3.reg A5 = base + BitVec.ofNat 32 (TREE + 32 * (lvl j + sib (idx m0 base / 2 ^ j))) := by
    rw [reg_wrote u3 (by decide), reg_wrote u2 (by decide), reg_kept u2 (by decide), reg_kept u1 (by decide),
      reg_wrote u1 (by decide), h.s10, h.a3]
    simp only [aluR]
    rw [sib_word _ hq, off_add fit _ _ (by bnd)]
    congr 2; omega
  -- the sibling, onto the path
  obtain ⟨t4, f4, q4, n4, u4⟩ := (copy_words (prog := kernel) hp (k0 := 114) (rs := A5) (rd := S2) (t := T4)
    (src := TREE + 32 * (lvl j + sib (idx m0 base / 2 ^ j))) (dst := AUTH + 32 * j) at_path
    (by rw [kernel_length]; decide) (by decide) (by decide) (by decide) (by bnd) (by bnd) (by bnd) (by bnd)
    (by rw [kernel_length]; bnd) (by right; bnd) q3 hc3 v_a5
    (by rw [k3 _ (by decide) (by decide), h.s2])) 8 (Nat.le_refl _)
  have K4 : Keeps (base + BitVec.ofNat 32 (AUTH + 32 * j)) 32 t3.mem t4.mem := by
    rw [n4]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have out3 : Out base m0 t3.mem := by rw [mem3]; exact h.out
  have out4 : Out base m0 t4.mem := out3.left fit K4 (by bnd) (by bnd) (by decide)
  have hc4 : CodeAt t4.mem base kernel :=
    out4.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hc0
  have k4 : ∀ r, r ≠ T1 → r ≠ A5 → r ≠ T4 → t4.reg r = s.reg r := fun r a b c => by rw [u4 r c, k3 r a b]
  -- addi s2, s2, 32; add s10, s10, s11; srli s11, s11, 1; srli a3, a3, 1; addi a6, a6, -1
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 130 (by decide) hc4 q4
    (i := .opi .addi S2 S2 32) (by decide) rfl
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := kernel) hp 131 (by decide) (by rw [n5]; exact hc4) q5
    (i := .op .add S10 S10 S11) (by decide) rfl
  obtain ⟨t7, f7, q7, n7, u7⟩ := regStep (prog := kernel) hp 132 (by decide) (by rw [n6, n5]; exact hc4) q6
    (i := .sh .srli S11 S11 1) (by decide) rfl
  obtain ⟨t8, f8, q8, n8, u8⟩ := regStep (prog := kernel) hp 133 (by decide) (by rw [n7, n6, n5]; exact hc4) q7
    (i := .sh .srli A3 A3 1) (by decide) rfl
  obtain ⟨t9, f9, q9, n9, u9⟩ := regStep (prog := kernel) hp 134 (by decide) (by rw [n8, n7, n6, n5]; exact hc4)
    q8 (i := .opi .addi A6 A6 0xfff) (by decide) rfl
  have mem9 : t9.mem = t4.mem := by rw [n9, n8, n7, n6, n5]
  have hc9 : CodeAt t9.mem base kernel := by rw [mem9]; exact hc4
  have v_a6 : t9.reg A6 = BitVec.ofNat 32 (4 - (j + 1)) := by
    rw [reg_wrote u9 (by decide), reg_kept u8 (by decide), reg_kept u7 (by decide), reg_kept u6 (by decide),
      reg_kept u5 (by decide), k4 _ (by decide) (by decide) (by decide), h.a6]
    simp only [aluI]
    rw [show 4 - j = (4 - (j + 1)) + 1 by omega]
    exact dec_one _ (by omega)
  have htk : taken .bne (t9.reg A6) (t9.reg 0) = decide (j + 1 < 4) := by
    rw [v_a6, reg_zero]; simp only [taken]
    by_cases hl : j + 1 < 4
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this
      have : (0 : Word).toNat = 0 := rfl
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show 4 - (j + 1) = 0 by omega]; rfl
  have finish : ∀ s5 : Machine, run env 1 t9 = .running s5 → (∀ r, s5.reg r = t9.reg r) →
      s5.mem = t9.mem → s5.pc = base + BitVec.ofNat 32 (4 * (if j + 1 < 4 then 111 else 136)) →
      ∃ s', run env 25 s = .running s' ∧ AInv env.hash base m0 (j + 1) s' := by
    intro s5 e5 b5 m5 p5
    have mm : s5.mem = t4.mem := by rw [m5, mem9]
    refine ⟨s5, ?_, ⟨p5, ?_, ?_, ?_, by rw [b5, v_a6], ?_, ?_, by rw [mm]; exact out4, ?_, ?_⟩⟩
    · have ew : run env (2 * 8 + (1 + (1 + (1 + (1 + (1 + 1)))))) t3 = .running s5 := by
        rw [run_add_running f4]
        exact run_cons f5 (run_cons f6 (run_cons f7 (run_cons f8 (run_cons f9 e5))))
      exact run_cons f1 (run_cons f2 (run_cons f3 ew))
    · rw [b5, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_kept u7 (by decide),
        reg_wrote u6 (by decide), reg_kept u5 (r := S10) (by decide), reg_kept u5 (r := S11) (by decide),
        k4 S10 (by decide) (by decide) (by decide), k4 S11 (by decide) (by decide) (by decide), h.s10, h.s11]
      simp only [aluR]
      rw [off_add fit _ _ (by bnd)]
      congr 2
      have := lvl_step hj; omega
    · rw [b5, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_wrote u7 (by decide),
        reg_kept u6 (by decide), reg_kept u5 (by decide), k4 _ (by decide) (by decide) (by decide), h.s11]
      simp only [shiftI]
      rw [show (1 : BitVec 5).toNat = 1 from rfl, shr _ _ (by have := Nat.div_le_self 512 (2 ^ j); omega),
        Nat.pow_one, div_two_pow]
    · rw [b5, reg_kept u9 (by decide), reg_wrote u8 (by decide), reg_kept u7 (by decide),
        reg_kept u6 (by decide), reg_kept u5 (by decide), k4 _ (by decide) (by decide) (by decide), h.a3]
      simp only [shiftI]
      rw [show (1 : BitVec 5).toNat = 1 from rfl, shr _ _ (by omega), Nat.pow_one, div_two_pow]
    · rw [b5, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_kept u7 (by decide),
        reg_kept u6 (by decide), reg_wrote u5 (by decide), k4 _ (by decide) (by decide) (by decide), h.s2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide, off_add fit _ _ (by bnd)]
      congr 2
    · rw [b5, reg_kept u9 (by decide), reg_kept u8 (by decide), reg_kept u7 (by decide),
        reg_kept u6 (by decide), reg_kept u5 (by decide), k4 _ (by decide) (by decide) (by decide), h.t0]
    · intro k hk
      unfold sigAt
      rw [mm, K4.bytes fit (by bnd) (by bnd) (by left; bnd), mem3]
      exact h.sig k hk
    · intro k hk
      unfold authAt
      rw [mm]
      by_cases hkj : k < j
      · rw [K4.bytes fit (by bnd) (by bnd) (by left; bnd), mem3]; exact h.path k hkj
      · rw [show k = j by omega, n4]
        unfold pathAt
        rw [← out3.bytes fit (by decide) (by decide) (by bnd) (by right; bnd) (by left; bnd)]
        apply readBytes_shift
        intro d hd
        rw [off_add fit _ _ (by bnd), overlay_off_in fit _ _ (by bnd) (by omega) (by omega),
          show AUTH + 32 * j + d - (AUTH + 32 * j) = d by omega, off_add fit _ _ (by bnd)]
  by_cases hl : j + 1 < 4
  · have e5 : run env 1 t9 = .running (t9.setPc (t9.pc + ((0xfd0 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 135 (by decide) hc9 q9 (i := .br .bne A6 0 0xfd0) (by decide)
        (exec_br_taken (by rw [htk]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e5 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, q9]
    rw [BitVec.add_assoc]
    congr 1
  · have e5 : run env 1 t9 = .running t9.next :=
      (stepK (prog := kernel) hp 135 (by decide) hc9 q9 (i := .br .bne A6 0 0xfd0) (by decide)
        (exec_br_not (by rw [htk]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e5 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, q9]
    exact pc_next fit 135 (by decide)

theorem level_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : AInv env.hash base m0 0 s) :
    ∀ j ≤ 4, ∃ s', run env (25 * j) s = .running s' ∧ AInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := level_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 25 * (j + 1) = 25 * j + 25 by omega, run_add_running e, e'], hs''⟩

/-! ## The whole kernel -/

/-- Everything up to the `ecall` that halts: `2283 + 3 Σ dᵢ` instructions,
then HALT with 0 — the signature, the path and the root written. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env (2283 + 3 * dsum s.mem base) s = .running s1 ∧ run env 1 s1 = .halted 0 s2
      ∧ Out base s.mem s2.mem
      ∧ (∀ i < 67, sigAt s2.mem base i
          = chain env.hash (secret env.hash (seedOf s.mem base) (idx s.mem base) i) (digit s.mem base i))
      ∧ (∀ j < 4, authAt s2.mem base j = pathAt s.mem base (idx s.mem base) j)
      ∧ rootAt s2.mem base = rootIn s.mem base := by
  have fit := hp.fit
  obtain ⟨sc, ec, hc⟩ := to_chains hp s hpc hcode
  obtain ⟨sl, el, hl⟩ := chain_loop hp hcode hc 67 (Nat.le_refl _)
  obtain ⟨sa, ea, ha⟩ := to_path hp hcode hl
  obtain ⟨sv, ev, hv⟩ := level_loop hp hcode ha 4 (Nat.le_refl _)
  have hpcv : sv.pc = base + BitVec.ofNat 32 (4 * 136) := by rw [hv.pc]; rfl
  have hcv : CodeAt sv.mem base kernel :=
    hv.out.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hcode
  -- the root, after the path
  obtain ⟨t1, f1, q1, n1, u1⟩ := (copy_words (prog := kernel) hp (k0 := 136) (rs := S10) (rd := S2) (t := T4)
    (src := TREE + 32 * 30) (dst := ROOT) at_root (by rw [kernel_length]; decide) (by decide) (by decide)
    (by decide) (by bnd) (by bnd) (by bnd) (by bnd) (by rw [kernel_length]; bnd) (by right; bnd) hpcv hcv
    (by rw [hv.s10]; rfl) (by rw [hv.s2]; rfl)) 8 (Nat.le_refl _)
  have K1 : Keeps (base + BitVec.ofNat 32 ROOT) 32 sv.mem t1.mem := by
    rw [n1]; exact keeps_overlay fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by bnd)
  have out1 : Out base s.mem t1.mem := hv.out.left fit K1 (by bnd) (by bnd) (by decide)
  have hc1 : CodeAt t1.mem base kernel :=
    out1.code fit (by decide) (by decide) (by rw [kernel_length]; decide) (by rw [kernel_length]; decide) hcode
  obtain ⟨u2, g2, o2, l2, v2⟩ := regStep (prog := kernel) hp 152 (by decide) hc1 q1
    (i := .opi .addi A0 0 0) (by decide) rfl
  obtain ⟨u3, g3, o3, l3, v3⟩ := regStep (prog := kernel) hp 153 (by decide) (by rw [l2]; exact hc1) o2
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : u3.reg T0 = 1 := by rw [reg_wrote v3 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : u3.reg A0 = 0 := by
    rw [reg_kept v3 (by decide), reg_wrote v2 (by decide)]; simp only [aluI, reg_zero]; decide
  have mm : u3.mem = t1.mem := by rw [l3, l2]
  refine ⟨u3, u3, ?_, ?_, by rw [mm]; exact out1, ?_, ?_, ?_⟩
  · rw [show 2283 + 3 * dsum s.mem base = 416 + (loopCount s.mem base 67 + (7 + (25 * 4 + (2 * 8 + (1 + 1)))))
      by rw [loopCount_eq]; omega,
      run_add_running ec, run_add_running el, run_add_running ea, run_add_running ev, run_add_running f1]
    exact run_cons g2 g3
  · rw [← a0]
    exact (step_of_code (k := 154) (by rw [kernel_length]; decide) (by rw [mm]; exact hc1)
        (by rw [o3])
        (by rw [o3]; exact align_off hp.align hp.fit _ (by decide) (by decide))
        (by rw [o3]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
          rw [run, e, show kernel[154]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])
  · intro i hi
    unfold sigAt
    rw [mm, K1.bytes fit (by bnd) (by bnd) (by left; bnd)]
    exact hv.sig i hi
  · intro j hj
    unfold authAt
    rw [mm, K1.bytes fit (by bnd) (by bnd) (by left; bnd)]
    exact hv.path j hj
  · unfold rootAt rootIn
    rw [mm, n1, ← hv.out.bytes fit (by decide) (by decide) (by bnd) (by right; bnd) (by left; bnd)]
    apply readBytes_shift
    intro d hd
    rw [off_add fit _ _ (by bnd), overlay_off_in fit _ _ (by bnd) (by omega) (by omega),
      show ROOT + d - ROOT = d by omega, off_add fit _ _ (by bnd)]

/-- **The signer.** From `base`, with the kernel's 620 bytes there, it halts
with 0 after exactly `2284 + 3 Σ dᵢ` instructions, where `dᵢ` are the
message's 64 digits and the checksum's 3 — the same digits exp206's verifier
computes. It has written, where the verifier reads them: chain `i` of key `l`
(the index byte) walked `dᵢ` steps from its secret, the path's four nodes
from the tree, and the tree's root. Nothing outside the PRF input to the root
(`0x1080` to `0x4100`) and the 131 bytes of scratch changes, so the message,
the index, the seed and the tree are still the input's. -/
theorem signs {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    (∃ s1, run env (2283 + 3 * dsum s.mem base) s = .running s1) ∧
    ∃ s', run env (2284 + 3 * dsum s.mem base) s = .halted 0 s' ∧ Out base s.mem s'.mem
      ∧ (∀ i < 67, sigAt s'.mem base i
          = chain env.hash (secret env.hash (seedOf s.mem base) (idx s.mem base) i) (digit s.mem base i))
      ∧ (∀ j < 4, authAt s'.mem base j = pathAt s.mem base (idx s.mem base) j)
      ∧ rootAt s'.mem base = rootIn s.mem base := by
  obtain ⟨s1, s2, e, e1, ho, hs, ha, hr⟩ := to_the_ecall hp s hpc hcode
  exact ⟨⟨s1, e⟩, s2, by rw [show 2284 + 3 * dsum s.mem base = 2283 + 3 * dsum s.mem base + 1 by omega,
    run_add_running e, e1], ho, hs, ha, hr⟩

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction
`k`. 155 cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- Any image that begins with the kernel's 620 bytes holds the kernel. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 620 ≤ img.size)
    (himg : ∀ d (h : d < 620), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

end Sign
end Rv32.Mss
