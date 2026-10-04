/-
SPDX-License-Identifier: Apache-2.0

# exp205 — a WOTS (w = 16) verify kernel, proved

The kernel, as data; its bytes, which are `kernel.bin`; and what they do,
for every message, signature, public key and HASH.
-/
import Rv32.Blocks
import Rv32.Asm

namespace Exp205
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S3 : Reg := 19
def S5 : Reg := 21
def S6 : Reg := 22
def S7 : Reg := 23
def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def A3 : Reg := 13
def A4 : Reg := 14
def A5 : Reg := 15
def A6 : Reg := 16

/-- Where everything is, from `auipc`; the HASH input's zero half; `t0 = 0`
for every HASH from here on. -/
def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S3 S0 T1,
  .lui T1 2, .op .add S1 S0 T1,
  .lui T1 3, .op .add S2 S0 T1,
  .lui T1 8, .op .add S5 S0 T1,
  .opi .addi S6 0 0 ] ++
  (List.range 8).map (fun j => .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)))

/-- The 64 message digits into scratch, low nibble first, and their
checksum `Σ (15 - a)` into `a3`. -/
def digits : List Instr := [
  .opi .addi A4 S3 0, .opi .addi A5 S5 64, .opi .addi A6 S3 32, .opi .addi A3 0 0,
  .ld .lbu T1 A4 0, .opi .andi T2 T1 15, .sh .srli T1 T1 4,
  .st .sb A5 T2 0, .st .sb A5 T1 1,
  .op .sub A3 A3 T2, .op .sub A3 A3 T1, .opi .addi A3 A3 30,
  .opi .addi A4 A4 1, .opi .addi A5 A5 2, .br .bne A4 A6 0xfec ]

/-- The checksum's three digits, low first, after the message's. -/
def checksum : List Instr := [
  .opi .andi T1 A3 15, .st .sb A5 T1 0,
  .sh .srli T1 A3 4, .opi .andi T1 T1 15, .st .sb A5 T1 1,
  .sh .srli T1 A3 8, .st .sb A5 T1 2 ]

/-- The chains: the digit pointer, its end, and HASH's three arguments,
which no chain changes — the buffer is hashed in place. -/
def start : List Instr := [
  .opi .addi A4 S5 64, .opi .addi S7 S5 131, .opi .addi T0 0 0,
  .opi .addi A0 S5 0, .opi .addi A1 0 64, .opi .addi A2 S5 0 ]

def copy : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T4 S1 (BitVec.ofNat 12 (4 * j)), .st .sw S5 T4 (BitVec.ofNat 12 (4 * j))]

/-- `15 - d` steps along the chain, none at all when the digit is 15. -/
def walk : List Instr := [
  .ld .lbu T3 A4 0, .opi .addi T2 0 15, .op .sub T3 T2 T3,
  .br .beq T3 0 8,
  .ecall, .opi .addi T3 T3 0xfff, .br .bne T3 0 0xffc ]

def compare : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T2 S5 (BitVec.ofNat 12 (4 * j)), .ld .lw T3 S2 (BitVec.ofNat 12 (4 * j)),
     .op .xor T2 T2 T3, .op .or S6 S6 T2]

def advance : List Instr := [
  .opi .addi S1 S1 32, .opi .addi S2 S2 32, .opi .addi A4 A4 1, .br .bne A4 S7 0xf8c ]

def finish : List Instr := [ .op .sltu A0 0 S6, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  setup ++ digits ++ checksum ++ start ++ copy ++ walk ++ compare ++ advance ++ finish

/-- The kernel as bytes. This is `kernel.bin`, and the only thing on the chip
the theorems are about. -/
def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 108 := by decide

/-! ## Where everything is

Offsets from `base`, the kernel's own address, which `auipc` finds. -/

/-- The message, 32 bytes. -/
def MSG : Nat := 0x1000
/-- The signature: chain `i`'s value at `SIG + 32 i`, for `i < 67`. -/
def SIG : Nat := 0x2000
/-- The public key: chain `i`'s end at `PK + 32 i`. -/
def PK : Nat := 0x3000
/-- Scratch, 131 bytes: the HASH buffer — 32 bytes of chain value, then 32
zeros — and from `SCR + 64` the 67 digits. -/
def SCR : Nat := 0x8000

/-! ## What is proved: WOTS verification

`H` is `env.hash`, and nothing is assumed about it. -/

/-- One step along a chain: HASH of the value and 32 zeros. -/
def F (H : List Byte → Fin 32 → Byte) (x : List Byte) : List Byte := List.ofFn (H (x ++ List.replicate 32 0))

/-- `k` steps along a chain from `x`. -/
def chain (H : List Byte → Fin 32 → Byte) (x : List Byte) : Nat → List Byte
  | 0 => x
  | k + 1 => F H (chain H x k)

/-- Digit `i < 64` of the message: base 16, low nibble of each byte first. -/
def msgDigit (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  (m (base + BitVec.ofNat 32 (MSG + i / 2))).toNat / 16 ^ (i % 2) % 16

/-- The checksum of the first `n` message digits: `Σ (15 - a)`. -/
def csumTo (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 15 - msgDigit m base i).sum

/-- Digit `i < 67`: the 64 of the message, then the checksum's three, low first. -/
def digit (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  if i < 64 then msgDigit m base i else csumTo m base 64 / 16 ^ (i - 64) % 16

def sigAt (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (SIG + 32 * i)) 32

def pkAt (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (PK + 32 * i)) 32

/-- Chain `i` checks: `15 - dᵢ` more steps from the signature reach the key. -/
def Good (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) : Prop :=
  chain H (sigAt m base i) (15 - digit m base i) = pkAt m base i

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) :
    Decidable (Good H m base i) := by unfold Good; infer_instance

/-- **The signature verifies**: all 67 chains do. -/
def Verifies (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Prop :=
  ∀ i < 67, Good H m base i

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    Decidable (Verifies H m base) := by unfold Verifies; infer_instance

/-- How many HASH calls a verifier makes: `Σ (15 - dᵢ)`, which depends on
the message. -/
def steps (m : Word → Byte) (base : Word) : Nat :=
  ((List.range 67).map fun i => 15 - digit m base i).sum

/-! ## The bytes are the kernel, instruction by instruction -/

theorem at_zero : ∀ j < 8, kernel.getD (10 + j) .ecall = .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem at_copy : ∀ j < 8, kernel.getD (46 + 2 * j) .ecall = .ld .lw T4 S1 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (46 + 2 * j + 1) .ecall = .st .sw S5 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_cmp : ∀ j < 8, kernel.getD (69 + 4 * j) .ecall = .ld .lw T2 S5 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (69 + 4 * j + 1) .ecall = .ld .lw T3 S2 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (69 + 4 * j + 2) .ecall = .op .xor T2 T2 T3
    ∧ kernel.getD (69 + 4 * j + 3) .ecall = .op .or S6 S6 T2 := by
  decide

/-! ## Block 1: setup -/

/-- The registers setup leaves that nothing after it changes. -/
structure Regs (base : Word) (s : Machine) : Prop where
  s3 : s.reg S3 = base + BitVec.ofNat 32 MSG
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR

/-- Ten instructions that only set registers: the pointers, from `auipc`. -/
theorem setup_regs {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 10 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 10) ∧ s'.mem = s.mem
      ∧ Regs base s' ∧ s'.reg S1 = base + BitVec.ofNat 32 SIG ∧ s'.reg S2 = base + BitVec.ofNat 32 PK
      ∧ s'.reg S6 = 0 := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) hc1 p1
      (i := .lui T1 1) (by decide) rfl
  have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) hc2 p2
      (i := .op .add S3 S0 T1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) hc3 p3
      (i := .lui T1 2) (by decide) rfl
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) hc4 p4
      (i := .op .add S1 S0 T1) (by decide) rfl
  have hc5 : CodeAt s5.mem base kernel := by rw [m5]; exact hc4
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) hc5 p5
      (i := .lui T1 3) (by decide) rfl
  have hc6 : CodeAt s6.mem base kernel := by rw [m6]; exact hc5
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 6 (by decide) hc6 p6
      (i := .op .add S2 S0 T1) (by decide) rfl
  have hc7 : CodeAt s7.mem base kernel := by rw [m7]; exact hc6
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 7 (by decide) hc7 p7
      (i := .lui T1 8) (by decide) rfl
  have hc8 : CodeAt s8.mem base kernel := by rw [m8]; exact hc7
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp 8 (by decide) hc8 p8
      (i := .op .add S5 S0 T1) (by decide) rfl
  have hc9 : CodeAt s9.mem base kernel := by rw [m9]; exact hc8
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp 9 (by decide) hc9 p9
      (i := .opi .addi S6 0 0) (by decide) rfl
  refine ⟨s10, (run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7 (run_cons e8 (run_cons e9 e10))))))))), p10, by rw [m10, m9, m8, m7, m6, m5, m4, m3, m2, m1], ⟨?_, ?_⟩, ?_, ?_, ?_⟩ <;>
    simp [r10, r9, r8, r7, r6, r5, r4, r3, r2, r1, hpc, S0, S1, S2, S3, S5, S6, T1,
      aluR, aluI, MSG, SIG, PK, SCR] <;> rfl

