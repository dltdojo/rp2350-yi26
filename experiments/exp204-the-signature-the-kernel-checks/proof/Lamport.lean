import Rv32.Blocks
import Rv32.Asm

namespace Exp204
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S3 : Reg := 19
def S4 : Reg := 20
def S5 : Reg := 21
def S6 : Reg := 22
def S7 : Reg := 23
def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29

def setup : List Instr := [
  .auipc S0 0,
  .lui T1 2, .op .add S1 S0 T1,
  .lui T1 4, .op .add S2 S0 T1,
  .lui T1 1, .op .add S3 S0 T1,
  .lui T1 8, .op .add S5 S0 T1,
  .opi .addi S4 0 0,
  .opi .addi S6 0 0,
  .opi .addi S7 0 256 ] ++
  (List.range 8).map fun j => .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j))

def copy : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T4 S1 (BitVec.ofNat 12 (4 * j)), .st .sw S5 T4 (BitVec.ofNat 12 (4 * j))]

def hash : List Instr := [
  .opi .addi T0 0 0, .opi .addi A0 S5 0, .opi .addi A1 0 64, .opi .addi A2 S5 64, .ecall ]

def pick : List Instr := [
  .sh .srli T1 S4 3, .op .add T1 S3 T1, .ld .lbu T1 T1 0,
  .opi .andi T2 S4 7, .op .srl T1 T1 T2, .opi .andi T1 T1 1,
  .sh .slli T1 T1 5, .op .add T1 S2 T1 ]

def compare : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T2 S5 (BitVec.ofNat 12 (64 + 4 * j)), .ld .lw T3 T1 (BitVec.ofNat 12 (4 * j)),
     .op .xor T2 T2 T3, .op .or S6 S6 T2]

def advance : List Instr := [
  .opi .addi S1 S1 32, .opi .addi S2 S2 64, .opi .addi S4 S4 1, .br .bne S4 S7 0xf80 ]

def finish : List Instr := [ .op .sltu A0 0 S6, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := setup ++ copy ++ hash ++ pick ++ compare ++ advance ++ finish

/-- The kernel as bytes. This is `kernel.bin`, and the only thing on the chip
the theorems are about. -/
def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩


theorem kernel_length : kernel.length = 88 := by decide

/-! ## Where everything is

Offsets from `base`, the kernel's own address, which `auipc` finds: -/

/-- The message, 32 bytes. -/
def MSG : Nat := 0x1000
/-- The signature: preimage `i` at `SIG + 32 i`. -/
def SIG : Nat := 0x2000
/-- The public key: `pk[i][b]` at `PK + 64 i + 32 b`. -/
def PK : Nat := 0x4000
/-- Scratch: the 64-byte HASH input at `SCR`, its 32-byte output at `SCR + 64`. -/
def SCR : Nat := 0x8000

/-! ## What is proved: Lamport verification

`H` is `env.hash`, and nothing is assumed about it. -/

/-- Bit `i` of the message, low bit of each byte first. -/
def bitAt (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  (m (base + BitVec.ofNat 32 (MSG + i / 8))).toNat / 2 ^ (i % 8) % 2

/-- Preimage `i` of the signature. -/
def preimage (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (SIG + 32 * i)) 32

/-- Preimage `i` hashes, padded with 32 zeros, to the half of public key `i`
that bit `i` of the message selects. -/
def Good (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) : Prop :=
  ∀ d : Fin 32, H (preimage m base i ++ List.replicate 32 0) d
    = m (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m base i + d))

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) :
    Decidable (Good H m base i) := by unfold Good; infer_instance

/-- **The signature verifies**: every one of the 256 preimages does. -/
def Verifies (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Prop :=
  ∀ i < 256, Good H m base i

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    Decidable (Verifies H m base) := by unfold Verifies; infer_instance

/-- A byte the kernel may write: the 96 of scratch. -/
def InScr (base x : Word) : Prop := (x - (base + BitVec.ofNat 32 SCR)).toNat < 96

/-! ## The bytes are the kernel, instruction by instruction -/

theorem at_setup_zero : ∀ j < 8, kernel.getD (12 + j) .ecall = .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem at_copy_lw : ∀ j < 8, kernel.getD (20 + 2 * j) .ecall = .ld .lw T4 S1 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_copy_sw : ∀ j < 8, kernel.getD (21 + 2 * j) .ecall = .st .sw S5 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_cmp_out : ∀ j < 8, kernel.getD (49 + 4 * j) .ecall = .ld .lw T2 S5 (BitVec.ofNat 12 (64 + 4 * j)) := by
  decide
theorem at_cmp_pk : ∀ j < 8, kernel.getD (50 + 4 * j) .ecall = .ld .lw T3 T1 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_cmp_xor : ∀ j < 8, kernel.getD (51 + 4 * j) .ecall = .op .xor T2 T2 T3 := by
  decide
theorem at_cmp_or : ∀ j < 8, kernel.getD (52 + 4 * j) .ecall = .op .or S6 S6 T2 := by
  decide

/-! ## Block 1: setup -/

/-- The registers the loop reads, as setup leaves them. -/
structure Regs (base : Word) (s : Machine) : Prop where
  s3 : s.reg S3 = base + BitVec.ofNat 32 MSG
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR
  s7 : s.reg S7 = BitVec.ofNat 32 256

/-- Twelve instructions that only set registers: the pointers, from `auipc`. -/
theorem setup_regs {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 12 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 48 ∧ s'.mem = s.mem
      ∧ Regs base s' ∧ s'.reg S1 = base + BitVec.ofNat 32 SIG ∧ s'.reg S2 = base + BitVec.ofNat 32 PK
      ∧ s'.reg S4 = 0 ∧ s'.reg S6 = 0 := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) hc1 p1
      (i := .lui T1 2) (by decide) rfl
  have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) hc2 p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) hc3 p3
      (i := .lui T1 4) (by decide) rfl
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) hc4 p4
      (i := .op .add S2 S0 T1) (by decide) rfl
  have hc5 : CodeAt s5.mem base kernel := by rw [m5]; exact hc4
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) hc5 p5
      (i := .lui T1 1) (by decide) rfl
  have hc6 : CodeAt s6.mem base kernel := by rw [m6]; exact hc5
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 6 (by decide) hc6 p6
      (i := .op .add S3 S0 T1) (by decide) rfl
  have hc7 : CodeAt s7.mem base kernel := by rw [m7]; exact hc6
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 7 (by decide) hc7 p7
      (i := .lui T1 8) (by decide) rfl
  have hc8 : CodeAt s8.mem base kernel := by rw [m8]; exact hc7
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp 8 (by decide) hc8 p8
      (i := .op .add S5 S0 T1) (by decide) rfl
  have hc9 : CodeAt s9.mem base kernel := by rw [m9]; exact hc8
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp 9 (by decide) hc9 p9
      (i := .opi .addi S4 0 0) (by decide) rfl
  have hc10 : CodeAt s10.mem base kernel := by rw [m10]; exact hc9
  obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp 10 (by decide) hc10 p10
      (i := .opi .addi S6 0 0) (by decide) rfl
  have hc11 : CodeAt s11.mem base kernel := by rw [m11]; exact hc10
  obtain ⟨s12, e12, p12, m12, r12⟩ := regStep (prog := kernel) hp 11 (by decide) hc11 p11
      (i := .opi .addi S7 0 256) (by decide) rfl
  have hc12 : CodeAt s12.mem base kernel := by rw [m12]; exact hc11
  refine ⟨s12, (run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7 (run_cons e8 (run_cons e9 (run_cons e10 (run_cons e11 e12))))))))))), p12, by rw [m12, m11, m10, m9, m8, m7, m6, m5, m4, m3, m2, m1], ⟨?_, ?_, ?_⟩, ?_, ?_, ?_, ?_⟩ <;>
    simp [r12, r11, r10, r9, r8, r7, r6, r5, r4, r3, r2, r1, hpc, S0, S1, S2, S3, S4, S5, S6, S7, T1,
      aluR, aluI, MSG, SIG, PK, SCR] <;> rfl

