/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-3 — the count the estimate rests on

SP 800-90B's most common value estimate (§6.3.1) rests on one number: how
many times the commonest value occurs. This kernel counts it, for 4096
byte-sized samples over all 256 values, in a way whose trace the samples
cannot move: for each value b it reads every sample and adds 1 when the
sample is b, with no branch and no address that depends on a sample. Then
the largest count, also without a branch.

   0       s0 = base
   1-7     s1 = base + 0x400 (the samples), s2 = s1 + 4096 (their end, and
           the histogram), s3 = s2, s4 = 0 (the value), s5 = 0 (the most),
           s7 = 256
   8-9     BIN: a0 = s1, s6 = 0
   10-15   LOOP: t1 = byte at a0; t1 = (t1 xor s4) <u 1; s6 += t1; a0 += 1;
           bne a0, s2 → LOOP
   16      the count to the histogram, at s3
   17-21   s5 = max(s5, s6), branchless: mask = -(s5 <u s6),
           s5 ^= (s6 ^ s5) & mask
   22-24   s3 += 4; s4 += 1; bne s4, s7 → BIN
   25      the most to base + 0x1800
   26-28   HALT 0

4096 is `lui t1, 1`, not `addi` and `slli`: lean/Rv32/Ct.lean knows a
`lui`'s value and only that a shift's is public, and it needs the
histogram's place as a number to accept a store there.
-/
import Rv32.Health
import Rv32.Asm
import Rv32.Ct
import Rv32.Limbs
import Rv32.Flow

set_option maxRecDepth 20000

namespace Count
open Rv32 Rv32.Health

def setup : List Instr := [
  .opi .addi S1 S0 0x400, .lui T1 1, .op .add S2 S1 T1,
  .opi .addi S3 S2 0, .opi .addi S4 0 0, .opi .addi S5 0 0, .opi .addi S7 0 256 ]

def binTop : List Instr := [ .opi .addi A0 S1 0, .opi .addi S6 0 0 ]

/-- One sample, loaded into `t1`, against the value in `s4`: `s6` += 1 if
they are equal; and on to the next sample. -/
def tally : List Instr := [ .op .xor T1 T1 S4, .opi .sltiu T1 T1 1, .op .add S6 S6 T1, .opi .addi A0 A0 1 ]

def look : List Instr := .ld .lbu T1 A0 0 :: tally

/-- `s5` = max(`s5`, `s6`), unsigned, without a branch. -/
def maxLine : List Instr := [ .op .sltu T1 S5 S6, .op .sub T1 0 T1, .op .xor T2 S6 S5, .op .and T2 T2 T1,
  .op .xor S5 S5 T2 ]

def onward : List Instr := [ .opi .addi S3 S3 4, .opi .addi S4 S4 1 ]

def kernel : List Instr :=
  [.auipc S0 0] ++ setup ++ binTop ++ look ++ [.br .bne A0 S2 (BitVec.ofInt 12 (2 * (10 - 15 : Int)))]
  ++ [.st .sw S3 S6 0] ++ maxLine ++ onward ++ [.br .bne S4 S7 (BitVec.ofInt 12 (2 * (8 - 24 : Int)))]
  ++ [.st .sw S3 S5 0, .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall]