/-! ## Block 2: the digits -/

/-- `andi 15`: the low nibble. -/
theorem and15 (b : Nat) (hb : b < 2^32) :
    BitVec.ofNat 32 b &&& BitVec.signExtend 32 (15 : BitVec 12) = BitVec.ofNat 32 (b % 16) := by
  rw [show BitVec.signExtend 32 (15 : BitVec 12) = BitVec.ofNat 32 15 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat]
  rw [show (15 : Nat) % 2^32 = 2^4 - 1 by decide, Nat.and_two_pow_sub_one_eq_mod]
  omega

/-- `srli n`: division by `2^n`. -/
theorem shr (b n : Nat) (hb : b < 2^32) :
    BitVec.ofNat 32 b >>> n = BitVec.ofNat 32 (b / 2 ^ n) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  rw [Nat.mod_eq_of_lt hb, Nat.mod_eq_of_lt (by have := Nat.div_le_self b (2 ^ n); omega)]

/-- `sub a3, a3, t2; sub a3, a3, t1; addi a3, a3, 30`: the checksum takes
`15 - lo` and `15 - hi`, and never wraps. -/
theorem csum_step (X lo hi : Nat) (hX : X ≤ 960) (hlo : lo < 16) (hhi : hi < 16) :
    BitVec.ofNat 32 X - BitVec.ofNat 32 lo - BitVec.ofNat 32 hi + BitVec.signExtend 32 (30 : BitVec 12)
      = BitVec.ofNat 32 (X + (15 - lo) + (15 - hi)) := by
  rw [show BitVec.signExtend 32 (30 : BitVec 12) = BitVec.ofNat 32 30 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_sub, BitVec.toNat_ofNat]
  rw [Nat.mod_eq_of_lt (show lo < 2^32 by omega), Nat.mod_eq_of_lt (show X < 2^32 by omega),
    Nat.mod_eq_of_lt (show hi < 2^32 by omega), Nat.mod_eq_of_lt (show (30 : Nat) < 2^32 by omega),
    Nat.mod_eq_of_lt (show X + (15 - lo) + (15 - hi) < 2^32 by omega)]
  generalize hA : (2 ^ 32 - lo + X) % 2 ^ 32 = A
  have hA' : A = if lo ≤ X then X - lo else 2 ^ 32 - lo + X := by
    rw [← hA]; exact wrapdist _ _ (by omega) (by omega)
  have hAlt : A < 2 ^ 32 := by rw [← hA]; exact Nat.mod_lt _ (by omega)
  generalize hB : (2 ^ 32 - hi + A) % 2 ^ 32 = B
  have hB' : B = if hi ≤ A then A - hi else 2 ^ 32 - hi + A := by
    rw [← hB]; exact wrapdist _ _ (by omega) hAlt
  have key : B + 30 = X + (15 - lo) + (15 - hi) ∨ B + 30 = X + (15 - lo) + (15 - hi) + 2 ^ 32 := by
    split at hA' <;> split at hB' <;> omega
  rcases key with k | k <;> rw [k]
  · exact Nat.mod_eq_of_lt (by omega)
  · rw [Nat.add_mod_right]; exact Nat.mod_eq_of_lt (by omega)

theorem csumTo_succ (m : Word → Byte) (base : Word) (n : Nat) :
    csumTo m base (n + 1) = csumTo m base n + (15 - msgDigit m base n) := by
  simp [csumTo, List.range_succ, List.sum_append]

theorem csumTo_le (m : Word → Byte) (base : Word) (n : Nat) : csumTo m base n ≤ 15 * n := by
  induction n with
  | zero => simp [csumTo]
  | succ n ih => rw [csumTo_succ]; omega

theorem msgDigit_lt (m : Word → Byte) (base : Word) (i : Nat) : msgDigit m base i < 16 := by
  unfold msgDigit; omega

theorem digit_lt (m : Word → Byte) (base : Word) (i : Nat) : digit m base i < 16 := by
  unfold digit; split
  · exact msgDigit_lt m base i
  · omega

theorem digit_of_lt (m : Word → Byte) (base : Word) (i : Nat) (hi : i < 64) :
    digit m base i = msgDigit m base i := by
  unfold digit; exact ite_eq_left_of_eq_true _ _ (eq_true hi)

/-- The low and the high nibble of message byte `k`, as `msgDigit` reads them. -/
theorem md_lo (m : Word → Byte) (base : Word) (k : Nat) :
    msgDigit m base (2 * k) = (m (base + BitVec.ofNat 32 (MSG + k))).toNat % 16 := by
  unfold msgDigit
  rw [show 2 * k / 2 = k by omega, show 2 * k % 2 = 0 by omega]; simp
theorem md_hi (m : Word → Byte) (base : Word) (k : Nat) :
    msgDigit m base (2 * k + 1) = (m (base + BitVec.ofNat 32 (MSG + k))).toNat / 16 := by
  unfold msgDigit
  rw [show (2 * k + 1) / 2 = k by omega, show (2 * k + 1) % 2 = 1 by omega]
  have := (m (base + BitVec.ofNat 32 (MSG + k))).isLt
  simp only [Nat.pow_one]; omega

/-- The digits, as bytes: what the kernel writes into scratch. -/
def dg (m : Word → Byte) (base : Word) : Nat → Byte := fun d => BitVec.ofNat 8 (digit m base d)

/-- At the top of digit iteration `k` — or, at 32, at the checksum: the
pointers have moved `k` bytes and `2k` digits, `a3` holds the checksum of
the first `2k` digits, and those digits are in scratch over `M`, the memory
setup left. Every register the pass does not touch is what it was in `R`. -/
structure DInv (base : Word) (m0 M : Word → Byte) (R : Machine) (k : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if k < 32 then 22 else 33))
  a4 : s.reg A4 = base + BitVec.ofNat 32 (MSG + k)
  a5 : s.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * k)
  a6 : s.reg A6 = base + BitVec.ofNat 32 (MSG + 32)
  a3 : s.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * k))
  mem : s.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) (2 * k) (dg m0 base)
  regs : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s.reg r = R.reg r