/-! ## Memory, as a base and what has been written over it -/

/-! ## Instructions that touch memory, one at a time -/

/-- A machine's memory is `m` outside scratch, whatever scratch holds: the
kernel writes nowhere else. -/
def Outside (base : Word) (m m' : Word → Byte) : Prop := ∀ x, ¬ InScr base x → m' x = m x

/-- A program stays loaded while memory changes only inside scratch: the
kernel's 352 bytes are far below it. -/
theorem code_of_outside {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte}
    (h : Outside base m m') (hc : CodeAt m base kernel) : CodeAt m' base kernel := by
  refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => (h x ?_).symm) hc
  unfold InScr
  rw [toNat_sub_off hfit x SCR (by decide)]
  rw [kernel_length] at h2
  simp only [SCR]; omega

theorem overlay_outside {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte}
    (c n : Nat) (hc : SCR ≤ c) (hn : c + n ≤ SCR + 96) (f : Nat → Byte) :
    Outside base m (overlay m (base + BitVec.ofNat 32 c) n f) := by
  intro x hx
  unfold overlay InScr at *
  rw [toNat_sub_off hfit x SCR (by decide)] at hx
  rw [toNat_sub_off hfit x c (by simp only [SCR] at hn; omega)]
  have := x.isLt
  simp only [SCR] at hx hc hn
  have : ¬ (2 ^ 32 - (base.toNat + c) + x.toNat) % 2 ^ 32 < n := by omega
  simp only [this, ↓reduceIte]

/-- The immediates the kernel's blocks use, sign-extended: all small and
positive, so each is itself. -/
theorem se_tail : ∀ j < 8, (BitVec.ofNat 12 (32 + 4 * j)).signExtend 32 = BitVec.ofNat 32 (32 + 4 * j) := by
  decide
theorem se_word : ∀ j < 8, (BitVec.ofNat 12 (4 * j)).signExtend 32 = BitVec.ofNat 32 (4 * j) := by
  decide
theorem se_out : ∀ j < 8, (BitVec.ofNat 12 (64 + 4 * j)).signExtend 32 = BitVec.ofNat 32 (64 + 4 * j) := by
  decide

/-- The tail of the HASH input — 32 zeros — written by the kernel itself, so
the theorem needs nothing of what scratch held. -/
theorem zero_tail {env : Env} {base : Word} (hp : Placed env base) {m : Word → Byte} {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 48) (hm : s.mem = m) (hcode : CodeAt m base kernel)
    (h5 : s.reg S5 = base + BitVec.ofNat 32 SCR) :
    ∀ j ≤ 8, ∃ s', run env j s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (48 + 4 * j)
      ∧ s'.mem = overlay m (base + BitVec.ofNat 32 (SCR + 32)) (4 * j) (fun _ => 0)
      ∧ ∀ r, s'.reg r = s.reg r := by
  intro j hj
  obtain ⟨s', e, p, mm, r⟩ := (zero_words (prog := kernel) hp (k0 := 12) (rd := S5) (o := 32) (a := SCR)
    at_setup_zero (by decide) (by decide) (by decide) (by decide) (by decide) (by rw [hpc])
    (by rw [hm]; exact hcode) h5) j hj
  exact ⟨s', e, by rw [p]; congr 2; omega, by rw [mm, hm], r⟩