theorem kernel_length : kernel.length = 29 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-- An image that begins with the kernel's 116 bytes holds the kernel. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 116 ≤ img.size) (himg : ∀ d (h : d < 116), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) (toBytes_words kernel) img
    (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-! ## The specification

Sample `i` is the byte at 0x400 + i. `cnt b n` is how many of the first `n`
are `b`; the histogram is `cnt b 4096` for each `b`; `best k` is the largest
of the first `k` of them. Afterwards memory is the image with the 256 counts
as words from 0x1400, and the largest at 0x1800, and nothing else. -/

def SMP : Nat := 0x400
def HST : Nat := 0x1400
def MOST : Nat := 0x1800
def L : Nat := 4096

/-- Sample `i`. -/
def smp (m : Word → Byte) (base : Word) (i : Nat) : Nat := (m (base + BitVec.ofNat 32 (SMP + i))).toNat

/-- How many of the first `n` samples are `b`. -/
def cnt (m : Word → Byte) (base : Word) (b n : Nat) : Nat :=
  ((List.range n).filter (fun i => smp m base i == b)).length

/-- The histogram: how many of the 4096 samples are `b`. -/
def hist (m : Word → Byte) (base : Word) (b : Nat) : Nat := cnt m base b L

/-- The largest of the first `k` counts. -/
def best (m : Word → Byte) (base : Word) (k : Nat) : Nat := ((List.range k).map (hist m base)).foldl max 0

/-- **The commonest value's count**: the number §6.3.1's estimate rests on. -/
def most (m : Word → Byte) (base : Word) : Nat := best m base 256

/-- Memory with the first `k` counts written. -/
def wrote (m : Word → Byte) (base : Word) : Nat → Word → Byte
  | 0 => m
  | k + 1 => writeLE (wrote m base k) (base + BitVec.ofNat 32 (HST + 4 * k)) (hist m base k) 4

/-- Memory at the halt. -/
def after (m : Word → Byte) (base : Word) : Word → Byte :=
  writeLE (wrote m base 256) (base + BitVec.ofNat 32 MOST) (most m base) 4

/-- Instructions to the halt, whatever the samples. -/
def COST : Nat := 8 + 256 * (2 + 6 * L + 9) + 4

/-! ## The specification's arithmetic -/

theorem cnt_succ (m : Word → Byte) (base : Word) (b n : Nat) :
    cnt m base b (n + 1) = cnt m base b n + if smp m base n = b then 1 else 0 := by
  simp only [cnt, List.range_succ, List.filter_append, List.length_append]
  by_cases h : smp m base n = b <;> simp [h]

theorem cnt_le (m : Word → Byte) (base : Word) (b n : Nat) : cnt m base b n ≤ n := by
  unfold cnt; exact Nat.le_trans (List.length_filter_le _ _) (by simp)

theorem best_succ (m : Word → Byte) (base : Word) (k : Nat) :
    best m base (k + 1) = max (best m base k) (hist m base k) := by
  simp [best, List.range_succ, List.map_append, List.foldl_append]

theorem best_le (m : Word → Byte) (base : Word) (k : Nat) : best m base k ≤ L := by
  induction k with
  | zero => simp [best]
  | succ k ih => rw [best_succ]; exact Nat.max_le.mpr ⟨ih, cnt_le _ _ _ _⟩

theorem smp_lt (m : Word → Byte) (base : Word) (i : Nat) : smp m base i < 256 := (m _).isLt

variable {env : Env} {base : Word}

/-- The counts are written above the samples: the samples stay. -/
theorem wrote_smp (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {k : Nat} (hk : k ≤ 256)
    {i : Nat} (hi : i < L) :
    wrote m base k (base + BitVec.ofNat 32 (SMP + i)) = m (base + BitVec.ofNat 32 (SMP + i)) := by
  induction k with
  | zero => rfl
  | succ k ih =>
    simp only [wrote]
    rw [Ct.writeLE_out hfit _ _ (by decide) (by simp only [HST]; omega) (by simp only [HST]; omega)
      (by simp only [SMP, L] at hi ⊢; omega) (Or.inl (by simp only [SMP, HST, L] at hi ⊢; omega)), ih (by omega)]

theorem wrote_code (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} (hc : CodeAt m base kernel)
    {k : Nat} (hk : k ≤ 256) : CodeAt (wrote m base k) base kernel := by
  induction k with
  | zero => exact hc
  | succ k ih =>
    exact code_write hfit (ih (by omega)) (by rw [kernel_length]; simp only [HST]; omega)
      (by simp only [HST]; omega) (by rw [kernel_length]; decide) _

/-! ## Words -/

/-- `(x xor b) <u 1` is 1 exactly when `x = b`. -/
theorem eq_test (x b : Nat) (hx : x < 256) (hb : b < 256) :
    (if (BitVec.ofNat 32 x ^^^ BitVec.ofNat 32 b).ult ((1 : BitVec 12).signExtend 32) then (1 : Word) else 0)
      = BitVec.ofNat 32 (if x = b then 1 else 0) := by
  rw [show (1 : BitVec 12).signExtend 32 = (1 : Word) by decide]
  by_cases h : x = b
  · subst h; simp [BitVec.ult]
  · have hne : BitVec.ofNat 32 x ^^^ BitVec.ofNat 32 b ≠ 0 := by
      intro e
      have := congrArg BitVec.toNat ((xorz _ _).mp e)
      simp only [BitVec.toNat_ofNat] at this
      omega
    have : ¬ (BitVec.ofNat 32 x ^^^ BitVec.ofNat 32 b).toNat < 1 := by
      intro e; exact hne (BitVec.eq_of_toNat_eq (by show (BitVec.ofNat 32 x ^^^ BitVec.ofNat 32 b).toNat = 0; omega))
    have hu : (BitVec.ofNat 32 x ^^^ BitVec.ofNat 32 b).ult 1 = false := by
      unfold BitVec.ult; exact decide_eq_false this
    rw [hu]; simp [h]

/-- The branchless max: `x ^ ((y ^ x) & -(x <u y))`. -/
theorem max_word (x y : Nat) (hx : x < 2 ^ 32) (hy : y < 2 ^ 32) :
    BitVec.ofNat 32 x ^^^ ((BitVec.ofNat 32 y ^^^ BitVec.ofNat 32 x)
      &&& (0 - if (BitVec.ofNat 32 x).ult (BitVec.ofNat 32 y) then (1 : Word) else 0))
      = BitVec.ofNat 32 (max x y) := by
  have hu : (BitVec.ofNat 32 x).ult (BitVec.ofNat 32 y) = decide (x < y) := by
    simp [BitVec.ult, Nat.mod_eq_of_lt hx, Nat.mod_eq_of_lt hy]
  rw [hu]
  by_cases h : x < y
  · simp only [h, decide_true, ↓reduceIte]
    rw [show (0 : Word) - 1 = BitVec.allOnes 32 by decide, BitVec.and_allOnes, BitVec.xor_comm (BitVec.ofNat 32 y),
      ← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor, Nat.max_eq_right (by omega)]
  · simp only [h, decide_false, Bool.false_eq_true, ↓reduceIte]
    rw [show (0 : Word) - 0 = 0#32 from rfl, BitVec.and_zero, BitVec.xor_zero, Nat.max_eq_left (by omega)]

/-- Two places past `base` are equal exactly when their offsets are. -/
theorem off_eq {a b : Nat} (ha : a < 0x10000) (hb : b < 0x10000) :
    (base + BitVec.ofNat 32 a = base + BitVec.ofNat 32 b) ↔ a = b := by
  constructor
  · intro e
    rw [BitVec.add_comm base, BitVec.add_comm base] at e
    have e2 := congrArg (fun w => w - base) e
    simp only [BitVec.add_sub_cancel] at e2
    have := congrArg BitVec.toNat e2
    simp only [BitVec.toNat_ofNat] at this
    rwa [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt (by omega)] at this
  · intro e; rw [e]

/-! ## One value's count: the inner loop -/

/-- At LOOP with `i` samples looked at, or at the store once all 4096 have
been: memory `M`, `a0` at sample `i`, `s6` the count so far, and every
register but `t1`, `s6` and `a0` as it was on the way in, in `keep`. -/
structure LInv (base : Word) (M m0 : Word → Byte) (b : Nat) (keep : Reg → Word) (i : Nat) (s : Machine) :
    Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < L then 10 else 16))
  mem : s.mem = M
  a0 : s.reg A0 = base + BitVec.ofNat 32 (SMP + i)
  s6 : s.reg S6 = BitVec.ofNat 32 (cnt m0 base b i)
  kept : ∀ r, r ≠ T1 → r ≠ S6 → r ≠ A0 → s.reg r = keep r

theorem hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide

theorem tally_regs (s : Machine) (x b c : Nat) (hx : x < 256) (hb : b < 256)
    (h1 : s.reg T1 = BitVec.ofNat 32 x) (h4 : s.reg S4 = BitVec.ofNat 32 b) (h6 : s.reg S6 = BitVec.ofNat 32 c) :
    (s.line tally).reg S6 = BitVec.ofNat 32 (c + if x = b then 1 else 0)
    ∧ (s.line tally).reg A0 = s.reg A0 + 1
    ∧ ∀ r, r ≠ T1 → r ≠ S6 → r ≠ A0 → (s.line tally).reg r = s.reg r := by
  refine ⟨?_, ?_, fun r h1' h6' ha => ?_⟩
  · have : (s.line tally).reg S6
        = s.reg S6 + (if (s.reg T1 ^^^ s.reg S4).ult ((1 : BitVec 12).signExtend 32) then 1 else 0) := by
      simp [Machine.line, tally, Machine.alu, reg_setReg, aluR, aluI, T1, S4, S6, A0] <;> rfl
    rw [this, h1, h4, h6, eq_test x b hx hb, ← BitVec.ofNat_add]
  · simp [Machine.line, tally, Machine.alu, reg_setReg, aluR, aluI, T1, S4, S6, A0]
  · refine line_keeps _ _ r (fun i hi => ?_)
    simp only [tally, List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => h1' e.symm | exact fun e => h6' e.symm | exact fun e => ha e.symm

variable {env : Env}

/-- **One sample**: six instructions take the count from `i` samples to `i + 1`. -/
theorem look_iter (hp : Placed env base) {M m0 : Word → Byte} (hc : CodeAt M base kernel)
    (hM : ∀ i < L, M (base + BitVec.ofNat 32 (SMP + i)) = m0 (base + BitVec.ofNat 32 (SMP + i)))
    {b : Nat} (hb : b < 256) {keep : Reg → Word} (k4 : keep S4 = BitVec.ofNat 32 b)
    (k2 : keep S2 = base + BitVec.ofNat 32 (SMP + L))
    {i : Nat} (hi : i < L) {s : Machine} (h : LInv base M m0 b keep i s) :
    ∃ s', run env 6 s = .running s' ∧ LInv base M m0 b keep (i + 1) s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 10) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact hc
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep hp 10 (by rw [kernel_length]; decide) hcode hpc
    (rd := T1) (rs1 := A0) (imm := 0) rfl (SMP + i)
    (by rw [h.a0, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero])
    (by simp only [SMP, L] at hi ⊢; omega) hlen
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have t1 : s1.reg T1 = BitVec.ofNat 32 (smp m0 base i) := by
    rw [reg_wrote r1 (by decide), h.mem, hM i hi]; rfl
  have e2 := run_line hp tally (by decide) (10 + 1) s1 (by decide) (by rw [kernel_length]; decide) hc1 p1 hlen
  have k1 : ∀ r, r ≠ T1 → s1.reg r = s.reg r := fun r hr => reg_kept r1 hr
  obtain ⟨g6, ga, gk⟩ := tally_regs s1 (smp m0 base i) b (cnt m0 base b i) (smp_lt _ _ _) hb t1
    (by rw [k1 S4 (by decide), h.kept S4 (by decide) (by decide) (by decide), k4])
    (by rw [k1 S6 (by decide), h.s6])
  have p2 : (s1.line tally).pc = base + BitVec.ofNat 32 (4 * (10 + 1 + tally.length)) :=
    line_pc_at tally p1 (by decide)
  have hc2 : CodeAt (s1.line tally).mem base kernel := by rw [line_mem]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := brStep hp (10 + 1 + tally.length) (by rw [kernel_length]; decide) hc2 p2
    (op := .bne) (rs1 := A0) (rs2 := S2) (off := BitVec.ofInt 12 (2 * (10 - 15 : Int))) rfl (k' := 10)
    (by decide) hlen
  have a2 : (s1.line tally).reg A0 = base + BitVec.ofNat 32 (SMP + (i + 1)) := by
    rw [ga, k1 A0 (by decide), h.a0, show (1 : Word) = BitVec.ofNat 32 1 from rfl,
      off_add hp.fit _ _ (by simp only [SMP, L] at hi ⊢; omega)]
    rfl
  have s2 : (s1.line tally).reg S2 = base + BitVec.ofNat 32 (SMP + L) := by
    rw [gk S2 (by decide) (by decide) (by decide), k1 S2 (by decide),
      h.kept S2 (by decide) (by decide) (by decide), k2]
  have tk : taken .bne ((s1.line tally).reg A0) ((s1.line tally).reg S2) = decide (i + 1 < L) := by
    rw [a2, s2]
    have hne : (base + BitVec.ofNat 32 (SMP + (i + 1)) = base + BitVec.ofNat 32 (SMP + L)) ↔ i + 1 = L :=
      (off_eq (by simp only [SMP, L] at hi ⊢; omega) (by simp only [SMP, L]; omega)).trans
        (by constructor <;> intro e <;> omega)
    by_cases h' : i + 1 < L
    · have : base + BitVec.ofNat 32 (SMP + (i + 1)) ≠ base + BitVec.ofNat 32 (SMP + L) :=
        fun e => by have := hne.mp e; omega
      simp [taken, this, h']
    · have : base + BitVec.ofNat 32 (SMP + (i + 1)) = base + BitVec.ofNat 32 (SMP + L) := hne.mpr (by omega)
      simp [taken, this, h']
  refine ⟨s3, ?_, ⟨?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 6 = 1 + (tally.length + 1) by rfl, run_add_running e1, run_add_running e2, e3]
  · rw [p3, tk]
    by_cases h' : i + 1 < L <;> simp [h', tally]
  · rw [m3, line_mem, m1, h.mem]
  · rw [r3, a2]
  · rw [r3, g6, cnt_succ]
  · intro r h1' h6' ha
    rw [r3, gk r h1' h6' ha, k1 r h1', h.kept r h1' h6' ha]

/-- 4096 samples, by induction. -/
theorem look_loop (hp : Placed env base) {M m0 : Word → Byte} (hc : CodeAt M base kernel)
    (hM : ∀ i < L, M (base + BitVec.ofNat 32 (SMP + i)) = m0 (base + BitVec.ofNat 32 (SMP + i)))
    {b : Nat} (hb : b < 256) {keep : Reg → Word} (k4 : keep S4 = BitVec.ofNat 32 b)
    (k2 : keep S2 = base + BitVec.ofNat 32 (SMP + L)) {s : Machine} (h : LInv base M m0 b keep 0 s) :
    ∀ j ≤ L, ∃ s', run env (6 * j) s = .running s' ∧ LInv base M m0 b keep j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := look_iter hp hc hM hb k4 k2 (by omega) hs'
    exact ⟨s'', by rw [show 6 * (j + 1) = 6 * j + 6 by omega, run_add_running e, e'], hs''⟩

/-! ## Each value: the outer loop -/

theorem maxLine_regs (s : Machine) (x y : Nat) (hx : x < 2 ^ 32) (hy : y < 2 ^ 32)
    (h5 : s.reg S5 = BitVec.ofNat 32 x) (h6 : s.reg S6 = BitVec.ofNat 32 y) :
    (s.line maxLine).reg S5 = BitVec.ofNat 32 (max x y) := by
  have : (s.line maxLine).reg S5
      = s.reg S5 ^^^ ((s.reg S6 ^^^ s.reg S5) &&& (0 - if (s.reg S5).ult (s.reg S6) then 1 else 0)) := by
    simp [Machine.line, maxLine, Machine.alu, reg_setReg, aluR, T1, T2, S5, S6] <;> rfl
  rw [this, h5, h6, max_word x y hx hy]

/-- At BIN with `b` values counted, or at the last store once all 256 have
been: the first `b` counts written, `s3` at the next one's place, `s4` the
value, `s5` the largest count so far. -/
structure BInv (base : Word) (m0 : Word → Byte) (b : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if b < 256 then 8 else 25))
  mem : s.mem = wrote m0 base b
  s1 : s.reg S1 = base + BitVec.ofNat 32 SMP
  s2 : s.reg S2 = base + BitVec.ofNat 32 (SMP + L)
  s3 : s.reg S3 = base + BitVec.ofNat 32 (HST + 4 * b)
  s4 : s.reg S4 = BitVec.ofNat 32 b
  s5 : s.reg S5 = BitVec.ofNat 32 (best m0 base b)
  s7 : s.reg S7 = BitVec.ofNat 32 256

/-- Instructions for one value. -/
def BIN : Nat := 2 + 6 * L + 9

theorem toNat_small {n : Nat} (h : n ≤ L) : (BitVec.ofNat 32 n).toNat = n := by
  simp only [BitVec.toNat_ofNat]; simp only [L] at h; omega

/-- **One value**: its count written, the largest so far kept. -/
theorem bin_iter (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {b : Nat} (hb : b < 256)
    {s : Machine} (h : BInv base m0 b s) :
    ∃ s', run env BIN s = .running s' ∧ BInv base m0 (b + 1) s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 8) := by rw [h.pc]; simp [hb]
  have hcB : CodeAt (wrote m0 base b) base kernel := wrote_code hp.fit hc0 (by omega)
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact hcB
  have e1 := run_line hp binTop (by decide) 8 s (by decide) (by rw [kernel_length]; decide) hcode hpc hlen
  generalize hsA : s.line binTop = sA at e1
  have gA0 : sA.reg A0 = base + BitVec.ofNat 32 (SMP + 0) := by
    have : sA.reg A0 = s.reg S1 + (0 : BitVec 12).signExtend 32 := by
      rw [← hsA]; simp [Machine.line, binTop, Machine.alu, reg_setReg, aluI, A0, S1, S6]
    rw [this, h.s1, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]; rfl
  have gS6 : sA.reg S6 = BitVec.ofNat 32 (cnt m0 base b 0) := by
    rw [← hsA]; simp [Machine.line, binTop, Machine.alu, reg_setReg, aluI, A0, S1, S6, cnt]
  have kA : ∀ r, r ≠ A0 → r ≠ S6 → sA.reg r = s.reg r := by
    intro r ha h6; rw [← hsA]
    refine line_keeps _ _ r (fun i hi => ?_)
    simp only [binTop, List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => ha e.symm | exact fun e => h6 e.symm
  have pA : sA.pc = base + BitVec.ofNat 32 (4 * (8 + binTop.length)) := by
    rw [← hsA]; exact line_pc_at binTop hpc (by decide)
  have hL0 : LInv base (wrote m0 base b) m0 b sA.reg 0 sA :=
    ⟨by rw [pA]; rfl, by rw [← hsA, line_mem, h.mem], gA0, gS6, fun _ _ _ _ => rfl⟩
  obtain ⟨sL, eL, hL⟩ := look_loop hp hcB (fun i hi => wrote_smp hp.fit m0 (by omega) hi) hb (keep := sA.reg)
    (by rw [kA S4 (by decide) (by decide), h.s4]) (by rw [kA S2 (by decide) (by decide), h.s2]) hL0 L (Nat.le_refl _)
  have pL : sL.pc = base + BitVec.ofNat 32 (4 * 16) := by rw [hL.pc]; simp
  have hcL : CodeAt sL.mem base kernel := by rw [hL.mem]; exact hcB
  have kL : ∀ r, r ≠ T1 → r ≠ S6 → r ≠ A0 → sL.reg r = s.reg r := fun r a c d => by
    rw [hL.kept r a c d, kA r d c]
  obtain ⟨sW, eW, pW, mW, rW⟩ := storeStep hp 16 (by rw [kernel_length]; decide) hcL pL
    (rs1 := S3) (rs2 := S6) (imm := 0) rfl (HST + 4 * b)
    (by rw [kL S3 (by decide) (by decide) (by decide), h.s3, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl,
      BitVec.add_zero])
    (by simp only [HST]; omega) (by simp only [HST]; omega) hlen
  have memW : sW.mem = wrote m0 base (b + 1) := by
    rw [mW, hL.mem, hL.s6, toNat_small (cnt_le _ _ _ _)]; rfl
  have hcW : CodeAt sW.mem base kernel := by rw [memW]; exact wrote_code hp.fit hc0 (by omega)
  have e3 := run_line hp maxLine (by decide) (16 + 1) sW (by decide) (by rw [kernel_length]; decide) hcW pW hlen
  have g5 : (sW.line maxLine).reg S5 = BitVec.ofNat 32 (best m0 base (b + 1)) := by
    rw [best_succ]
    exact maxLine_regs sW _ _ (by have := best_le m0 base b; simp only [L] at this; omega)
      (by have := cnt_le m0 base b L; simp only [hist, L] at this ⊢; omega)
      (by rw [rW, kL S5 (by decide) (by decide) (by decide), h.s5]) (by rw [rW, hL.s6]; rfl)
  have kM : ∀ r, r ≠ T1 → r ≠ T2 → r ≠ S5 → (sW.line maxLine).reg r = sW.reg r := by
    intro r a c d
    refine line_keeps _ _ r (fun i hi => ?_)
    simp only [maxLine, List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => a e.symm | exact fun e => c e.symm | exact fun e => d e.symm
  have pM : (sW.line maxLine).pc = base + BitVec.ofNat 32 (4 * (16 + 1 + maxLine.length)) :=
    line_pc_at maxLine pW (by decide)
  have hcM : CodeAt (sW.line maxLine).mem base kernel := by rw [line_mem]; exact hcW
  have e4 := run_line hp onward (by decide) (16 + 1 + maxLine.length) (sW.line maxLine) (by decide)
    (by rw [kernel_length]; decide) hcM pM hlen
  generalize hsO : (sW.line maxLine).line onward = sO at e4
  have gS3 : sO.reg S3 = base + BitVec.ofNat 32 (HST + 4 * (b + 1)) := by
    have : sO.reg S3 = (sW.line maxLine).reg S3 + (4 : BitVec 12).signExtend 32 := by
      rw [← hsO]; simp [Machine.line, onward, Machine.alu, reg_setReg, aluI, S3, S4]
    rw [this, kM S3 (by decide) (by decide) (by decide), rW, kL S3 (by decide) (by decide) (by decide), h.s3,
      show (4 : BitVec 12).signExtend 32 = BitVec.ofNat 32 4 from rfl, off_add hp.fit _ _ (by simp only [HST]; omega)]
    rfl
  have gS4 : sO.reg S4 = BitVec.ofNat 32 (b + 1) := by
    have : sO.reg S4 = (sW.line maxLine).reg S4 + (1 : BitVec 12).signExtend 32 := by
      rw [← hsO]; simp [Machine.line, onward, Machine.alu, reg_setReg, aluI, S3, S4]
    rw [this, kM S4 (by decide) (by decide) (by decide), rW, kL S4 (by decide) (by decide) (by decide), h.s4,
      show (1 : BitVec 12).signExtend 32 = BitVec.ofNat 32 1 from rfl, ← BitVec.ofNat_add]
  have kO : ∀ r, r ≠ S3 → r ≠ S4 → sO.reg r = (sW.line maxLine).reg r := by
    intro r a c; rw [← hsO]
    refine line_keeps _ _ r (fun i hi => ?_)
    simp only [onward, List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => c e.symm
  have pO : sO.pc = base + BitVec.ofNat 32 (4 * (16 + 1 + maxLine.length + onward.length)) := by
    rw [← hsO]; exact line_pc_at onward pM (by decide)
  have hcO : CodeAt sO.mem base kernel := by rw [← hsO, line_mem]; exact hcM
  have gS7 : sO.reg S7 = BitVec.ofNat 32 256 := by
    rw [kO S7 (by decide) (by decide), kM S7 (by decide) (by decide) (by decide), rW,
      kL S7 (by decide) (by decide) (by decide), h.s7]
  obtain ⟨sB, eB, pB, mB, rB⟩ := brStep hp (16 + 1 + maxLine.length + onward.length) (by rw [kernel_length]; decide)
    hcO pO (op := .bne) (rs1 := S4) (rs2 := S7) (off := BitVec.ofInt 12 (2 * (8 - 24 : Int))) rfl (k' := 8)
    (by decide) hlen
  have tk : taken .bne (sO.reg S4) (sO.reg S7) = decide (b + 1 < 256) := by
    rw [gS4, gS7]
    by_cases h' : b + 1 < 256
    · have : BitVec.ofNat 32 (b + 1) ≠ BitVec.ofNat 32 256 := by
        intro e; have := congrArg BitVec.toNat e; simp only [BitVec.toNat_ofNat] at this; omega
      simp [taken, this, h']
    · have : b + 1 = 256 := by omega
      simp [taken, this]
  refine ⟨sB, ?_, ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show BIN = binTop.length + (6 * L + (1 + (maxLine.length + (onward.length + 1)))) by rfl,
      run_add_running e1, run_add_running eL, run_add_running eW, run_add_running e3, run_add_running e4, eB]
  · rw [pB, tk]; by_cases h' : b + 1 < 256 <;> simp [h', maxLine, onward]
  · rw [mB, ← hsO, line_mem, line_mem, memW]
  · rw [rB, kO S1 (by decide) (by decide), kM S1 (by decide) (by decide) (by decide), rW,
      kL S1 (by decide) (by decide) (by decide), h.s1]
  · rw [rB, kO S2 (by decide) (by decide), kM S2 (by decide) (by decide) (by decide), rW,
      kL S2 (by decide) (by decide) (by decide), h.s2]
  · rw [rB, gS3]
  · rw [rB, gS4]
  · rw [rB, kO S5 (by decide) (by decide), g5]
  · rw [rB, gS7]

/-- All 256 values, by induction. -/
theorem bin_loop (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {s : Machine}
    (h : BInv base m0 0 s) : ∀ j ≤ 256, ∃ s', run env (BIN * j) s = .running s' ∧ BInv base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := bin_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show BIN * (j + 1) = BIN * j + BIN by rw [Nat.mul_succ], run_add_running e, e'], hs''⟩

/-! ## From boot to the halt -/

def setA : List Instr := [.opi .addi S1 S0 0x400]
def setB : List Instr := [.op .add S2 S1 T1, .opi .addi S3 S2 0, .opi .addi S4 0 0, .opi .addi S5 0 0,
  .opi .addi S7 0 256]

/-- Eight instructions: the places, the value 0, the largest 0. -/
theorem setup_run (hp : Placed env base) {m0 : Word → Byte} (s : Machine) (hpc : s.pc = base)
    (hmem : s.mem = m0) (hc0 : CodeAt m0 base kernel) :
    ∃ s', run env 8 s = .running s' ∧ BInv base m0 0 s' := by
  have hcode : CodeAt s.mem base kernel := by rw [hmem]; exact hc0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep hp 0 (by rw [kernel_length]; decide) hcode (by simpa using hpc)
    (i := .auipc S0 0) (by decide) (rd := S0) (v := s.pc + ((0 : BitVec 20) ++ 0#12)) rfl hlen
  have h0 : s1.reg S0 = base := by
    rw [reg_wrote r1 (by decide), hpc, show ((0 : BitVec 20) ++ 0#12) = (0 : Word) by decide]; simp
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have e2 := run_line hp setA (by decide) (0 + 1) s1 (by decide) (by rw [kernel_length]; decide) hc1 p1 hlen
  have p2 : (s1.line setA).pc = base + BitVec.ofNat 32 (4 * (0 + 1 + setA.length)) := line_pc_at setA p1 (by decide)
  have hc2 : CodeAt (s1.line setA).mem base kernel := by rw [line_mem]; exact hc1
  have g1 : (s1.line setA).reg S1 = base + BitVec.ofNat 32 SMP := by
    have : (s1.line setA).reg S1 = s1.reg S0 + (0x400 : BitVec 12).signExtend 32 := by
      simp [Machine.line, setA, Machine.alu, reg_setReg, aluI, S0, S1]
    rw [this, h0, show (0x400 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x400 from se_small 0x400 (by decide)]; rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep hp (0 + 1 + setA.length) (by rw [kernel_length]; decide) hc2 p2
    (i := .lui T1 1) (by decide) (rd := T1) (v := (1 : BitVec 20) ++ 0#12) rfl hlen
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc2
  have t1 : s3.reg T1 = BitVec.ofNat 32 L := by rw [reg_wrote r3 (by decide)]; decide
  have g1' : s3.reg S1 = base + BitVec.ofNat 32 SMP := by rw [reg_kept r3 (by decide), g1]
  have e4 := run_line hp setB (by decide) (0 + 1 + setA.length + 1) s3 (by decide) (by rw [kernel_length]; decide)
    hc3 p3 hlen
  generalize hs4 : s3.line setB = s4 at e4
  have p4 : s4.pc = base + BitVec.ofNat 32 (4 * (0 + 1 + setA.length + 1 + setB.length)) := by
    rw [← hs4]; exact line_pc_at setB p3 (by decide)
  have g2 : s4.reg S2 = base + BitVec.ofNat 32 (SMP + L) := by
    have : s4.reg S2 = s3.reg S1 + s3.reg T1 := by
      rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1]
    rw [this, g1', t1, off_add hp.fit _ _ (by decide)]
  refine ⟨s4, ?_, ⟨?_, ?_, ?_, g2, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 8 = 1 + (setA.length + (1 + setB.length)) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3, e4]
  · rw [p4]; rfl
  · rw [← hs4, line_mem, m3, line_mem, m1, hmem]; rfl
  · have : s4.reg S1 = s3.reg S1 := by
      rw [← hs4]; exact line_keeps _ _ S1 (by decide)
    rw [this, g1']
  · have : s4.reg S3 = s4.reg S2 + (0 : BitVec 12).signExtend 32 := by
      have e : s4.reg S3 = (s3.reg S1 + s3.reg T1) + (0 : BitVec 12).signExtend 32 := by
        rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1]
      have e' : s4.reg S2 = s3.reg S1 + s3.reg T1 := by
        rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1]
      rw [e, e']
    rw [this, g2, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]; rfl
  · rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1]
  · rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1, best]
  · have : s4.reg S7 = (0 : Word) + (256 : BitVec 12).signExtend 32 := by
      rw [← hs4]; simp [Machine.line, setB, Machine.alu, reg_setReg, aluI, aluR, S1, S2, S3, S4, S5, S7, T1]
    rw [this, show (256 : BitVec 12).signExtend 32 = BitVec.ofNat 32 256 from se_small 256 (by decide)]; rfl

def setF : List Instr := [.opi .addi A0 0 0, .opi .addi T0 0 1]

/-- The largest count to 0x1800, and HALT 0. -/
theorem fin_run (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {s : Machine}
    (h : BInv base m0 256 s) :
    ∃ s', run env 3 s = .running s' ∧ run env 4 s = .halted 0 s' ∧ s'.mem = after m0 base := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 25) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact wrote_code hp.fit hc0 (Nat.le_refl _)
  obtain ⟨sW, eW, pW, mW, rW⟩ := storeStep hp 25 (by rw [kernel_length]; decide) hcode hpc
    (rs1 := S3) (rs2 := S5) (imm := 0) rfl MOST
    (by rw [h.s3, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]; rfl)
    (by decide) (by decide) hlen
  have hcW : CodeAt sW.mem base kernel := by
    rw [mW]; exact code_write hp.fit hcode (by rw [kernel_length]; decide) (by decide) hlen _
  have e2 := run_line hp setF (by decide) (25 + 1) sW (by decide) (by rw [kernel_length]; decide) hcW pW hlen
  generalize hsF : sW.line setF = sF at e2
  have pF : sF.pc = base + BitVec.ofNat 32 (4 * (25 + 1 + setF.length)) := by
    rw [← hsF]; exact line_pc_at setF pW (by decide)
  have hcF : CodeAt sF.mem base kernel := by rw [← hsF, line_mem]; exact hcW
  have a0 : sF.reg A0 = 0 := by rw [← hsF]; simp [Machine.line, setF, Machine.alu, reg_setReg, aluI, A0, T0]
  have t0 : sF.reg T0 = 1 := by rw [← hsF]; simp [Machine.line, setF, Machine.alu, reg_setReg, aluI, A0, T0]
  have eH := haltStep hp (25 + 1 + setF.length) (by rw [kernel_length]; decide) hcF pF rfl t0 hlen 0
  refine ⟨sF, ?_, ?_, ?_⟩
  · rw [show 3 = 1 + setF.length by rfl, run_add_running eW, e2]
  · rw [show 4 = 1 + (setF.length + 1) by rfl, run_add_running eW, run_add_running e2, eH, a0]
  · rw [← hsF, line_mem, mW, h.mem, h.s5, toNat_small (best_le _ _ _)]; rfl

/-- **The count, for every input.** Placed at any `base` the model allows,
with the image's first 116 bytes the kernel's: one instruction before
`COST` the kernel is still running, and at `COST` it halts with 0, memory the
image with the 256 counts of its 4096 samples as words from 0x1400 and the
largest of them at 0x1800, and nothing else. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 116 ≤ img.size)
    (himg : ∀ d (h : d < 116), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (COST - 1) (boot env.region img) = .running s1) ∧
    ∃ s', run env COST (boot env.region img) = .halted 0 s' ∧ s'.mem = after (memOfImage base img) base := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hc0 := code_of_image hp.fit img hsize himg
  obtain ⟨sS, eS, hS⟩ := setup_run hp _ hpc hmem hc0
  obtain ⟨sB, eB, hB⟩ := bin_loop hp hc0 hS 256 (Nat.le_refl _)
  obtain ⟨sF, eF3, eF4, mF⟩ := fin_run hp hc0 hB
  refine ⟨⟨sF, ?_⟩, sF, ?_, mF⟩
  · rw [show COST - 1 = 8 + (BIN * 256 + 3) by rfl, run_add_running eS, run_add_running eB, eF3]
  · rw [show COST = 8 + (BIN * 256 + 4) by rfl, run_add_running eS, run_add_running eB, eF4]

/-! ## What the specification says, checked -/

theorem hist_le_best (m : Word → Byte) (base : Word) {b k : Nat} (h : b < k) : hist m base b ≤ best m base k := by
  induction k with
  | zero => omega
  | succ k ih =>
    rw [best_succ]
    by_cases hb : b < k
    · exact Nat.le_trans (ih hb) (Nat.le_max_left _ _)
    · have : b = k := by omega
      subst this; exact Nat.le_max_right _ _

theorem best_attained (m : Word → Byte) (base : Word) (k : Nat) (hk : 0 < k) :
    ∃ b < k, best m base k = hist m base b := by
  induction k with
  | zero => omega
  | succ k ih =>
    rw [best_succ]
    by_cases h0 : k = 0
    · subst h0; exact ⟨0, by omega, by simp [best]⟩
    obtain ⟨b, hb, e⟩ := ih (by omega)
    by_cases hm : best m base k ≤ hist m base k
    · exact ⟨k, by omega, Nat.max_eq_right hm⟩
    · exact ⟨b, by omega, by rw [Nat.max_eq_left (by omega), e]⟩

/-- **`most` is the commonest value's count**: no value is counted more
often, and some value is counted exactly that often. -/
theorem most_is_max (m : Word → Byte) (base : Word) :
    (∀ b < 256, hist m base b ≤ most m base) ∧ ∃ b < 256, hist m base b = most m base :=
  ⟨fun _ hb => hist_le_best m base hb, by
    obtain ⟨b, hb, e⟩ := best_attained m base 256 (by decide); exact ⟨b, hb, e.symm⟩⟩

theorem ind_sum (x : Nat) (K : Nat) :
    ((List.range K).map (fun b => if x = b then 1 else 0)).sum = if x < K then 1 else 0 := by
  induction K with
  | zero => simp
  | succ K ih =>
    rw [List.range_succ, List.map_append, List.sum_append, ih]
    by_cases h1 : x < K
    · have : x ≠ K := by omega
      simp [h1, this, show x < K + 1 by omega]
    · by_cases h2 : x = K
      · subst h2; simp
      · simp [h1, h2, show ¬ x < K + 1 by omega]

theorem sum_zero (l : List Nat) : (l.map fun _ => (0 : Nat)).sum = 0 := by
  induction l <;> simp_all

theorem sum_add (l : List Nat) (f g : Nat → Nat) :
    (l.map fun b => f b + g b).sum = (l.map f).sum + (l.map g).sum := by
  induction l with
  | nil => simp
  | cons x l ih => simp only [List.map_cons, List.sum_cons, ih]; omega

/-- Over any `K` values that every sample is below, the counts of the first
`n` samples add up to `n`. -/
theorem cnt_sum (m : Word → Byte) (base : Word) (K : Nat) (hK : ∀ i, smp m base i < K) (n : Nat) :
    ((List.range K).map (fun b => cnt m base b n)).sum = n := by
  induction n with
  | zero =>
    have : (fun b => cnt m base b 0) = fun _ => 0 := by funext b; simp [cnt]
    rw [this, sum_zero]
  | succ n ih =>
    have e : (List.range K).map (fun b => cnt m base b (n + 1))
        = (List.range K).map (fun b => cnt m base b n + if smp m base n = b then 1 else 0) := by
      congr 1; funext b; exact cnt_succ m base b n
    rw [e, sum_add, ih, ind_sum]; simp [hK n]

/-- **Every sample is counted once**: the 256 counts add up to 4096. -/
theorem hist_sum (m : Word → Byte) (base : Word) : ((List.range 256).map (hist m base)).sum = L :=
  cnt_sum m base 256 (smp_lt m base) L

/-! ## Constant time

The kernel through lean/Rv32/Ct.lean's checker. Only the program is public:
the samples, the histogram and the most may differ between two runs. At BIN
the value s4 is 0 to 255 and s3 is the histogram's place for it,
base + 0x1400 + 4·s4; at LOOP, the same, and a0 is somewhere in the samples. -/

open Rv32.Ct

def known (o : List (Nat × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1 == n) with
    | some (_, v) => v
    | none => .sec

/-- What is known at both heads: the four places, the value, and 256. -/
def fixed : List (Nat × AV) :=
  [(8, .ptr 0 0), (9, .ptr 0x400 0x400), (18, .ptr 0x1400 0x1400), (19, .aff 20 4 0x1400), (20, .num 0 255),
   (23, .num 256 256)]

def heads : Heads := [(8, known fixed), (10, known ((10, .ptr 0x400 0x13ff) :: fixed))]

set_option maxRecDepth 100000 in
theorem accepted : check kernel [] heads = true := by decide

/-- The plain histogram, `counts[sample] += 1`: 4096 times, load the sample,
make it a word offset into the counts, load that count, add 1, store it.
Its addresses depend on the samples. -/
def naive : List Instr := [
  .auipc S0 0, .opi .addi S1 S0 0x400, .lui T1 1, .op .add S2 S1 T1,
  .ld .lbu T1 S1 0, .sh .slli T1 T1 2, .op .add T1 T1 S2, .ld .lw T2 T1 0, .opi .addi T2 T2 1,
  .st .sw T1 T2 0, .opi .addi S1 S1 1, .br .bne S1 S2 (BitVec.ofInt 12 (2 * (4 - 11 : Int))),
  .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

/-- **The checker refuses it**, at its loop's head as this kernel's are
given: the count it loads is at an address made from a sample. -/
theorem naive_refused :
    check naive [] [(4, known [(8, .ptr 0 0), (9, .ptr 0x400 0x13ff), (18, .ptr 0x1400 0x1400)])] = false := by
  decide

/-- **The trace does not depend on the samples.** Two images that begin
with the kernel — whatever samples they hold, and whatever else — run in
lock step: at every step the same `pc`, the same address loaded or stored,
and the same end. -/
theorem count_constant_time {env : Env} {base : Word} (hp : Placed env base) (img1 img2 : ByteArray)
    (hsize1 : 116 ≤ img1.size) (h1 : ∀ d (h : d < 116), img1.get d (by omega) = bytes.getD d 0)
    (hsize2 : 116 ≤ img2.size) (h2 : ∀ d (h : d < 116), img2.get d (by omega) = bytes.getD d 0) :
    ∀ n, trace env n (boot env.region img1) = trace env n (boot env.region img2)
      ∧ Same (run env n (boot env.region img1)) (run env n (boot env.region img2)) := by
  refine constant_time_boot hp accepted (by decide) img1 img2 (fun o ho hin => ?_)
    (code_of_image hp.fit img1 hsize1 h1)
  rcases hin with hin | ⟨_, hab, _⟩
  · rw [kernel_length] at hin
    have e : ∀ img : ByteArray, (h : 116 ≤ img.size) →
        (∀ d (h' : d < 116), img.get d (by omega) = bytes.getD d 0) →
        memOfImage base img (base + BitVec.ofNat 32 o) = BitVec.ofNat 8 (bytes.getD o 0).toNat := by
      intro img hs himg
      unfold memOfImage
      have hd : (base + BitVec.ofNat 32 o - base).toNat = o := off_of base o (by omega)
      simp only [hd, show o < img.size by omega, ↓reduceDIte]
      rw [himg o (by omega)]
    rw [e img1 hsize1 h1, e img2 hsize2 h2]
  · cases hab

end Count

#print axioms Count.look_loop
#print axioms Count.bin_loop
#print axioms Count.from_boot
#print axioms Count.most_is_max
#print axioms Count.hist_sum
#print axioms Count.accepted
#print axioms Count.naive_refused
#print axioms Count.count_constant_time

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Count.image
  | _ => pure ()
  for (i, k) in Count.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