/-- One iteration of the digit pass: eleven instructions. -/
theorem digit_iter {env : Env} {base : Word} (hp : Placed env base) {m0 M : Word → Byte}
    (hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M) (hc : CodeAt M base kernel) {R : Machine}
    {k : Nat} (hk : k < 32) {s : Machine} (h : DInv base m0 M R k s) :
    ∃ s', run env 11 s = .running s' ∧ DInv base m0 M R (k + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 22) := by rw [h.pc]; simp [hk]
  have hcode : CodeAt s.mem base kernel := by
    rw [h.mem]; exact code_of_overlay fit hc (by decide) (by simp only [SCR]; omega) _
  have hbyte : s.mem (base + BitVec.ofNat 32 (MSG + k)) = m0 (base + BitVec.ofNat 32 (MSG + k)) := by
    rw [h.mem, overlay_off_out fit _ _ (by simp only [SCR]; omega) (by simp only [MSG]; omega)
      (by left; simp only [MSG, SCR]; omega)]
    exact hM.off fit (by simp only [SCR]; omega) (by simp only [MSG]; omega) (by left; simp only [MSG, SCR]; omega)
  have hb256 := (m0 (base + BitVec.ofNat 32 (MSG + k))).isLt
  generalize hb : (m0 (base + BitVec.ofNat 32 (MSG + k))).toNat = b at hb256
  -- lbu t1, 0(a4)
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := kernel) hp 22 (by decide) hcode hpc
    (rd := T1) (rs1 := A4) (imm := 0) (by decide) (MSG + k)
    (by rw [h.a4, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _)
    (by simp only [MSG]; omega)
  have v1 : s1.reg T1 = BitVec.ofNat 32 b := by rw [reg_wrote r1 (by decide), hbyte, hb]
  -- andi t2, t1, 15
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 23 (by decide) (by rw [m1]; exact hcode) p1
    (i := .opi .andi T2 T1 15) (by decide) rfl
  have v2 : s2.reg T2 = BitVec.ofNat 32 (b % 16) := by
    rw [reg_wrote r2 (by decide)]; simp only [aluI]; rw [v1]; exact and15 b (by omega)
  -- srli t1, t1, 4
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 24 (by decide) (by rw [m2, m1]; exact hcode) p2
    (i := .sh .srli T1 T1 4) (by decide) rfl
  have v3 : s3.reg T1 = BitVec.ofNat 32 (b / 16) := by
    rw [reg_wrote r3 (by decide)]; simp only [shiftI]; rw [reg_kept r2 (by decide), v1]
    exact shr b 4 (by omega)
  have a5_3 : s3.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * k) := by
    rw [reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a5]
  -- sb t2, 0(a5)
  obtain ⟨s4, e4, p4, m4, r4⟩ := sbStep (prog := kernel) hp 25 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
    (rs1 := A5) (rs2 := T2) (imm := 0) (by decide) (SCR + 64 + 2 * k)
    (by rw [a5_3, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  -- sb t1, 1(a5)
  have hc4 : CodeAt s4.mem base kernel := by
    rw [m4]; exact code_of_writeByte fit (by rw [m3, m2, m1]; exact hcode) (by rw [kernel_length]; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  obtain ⟨s5, e5, p5, m5, r5⟩ := sbStep (prog := kernel) hp 26 (by decide) hc4 p4
    (rs1 := A5) (rs2 := T1) (imm := 1) (by decide) (SCR + 64 + 2 * k + 1)
    (by rw [r4, a5_3, show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
        off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc5 : CodeAt s5.mem base kernel := by
    rw [m5]; exact code_of_writeByte fit hc4 (by rw [kernel_length]; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  -- sub a3, a3, t2; sub a3, a3, t1; addi a3, a3, 30
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 27 (by decide) hc5 p5
    (i := .op .sub A3 A3 T2) (by decide) rfl
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 28 (by decide) (by rw [m6]; exact hc5) p6
    (i := .op .sub A3 A3 T1) (by decide) rfl
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 29 (by decide) (by rw [m7, m6]; exact hc5) p7
    (i := .opi .addi A3 A3 30) (by decide) rfl
  -- addi a4, a4, 1; addi a5, a5, 2
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp 30 (by decide) (by rw [m8, m7, m6]; exact hc5) p8
    (i := .opi .addi A4 A4 1) (by decide) rfl
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp 31 (by decide)
    (by rw [m9, m8, m7, m6]; exact hc5) p9 (i := .opi .addi A5 A5 2) (by decide) rfl
  have hc10 : CodeAt s10.mem base kernel := by rw [m10, m9, m8, m7, m6]; exact hc5
  -- the values
  have kept5 : ∀ r, s5.reg r = s3.reg r := fun r => by rw [r5, r4]
  have t2_5 : s5.reg T2 = BitVec.ofNat 32 (b % 16) := by rw [kept5, reg_kept r3 (by decide), v2]
  have t1_5 : s5.reg T1 = BitVec.ofNat 32 (b / 16) := by rw [kept5, v3]
  have a3_5 : s5.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * k)) := by
    rw [kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a3]
  have v_a3 : s10.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * (k + 1))) := by
    rw [reg_kept r10 (by decide), reg_kept r9 (by decide), reg_wrote r8 (by decide), reg_wrote r7 (by decide),
      reg_wrote r6 (by decide), reg_kept r6 (by decide), t1_5, t2_5, a3_5]
    simp only [aluR, aluI]
    rw [csum_step _ _ _ (by have := csumTo_le m0 base (2 * k); omega) (by omega) (by omega),
      show 2 * (k + 1) = 2 * k + 1 + 1 by omega, csumTo_succ, csumTo_succ, md_lo, md_hi, hb]
  have v_a4 : s10.reg A4 = base + BitVec.ofNat 32 (MSG + (k + 1)) := by
    rw [reg_kept r10 (by decide), reg_wrote r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by simp only [MSG]; omega), Nat.add_assoc]
  have v_a5 : s10.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * (k + 1)) := by
    rw [reg_wrote r10 (by decide), reg_kept r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, a5_3]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (2 : BitVec 12) = BitVec.ofNat 32 2 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
    congr 2
  have v_a6 : s10.reg A6 = base + BitVec.ofNat 32 (MSG + 32) := by
    rw [reg_kept r10 (by decide), reg_kept r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a6]
  have v_mem : s10.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) (2 * (k + 1)) (dg m0 base) := by
    rw [m10, m9, m8, m7, m6, m5, m4, m3, m2, m1, h.mem, r4, v3, reg_kept r3 (by decide), v2]
    rw [← off_add fit (SCR + 64) (2 * k) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [digit_of_lt _ _ _ (by omega), md_lo, hb]),
      show SCR + 64 + 2 * k + 1 = (SCR + 64) + (2 * k + 1) by omega,
      ← off_add fit (SCR + 64) (2 * k + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [digit_of_lt _ _ _ (by omega), md_hi, hb])]
    rw [show 2 * k + 1 + 1 = 2 * (k + 1) by omega]
  have regs10 : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s10.reg r = R.reg r := by
    intro r a b c d e
    rw [reg_kept r10 c, reg_kept r9 b, reg_kept r8 a, reg_kept r7 a, reg_kept r6 a, kept5, reg_kept r3 d,
      reg_kept r2 e, reg_kept r1 d, h.regs r a b c d e]
  have ht : taken .bne (s10.reg A4) (s10.reg A6) = decide (k + 1 < 32) := by
    rw [v_a4, v_a6]; simp only [taken]
    by_cases hl : k + 1 < 32
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by simp only [MSG]; omega), toNat_off fit _ (by simp only [MSG]; omega)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show k + 1 = 32 by omega]
  -- What the branch leaves, whichever way it goes.
  have finish : ∀ s11 : Machine, run env 1 s10 = .running s11 → (∀ r, s11.reg r = s10.reg r) →
      s11.mem = s10.mem → s11.pc = base + BitVec.ofNat 32 (4 * (if k + 1 < 32 then 22 else 33)) →
      ∃ s', run env 11 s = .running s' ∧ DInv base m0 M R (k + 1) s' := by
    intro s11 e11 hr hm hp11
    refine ⟨s11, ?_, hp11, by rw [hr, v_a4], by rw [hr, v_a5], by rw [hr, v_a6], by rw [hr, v_a3],
      by rw [hm, v_mem], fun r a b c d e => by rw [hr, regs10 r a b c d e]⟩
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7
      (run_cons e8 (run_cons e9 (run_cons e10 e11)))))))))
  by_cases hl : k + 1 < 32
  · have e11 : run env 1 s10 = .running (s10.setPc (s10.pc + ((0xfec : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 32 (by decide) hc10 p10 (i := .br .bne A4 A6 0xfec) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p10]
    rw [BitVec.add_assoc]
    congr 1
  · have e11 : run env 1 s10 = .running s10.next :=
      (stepK (prog := kernel) hp 32 (by decide) hc10 p10 (i := .br .bne A4 A6 0xfec) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p10]
    exact pc_next fit 32 (by decide)

/-- Setup, the zero half of the HASH buffer, and the four instructions that
start the digit pass: the invariant for `k = 0`, over the memory setup left. -/
theorem front {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 22 s = .running s'
      ∧ DInv base s.mem (overlay s.mem (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0)) s' 0 s'
      ∧ Regs base s' ∧ s'.reg S1 = base + BitVec.ofNat 32 SIG ∧ s'.reg S2 = base + BitVec.ofNat 32 PK
      ∧ s'.reg S6 = 0 := by
  have fit := hp.fit
  obtain ⟨s10, e10, p10, m10, rg, h1, h2, h6⟩ := setup_regs hp s hpc hcode
  obtain ⟨s18, e8, p18, m18, r18⟩ := (zero_words (prog := kernel) hp (k0 := 10) (rd := S5) (o := 32)
    (a := SCR) at_zero (by decide) (by decide) (by decide) (by decide) (by decide) p10
    (by rw [m10]; exact hcode) rg.s5) 8 (Nat.le_refl _)
  have hc18 : CodeAt s18.mem base kernel := by
    rw [m18, m10]; exact code_of_overlay fit hcode (by decide) (by decide) _
  obtain ⟨s19, e19, p19, m19, r19⟩ := regStep (prog := kernel) hp 18 (by decide) hc18 p18
    (i := .opi .addi A4 S3 0) (by decide) rfl
  obtain ⟨s20, e20, p20, m20, r20⟩ := regStep (prog := kernel) hp 19 (by decide) (by rw [m19]; exact hc18) p19
    (i := .opi .addi A5 S5 64) (by decide) rfl
  obtain ⟨s21, e21, p21, m21, r21⟩ := regStep (prog := kernel) hp 20 (by decide) (by rw [m20, m19]; exact hc18) p20
    (i := .opi .addi A6 S3 32) (by decide) rfl
  obtain ⟨s22, e22, p22, m22, r22⟩ := regStep (prog := kernel) hp 21 (by decide)
    (by rw [m21, m20, m19]; exact hc18) p21 (i := .opi .addi A3 0 0) (by decide) rfl
  have kept : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ A6 → s22.reg r = s10.reg r := by
    intro r a b c d
    rw [reg_kept r22 a, reg_kept r21 d, reg_kept r20 c, reg_kept r19 b, r18]
  have s3_18 : s18.reg S3 = base + BitVec.ofNat 32 MSG := by rw [r18, rg.s3]
  have s5_18 : s18.reg S5 = base + BitVec.ofNat 32 SCR := by rw [r18, rg.s5]
  refine ⟨s22, ?_, ⟨by rw [p22]; rfl, ?_, ?_, ?_, ?_, ?_, fun r _ _ _ _ _ => rfl⟩,
    ⟨by rw [kept _ (by decide) (by decide) (by decide) (by decide), rg.s3],
     by rw [kept _ (by decide) (by decide) (by decide) (by decide), rg.s5]⟩,
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h1],
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h2],
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h6]⟩
  · rw [show 22 = 10 + (8 + (1 + (1 + (1 + 1)))) by rfl, run_add_running e10, run_add_running e8]
    exact run_cons e19 (run_cons e20 (run_cons e21 e22))
  · rw [reg_kept r22 (by decide), reg_kept r21 (by decide), reg_kept r20 (by decide), reg_wrote r19 (by decide),
      s3_18]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [reg_kept r22 (by decide), reg_kept r21 (by decide), reg_wrote r20 (by decide), reg_kept r19 (by decide),
      s5_18]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [reg_kept r22 (by decide), reg_wrote r21 (by decide), reg_kept r20 (by decide), reg_kept r19 (by decide),
      s3_18]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
      off_add fit _ _ (by simp only [MSG]; omega)]
  · rw [reg_wrote r22 (by decide), show csumTo s.mem base (2 * 0) = 0 by simp [csumTo]]
    simp only [aluI, reg_zero]; decide
  · rw [m22, m21, m20, m19, m18, m10, overlay_zero]