/-- Below scratch, an overlay of scratch reads what was there. -/
theorem overlay_below {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (n : Nat)
    (hn : n ≤ 96) (f : Nat → Byte) (c : Nat) (hc : c < SCR) :
    overlay m (base + BitVec.ofNat 32 SCR) n f (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) := by
  unfold overlay
  rw [toNat_sub_off hfit _ SCR (by decide), toNat_off hfit c (by simp only [SCR] at hc; omega)]
  have : ¬ (2 ^ 32 - (base.toNat + SCR) + (base.toNat + c)) % 2 ^ 32 < n := by
    simp only [SCR] at hc ⊢; omega
  simp only [this, ↓reduceIte]

/-! ## Block 2: one iteration — the copy -/

/-- Preimage `i`, word by word, into the first half of the HASH input. -/
theorem copy_block {env : Env} {base : Word} (hp : Placed env base) {i : Nat} (hi : i < 256)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 80) (hcode : CodeAt s.mem base kernel)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 (SIG + 32 * i)) (h5 : s.reg S5 = base + BitVec.ofNat 32 SCR) :
    ∀ j ≤ 8, ∃ s', run env (2 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (80 + 8 * j)
      ∧ s'.mem = overlay s.mem (base + BitVec.ofNat 32 SCR) (4 * j)
          (fun d => s.mem (base + BitVec.ofNat 32 (SIG + 32 * i + d)))
      ∧ ∀ r, r ≠ T4 → s'.reg r = s.reg r := by
  intro j hj
  obtain ⟨s', e, p, mm, r⟩ := (copy_words (prog := kernel) hp (k0 := 20) (rs := S1) (rd := S5) (t := T4)
    (src := SIG + 32 * i) (dst := SCR)
    (fun j hj => ⟨at_copy_lw j hj, by rw [show 20 + 2 * j + 1 = 21 + 2 * j by omega]; exact at_copy_sw j hj⟩)
    (by decide) (by decide) (by decide) (by decide)
    (by simp only [SIG]; omega) (by decide) (by simp only [SIG]; omega) (by decide) (by decide)
    (by simp only [SIG, SCR]; omega) (by rw [hpc]) hcode h1 h5) j hj
  exact ⟨s', e, by rw [p]; congr 2; omega, mm, r⟩

/-! ## Block 2: one iteration — HASH -/

/-- The machine after a HASH call, as `exec` builds it. -/
def hashed (env : Env) (s : Machine) : Machine :=
  ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next