/-- 32 iterations, by induction: after `j` of them, the invariant holds for `j`. -/
theorem digits_loop {env : Env} {base : Word} (hp : Placed env base) {m0 M : Word → Byte}
    (hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M) (hc : CodeAt M base kernel) {R : Machine}
    {s : Machine} (h : DInv base m0 M R 0 s) :
    ∀ j ≤ 32, ∃ s', run env (11 * j) s = .running s' ∧ DInv base m0 M R j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := digit_iter hp hM hc (by omega) hs'
    exact ⟨s'', by rw [show 11 * (j + 1) = 11 * j + 11 by omega, run_add_running e, e'], hs''⟩

/-! ## Block 3: the checksum's digits, and the start of the chains -/

/-- Checksum digit `t < 3`: base 16, low first. -/
theorem digit_ck (m : Word → Byte) (base : Word) (t : Nat) :
    digit m base (64 + t) = csumTo m base 64 / 16 ^ t % 16 := by
  unfold digit; rw [ite_eq_right_of_eq_false _ _ (eq_false (by omega)), show 64 + t - 64 = t by omega]

/-- At the top of chain `i` — or, once `i` is 67, at the verdict: the
pointers have moved `i` chains, `s6` is zero exactly when every chain so far
checked, HASH's arguments are set, memory is the original outside scratch,
and scratch holds the zero half of the buffer and all 67 digits. -/
structure CInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (i : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 67 then 46 else 105))
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SIG + 32 * i)
  s2 : s.reg S2 = base + BitVec.ofNat 32 (PK + 32 * i)
  a4 : s.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + i)
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR
  s7 : s.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67)
  t0 : s.reg T0 = 0
  a0 : s.reg A0 = base + BitVec.ofNat 32 SCR
  a1 : s.reg A1 = BitVec.ofNat 32 64
  a2 : s.reg A2 = base + BitVec.ofNat 32 SCR
  acc : s.reg S6 = 0 ↔ ∀ j < i, Good H m0 base j
  out : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 s.mem
  tail : ∀ d < 32, s.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0
  dig : ∀ d < 67, s.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d

/-- Seven instructions for the checksum's digits, six to start the chains:
from the end of the digit pass to the invariant for chain 0. -/
theorem middle {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte} {R s : Machine}
    (hc0 : CodeAt m0 base kernel)
    (h : DInv base m0 (overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0)) R 32 s)
    (hR : Regs base R) (h1 : R.reg S1 = base + BitVec.ofNat 32 SIG) (h2 : R.reg S2 = base + BitVec.ofNat 32 PK)
    (h6 : R.reg S6 = 0) :
    ∃ s', run env 13 s = .running s' ∧ CInv env.hash base m0 0 s' := by
  have fit := hp.fit
  generalize hMdef : overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0) = M at h
  have hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M := by
    rw [← hMdef]; exact keeps_overlay fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega)
  have hcM : CodeAt M base kernel := hM.code fit (by simp only [SCR]; omega) (by decide) hc0
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 33) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := by
    rw [h.mem]; exact code_of_overlay fit hcM (by decide) (by simp only [SCR]; omega) _
  have hcl := csumTo_le m0 base 64
  generalize hcdef : csumTo m0 base 64 = c at hcl
  have a3 : s.reg A3 = BitVec.ofNat 32 c := by rw [h.a3, ← hcdef]
  have a5 : s.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 64) := h.a5
  -- andi t1, a3, 15; sb t1, 0(a5)
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 33 (by decide) hcode hpc
    (i := .opi .andi T1 A3 15) (by decide) rfl
  have v1 : s1.reg T1 = BitVec.ofNat 32 (c % 16) := by
    rw [reg_wrote r1 (by decide)]; simp only [aluI]; rw [a3]; exact and15 c (by omega)
  obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep (prog := kernel) hp 34 (by decide) (by rw [m1]; exact hcode) p1
    (rs1 := A5) (rs2 := T1) (imm := 0) (by decide) (SCR + 64 + 64)
    (by rw [reg_kept r1 (by decide), a5, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]
        exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  have hc2 : CodeAt s2.mem base kernel := by
    rw [m2]; exact code_of_writeByte fit (by rw [m1]; exact hcode) (by decide) (by simp only [SCR]; omega) _
  -- srli t1, a3, 4; andi t1, t1, 15; sb t1, 1(a5)
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 35 (by decide) hc2 p2
    (i := .sh .srli T1 A3 4) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 36 (by decide) (by rw [m3]; exact hc2) p3
    (i := .opi .andi T1 T1 15) (by decide) rfl
  have v4 : s4.reg T1 = BitVec.ofNat 32 (c / 16 % 16) := by
    rw [reg_wrote r4 (by decide)]; simp only [aluI]
    rw [reg_wrote r3 (by decide)]; simp only [shiftI]
    rw [r2, reg_kept r1 (by decide), a3, show ((4 : BitVec 5)).toNat = 4 from rfl, shr c 4 (by omega)]
    exact and15 _ (by omega)
  obtain ⟨s5, e5, p5, m5, r5⟩ := sbStep (prog := kernel) hp 37 (by decide) (by rw [m4, m3]; exact hc2) p4
    (rs1 := A5) (rs2 := T1) (imm := 1) (by decide) (SCR + 64 + 65)
    (by rw [reg_kept r4 (by decide), reg_kept r3 (by decide), r2, reg_kept r1 (by decide), a5,
          show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
          off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc5 : CodeAt s5.mem base kernel := by
    rw [m5]; exact code_of_writeByte fit (by rw [m4, m3]; exact hc2) (by decide) (by simp only [SCR]; omega) _
  -- srli t1, a3, 8; sb t1, 2(a5)
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 38 (by decide) hc5 p5
    (i := .sh .srli T1 A3 8) (by decide) rfl
  have v6 : s6.reg T1 = BitVec.ofNat 32 (c / 256) := by
    rw [reg_wrote r6 (by decide)]; simp only [shiftI]
    rw [r5, reg_kept r4 (by decide), reg_kept r3 (by decide), r2, reg_kept r1 (by decide), a3]
    exact shr c 8 (by omega)
  obtain ⟨s7, e7, p7, m7, r7⟩ := sbStep (prog := kernel) hp 39 (by decide) (by rw [m6]; exact hc5) p6
    (rs1 := A5) (rs2 := T1) (imm := 2) (by decide) (SCR + 64 + 66)
    (by rw [reg_kept r6 (by decide), r5, reg_kept r4 (by decide), reg_kept r3 (by decide), r2,
          reg_kept r1 (by decide), a5, show BitVec.signExtend 32 (2 : BitVec 12) = BitVec.ofNat 32 2 by decide,
          off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc7 : CodeAt s7.mem base kernel := by
    rw [m7]; exact code_of_writeByte fit (by rw [m6]; exact hc5) (by decide) (by simp only [SCR]; omega) _
  have mem7 : s7.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) 67 (dg m0 base) := by
    rw [m7, m6, m5, m4, m3, m2, m1, h.mem, v1, v4, v6]
    rw [← off_add fit (SCR + 64) (2 * 32) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [show 2 * 32 = 64 + 0 by rfl, digit_ck, hcdef, Nat.pow_zero, Nat.div_one]),
      show SCR + 64 + 65 = (SCR + 64) + (2 * 32 + 1) by rfl,
      ← off_add fit (SCR + 64) (2 * 32 + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [show 2 * 32 + 1 = 64 + 1 by rfl, digit_ck, hcdef, Nat.pow_one]),
      show SCR + 64 + 66 = (SCR + 64) + (2 * 32 + 1 + 1) by rfl,
      ← off_add fit (SCR + 64) (2 * 32 + 1 + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]
            rw [show 2 * 32 + 1 + 1 = 64 + 2 by rfl, digit_ck, hcdef, show (16 : Nat) ^ 2 = 256 by rfl,
              Nat.mod_eq_of_lt (show c / 256 < 16 by omega)])]
  have k7 : ∀ r, r ≠ T1 → s7.reg r = s.reg r := by
    intro r hr; rw [r7, reg_kept r6 hr, r5, reg_kept r4 hr, reg_kept r3 hr, r2, reg_kept r1 hr]
  have fromR : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s7.reg r = R.reg r :=
    fun r a b c d e => (k7 r d).trans (h.regs r a b c d e)
  have s5_7 : s7.reg S5 = base + BitVec.ofNat 32 SCR := by
    rw [fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), hR.s5]
  -- the chains' registers
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 40 (by decide) hc7 p7
    (i := .opi .addi A4 S5 64) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 41 (by decide) (by rw [n1]; exact hc7) q1
    (i := .opi .addi S7 S5 131) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 42 (by decide) (by rw [n2, n1]; exact hc7) q2
    (i := .opi .addi T0 0 0) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 43 (by decide) (by rw [n3, n2, n1]; exact hc7) q3
    (i := .opi .addi A0 S5 0) (by decide) rfl
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 44 (by decide)
    (by rw [n4, n3, n2, n1]; exact hc7) q4 (i := .opi .addi A1 0 64) (by decide) rfl
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := kernel) hp 45 (by decide)
    (by rw [n5, n4, n3, n2, n1]; exact hc7) q5 (i := .opi .addi A2 S5 0) (by decide) rfl
  have k6 : ∀ r, r ≠ A4 → r ≠ S7 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → t6.reg r = s7.reg r := by
    intro r a b c d e f
    rw [reg_kept u6 f, reg_kept u5 e, reg_kept u4 d, reg_kept u3 c, reg_kept u2 b, reg_kept u1 a]
  have mem6 : t6.mem = s7.mem := by rw [n6, n5, n4, n3, n2, n1]
  have mM : M = overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0) := hMdef.symm
  refine ⟨t6, ?_, ⟨by rw [q6]; rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 13 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + 1))))))))))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7
      (run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 f6)))))))))))
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), h1]; rfl
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), h2]; rfl
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_wrote u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s5_7]
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_wrote u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (131 : BitVec 12) = BitVec.ofNat 32 131 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_wrote u3 (by decide)]
    simp only [aluI, reg_zero]; decide
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_wrote u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [reg_kept u6 (by decide), reg_wrote u5 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_wrote u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), h6]
    simp
  · rw [mem6, mem7]
    exact hM.trans (keeps_overlay fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
  · intro d hd
    rw [mem6, mem7, overlay_off_out fit _ _ (by simp only [SCR]; omega) (by simp only [SCR]; omega)
      (by left; simp only [SCR]; omega), mM, overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega)
      (by omega)]
  · intro d hd
    rw [mem6, mem7, overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega) (by omega),
      show SCR + 64 + d - (SCR + 64) = d by omega]