/-- Four instructions that set the call's arguments, and the `ecall`: the
output, 32 bytes of `env.hash` of the 64 at scratch, is written right after
them. -/
theorem hash_block {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 144) (hcode : CodeAt s.mem base kernel)
    (h5 : s.reg S5 = base + BitVec.ofNat 32 SCR) :
    ∃ s', run env 5 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 164
      ∧ s'.mem = writeBytes s.mem (base + BitVec.ofNat 32 (SCR + 64))
          (env.hash (readBytes s.mem (base + BitVec.ofNat 32 SCR) 64))
      ∧ ∀ r, r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → s'.reg r = s.reg r := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 36 (by decide) hcode (by rw [hpc]; try rfl)
    (i := .opi .addi T0 0 0) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 37 (by decide) (m1 ▸ hcode) p1
    (i := .opi .addi A0 S5 0) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 38 (by decide) (by rw [m2, m1]; exact hcode) p2
    (i := .opi .addi A1 0 64) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 39 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
    (i := .opi .addi A2 S5 64) (by decide) rfl
  have t0 : s4.reg T0 = 0 := by simp [r4, r3, r2, r1, T0, A0, A1, A2, aluI]; try rfl
  have a0 : s4.reg A0 = base + BitVec.ofNat 32 SCR := by
    simp [r4, r3, r2, r1, T0, A0, A1, A2, S5, aluI]; rw [show (21#5 : Reg) = S5 from rfl, h5]; try rfl
  have a1 : s4.reg A1 = BitVec.ofNat 32 64 := by simp [r4, r3, r2, r1, T0, A0, A1, A2, aluI]; try rfl
  have a2 : s4.reg A2 = base + BitVec.ofNat 32 (SCR + 64) := by
    simp [r4, r3, r2, r1, T0, A0, A1, A2, S5, aluI]
    rw [show (21#5 : Reg) = S5 from rfl, h5]
    exact off_add hp.fit SCR 64 (by decide)
  have mm : s4.mem = s.mem := by rw [m4, m3, m2, m1]
  have hexec := exec_hash (env := env) t0 (by rw [a1]; rfl)
    (by rw [a0]; exact align_off hp.align hp.fit _ (by decide) (by decide))
    (by rw [a2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
    (by rw [a0, a1]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [a2]; exact ok_off hp _ _ (by decide) (by decide))
  obtain ⟨s5, e5, hs5⟩ : ∃ s5, run env 1 s4 = .running s5 ∧ s5 = hashed env s4 :=
    ⟨_, (stepK (prog := kernel) hp 40 (by decide) (by rw [mm]; exact hcode) p4 (i := .ecall) (by decide) hexec 0).trans
        (run_zero _ _), rfl⟩
  refine ⟨s5, run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 e5))), ?_, ?_, ?_⟩
  · rw [hs5, hashed]; simp only [next_pc]; rw [p4]; exact pc_next hp.fit 40 (by decide)
  · rw [hs5, hashed]; simp only [next_mem, mm, a0, a1, a2]; rfl
  · intro r h0 h1 h2 h3
    rw [hs5, hashed]
    simp only [next_reg, mk_reg, r4, r3, r2, r1, h0, h1, h2, h3, false_and, ↓reduceIte]

/-- **What is hashed** is preimage `i` and 32 zeros — the padding the
briefing settled on — read back from what the copy left in scratch. -/
theorem hash_input {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte} {i : Nat}
    (hi : i < 256) (hout : Outside base m0 m)
    (htail : ∀ d < 32, m (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0) :
    readBytes (overlay m (base + BitVec.ofNat 32 SCR) 32
        (fun d => m (base + BitVec.ofNat 32 (SIG + 32 * i + d)))) (base + BitVec.ofNat 32 SCR) 64
      = preimage m0 base i ++ List.replicate 32 0 := by
  refine (readBytes_append _ _ 32 32).trans (app_congr ?_ ?_)
  · apply readBytes_shift
    intro d hd
    have hx : (base + BitVec.ofNat 32 SCR + BitVec.ofNat 32 d - (base + BitVec.ofNat 32 SCR)).toNat = d := by
      rw [off_add hfit _ _ (by simp only [SCR]; omega)]; exact dist_off hfit _ _ (by simp only [SCR]; omega)
    simp only [overlay, hx, hd, ↓reduceIte]
    rw [off_add hfit _ _ (by simp only [SIG]; omega)]
    apply hout
    unfold InScr
    rw [toNat_sub_off hfit _ SCR (by decide), toNat_off hfit _ (by simp only [SIG]; omega)]
    simp only [SIG, SCR]; omega
  · apply readBytes_const
    intro d hd
    rw [off_add hfit _ _ (by simp only [SCR]; omega), off_add hfit _ _ (by simp only [SCR]; omega), Nat.add_assoc]
    have hx := dist_off hfit SCR (32 + d) (by simp only [SCR]; omega)
    simp only [overlay, hx, show ¬ 32 + d < 32 by omega, ↓reduceIte]
    rw [← Nat.add_assoc]; exact htail d hd

/-! ## Block 2: one iteration — which half of the public key -/

/-- `srli t1, s4, 3`: the byte the bit is in. -/
theorem shr3 (i : Nat) (hi : i < 256) : BitVec.ofNat 32 i >>> 3 = BitVec.ofNat 32 (i / 8) := by
  apply BitVec.eq_of_toNat_eq
  simp [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
  omega
/-- `andi t2, s4, 7`: which bit of it. -/
theorem and7 (i : Nat) (hi : i < 256) :
    BitVec.ofNat 32 i &&& BitVec.signExtend 32 (7 : BitVec 12) = BitVec.ofNat 32 (i % 8) := by
  rw [show BitVec.signExtend 32 (7 : BitVec 12) = BitVec.ofNat 32 7 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat]
  rw [show (7 : Nat) % 2^32 = 2^3 - 1 by decide, Nat.and_two_pow_sub_one_eq_mod]
  omega
/-- `srl`, `andi 1`, `slli 5`: the bit, times 32 — the offset of the half it picks. -/
theorem bit_times_32 (b k : Nat) (hb : b < 256) (hk : k < 8) :
    (BitVec.ofNat 32 b >>> ((BitVec.ofNat 32 k).toNat % 32) &&& BitVec.signExtend 32 (1 : BitVec 12)) <<< 5
      = BitVec.ofNat 32 (32 * (b / 2 ^ k % 2)) := by
  rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_shiftLeft, BitVec.toNat_and, BitVec.toNat_ushiftRight, BitVec.toNat_ofNat,
    Nat.shiftRight_eq_div_pow, Nat.shiftLeft_eq]
  rw [show (1 : Nat) % 2^32 = 1 from rfl, Nat.and_one_is_mod]
  have : b % 2^32 = b := Nat.mod_eq_of_lt (by omega)
  have : k % 2^32 % 32 = k := by omega
  simp only [*]
  omega

/-- Eight instructions: `t1` is where the half of public key `i` that bit `i`
of the message selects begins. -/
theorem pick_block {env : Env} {base : Word} (hp : Placed env base) {i : Nat} (hi : i < 256)
    {m0 : Word → Byte} {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 164)
    (hcode : CodeAt s.mem base kernel) (hout : Outside base m0 s.mem)
    (h2 : s.reg S2 = base + BitVec.ofNat 32 (PK + 64 * i)) (h3 : s.reg S3 = base + BitVec.ofNat 32 MSG)
    (h4 : s.reg S4 = BitVec.ofNat 32 i) :
    ∃ s', run env 8 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 196 ∧ s'.mem = s.mem
      ∧ s'.reg T1 = base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i)
      ∧ ∀ r, r ≠ T1 → r ≠ T2 → s'.reg r = s.reg r := by
  have z1 : T1 ≠ 0 := by decide
  have z2 : T2 ≠ 0 := by decide
  have n21 : T2 ≠ T1 := by decide
  have n12 : T1 ≠ T2 := by decide
  have n31 : S3 ≠ T1 := by decide
  have n41 : S4 ≠ T1 := by decide
  have n42 : S4 ≠ T2 := by decide
  have n2t1 : S2 ≠ T1 := by decide
  have n2t2 : S2 ≠ T2 := by decide
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 41 (by decide) hcode (by rw [hpc]; try rfl)
    (i := .sh .srli T1 S4 3) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 42 (by decide) (by rw [m1]; exact hcode) p1
    (i := .op .add T1 S3 T1) (by decide) rfl
  have t1 : s2.reg T1 = base + BitVec.ofNat 32 (MSG + i / 8) := by
    rw [reg_wrote r2 z1, reg_kept r1 n31, reg_wrote r1 z1, h3, h4]
    simp only [aluR, shiftI]
    rw [show ((3 : BitVec 5)).toNat = 3 from rfl, shr3 i hi, off_add hp.fit _ _ (by simp only [MSG]; omega)]
  obtain ⟨s3, e3, p3, m3, r3⟩ := lbuStep (prog := kernel) hp 43 (by decide) (by rw [m2, m1]; exact hcode) p2
    (rd := T1) (rs1 := T1) (imm := 0) (by decide) (MSG + i / 8)
    (by rw [t1, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _)
    (by simp only [MSG]; omega)
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 44 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
    (i := .opi .andi T2 S4 7) (by decide) rfl
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 45 (by decide) (by rw [m4, m3, m2, m1]; exact hcode) p4
    (i := .op .srl T1 T1 T2) (by decide) rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 46 (by decide) (by rw [m5, m4, m3, m2, m1]; exact hcode) p5
    (i := .opi .andi T1 T1 1) (by decide) rfl
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 47 (by decide) (by rw [m6, m5, m4, m3, m2, m1]; exact hcode) p6
    (i := .sh .slli T1 T1 5) (by decide) rfl
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 48 (by decide) (by rw [m7, m6, m5, m4, m3, m2, m1]; exact hcode) p7
    (i := .op .add T1 S2 T1) (by decide) rfl
  have byte : s.mem (base + BitVec.ofNat 32 (MSG + i / 8)) = m0 (base + BitVec.ofNat 32 (MSG + i / 8)) := by
    apply hout; unfold InScr
    rw [toNat_sub_off hp.fit _ SCR (by decide), toNat_off hp.fit _ (by simp only [MSG]; omega)]
    have := base.isLt; have := hp.fit
    simp only [MSG, SCR]; omega
  have nT : ∀ r, r ≠ T1 → r ≠ T2 → s8.reg r = s.reg r := by
    intro r a b
    rw [reg_kept r8 a, reg_kept r7 a, reg_kept r6 a, reg_kept r5 a, reg_kept r4 b, r3]
    simp only [a, false_and, ↓reduceIte]
    rw [reg_kept r2 a, reg_kept r1 a]
  refine ⟨s8, ?_, by rw [p8]; try rfl, by rw [m8, m7, m6, m5, m4, m3, m2, m1], ?_, nT⟩
  · exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7 e8))))))
  · have v3 : s3.reg T1 = BitVec.ofNat 32 (m0 (base + BitVec.ofNat 32 (MSG + i / 8))).toNat := by
      rw [r3]; simp only [z1, ne_eq, not_false_eq_true, and_self, ↓reduceIte]; rw [m2, m1, byte]
    have v4 : s4.reg T2 = BitVec.ofNat 32 (i % 8) := by
      rw [reg_wrote r4 z2, reg_kept r3 n41, reg_kept r2 n41, reg_kept r1 n41, h4]
      simp only [aluI]; exact and7 i hi
    rw [reg_wrote r8 z1, reg_kept r7 n2t1, reg_kept r6 n2t1, reg_kept r5 n2t1, reg_kept r4 n2t2,
      r3]
    simp only [show ¬ (S2 = T1 ∧ T1 ≠ 0) from fun h => n2t1 h.1, ↓reduceIte]
    rw [reg_kept r2 n2t1, reg_kept r1 n2t1, h2, reg_wrote r7 z1, reg_wrote r6 z1, reg_wrote r5 z1,
      reg_kept r4 n12, v3, v4]
    simp only [aluR, aluI, shiftI]
    rw [show ((5 : BitVec 5)).toNat = 5 from rfl,
      bit_times_32 _ _ (m0 (base + BitVec.ofNat 32 (MSG + i / 8))).isLt (by omega),
      off_add hp.fit _ _ (by have : bitAt m0 base i ≤ 1 := by unfold bitAt; omega
                             simp only [PK]; omega)]
    rfl