/-! ## Block 4: one chain — the signature's value, and how far to walk it -/

/-- An address in scratch past the buffer: neither the copy nor HASH touches it. -/
theorem above_buffer {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (f : Nat → Byte)
    (c : Nat) (h1 : SCR + 32 ≤ c) (h2 : c < 0x10000) :
    overlay m (base + BitVec.ofNat 32 SCR) 32 f (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) :=
  overlay_off_out hfit _ _ (by simp only [SCR]; omega) h2 (by right; exact h1)

/-- Sixteen instructions copy chain `i`'s value into the buffer; three more
load its digit `d` and leave `t3 = 15 - d`. -/
theorem fetch {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 67) {s : Machine} (h : CInv env.hash base m0 i s) :
    ∃ s', run env 19 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 65)
      ∧ s'.reg T3 = BitVec.ofNat 32 (15 - digit m0 base i)
      ∧ readBytes s'.mem (base + BitVec.ofNat 32 SCR) 32 = sigAt m0 base i
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 m0 s'.mem
      ∧ (∀ d < 32, s'.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0)
      ∧ (∀ d < 67, s'.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d)
      ∧ ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → s'.reg r = s.reg r := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 46) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := h.out.code fit (by simp only [SCR]; omega) (by decide) hc0
  obtain ⟨sc, ec, pc_, mc, rc⟩ := (copy_words (prog := kernel) hp (k0 := 46) (rs := S1) (rd := S5) (t := T4)
    (src := SIG + 32 * i) (dst := SCR) at_copy (by decide) (by decide) (by decide) (by decide)
    (by simp only [SIG]; omega) (by decide) (by simp only [SIG]; omega) (by decide) (by decide)
    (by simp only [SIG, SCR]; omega) hpc hcode h.s1 h.s5) 8 (Nat.le_refl _)
  have hcc : CodeAt sc.mem base kernel := by rw [mc]; exact code_of_overlay fit hcode (by decide) (by decide) _
  have hdig : ∀ d < 67, sc.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d := by
    intro d hd; rw [mc, above_buffer fit _ _ _ (by omega) (by simp only [SCR]; omega)]; exact h.dig d hd
  -- lbu t3, 0(a4); addi t2, x0, 15; sub t3, t2, t3
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := kernel) hp 62 (by decide) hcc (by rw [pc_]) (rd := T3) (rs1 := A4)
    (imm := 0) (by decide) (SCR + 64 + i)
    (by rw [rc _ (by decide), h.a4, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]
        exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 63 (by decide) (by rw [m1]; exact hcc) p1
    (i := .opi .addi T2 0 15) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 64 (by decide) (by rw [m2, m1]; exact hcc) p2
    (i := .op .sub T3 T2 T3) (by decide) rfl
  have hd := digit_lt m0 base i
  have mm : s3.mem = overlay s.mem (base + BitVec.ofNat 32 SCR) (4 * 8)
      (fun d => s.mem (base + BitVec.ofNat 32 (SIG + 32 * i + d))) := by rw [m3, m2, m1, mc]
  refine ⟨s3, ?_, p3, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [show 19 = 16 + (1 + (1 + 1)) by rfl, run_add_running ec]; exact run_cons e1 (run_cons e2 e3)
  · rw [reg_wrote r3 (by decide), reg_wrote r2 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
      hdig i hi]
    simp only [aluR, aluI, reg_zero, dg]
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_sub, BitVec.toNat_add, BitVec.toNat_ofNat]
    rw [Nat.mod_eq_of_lt (show digit m0 base i < 2 ^ 8 by omega), Nat.mod_eq_of_lt (show digit m0 base i < 2 ^ 32 by omega)]
    have : ((BitVec.toNat (0 : Word) + (BitVec.signExtend 32 (15 : BitVec 12)).toNat) % 2 ^ 32) = 15 := by decide
    rw [this, show 2 ^ 32 - digit m0 base i + 15 = (15 - digit m0 base i) + 2 ^ 32 by omega, Nat.add_mod_right,
      Nat.mod_eq_of_lt (by omega)]
  · rw [mm]; unfold sigAt
    apply readBytes_shift
    intro d hd'
    rw [off_add fit _ _ (by simp only [SCR]; omega), overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega)
      (by omega), off_add fit _ _ (by simp only [SIG]; omega), show SCR + d - SCR = d by omega]
    exact h.out.off fit (by simp only [SCR]; omega) (by simp only [SIG]; omega) (by left; simp only [SIG, SCR]; omega)
  · rw [mm]; exact h.out.trans (keeps_overlay fit _ _ (by omega) (by omega) (by simp only [SCR]; omega))
  · intro d hd'
    rw [mm, above_buffer fit _ _ _ (by omega) (by simp only [SCR]; omega)]; exact h.tail d hd'
  · intro d hd'; rw [m3, m2, m1]; exact hdig d hd'
  · intro r a b c
    rw [reg_kept r3 b, reg_kept r2 c, reg_kept r1 b, rc r a]

/-! ## Block 4: one chain — the walk -/

/-- What the walk keeps, and the buffer it advances: `j` steps along the
chain from `x`. -/
structure WInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (x : List Byte) (j : Nat)
    (s : Machine) : Prop where
  buf : readBytes s.mem (base + BitVec.ofNat 32 SCR) 32 = chain H x j
  out : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 s.mem
  tail : ∀ d < 32, s.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0
  dig : ∀ d < 67, s.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d

/-- Memory after HASH of the buffer, written over the buffer. -/
def hashedMem (H : List Byte → Fin 32 → Byte) (base : Word) (m : Word → Byte) : Word → Byte :=
  writeBytes m (base + BitVec.ofNat 32 SCR) (H (readBytes m (base + BitVec.ofNat 32 SCR) 64))

/-- HASH, in place, at the buffer: one step along the chain, and nothing
else moves. -/
theorem hash_in_place {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 : Word → Byte} {x : List Byte} {j : Nat} {s : Machine} (h : WInv H base m0 x j s) :
    WInv H base m0 x (j + 1) { s with mem := hashedMem H base s.mem } := by
  have hin : readBytes s.mem (base + BitVec.ofNat 32 SCR) 64 = chain H x j ++ List.replicate 32 0 := by
    rw [show (64 : Nat) = 32 + 32 from rfl, readBytes_append, h.buf]
    congr 1
    apply readBytes_const
    intro d hd
    rw [off_add hfit _ _ (by simp only [SCR]; omega), off_add hfit _ _ (by simp only [SCR]; omega)]
    exact h.tail d hd
  have far : ∀ c, 32 ≤ c → c < 131 → hashedMem H base s.mem (base + BitVec.ofNat 32 (SCR + c))
        = s.mem (base + BitVec.ofNat 32 (SCR + c)) := by
    intro c h1 h2
    rw [hashedMem, writeBytes_apply, dist_off hfit _ _ (by simp only [SCR]; omega)]
    simp only [show ¬ c < 32 by omega, ↓reduceDIte]
  refine ⟨?_, ?_, ?_, ?_⟩
  · show readBytes (hashedMem H base s.mem) _ 32 = _
    rw [hashedMem, readBytes_writeBytes, hin]; rfl
  · exact h.out.trans (keeps_writeBytes hfit _ _ (by omega) (by omega) (by simp only [SCR]; omega))
  · intro d hd
    show hashedMem H base s.mem _ = _
    rw [Nat.add_assoc, far _ (by omega) (by omega), ← Nat.add_assoc]; exact h.tail d hd
  · intro d hd
    show hashedMem H base s.mem _ = _
    rw [Nat.add_assoc, far _ (by omega) (by omega), ← Nat.add_assoc]; exact h.dig d hd

/-- The walk, `n` rounds of `ecall; addi t3, t3, -1; bne t3, x0`: `n` more
steps along the chain, in exactly `3n` instructions. -/
theorem walk_chain {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {x : List Byte} :
    ∀ n, 0 < n → n < 16 → ∀ (j : Nat) (s : Machine), s.pc = base + BitVec.ofNat 32 (4 * 66) →
      s.reg T3 = BitVec.ofNat 32 n → s.reg T0 = 0 → s.reg A0 = base + BitVec.ofNat 32 SCR →
      s.reg A1 = BitVec.ofNat 32 64 → s.reg A2 = base + BitVec.ofNat 32 SCR → WInv env.hash base m0 x j s →
      ∃ s', run env (3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 69)
        ∧ WInv env.hash base m0 x (j + n) s' ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro _ hn j s hpc h3 h0 ha0 ha1 ha2 hw
    have hcode : CodeAt s.mem base kernel := hw.out.code fit (by simp only [SCR]; omega) (by decide) hc0
    have hexec := exec_hash (env := env) (s := s) h0 (by rw [ha1]; rfl)
      (by rw [ha0]; exact align_off hp.align fit _ (by decide) (by decide))
      (by rw [ha2]; exact align_off hp.align fit _ (by decide) (by decide))
      (by rw [ha0, ha1]; exact ok_off hp _ _ (by decide) (by decide))
      (by rw [ha2]; exact ok_off hp _ _ (by decide) (by decide))
    obtain ⟨s1, e1, hs1⟩ : ∃ s1, run env 1 s = .running s1 ∧
        s1 = ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next :=
      ⟨_, (stepK (prog := kernel) hp 66 (by decide) hcode hpc (i := .ecall) (by decide) hexec 0).trans
        (run_zero _ _), rfl⟩
    have mem1 : s1.mem = hashedMem env.hash base s.mem := by
      rw [hs1, next_mem, ha0, ha2, ha1, show (BitVec.ofNat 32 64).toNat = 64 from rfl]; rfl
    have hw1 : WInv env.hash base m0 x (j + 1) s1 := by
      obtain ⟨a, b, c, d⟩ := hash_in_place (s := s) fit hw
      exact ⟨by rw [mem1]; exact a, by rw [mem1]; exact b, by rw [mem1]; exact c, by rw [mem1]; exact d⟩
    have p1 : s1.pc = base + BitVec.ofNat 32 (4 * 67) := by
      rw [hs1]; simp only [next_pc]; rw [hpc]; exact pc_next fit 66 (by decide)
    have k1 : ∀ r, s1.reg r = s.reg r := fun r => by rw [hs1]; rfl
    have hc1 : CodeAt s1.mem base kernel := hw1.out.code fit (by simp only [SCR]; omega) (by decide) hc0
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 67 (by decide) hc1 p1
      (i := .opi .addi T3 T3 0xfff) (by decide) rfl
    have v2 : s2.reg T3 = BitVec.ofNat 32 n := by
      rw [reg_wrote r2 (by decide), k1, h3]; simp only [aluI]; exact dec_one n (by omega)
    have hw2 : WInv env.hash base m0 x (j + 1) s2 := by
      obtain ⟨a, b, c, d⟩ := hw1; exact ⟨by rw [m2]; exact a, by rw [m2]; exact b, by rw [m2]; exact c, by rw [m2]; exact d⟩
    have k2 : ∀ r, r ≠ T3 → s2.reg r = s.reg r := fun r hr => by rw [reg_kept r2 hr, k1]
    have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hc1
    by_cases hz : n = 0
    · -- the last round: fall through to the compare
      subst hz
      have e3 : run env 1 s2 = .running s2.next :=
        (stepK (prog := kernel) hp 68 (by decide) hc2 p2 (i := .br .bne T3 0 0xffc) (by decide)
          (exec_br_not (by rw [v2]; simp [taken])) 0).trans (run_zero _ _)
      refine ⟨s2.next, ?_, by simp only [next_pc, p2]; exact pc_next fit 68 (by decide), ?_, ?_⟩
      · exact run_cons e1 (run_cons e2 e3)
      · obtain ⟨a, b, c, d⟩ := hw2
        exact ⟨by rw [next_mem]; exact a, by rw [next_mem]; exact b, by rw [next_mem]; exact c,
          by rw [next_mem]; exact d⟩
      · intro r hr; rw [next_reg, k2 r hr]
    · have hne : BitVec.ofNat 32 n ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz this
      have e3 : run env 1 s2 = .running (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32)) :=
        (stepK (prog := kernel) hp 68 (by decide) hc2 p2 (i := .br .bne T3 0 0xffc) (by decide)
          (exec_br_taken (by rw [v2]; simp only [taken, bne_iff_ne, ne_eq]; exact hne)) 0).trans (run_zero _ _)
      obtain ⟨s', e', p', w', k'⟩ := ih (by omega) (by omega) (j + 1)
        (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32))
        (by simp only [setPc_pc, p2]; rw [BitVec.add_assoc]; congr 1)
        (by rw [setPc_reg, v2]) (by rw [setPc_reg, k2 _ (by decide), h0])
        (by rw [setPc_reg, k2 _ (by decide), ha0]) (by rw [setPc_reg, k2 _ (by decide), ha1])
        (by rw [setPc_reg, k2 _ (by decide), ha2])
        (by obtain ⟨a, b, c, d⟩ := hw2
            exact ⟨by rw [setPc_mem]; exact a, by rw [setPc_mem]; exact b, by rw [setPc_mem]; exact c,
              by rw [setPc_mem]; exact d⟩)
      refine ⟨s', ?_, p', by rw [show j + (n + 1) = j + 1 + n by omega]; exact w', ?_⟩
      · have := run_cons e1 (run_cons e2 (run_cons e3 e'))
        rwa [show 3 * n + 1 + 1 + 1 = 3 * (n + 1) by omega] at this
      · intro r hr; rw [k' r hr, setPc_reg, k2 r hr]

/-- `beq t3, x0` and the walk: when the digit is 15 nothing is hashed and
the branch goes straight to the compare; otherwise `15 - d` rounds. Either
way, `1 + 3n` instructions. -/
theorem skip_or_walk {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {x : List Byte} (n : Nat) (hn : n < 16) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * 65)) (h3 : s.reg T3 = BitVec.ofNat 32 n) (h0 : s.reg T0 = 0)
    (ha0 : s.reg A0 = base + BitVec.ofNat 32 SCR) (ha1 : s.reg A1 = BitVec.ofNat 32 64)
    (ha2 : s.reg A2 = base + BitVec.ofNat 32 SCR) (hw : WInv env.hash base m0 x 0 s) :
    ∃ s', run env (1 + 3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 69)
      ∧ WInv env.hash base m0 x n s' ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  have hcode : CodeAt s.mem base kernel := hw.out.code fit (by simp only [SCR]; omega) (by decide) hc0
  by_cases hz : n = 0
  · subst hz
    have e : run env 1 s = .running (s.setPc (s.pc + ((8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 65 (by decide) hcode hpc (i := .br .beq T3 0 8) (by decide)
        (exec_br_taken (by rw [h3]; simp [taken])) 0).trans (run_zero _ _)
    refine ⟨_, e, by simp only [setPc_pc, hpc]; rw [BitVec.add_assoc]; congr 1, ?_, fun r _ => setPc_reg _ _ r⟩
    obtain ⟨a, b, c, d⟩ := hw
    exact ⟨by rw [setPc_mem]; exact a, by rw [setPc_mem]; exact b, by rw [setPc_mem]; exact c,
      by rw [setPc_mem]; exact d⟩
  · have hne : BitVec.ofNat 32 n ≠ 0 := by
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz this
    have e : run env 1 s = .running s.next :=
      (stepK (prog := kernel) hp 65 (by decide) hcode hpc (i := .br .beq T3 0 8) (by decide)
        (exec_br_not (by rw [h3]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact hne)) 0).trans
        (run_zero _ _)
    obtain ⟨s', e', p', w', k'⟩ := walk_chain hp hc0 n (by omega) hn 0 s.next
      (by simp only [next_pc, hpc]; exact pc_next fit 65 (by decide))
      (by rw [next_reg, h3]) (by rw [next_reg, h0]) (by rw [next_reg, ha0]) (by rw [next_reg, ha1])
      (by rw [next_reg, ha2])
      (by obtain ⟨a, b, c, d⟩ := hw
          exact ⟨by rw [next_mem]; exact a, by rw [next_mem]; exact b, by rw [next_mem]; exact c,
            by rw [next_mem]; exact d⟩)
    refine ⟨s', ?_, p', by rw [Nat.zero_add] at w'; exact w', fun r hr => by rw [k' r hr, next_reg]⟩
    have := run_cons e e'
    rwa [Nat.add_comm] at this

/-! ## Block 4: one chain — the compare, and on to the next -/

/-- **What the compare decided is the definition.** With the walked chain in
the buffer and the public key untouched, the eight words matching is exactly
`Good`: `15 - d` steps from the signature reach the key. -/
theorem good_iff {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 M : Word → Byte} {i : Nat} (hi : i < 67) (hout : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M)
    (hbuf : readBytes M (base + BitVec.ofNat 32 SCR) 32 = chain H (sigAt m0 base i) (15 - digit m0 base i)) :
    (∀ j < 8, readLE M (base + BitVec.ofNat 32 (SCR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 32 * i + 0 + 4 * j)) 4) ↔ Good H m0 base i := by
  have e : ∀ j < 8, (readLE M (base + BitVec.ofNat 32 (SCR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 32 * i + 0 + 4 * j)) 4)
      = (readLE M (base + BitVec.ofNat 32 SCR + BitVec.ofNat 32 (4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (PK + 32 * i) + BitVec.ofNat 32 (4 * j)) 4) := by
    intro j hj
    rw [Nat.add_zero, Nat.add_zero, off_add hfit _ _ (by simp only [SCR]; omega),
      off_add hfit _ _ (by simp only [PK]; omega)]
  rw [show (∀ j < 8, _) ↔ (∀ j < 8, _) from forall_congr' fun j => imp_congr_right fun hj => by rw [e j hj],
    words_iff_bytes, bytes_iff_readBytes, hbuf]
  unfold Good pkAt
  rw [readBytes_congr (m' := m0) (fun d hd => by
    rw [off_add hfit _ _ (by simp only [PK]; omega)]
    exact hout.off hfit (by simp only [SCR]; omega) (by simp only [PK]; omega)
      (by left; simp only [PK, SCR]; omega))]

/-- **One chain**: `56 + 3 (15 - dᵢ)` instructions, from the invariant for
`i` to the invariant for `i + 1`. -/
theorem chain_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 67) {s : Machine} (h : CInv env.hash base m0 i s) :
    ∃ s', run env (56 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
  have fit := hp.fit
  have hd := digit_lt m0 base i
  obtain ⟨sf, ef, pf, tf, bf, of, lf, df, kf⟩ := fetch hp hc0 hi h
  obtain ⟨sw, ew, pw, ww, kw⟩ := skip_or_walk hp hc0 (x := sigAt m0 base i) (15 - digit m0 base i) (by omega)
    pf tf (by rw [kf _ (by decide) (by decide) (by decide), h.t0])
    (by rw [kf _ (by decide) (by decide) (by decide), h.a0]) (by rw [kf _ (by decide) (by decide) (by decide), h.a1])
    (by rw [kf _ (by decide) (by decide) (by decide), h.a2]) ⟨by rw [bf]; rfl, of, lf, df⟩
  -- every register the walk and the fetch leave alone
  have kfw : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → sw.reg r = s.reg r := fun r a b c => (kw r b).trans (kf r a b c)
  have hcw : CodeAt sw.mem base kernel := ww.out.code fit (by simp only [SCR]; omega) (by decide) hc0
  obtain ⟨sq, eq, pq, mq, zq, kq⟩ := (compare_words (prog := kernel) hp (k0 := 69) (ra := S5) (rb := S2)
    (acc := S6) (t := T2) (u := T3) (oa := 0) (ob := 0) (a := SCR) (b := PK + 32 * i) at_cmp
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by simp only [SCR]; omega) (by simp only [PK]; omega) (by decide) (by simp only [PK]; omega)
    pw hcw (by rw [kfw _ (by decide) (by decide) (by decide), h.s5])
    (by rw [kfw _ (by decide) (by decide) (by decide), h.s2])) 8 (Nat.le_refl _)
  have kwq : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → sq.reg r = s.reg r :=
    fun r a b c d => (kq r d c b).trans (kfw r a b c)
  have hcq : CodeAt sq.mem base kernel := by rw [mq]; exact hcw
  -- addi s1, s1, 32; addi s2, s2, 32; addi a4, a4, 1
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 101 (by decide) hcq pq
    (i := .opi .addi S1 S1 32) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 102 (by decide) (by rw [m1]; exact hcq) p1
    (i := .opi .addi S2 S2 32) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 103 (by decide) (by rw [m2, m1]; exact hcq) p2
    (i := .opi .addi A4 A4 1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3, m2, m1]; exact hcq
  have k3 : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → s3.reg r = s.reg r :=
    fun r a b c d e f g => by rw [reg_kept r3 c, reg_kept r2 b, reg_kept r1 a, kwq r d e f g]
  have v_a4 : s3.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + (i + 1)) := by
    rw [reg_wrote r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide),
      kwq _ (by decide) (by decide) (by decide) (by decide), h.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by simp only [SCR]; omega), Nat.add_assoc]
  have v_s7 : s3.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67) := by
    rw [k3 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s7]
  have ht : taken .bne (s3.reg A4) (s3.reg S7) = decide (i + 1 < 67) := by
    rw [v_a4, v_s7]; simp only [taken]
    by_cases hl : i + 1 < 67
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by simp only [SCR]; omega), toNat_off fit _ (by simp only [SCR]; omega)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show i + 1 = 67 by omega]
  have hmem : s3.mem = sw.mem := by rw [m3, m2, m1, mq]
  -- What the branch leaves, whichever way it goes.
  have finish : ∀ s4 : Machine, run env 1 s3 = .running s4 → (∀ r, s4.reg r = s3.reg r) →
      s4.mem = s3.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if i + 1 < 67 then 46 else 105)) →
      ∃ s', run env (56 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → s4.reg r = s.reg r :=
      fun r a b c d e f g => by rw [b4, k3 r a b c d e f g]
    have mm : s4.mem = sw.mem := by rw [m4, hmem]
    refine ⟨s4, ?_, p4, ?_, ?_, by rw [b4, v_a4], ?_, by rw [b4, v_s7], ?_, ?_, ?_, ?_, ?_,
      by rw [mm]; exact ww.out, by rw [mm]; exact ww.tail, by rw [mm]; exact ww.dig⟩
    · rw [show 56 + 3 * (15 - digit m0 base i) = 19 + ((1 + 3 * (15 - digit m0 base i)) + (32 + (1 + (1 + (1 + 1)))))
        by omega, run_add_running ef, run_add_running ew, run_add_running eq]
      exact run_cons e1 (run_cons e2 (run_cons e3 e4))
    · rw [b4, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
        kwq _ (by decide) (by decide) (by decide) (by decide), h.s1]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [SIG]; omega)]
      congr 2
    · rw [b4, reg_kept r3 (by decide), reg_wrote r2 (by decide), reg_kept r1 (by decide),
        kwq _ (by decide) (by decide) (by decide) (by decide), h.s2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [PK]; omega)]
      congr 2
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a2]
    · rw [b4, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), zq,
        kfw _ (by decide) (by decide) (by decide), h.acc,
        good_iff fit hi ww.out ww.buf]
      constructor
      · rintro ⟨hall, hgood⟩ j hj
        rcases (by omega : j < i ∨ j = i) with hj | hj
        · exact hall j hj
        · subst hj; exact hgood
      · intro hall
        exact ⟨fun j hj => hall j (by omega), hall i (by omega)⟩
  by_cases hl : i + 1 < 67
  · have e4 : run env 1 s3 = .running (s3.setPc (s3.pc + ((0xf8c : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 104 (by decide) hc3 p3 (i := .br .bne A4 S7 0xf8c) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p3]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 s3 = .running s3.next :=
      (stepK (prog := kernel) hp 104 (by decide) hc3 p3 (i := .br .bne A4 S7 0xf8c) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p3]
    exact pc_next fit 104 (by decide)

/-! ## The whole kernel -/

/-- The instructions the first `n` chains take: each `56 + 3 (15 - dᵢ)`. -/
def loopCount (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 56 + 3 * (15 - digit m base i)).sum

def stepsTo (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 15 - digit m base i).sum

theorem loopCount_eq (m : Word → Byte) (base : Word) (n : Nat) :
    loopCount m base n = 56 * n + 3 * stepsTo m base n := by
  induction n with
  | zero => simp [loopCount, stepsTo]
  | succ n ih =>
    simp only [loopCount, stepsTo, List.range_succ, List.map_append, List.sum_append, List.map_cons,
      List.map_nil, List.sum_cons, List.sum_nil] at *
    rw [ih]; omega

/-- 67 chains, by induction: after `j` of them, the invariant holds for `j`. -/
theorem chain_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 0 s) :
    ∀ j ≤ 67, ∃ s', run env (loopCount m0 base j) s = .running s' ∧ CInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := chain_iter hp hc0 (by omega) hs'
    refine ⟨s'', ?_, hs''⟩
    rw [show loopCount m0 base (j + 1) = loopCount m0 base j + (56 + 3 * (15 - digit m0 base j)) by
      simp [loopCount, List.range_succ, List.sum_append], run_add_running e, e']

/-- Three instructions after the last chain: the verdict, and HALT. -/
theorem halt {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 67 s) :
    ∃ s1 s2, run env 2 s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash m0 base then 0 else 1) s2 ∧ s2.mem = s.mem := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 105) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.out.code hp.fit (by simp only [SCR]; omega) (by decide) hc0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 105 (by decide) hcode hpc
    (i := .op .sltu A0 0 S6) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 106 (by decide) (by rw [m1]; exact hcode) p1
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
  exact (step_of_code (k := 107) (by rw [kernel_length]; decide) (by rw [m2, m1]; exact hcode)
      (by rw [p2])
      (by rw [p2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [p2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[107]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-- Everything up to the `ecall` that halts: `4141 + 3 · steps` instructions. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env (4141 + 3 * steps s.mem base) s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash s.mem base then 0 else 1) s2
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 s.mem s2.mem := by
  obtain ⟨s22, e22, dinv, rg, h1, h2, h6⟩ := front hp s hpc hcode
  obtain ⟨sd, ed, dinv'⟩ := digits_loop hp
    (keeps_overlay hp.fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
    (code_of_overlay hp.fit hcode (by decide) (by decide) _) dinv 32 (Nat.le_refl _)
  obtain ⟨sm, em, cinv⟩ := middle hp hcode dinv' rg h1 h2 h6
  obtain ⟨sl, el, cinv'⟩ := chain_loop hp hcode cinv 67 (Nat.le_refl _)
  obtain ⟨s1, s2, e2, e1, hm⟩ := halt hp hcode cinv'
  refine ⟨s1, s2, ?_, e1, by rw [hm]; exact cinv'.out⟩
  rw [show 4141 + 3 * steps s.mem base = 22 + (11 * 32 + (13 + (loopCount s.mem base 67 + 2))) by
    rw [loopCount_eq]; unfold steps stepsTo; omega,
    run_add_running e22, run_add_running ed, run_add_running em, run_add_running el, e2]

/-- **The kernel verifies a WOTS signature.** From `base`, with the kernel's
432 bytes there, it halts with 0 if all 67 chains reach the public key and
with 1 if any does not — for every message, signature, key and `HASH` — and
it writes nothing outside its 131 bytes of scratch. It takes
`4142 + 3 · steps` instructions, where `steps = Σ (15 - dᵢ)` is the number of
HASH calls: the count depends on the message, and is exactly this. -/
theorem verifies {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env (4142 + 3 * steps s.mem base) s
        = .halted (if Verifies env.hash s.mem base then 0 else 1) s'
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 s.mem s'.mem := by
  obtain ⟨s1, s2, e, e1, hm⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s2, by rw [show 4142 + 3 * steps s.mem base = 4141 + 3 * steps s.mem base + 1 by omega,
    run_add_running e, e1], hm⟩

/-- **And in exactly that many.** After one fewer it is still running, for
every input: the count is not a bound. -/
theorem exactly {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1, run env (4141 + 3 * steps s.mem base) s = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s1, e⟩

/-- The number of HASH calls is at most `67 · 15`, and the count at most
`4142 + 3 · 1005 = 7157`. -/
theorem steps_le (m : Word → Byte) (base : Word) : steps m base ≤ 1005 := by
  have : ∀ n, stepsTo m base n ≤ 15 * n := by
    intro n; induction n with
    | zero => simp [stepsTo]
    | succ n ih =>
      simp only [stepsTo, List.range_succ, List.map_append, List.sum_append, List.map_cons, List.map_nil,
        List.sum_cons, List.sum_nil] at *
      omega
  exact this 67

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction
`k`. A hundred and eight cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 432 ≤ img.size)
    (himg : ∀ d (h : d < 432), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **From the state the shell builds**: any image that begins with the
kernel's 432 bytes. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 432 ≤ img.size) (himg : ∀ d (h : d < 432), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (4141 + 3 * steps (memOfImage base img) base) (boot env.region img) = .running s1) ∧
    ∃ s', run env (4142 + 3 * steps (memOfImage base img) base) (boot env.region img)
        = .halted (if Verifies env.hash (memOfImage base img) base then 0 else 1) s'
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 (memOfImage base img) s'.mem := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  obtain ⟨s1, e1⟩ := exactly hp _ hpc hcode
  obtain ⟨s', e, h⟩ := verifies hp _ hpc hcode
  rw [hmem] at e1 e h
  exact ⟨⟨s1, e1⟩, s', e, h⟩

#print axioms bytes_words
#print axioms code_of_image
#print axioms digit_iter
#print axioms middle
#print axioms walk_chain
#print axioms good_iff
#print axioms chain_iter
#print axioms chain_loop
#print axioms halt
#print axioms verifies
#print axioms exactly
#print axioms steps_le
#print axioms from_boot

end Exp205

/-- `lean --run Wots.lean OUT` writes `image` to OUT — that is `kernel.bin` —
and prints the listing: offset, word, instruction. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp205.image
  | _ => pure ()
  for (i, k) in Exp205.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