/-! ## Block 2: one iteration — the compare -/

/-- Eight words, each `xor`ed against its counterpart and `or`ed into `s6`,
with no early exit: afterwards `s6` is zero exactly when it was before and all
eight words matched. `c` is where the public-key half starts. -/
theorem compare_block {env : Env} {base : Word} (hp : Placed env base) {c : Nat}
    (hc : c + 32 ≤ SCR) (hc4 : c % 4 = 0)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 196) (hcode : CodeAt s.mem base kernel)
    (h1 : s.reg T1 = base + BitVec.ofNat 32 c) (h5 : s.reg S5 = base + BitVec.ofNat 32 SCR) :
    ∀ j ≤ 8, ∃ s', run env (4 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (196 + 16 * j)
      ∧ s'.mem = s.mem
      ∧ (s'.reg S6 = 0 ↔ s.reg S6 = 0 ∧ ∀ j' < j,
          readLE s.mem (base + BitVec.ofNat 32 (SCR + 64 + 4 * j')) 4
            = readLE s.mem (base + BitVec.ofNat 32 (c + 4 * j')) 4)
      ∧ ∀ r, r ≠ S6 → r ≠ T2 → r ≠ T3 → s'.reg r = s.reg r := by
  intro j hj
  obtain ⟨s', e, p, mm, z, r⟩ := (compare_words (prog := kernel) hp (k0 := 49) (ra := S5) (rb := T1)
    (acc := S6) (t := T2) (u := T3) (oa := 64) (ob := 0) (a := SCR) (b := c)
    (fun j hj => ⟨at_cmp_out j hj,
      by rw [show 49 + 4 * j + 1 = 50 + 4 * j by omega, Nat.zero_add]; exact at_cmp_pk j hj,
      by rw [show 49 + 4 * j + 2 = 51 + 4 * j by omega]; exact at_cmp_xor j hj,
      by rw [show 49 + 4 * j + 3 = 52 + 4 * j by omega]; exact at_cmp_or j hj⟩)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by simp only [SCR]; omega) (by simp only [SCR] at hc; omega) (by decide) (by omega)
    (by rw [hpc]) hcode h5 h1) j hj
  refine ⟨s', e, by rw [p]; congr 2; omega, mm, ?_, r⟩
  simpa only [Nat.add_zero] using z

/-! ## Words and bytes -/

/-- HASH's 32 bytes go after scratch's first 64, so below scratch nothing moves. -/
theorem writeBytes_outside {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte)
    (f : Fin 32 → Byte) : Outside base m (writeBytes m (base + BitVec.ofNat 32 (SCR + 64)) f) := by
  intro x hx
  unfold InScr at hx
  rw [writeBytes_apply]
  rw [toNat_sub_off hfit _ SCR (by decide)] at hx
  have : ¬ (x - (base + BitVec.ofNat 32 (SCR + 64))).toNat < 32 := by
    rw [toNat_sub_off hfit _ _ (by unfold SCR; omega)]
    have := x.isLt; have := base.isLt
    unfold SCR at hx ⊢
    generalize x.toNat = X at *
    generalize base.toNat = B at *
    rw [wrapdist _ _ (by omega) (by omega)] at hx ⊢
    simp only [Nat.reducePow, Nat.reduceAdd] at *
    split at hx <;> split <;> simp only [Nat.not_lt] at * <;> omega
  simp only [this, ↓reduceDIte]

theorem Outside.trans {base : Word} {a b c : Word → Byte} (h1 : Outside base a b) (h2 : Outside base b c) :
    Outside base a c := fun x hx => (h2 x hx).trans (h1 x hx)

/-- **What the compare decided is the definition.** With HASH's output at
`SCR + 64` and the public key untouched, the eight words matching is exactly
`Good`: preimage `i`, padded, hashes to the half bit `i` selects. -/
theorem good_iff {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 Mc M : Word → Byte} {i : Nat} (hi : i < 256)
    (hM : M = writeBytes Mc (base + BitVec.ofNat 32 (SCR + 64)) (H (preimage m0 base i ++ List.replicate 32 0)))
    (hout : Outside base m0 M) :
    (∀ j < 8, readLE M (base + BitVec.ofNat 32 (SCR + 64 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i + 4 * j)) 4)
      ↔ Good H m0 base i := by
  have hb : bitAt m0 base i ≤ 1 := by unfold bitAt; omega
  have e : ∀ j < 8, (readLE M (base + BitVec.ofNat 32 (SCR + 64 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i + 4 * j)) 4)
      = (readLE M (base + BitVec.ofNat 32 (SCR + 64) + BitVec.ofNat 32 (4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i) + BitVec.ofNat 32 (4 * j)) 4) := by
    intro j hj
    rw [off_add hfit _ _ (by simp only [SCR]; omega), off_add hfit _ _ (by simp only [PK]; omega)]
  rw [show (∀ j < 8, _) ↔ (∀ j < 8, _) from forall_congr' fun j => imp_congr_right fun hj => by rw [e j hj],
    words_iff_bytes]
  have hO : ∀ d (hd : d < 32), M (base + BitVec.ofNat 32 (SCR + 64) + BitVec.ofNat 32 d)
      = H (preimage m0 base i ++ List.replicate 32 0) ⟨d, hd⟩ := by
    intro d hd
    rw [hM, writeBytes_apply, off_add hfit _ _ (by simp only [SCR]; omega),
      dist_off hfit _ _ (by simp only [SCR]; omega)]
    simp only [hd, ↓reduceDIte]
  have hP : ∀ d < 32, M (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i) + BitVec.ofNat 32 d)
      = m0 (base + BitVec.ofNat 32 (PK + 64 * i + 32 * bitAt m0 base i + d)) := by
    intro d hd
    rw [off_add hfit _ _ (by simp only [PK]; omega)]
    apply hout
    unfold InScr
    rw [toNat_sub_off hfit _ SCR (by decide), toNat_off hfit _ (by simp only [PK]; omega)]
    have := base.isLt
    rw [wrapdist _ _ (by simp only [SCR]; omega) (by simp only [PK]; omega),
      ite_eq_right_of_eq_false _ _ (eq_false (by simp only [SCR, PK]; omega))]
    simp only [Nat.not_lt]
    simp only [PK, SCR, Nat.reduceAdd, Nat.reducePow] at *
    omega
  unfold Good
  constructor
  · intro h d
    rw [← hO d.val d.isLt, ← hP d.val d.isLt]
    exact h d.val d.isLt
  · intro h d hd
    rw [hO d hd, hP d hd]
    exact h ⟨d, hd⟩

/-! ## Block 2: the loop -/

/-- At the top of iteration `i` — or, once `i` is 256, at the instruction
after the loop: the pointers have moved `i` steps, `s6` is zero exactly when
every preimage so far was good, memory is the original outside scratch, and
the HASH input's zero tail is still zero. -/
structure Inv (env : Env) (base : Word) (m0 : Word → Byte) (i : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (if i < 256 then 80 else 340)
  regs : Regs base s
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SIG + 32 * i)
  s2 : s.reg S2 = base + BitVec.ofNat 32 (PK + 64 * i)
  s4 : s.reg S4 = BitVec.ofNat 32 i
  acc : s.reg S6 = 0 ↔ ∀ j < i, Good env.hash m0 base j
  out : Outside base m0 s.mem
  tail : ∀ d < 32, s.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0

theorem iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 256) {s : Machine} (h : Inv env base m0 i s) :
    ∃ s', run env 65 s = .running s' ∧ Inv env base m0 (i + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 80 := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := code_of_outside fit h.out hc0
  -- the copy
  obtain ⟨sc, ec, pc_, mc, rc⟩ := copy_block hp hi hpc hcode h.s1 h.regs.s5 8 (Nat.le_refl _)
  have oc : Outside base s.mem sc.mem := by
    rw [mc]; exact overlay_outside fit _ _ (Nat.le_refl _) (by simp only [SCR]; omega) _
  have hcc : CodeAt sc.mem base kernel := code_of_outside fit oc hcode
  -- HASH
  obtain ⟨sh, eh, ph, mh, rh⟩ := hash_block hp (s := sc) (by rw [pc_]) hcc
    (by rw [rc _ (by decide), h.regs.s5])
  have hin : readBytes sc.mem (base + BitVec.ofNat 32 SCR) 64 = preimage m0 base i ++ List.replicate 32 0 := by
    rw [mc]; exact hash_input fit hi h.out h.tail
  rw [hin] at mh
  have oh : Outside base m0 sh.mem := h.out.trans (oc.trans (by rw [mh]; exact writeBytes_outside fit _ _))
  have hch : CodeAt sh.mem base kernel := code_of_outside fit oh hc0
  -- which half
  have keep : ∀ r, r ≠ T4 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → sh.reg r = s.reg r :=
    fun r a b c d e => (rh r b c d e).trans (rc r a)
  obtain ⟨sp, ep, pp, mp, tp, rp⟩ := pick_block hp hi (m0 := m0) (s := sh) ph hch oh
    (by rw [keep _ (by decide) (by decide) (by decide) (by decide) (by decide), h.s2])
    (by rw [keep _ (by decide) (by decide) (by decide) (by decide) (by decide), h.regs.s3])
    (by rw [keep _ (by decide) (by decide) (by decide) (by decide) (by decide), h.s4])
  have hb : bitAt m0 base i ≤ 1 := by unfold bitAt; omega
  -- the compare
  obtain ⟨sq, eq, pq, mq, zq, rq⟩ := compare_block hp (c := PK + 64 * i + 32 * bitAt m0 base i)
    (by simp only [PK, SCR]; omega) (by simp only [PK]; omega) (s := sp) pp (by rw [mp]; exact hch) tp
    (by rw [rp _ (by decide) (by decide), keep _ (by decide) (by decide) (by decide) (by decide) (by decide),
      h.regs.s5]) 8 (Nat.le_refl _)
  have keep2 : ∀ r, r ≠ T4 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T1 → r ≠ T2 → r ≠ S6 → r ≠ T3 →
      sq.reg r = s.reg r :=
    fun r a b c d e f g k l => (rq r k g l).trans ((rp r f g).trans (keep r a b c d e))
  have mq' : sq.mem = sh.mem := by rw [mq, mp]
  have hcq : CodeAt sq.mem base kernel := by rw [mq']; exact hch
  -- advance
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 81 (by decide) hcq (by rw [pq]; try rfl)
    (i := .opi .addi S1 S1 32) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 82 (by decide) (by rw [m1]; exact hcq) p1
    (i := .opi .addi S2 S2 64) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 83 (by decide) (by rw [m2, m1]; exact hcq) p2
    (i := .opi .addi S4 S4 1) (by decide) rfl
  have v4 : s3.reg S4 = BitVec.ofNat 32 (i + 1) := by
    rw [reg_wrote r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide),
      keep2 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      h.s4]
    simp only [aluI]
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat, show (BitVec.signExtend 32 (1 : BitVec 12)).toNat = 1 by decide]
    omega
  have v7 : s3.reg S7 = BitVec.ofNat 32 256 := by
    rw [reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide),
      keep2 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      h.regs.s7]
  have ht : taken .bne (s3.reg S4) (s3.reg S7) = decide (i + 1 < 256) := by
    rw [v4, v7]; simp only [taken]
    by_cases hl : i + 1 < 256
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e; simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      apply BitVec.eq_of_toNat_eq; simp; omega
  have hc3 : CodeAt s3.mem base kernel := by rw [m3, m2, m1]; exact hcq
  -- every register but the three the loop advances, and s6, is as it was
  have kept : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ S4 → s3.reg r = sq.reg r :=
    fun r a b c => (reg_kept r3 c).trans ((reg_kept r2 b).trans (reg_kept r1 a))
  have keep3 : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ S4 → r ≠ T4 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T1 →
      r ≠ T2 → r ≠ S6 → r ≠ T3 → s3.reg r = s.reg r :=
    fun r a b c d e f g k l n o q => (kept r a b c).trans (keep2 r d e f g k l n o q)
  -- What the branch leaves, whichever way it goes: the registers and memory
  -- of `s3`, and a pc. Everything else is proved once, for both.
  have finish : ∀ s4 : Machine, run env 1 s3 = .running s4 → (∀ r, s4.reg r = s3.reg r) →
      s4.mem = s3.mem → s4.pc = base + BitVec.ofNat 32 (if i + 1 < 256 then 80 else 340) →
      ∃ s', run env 65 s = .running s' ∧ Inv env base m0 (i + 1) s' := by
    intro s4 e4 breg bmem' p4
    have bmem : s4.mem = sh.mem := by rw [bmem', m3, m2, m1, mq']
    refine ⟨s4, ?_, ?_⟩
    · rw [show 65 = 16 + (5 + (8 + (32 + (1 + (1 + (1 + 1)))))) by rfl, run_add_running ec, run_add_running eh,
        run_add_running ep, run_add_running eq, run_cons e1 (run_cons e2 (run_cons e3 e4))]
    constructor
    · exact p4
    · exact ⟨by rw [breg, keep3 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.regs.s3],
        by rw [breg, keep3 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.regs.s5],
        by rw [breg, v7]⟩
    · rw [breg, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
        keep2 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide), h.s1]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [SIG]; omega)]
      congr 2 <;> omega
    · rw [breg, reg_kept r3 (by decide), reg_wrote r2 (by decide), reg_kept r1 (by decide),
        keep2 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide), h.s2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide,
        off_add fit _ _ (by simp only [PK]; omega)]
      congr 2 <;> omega
    · rw [breg, v4]
    · rw [breg, kept _ (by decide) (by decide) (by decide), zq,
        rp _ (by decide) (by decide), keep _ (by decide) (by decide) (by decide) (by decide) (by decide),
        h.acc, mp, good_iff fit hi mh oh]
      constructor
      · rintro ⟨hall, hgood⟩ j hj
        rcases (by omega : j < i ∨ j = i) with hj | hj
        · exact hall j hj
        · subst hj; exact hgood
      · intro hall
        exact ⟨fun j hj => hall j (by omega), hall i (by omega)⟩
    · rw [bmem]; exact oh
    · intro d hd
      rw [bmem, mh, writeBytes_apply]
      have far : ¬ (base + BitVec.ofNat 32 (SCR + 32 + d) - (base + BitVec.ofNat 32 (SCR + 64))).toNat < 32 := by
        rw [BitVec.toNat_sub, toNat_off fit _ (by simp only [SCR]; omega), toNat_off fit _ (by simp only [SCR]; omega)]
        have := base.isLt
        rw [show 2 ^ 32 - (base.toNat + (SCR + 64)) + (base.toNat + (SCR + 32 + d))
          = (2 ^ 32 - 32 + d) by simp only [SCR]; omega]
        rw [Nat.mod_eq_of_lt (by omega)]
        simp only [Nat.not_lt]; omega
      simp only [far, ↓reduceDIte]
      rw [mc]; unfold overlay
      rw [show SCR + 32 + d = SCR + (32 + d) by omega, dist_off fit _ _ (by simp only [SCR]; omega)]
      simp only [show ¬ 32 + d < 32 by omega, ↓reduceIte]
      rw [← Nat.add_assoc]; exact h.tail d hd
  have ht' : taken .bne (s3.reg S4) (s3.reg S7) = decide (i + 1 < 256) := ht
  by_cases hl : i + 1 < 256
  · have e4 : run env 1 s3 = .running (s3.setPc (s3.pc + ((0xf80 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 84 (by decide) hc3 p3 (i := .br .bne S4 S7 0xf80) (by decide)
        (exec_br_taken (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p3]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 s3 = .running s3.next :=
      (stepK (prog := kernel) hp 84 (by decide) hc3 p3 (i := .br .bne S4 S7 0xf80) (by decide)
        (exec_br_not (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p3]
    rw [show (4 : Word) = BitVec.ofNat 32 4 from rfl, off_add fit _ _ (by decide)]

/-! ## The whole kernel -/

/-- Twenty instructions of setup, from `base`: the loop's invariant for `i = 0`. -/
theorem start {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 20 s = .running s' ∧ Inv env base s.mem 0 s' := by
  obtain ⟨s12, e12, p12, m12, rg, h1, h2, h4, h6⟩ := setup_regs hp s hpc hcode
  obtain ⟨s20, e8, p20, m20, r20⟩ := zero_tail hp p12 m12 hcode rg.s5 8 (Nat.le_refl _)
  refine ⟨s20, by rw [show 20 = 12 + 8 by rfl, run_add_running e12, e8], ?_⟩
  refine ⟨by rw [p20]; rfl, ⟨by rw [r20, rg.s3], by rw [r20, rg.s5], by rw [r20, rg.s7]⟩,
    by rw [r20, h1]; rfl, by rw [r20, h2]; rfl, by rw [r20, h4]; rfl,
    by rw [r20, h6]; simp, ?_, ?_⟩
  · rw [m20]; exact overlay_outside hp.fit _ _ (by simp only [SCR]; omega) (by simp only [SCR]; omega) _
  · intro d hd
    rw [m20]; unfold overlay
    rw [show SCR + 32 + d = (SCR + 32) + d by rfl, dist_off hp.fit _ _ (by simp only [SCR]; omega)]
    simp only [show d < 4 * 8 by omega, ↓reduceIte]

/-- 256 iterations, by induction: after `j` of them, the invariant holds for `j`. -/
theorem loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv env base m0 0 s) :
    ∀ j ≤ 256, ∃ s', run env (65 * j) s = .running s' ∧ Inv env base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 65 * (j + 1) = 65 * j + 65 by omega, run_add_running e, e'], hs''⟩

/-- Three instructions after the loop: the verdict, and HALT. -/
theorem halt {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv env base m0 256 s) :
    ∃ s1 s2, run env 2 s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash m0 base then 0 else 1) s2 ∧ s2.mem = s.mem := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 85) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := code_of_outside hp.fit h.out hc0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 85 (by decide) hcode hpc
    (i := .op .sltu A0 0 S6) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 86 (by decide) (by rw [m1]; exact hcode) p1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : s2.reg T0 = 1 := by rw [reg_wrote r2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : s2.reg A0 = if Verifies env.hash m0 base then 0 else 1 := by
    rw [reg_kept r2 (by decide), reg_wrote r1 (by decide)]
    simp only [aluR, reg_zero]
    rw [sltu_zero]
    have : s.reg S6 = 0 ↔ Verifies env.hash m0 base := h.acc
    by_cases hv : Verifies env.hash m0 base
    · simp [hv, this.mpr hv]
    · have hn : ¬ s.reg S6 = 0 := fun e => hv (this.mp e)
      rw [ite_eq_right_of_eq_false _ _ (eq_false hn), ite_eq_right_of_eq_false _ _ (eq_false hv)]
  refine ⟨s2, s2, run_cons e1 e2, ?_, by rw [m2, m1]⟩
  rw [← a0]
  exact (step_of_code (k := 87) (by rw [kernel_length]; decide) (by rw [m2, m1]; exact hcode)
      (by rw [p2])
      (by rw [p2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [p2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[87]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction `k`.
Eighty-eight cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 352 ≤ img.size)
    (himg : ∀ d (h : d < 352), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- Setup, 256 iterations, and the two instructions before the `ecall`. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env 16662 s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash s.mem base then 0 else 1) s2
      ∧ Outside base s.mem s2.mem := by
  obtain ⟨s20, e20, inv0⟩ := start hp s hpc hcode
  obtain ⟨sL, eL, invL⟩ := loop hp hcode inv0 256 (Nat.le_refl _)
  obtain ⟨s1, s2, e2, e1, hm⟩ := halt hp hcode invL
  refine ⟨s1, s2, ?_, e1, by rw [hm]; exact invL.out⟩
  rw [show 16662 = 20 + (65 * 256 + 2) by rfl, run_add_running e20, run_add_running eL, e2]

/-- **The kernel checks a Lamport signature.** From `base`, with the kernel's
352 bytes there, it halts with 0 if all 256 preimages hash to the half of the
public key their message bit selects, and with 1 if any one does not — for
every message, signature, key and `HASH`; and it writes nothing outside its
96 bytes of scratch. -/
theorem verifies {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 16663 s = .halted (if Verifies env.hash s.mem base then 0 else 1) s'
      ∧ Outside base s.mem s'.mem := by
  obtain ⟨s1, s2, e, e1, hm⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s2, by rw [show 16663 = 16662 + 1 by rfl, run_add_running e, e1], hm⟩

/-- **And in exactly 16663 instructions, whatever the verdict.** It has not
stopped after 16662: there is no early exit on the first bad preimage, and no
input the count depends on. -/
theorem exactly_16663 {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1, run env 16662 s = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s1, e⟩

/-- **From the state the shell builds**: any image that begins with the
kernel's 352 bytes. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 352 ≤ img.size) (himg : ∀ d (h : d < 352), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env 16662 (boot env.region img) = .running s1) ∧
    ∃ s', run env 16663 (boot env.region img)
        = .halted (if Verifies env.hash (memOfImage base img) base then 0 else 1) s'
      ∧ Outside base (memOfImage base img) s'.mem := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  refine ⟨exactly_16663 hp _ hpc hcode, ?_⟩
  obtain ⟨s', e, h⟩ := verifies hp _ hpc hcode
  rw [hmem] at e h
  exact ⟨s', e, h⟩

#print axioms bytes_words
#print axioms code_of_image
#print axioms copy_block
#print axioms hash_block
#print axioms pick_block
#print axioms compare_block
#print axioms good_iff
#print axioms iter
#print axioms loop
#print axioms halt
#print axioms verifies
#print axioms exactly_16663
#print axioms from_boot

end Exp204

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp204.image
  | _ => pure ()
  for (i, k) in Exp204.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
