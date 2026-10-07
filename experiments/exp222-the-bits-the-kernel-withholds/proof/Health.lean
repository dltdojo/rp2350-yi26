/-
SPDX-License-Identifier: Apache-2.0

# exp222 — the bits the kernel withholds

NIST SP 800-90B's two continuous health tests, as exp114 wrote them in
`crates/entropy-health`, over one adaptive-proportion window of 1024
samples, and the output withheld unless both pass:

  samples   1024 words at base + 0x1000, one sample each in bit 0
  output    1024 words at base + 0x2000

  Repetition Count Test   fail if 21 samples in a row are the same
  Adaptive Proportion     fail if 589 or more of the 1024 equal the first

If both pass, the kernel copies the samples to the output and halts with 0.
If either fails, it writes nothing at all and halts with 1. The health loop
has no branch but its own: each sample is the same seventeen instructions.

  0      auipc s0, 0
  1-2    s1 = base + 0x1000          the samples
  3-4    s2 = base + 0x2000          the output
  5-6    s7 = bit 0 of sample 0      the window's reference
  7      s4 = 2                      the last sample: none yet
  8-10   s5 = s6 = s8 = 0            run, bad, matches
  11     s3 = 1024
  12-28  per sample: t1 = bit; run = (t1 = last ? run : 0) + 1; last = t1;
         bad |= run ≥ 21; matches += (t1 = ref); next; bne s3 → 12
  29-31  bad |= matches ≥ 589
  32     bne s6, x0 → 45
  33-41  copy the 1024 words to the output
  42-44  HALT 0
  45-47  HALT 1
-/
import Rv32.Blocks
import Rv32.Line
import Rv32.Copy
import Rv32.Asm

namespace Exp222
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S3 : Reg := 19
def S4 : Reg := 20
def S5 : Reg := 21
def S6 : Reg := 22
def S7 : Reg := 23
def S8 : Reg := 24
def T1 : Reg := 6
def T2 : Reg := 7

def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S1 S0 T1,
  .lui T1 2, .op .add S2 S0 T1,
  .ld .lw S7 S1 0, .opi .andi S7 S7 1,
  .opi .addi S4 0 2,
  .opi .addi S5 0 0, .opi .addi S6 0 0, .opi .addi S8 0 0,
  .opi .addi S3 0 1024 ]

/-- One sample's straight line, after its load: no branch. -/
def body : List Instr := [
  .opi .andi T1 T1 1,
  .op .xor T2 T1 S4, .opi .sltiu T2 T2 1, .op .sub T2 0 T2, .op .and S5 S5 T2,
  .opi .addi S5 S5 1, .opi .addi S4 T1 0,
  .opi .sltiu T2 S5 21, .opi .xori T2 T2 1, .op .or S6 S6 T2,
  .op .xor T2 T1 S7, .opi .xori T2 T2 1, .op .add S8 S8 T2,
  .opi .addi S1 S1 4, .opi .addi S3 S3 0xfff ]

def health : List Instr := [.ld .lw T1 S1 0] ++ body ++ [.br .bne S3 0 0xfe0]

def verdict : List Instr := [
  .opi .sltiu T2 S8 589, .opi .xori T2 T2 1, .op .or S6 S6 T2,
  .br .bne S6 0 0x01a ]

def copy : List Instr := [
  .lui T1 1, .op .add S1 S0 T1, .opi .addi S3 0 1024,
  .ld .lw T2 S1 0, .st .sw S2 T2 0, .opi .addi S1 S1 4, .opi .addi S2 S2 4,
  .opi .addi S3 S3 0xfff, .br .bne S3 0 0xff6 ]

def finish : List Instr := [
  .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall,
  .opi .addi A0 0 1, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := setup ++ health ++ verdict ++ copy ++ finish

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 48 := by decide

/-! ## What the kernel is held to -/

def N : Nat := 1024
def SAMPLES : Nat := 0x1000
def OUT : Nat := 0x2000
def RCT_CUTOFF : Nat := 21
def APT_CUTOFF : Nat := 589

/-- Sample `i`, as the word the shell wrote. -/
def sample (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  readLE m (base + BitVec.ofNat 32 (SAMPLES + 4 * i)) 4

/-- The bit the tests see: bit 0. -/
def bit (m : Word → Byte) (base : Word) (i : Nat) : Nat := sample m base i % 2

/-- The repetition count's state: the last bit (2 before the first), the
run it ends, and whether any run has reached the cutoff. exp114's
`Health::push`, without its early stop: once `bad`, it stays so. -/
structure Rct where
  last : Nat
  run : Nat
  bad : Bool

def rctStep (st : Rct) (b : Nat) : Rct :=
  let run := if b = st.last then st.run + 1 else 1
  ⟨b, run, st.bad || decide (RCT_CUTOFF ≤ run)⟩

def rctInit : Rct := ⟨2, 0, false⟩

def bits (m : Word → Byte) (base : Word) (n : Nat) : List Nat := (List.range n).map (bit m base)

def rct (m : Word → Byte) (base : Word) (n : Nat) : Rct := (bits m base n).foldl rctStep rctInit

/-- How many of the first `n` bits equal the window's first. -/
def agree (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((bits m base n).filter (· = bit m base 0)).length

/-- **Healthy**: neither test fails over the 1024 samples. -/
def Healthy (m : Word → Byte) (base : Word) : Prop :=
  (rct m base N).bad = false ∧ agree m base N < APT_CUTOFF

instance (m : Word → Byte) (base : Word) : Decidable (Healthy m base) := by
  unfold Healthy; infer_instance

/-! ## One sample's line -/

theorem and_one (x : Word) : x &&& 1#32 = BitVec.ofNat 32 (x.toNat % 2) := by
  apply BitVec.eq_of_toNat_eq
  simp [BitVec.toNat_and, Nat.and_one_is_mod]; omega

theorem and_ones (x : Word) : x &&& 4294967295#32 = x := by
  rw [show (4294967295#32 : Word) = BitVec.allOnes 32 from rfl, BitVec.and_allOnes]

/-- The new run, from the bit, the last bit and the old run. -/
theorem run_word (b l run : Nat) (hb : b ≤ 1) (hl : l ≤ 2) :
    (BitVec.ofNat 32 run &&& -if BitVec.ult (BitVec.ofNat 32 b ^^^ BitVec.ofNat 32 l) 1#32 = true then 1#32 else 0#32)
      + 1#32 = BitVec.ofNat 32 (if b = l then run + 1 else 1) := by
  have hb' : b = 0 ∨ b = 1 := by omega
  have hl' : l = 0 ∨ l = 1 ∨ l = 2 := by omega
  rcases hb' with rfl | rfl <;> rcases hl' with rfl | rfl | rfl <;>
    simp [and_ones] <;> (apply BitVec.eq_of_toNat_eq; simp [BitVec.toNat_add]; try omega)

/-- Whether anything has failed, after a count is held to a cutoff: `sltiu;
xori 1; or`, for the run against 21 and for the agreements against 589. -/
theorem bad_word (c bad r : Nat) (hc : c < 2 ^ 32) (hbad : bad ≤ 1) (hr : r ≤ 1024) :
    BitVec.ofNat 32 bad ||| (if BitVec.ult (BitVec.ofNat 32 r) (BitVec.ofNat 32 c) = true then 1#32 else 0#32) ^^^ 1#32
      = BitVec.ofNat 32 (if bad = 1 ∨ c ≤ r then 1 else 0) := by
  have hu : BitVec.ult (BitVec.ofNat 32 r) (BitVec.ofNat 32 c) = decide (r < c) := by
    simp [BitVec.ult, Nat.mod_eq_of_lt (show r < 2 ^ 32 by omega), Nat.mod_eq_of_lt hc]
  rw [hu]
  have hb' : bad = 0 ∨ bad = 1 := by omega
  by_cases h : r < c
  · have h' : ¬ c ≤ r := by omega
    rcases hb' with rfl | rfl <;> simp [h, h']
  · have h' : c ≤ r := by omega
    rcases hb' with rfl | rfl <;> simp [h, h']

/-- How many agree, after this bit. -/
theorem agree_word (ag b rf : Nat) (hb : b ≤ 1) (hrf : rf ≤ 1) :
    BitVec.ofNat 32 ag + (BitVec.ofNat 32 b ^^^ BitVec.ofNat 32 rf ^^^ 1#32)
      = BitVec.ofNat 32 (ag + if b = rf then 1 else 0) := by
  have hb' : b = 0 ∨ b = 1 := by omega
  have hr' : rf = 0 ∨ rf = 1 := by omega
  rcases hb' with rfl | rfl <;> rcases hr' with rfl | rfl <;> simp <;>
    (apply BitVec.eq_of_toNat_eq; simp [BitVec.toNat_add]; try omega)

/-- What one sample's line — after its load into `t1` — leaves, in the
specification's terms: the bit, the run, whether anything has failed, how
many agreed with the reference; and the pointer and the counter moved on. -/
theorem body_regs (s : Machine) (l run bad ag rf : Nat) (hl : l ≤ 2) (hrun : run < 1024)
    (hbad : bad ≤ 1) (hrf : rf ≤ 1)
    (h4 : s.reg S4 = BitVec.ofNat 32 l) (h5 : s.reg S5 = BitVec.ofNat 32 run)
    (h6 : s.reg S6 = BitVec.ofNat 32 bad) (h7 : s.reg S7 = BitVec.ofNat 32 rf)
    (h8 : s.reg S8 = BitVec.ofNat 32 ag) :
    let b := (s.reg T1).toNat % 2
    let run' := if b = l then run + 1 else 1
    (s.line body).reg S4 = BitVec.ofNat 32 b ∧
    (s.line body).reg S5 = BitVec.ofNat 32 run' ∧
    (s.line body).reg S6 = BitVec.ofNat 32 (if bad = 1 ∨ 21 ≤ run' then 1 else 0) ∧
    (s.line body).reg S8 = BitVec.ofNat 32 (ag + if b = rf then 1 else 0) ∧
    (s.line body).reg S1 = s.reg S1 + 4 ∧
    (s.line body).reg S3 = s.reg S3 + (0xfff : BitVec 12).signExtend 32 := by
  intro b run'
  have hb : b ≤ 1 := by omega
  have g4 : (s.line body).reg S4 = s.reg T1 &&& 1#32 := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S8, S1, S3]
  have g5 : (s.line body).reg S5 =
      (s.reg S5 &&& -if BitVec.ult ((s.reg T1 &&& 1#32) ^^^ s.reg S4) 1#32 = true then 1#32 else 0#32)
        + 1#32 := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S8, S1, S3]; rfl
  have g6 : (s.line body).reg S6 = s.reg S6 |||
      (if BitVec.ult ((s.reg S5 &&& -if BitVec.ult ((s.reg T1 &&& 1#32) ^^^ s.reg S4) 1#32 = true then 1#32
          else 0#32) + 1#32) 21#32 = true then 1#32 else 0#32) ^^^ 1#32 := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S8, S1, S3]; rfl
  have g8 : (s.line body).reg S8 = s.reg S8 + ((s.reg T1 &&& 1#32) ^^^ s.reg S7 ^^^ 1#32) := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S7, S8, S1, S3]
  have g1 : (s.line body).reg S1 = s.reg S1 + 4 := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S7, S8, S1, S3]
  have g3 : (s.line body).reg S3 = s.reg S3 + (0xfff : BitVec 12).signExtend 32 := by
    simp [Machine.line, body, Machine.alu, reg_setReg, aluR, aluI, T1, T2, S4, S5, S6, S7, S8, S1, S3]
  have r5 := run_word b l run hb hl
  rw [and_one] at g4 g5 g6 g8
  rw [h4, h5] at g5 g6
  refine ⟨g4, by rw [g5]; exact r5, ?_, ?_, g1, g3⟩
  · rw [g6, h6, r5]
    exact bad_word 21 bad run' (by decide) hbad (by simp only [run']; split <;> omega)
  · rw [g8, h8, h7]; exact agree_word ag b rf hb hrf

/-! ## The specification, a sample at a time -/

theorem bits_succ (m : Word → Byte) (base : Word) (n : Nat) :
    bits m base (n + 1) = bits m base n ++ [bit m base n] := by
  simp [bits, List.range_succ]

theorem rct_succ (m : Word → Byte) (base : Word) (n : Nat) :
    rct m base (n + 1) = rctStep (rct m base n) (bit m base n) := by
  simp [rct, bits_succ, List.foldl_append]

theorem agree_succ (m : Word → Byte) (base : Word) (n : Nat) :
    agree m base (n + 1) = agree m base n + if bit m base n = bit m base 0 then 1 else 0 := by
  simp only [agree, bits_succ, List.filter_append, List.length_append]
  by_cases h : bit m base n = bit m base 0 <;> simp [h]

theorem bit_le (m : Word → Byte) (base : Word) (n : Nat) : bit m base n ≤ 1 := by
  simp only [bit]; omega

theorem rct_bounds (m : Word → Byte) (base : Word) (n : Nat) :
    (rct m base n).last ≤ 2 ∧ (rct m base n).run ≤ n := by
  induction n with
  | zero => simp [rct, bits, rctInit]
  | succ n ih =>
    rw [rct_succ]
    simp only [rctStep]
    have := bit_le m base n
    constructor
    · omega
    · split <;> omega

theorem agree_le (m : Word → Byte) (base : Word) (n : Nat) : agree m base n ≤ n := by
  induction n with
  | zero => simp [agree, bits]
  | succ n ih => rw [agree_succ]; split <;> omega


/-! ## Where the kernel is, instruction by instruction -/

def setupLine : List Instr := [
  .opi .andi S7 S7 1, .opi .addi S4 0 2, .opi .addi S5 0 0, .opi .addi S6 0 0,
  .opi .addi S8 0 0, .opi .addi S3 0 1024 ]

theorem seg_setupLine : (kernel.drop 6).take setupLine.length = setupLine := by decide
theorem seg_body : (kernel.drop 13).take body.length = body := by decide

/-- At the top of sample `i`, or once `i` is 1024 at the verdict: memory as
the shell left it, the pointer and the counter `i` on, and the four values
the tests carry as the specification has them after `i` samples. -/
structure Inv (m0 : Word → Byte) (base : Word) (i : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * if i < N then 12 else 29)
  mem : s.mem = m0
  s0 : s.reg S0 = base
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SAMPLES + 4 * i)
  s2 : s.reg S2 = base + BitVec.ofNat 32 OUT
  s3 : s.reg S3 = BitVec.ofNat 32 (N - i)
  s4 : s.reg S4 = BitVec.ofNat 32 (rct m0 base i).last
  s5 : s.reg S5 = BitVec.ofNat 32 (rct m0 base i).run
  s6 : s.reg S6 = BitVec.ofNat 32 (if (rct m0 base i).bad then 1 else 0)
  s7 : s.reg S7 = BitVec.ofNat 32 (bit m0 base 0)
  s8 : s.reg S8 = BitVec.ofNat 32 (agree m0 base i)

theorem read_bit (m : Word → Byte) (base : Word) (i : Nat) :
    (BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 (SAMPLES + 4 * i)) 4)).toNat % 2 = bit m base i := by
  rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)]; rfl

/-- Twelve instructions: the pointers, the reference bit, and the four values
at their starts. -/
theorem setup_run {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 12 s = .running s' ∧ Inv s.mem base 0 s' := by
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
  have b0 : s5.reg S0 = base := by
    rw [reg_kept r5 (by decide), reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide),
      reg_wrote r1 (by decide), hpc]; simp
  have b1 : s5.reg S1 = base + BitVec.ofNat 32 SAMPLES := by
    rw [reg_kept r5 (by decide), reg_kept r4 (by decide), reg_wrote r3 (by decide)]
    simp only [aluR]; rw [reg_kept r2 (by decide), reg_wrote r1 (by decide), reg_wrote r2 (by decide), hpc]
    simp [SAMPLES]
  have b2 : s5.reg S2 = base + BitVec.ofNat 32 OUT := by
    rw [reg_wrote r5 (by decide)]
    simp only [aluR]; rw [reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide),
      reg_wrote r1 (by decide), reg_wrote r4 (by decide), hpc]
    simp [OUT]
  have mm : s5.mem = s.mem := by rw [m5, m4, m3, m2, m1]
  have hc5 : CodeAt s5.mem base kernel := by rw [mm]; exact hcode
  obtain ⟨s6, e6, p6, m6, r6⟩ := loadStep (prog := kernel) hp 5 (by decide) hc5 p5
    (rd := S7) (rs1 := S1) (imm := 0) (by decide) SAMPLES (by rw [b1]; simp) (by decide) (by decide)
  have hc6 : CodeAt s6.mem base kernel := by rw [m6]; exact hc5
  have e7 := run_line (prog := kernel) hp setupLine (by decide) 6 s6 seg_setupLine (by decide) hc6 p6 (by decide)
  refine ⟨s6.line setupLine, ?_, ?_⟩
  · rw [show 12 = 1 + (1 + (1 + (1 + (1 + (1 + 6))))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 e7)))))
  have k6 : ∀ r, r ≠ S7 → r ≠ S4 → r ≠ S5 → r ≠ S6 → r ≠ S8 → r ≠ S3 → (s6.line setupLine).reg r = s5.reg r := by
    intro r h7 h4 h5 h6 h8 h3
    rw [line_keeps _ _ r (by simp [setupLine, rdOf]; exact ⟨fun e => h7 e.symm, fun e => h4 e.symm,
      fun e => h5 e.symm, fun e => h6 e.symm, fun e => h8 e.symm, fun e => h3 e.symm⟩),
      reg_kept r6 h7]
  constructor
  · rw [line_pc_at setupLine p6 (by decide)]; rfl
  · rw [line_mem, m6, mm]
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), b0]
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), b1]; simp
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), b2]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, N]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · have v : (s6.line setupLine).reg S7 = s6.reg S7 &&& 1#32 := by
      simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3]
    rw [v, reg_wrote r6 (by decide), and_one, mm, show SAMPLES = SAMPLES + 4 * 0 by rfl, read_bit]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, agree, bits]

/-! ## The health loop -/

/-- `addi s3, s3, -1`, counting down from 1024. -/
theorem countdown {i : Nat} (hi : i < N) :
    BitVec.ofNat 32 (N - i) + (0xfff : BitVec 12).signExtend 32 = BitVec.ofNat 32 (N - (i + 1)) := by
  have : (0xfff : BitVec 12).signExtend 32 = BitVec.ofNat 32 (2^32 - 1) := by decide
  rw [this]
  apply BitVec.eq_of_toNat_eq
  simp only [N] at hi ⊢
  rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat]
  omega

/-- And whether `bne s3, x0` goes round again. -/
theorem round_again {i : Nat} (hi : i < N) :
    taken .bne (BitVec.ofNat 32 (N - (i + 1))) 0 = decide (i + 1 < N) := by
  simp only [taken, N] at hi ⊢
  by_cases h : i + 1 < 1024
  · simp only [h, decide_true, bne_iff_ne, ne_eq]
    intro e; have := congrArg BitVec.toNat e; simp at this; omega
  · simp only [h, decide_false, bne_eq_false_iff_eq]
    apply BitVec.eq_of_toNat_eq; simp; omega

theorem back_to_12 (base : Word) :
    base + BitVec.ofNat 32 (4 * 28) + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 12) := by
  rw [BitVec.add_assoc]; congr 1

theorem on_to_29 (hfit : base.toNat + 0x10000 ≤ 2^32) :
    base + BitVec.ofNat 32 (4 * 28) + 4 = base + BitVec.ofNat 32 (4 * 29) := pc_next hfit 28 (by decide)

/-- **One sample**: seventeen instructions take the invariant from `i` to `i + 1`. -/
theorem health_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < N) {s : Machine} (h : Inv m0 base i s) :
    ∃ s', run env 17 s = .running s' ∧ Inv m0 base (i + 1) s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 12) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact hc0
  have hi' : i < 1024 := hi
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp 12 (by decide) hcode hpc
    (rd := T1) (rs1 := S1) (imm := 0) (by decide) (SAMPLES + 4 * i) (by rw [h.s1]; simp)
    (by simp only [SAMPLES]; omega) (by simp only [SAMPLES]; omega)
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have e2 := run_line (prog := kernel) hp body (by decide) 13 s1 seg_body (by decide) hc1 p1 (by decide)
  have bT1 : (s1.reg T1).toNat % 2 = bit m0 base i := by
    rw [reg_wrote r1 (by decide), h.mem]; exact read_bit m0 base i
  have hb := rct_bounds m0 base i
  have hag := agree_le m0 base i
  obtain ⟨g4, g5, g6, g8, g1, g3⟩ := body_regs s1 (rct m0 base i).last (rct m0 base i).run
    (if (rct m0 base i).bad then 1 else 0) (agree m0 base i) (bit m0 base 0) hb.1 (by omega)
    (by split <;> omega) (bit_le m0 base 0)
    (by rw [reg_kept r1 (by decide), h.s4]) (by rw [reg_kept r1 (by decide), h.s5])
    (by rw [reg_kept r1 (by decide), h.s6]) (by rw [reg_kept r1 (by decide), h.s7])
    (by rw [reg_kept r1 (by decide), h.s8])
  simp only [bT1] at g4 g5 g6 g8
  have p2 : (s1.line body).pc = base + BitVec.ofNat 32 (4 * 28) := line_pc_at body p1 (by decide)
  have hc2 : CodeAt (s1.line body).mem base kernel := by rw [line_mem]; exact hc1
  have keep : ∀ r, r = S0 ∨ r = S2 ∨ r = S7 → (s1.line body).reg r = s.reg r := by
    intro r hr
    rw [line_keeps _ _ r (by rcases hr with rfl | rfl | rfl <;> decide), reg_kept r1]
    rcases hr with rfl | rfl | rfl <;> decide
  have c3 : (s1.line body).reg S3 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g3, reg_kept r1 (by decide), h.s3]; exact countdown hi
  have c1 : (s1.line body).reg S1 = base + BitVec.ofNat 32 (SAMPLES + 4 * (i + 1)) := by
    rw [g1, reg_kept r1 (by decide), h.s1, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      off_add hp.fit _ _ (by simp only [SAMPLES]; omega)]
    congr 2
  have tk : taken .bne ((s1.line body).reg S3) ((s1.line body).reg 0) = decide (i + 1 < N) := by
    rw [c3, reg_zero]; exact round_again hi
  have mem2 : (s1.line body).mem = m0 := by rw [line_mem, m1, h.mem]
  have regs : ∀ s' : Machine, s'.mem = m0 → (∀ r, s'.reg r = (s1.line body).reg r) →
      s'.pc = base + BitVec.ofNat 32 (4 * if i + 1 < N then 12 else 29) → Inv m0 base (i + 1) s' := by
    intro s' hm hr hp'
    refine ⟨hp', hm, by rw [hr, keep _ (.inl rfl), h.s0], by rw [hr, c1],
      by rw [hr, keep _ (.inr (.inl rfl)), h.s2], by rw [hr, c3], ?_, ?_, ?_,
      by rw [hr, keep _ (.inr (.inr rfl)), h.s7], ?_⟩
    · rw [hr, g4, rct_succ]; rfl
    · rw [hr, g5, rct_succ]; rfl
    · rw [hr, g6, rct_succ]
      simp only [rctStep, RCT_CUTOFF]
      by_cases hbd : (rct m0 base i).bad = true
      · simp [hbd]
      · simp only [Bool.not_eq_true] at hbd
        simp only [hbd, Bool.false_eq_true, ↓reduceIte, Bool.false_or]
        generalize (if bit m0 base i = (rct m0 base i).last then (rct m0 base i).run + 1 else 1) = X
        by_cases h21 : 21 ≤ X <;> simp [h21]
    · rw [hr, g8, agree_succ]
  by_cases hl : i + 1 < N
  · refine ⟨(s1.line body).setPc ((s1.line body).pc + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32), ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp 28 (by decide) hc2 p2 (i := .br .bne S3 0 0xfe0) (by decide)
        (exec_br_taken (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)
    · exact regs _ (by rw [setPc_mem, mem2]) (fun r => by rw [setPc_reg])
        (by rw [setPc_pc, p2, back_to_12]; simp [hl])
  · refine ⟨(s1.line body).next, ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp 28 (by decide) hc2 p2 (i := .br .bne S3 0 0xfe0) (by decide)
        (exec_br_not (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)
    · exact regs _ (by rw [next_mem, mem2]) (fun r => by rw [next_reg])
        (by rw [next_pc, p2, on_to_29 hp.fit]; simp [hl])

/-- 1024 samples, by induction. -/
theorem health_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv m0 base 0 s) :
    ∀ j ≤ N, ∃ s', run env (17 * j) s = .running s' ∧ Inv m0 base j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := health_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 17 * (j + 1) = 17 * j + 17 by omega, run_add_running e, e'], hs''⟩

/-! ## The verdict -/

def verdictLine : List Instr := [ .opi .sltiu T2 S8 589, .opi .xori T2 T2 1, .op .or S6 S6 T2 ]

theorem seg_verdictLine : (kernel.drop 29).take verdictLine.length = verdictLine := by decide

/-- HALT, at an `ecall` of the kernel with `t0 = 1`. -/
theorem halts_at {env : Env} {base : Word} (hp : Placed env base) {s : Machine} (k : Nat) (hk : k < 48)
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (hi : kernel.getD k .ecall = .ecall) (ht0 : s.reg T0 = 1) :
    run env 1 s = .halted (s.reg A0) s := by
  have hk' : k < kernel.length := by rw [kernel_length]; exact hk
  have : kernel[k] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk']
  exact run_code_halt 0 hk' hcode hpc (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (by rw [this]; exact exec_halt ht0)

theorem to_45 (base : Word) :
    base + BitVec.ofNat 32 (4 * 32) + ((0x01a : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 45) := by
  rw [BitVec.add_assoc]; congr 1

/-- After the 1024th sample: the adaptive proportion's cutoff joins the flag,
and the flag decides. Unhealthy, it is HALT 1 seven instructions on, with
memory untouched; healthy, the copy starts four instructions on. -/
theorem verdict_run {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv m0 base N s) :
    (¬ Healthy m0 base → ∃ s', run env 7 s = .halted 1 s' ∧ s'.mem = m0) ∧
    (Healthy m0 base → ∃ s', run env 4 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 33)
      ∧ s'.mem = m0 ∧ s'.reg S0 = base ∧ s'.reg S2 = base + BitVec.ofNat 32 OUT) := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 29) := by rw [h.pc]; simp [N]
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact hc0
  have e1 := run_line (prog := kernel) hp verdictLine (by decide) 29 s seg_verdictLine (by decide) hcode hpc
    (by decide)
  have p1 : (s.line verdictLine).pc = base + BitVec.ofNat 32 (4 * 32) := line_pc_at verdictLine hpc (by decide)
  have hc1 : CodeAt (s.line verdictLine).mem base kernel := by rw [line_mem]; exact hcode
  have g6 : (s.line verdictLine).reg S6 = s.reg S6 |||
      (if BitVec.ult (s.reg S8) 589#32 = true then 1#32 else 0#32) ^^^ 1#32 := by
    simp [Machine.line, verdictLine, Machine.alu, reg_setReg, aluR, aluI, T2, S6, S8]; rfl
  have hag := agree_le m0 base N
  have v6 : (s.line verdictLine).reg S6 = BitVec.ofNat 32
      (if (if (rct m0 base N).bad then 1 else 0) = 1 ∨ APT_CUTOFF ≤ agree m0 base N then 1 else 0) := by
    rw [g6, h.s6, h.s8]
    exact bad_word 589 _ _ (by decide) (by split <;> omega) hag
  have tk : taken .bne ((s.line verdictLine).reg S6) ((s.line verdictLine).reg 0) = decide (¬ Healthy m0 base) := by
    rw [v6, reg_zero]
    simp only [Healthy, APT_CUTOFF, taken]
    by_cases hb : (rct m0 base N).bad = true
    · simp [hb]
    · simp only [Bool.not_eq_true] at hb
      by_cases ha : 589 ≤ agree m0 base N
      · simp [hb, ha]
      · simp [hb, ha]
  have keep : ∀ r, r = S0 ∨ r = S2 → (s.line verdictLine).reg r = s.reg r := by
    intro r hr
    rw [line_keeps _ _ r (by rcases hr with rfl | rfl <;> decide)]
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · have tt : taken .bne ((s.line verdictLine).reg S6) ((s.line verdictLine).reg 0) = true := by rw [tk]; simp [hn]
    have e2 : run env 1 (s.line verdictLine) = .running ((s.line verdictLine).setPc
        ((s.line verdictLine).pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK hp 32 (by decide) hc1 p1 (i := .br .bne S6 0 0x01a) (by decide) (exec_br_taken tt) 0).trans
        (run_zero _ _)
    set_option maxHeartbeats 400000 in
    have p2 : ((s.line verdictLine).setPc ((s.line verdictLine).pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)).pc
        = base + BitVec.ofNat 32 (4 * 45) := by rw [setPc_pc, p1, to_45]
    have hc2 : CodeAt ((s.line verdictLine).setPc
        ((s.line verdictLine).pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)).mem base kernel := by
      rw [setPc_mem]; exact hc1
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 45 (by decide) hc2 p2
      (i := .opi .addi A0 0 1) (by decide) rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 46 (by decide) (by rw [m3]; exact hc2) p3
      (i := .opi .addi T0 0 1) (by decide) rfl
    have t0 : s4.reg T0 = 1 := by rw [reg_wrote r4 (by decide)]; simp only [aluI, reg_zero]; decide
    have a0 : s4.reg A0 = 1 := by
      rw [reg_kept r4 (by decide), reg_wrote r3 (by decide)]; simp only [aluI, reg_zero]; decide
    have e5 := halts_at hp (s := s4) 47 (by decide) (by rw [m4, m3]; exact hc2) p4 (by decide) t0
    rw [a0] at e5
    refine ⟨s4, ?_, by rw [m4, m3, setPc_mem, line_mem, h.mem]⟩
    rw [show 7 = verdictLine.length + (1 + (1 + (1 + 1))) by decide, run_add_running e1,
      run_add_running e2, run_add_running e3, run_add_running e4, e5]
  · have tf : taken .bne ((s.line verdictLine).reg S6) ((s.line verdictLine).reg 0) = false := by rw [tk]; simp [hy]
    refine ⟨(s.line verdictLine).next, ?_, by rw [next_pc, p1]; exact pc_next hp.fit 32 (by decide),
      by rw [next_mem, line_mem, h.mem], by rw [next_reg, keep _ (.inl rfl), h.s0],
      by rw [next_reg, keep _ (.inr rfl), h.s2]⟩
    rw [show 4 = verdictLine.length + 1 by decide, run_add_running e1]
    exact (stepK hp 32 (by decide) hc1 p1 (i := .br .bne S6 0 0x01a) (by decide) (exec_br_not tf) 0).trans
      (run_zero _ _)

/-! ## The copy, when healthy -/

def startLine : List Instr := [ .op .add S1 S0 T1, .opi .addi S3 0 1024 ]
def stepLine : List Instr := [ .opi .addi S1 S1 4, .opi .addi S2 S2 4, .opi .addi S3 S3 0xfff ]

theorem seg_startLine : (kernel.drop 34).take startLine.length = startLine := by decide
theorem seg_stepLine : (kernel.drop 38).take stepLine.length = stepLine := by decide

/-- The copy never reaches the kernel's own bytes: they are below the output. -/
theorem code_of_copied {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) (j : Nat) (hj : j ≤ N) :
    CodeAt (copied m0 base SAMPLES OUT j) base kernel := by
  refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => ?_) hc0
  rw [kernel_length] at h2
  unfold copied
  have : ¬ (x - (base + BitVec.ofNat 32 OUT)).toNat < 4 * j := by
    rw [toNat_sub_off hfit x OUT (by decide)]
    have := x.isLt
    simp only [OUT, N] at hj ⊢
    rw [show 2 ^ 32 - (base.toNat + 8192) + x.toNat = 2 ^ 32 - (base.toNat + 8192 - x.toNat) by omega,
      Nat.mod_eq_of_lt (by omega)]
    omega
  simp only [this, ↓reduceIte]

/-- At the top of copy iteration `j`, or once `j` is 1024 at the HALT. -/
structure CInv (m0 : Word → Byte) (base : Word) (j : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * if j < N then 36 else 42)
  mem : s.mem = copied m0 base SAMPLES OUT j
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SAMPLES + 4 * j)
  s2 : s.reg S2 = base + BitVec.ofNat 32 (OUT + 4 * j)
  s3 : s.reg S3 = BitVec.ofNat 32 (N - j)

theorem back_to_36 (base : Word) :
    base + BitVec.ofNat 32 (4 * 41) + ((0xff6 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 36) := by
  rw [BitVec.add_assoc]; congr 1

/-- **One word copied**: six instructions take the copy's invariant from `j` to `j + 1`. -/
theorem copy_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {j : Nat} (hj : j < N) {s : Machine} (h : CInv m0 base j s) :
    ∃ s', run env 6 s = .running s' ∧ CInv m0 base (j + 1) s' := by
  have hj' : j < 1024 := hj
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 36) := by rw [h.pc]; simp [hj]
  have hcode : CodeAt s.mem base kernel := by rw [h.mem]; exact code_of_copied hp.fit hc0 j (by omega)
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp 36 (by decide) hcode hpc
    (rd := T2) (rs1 := S1) (imm := 0) (by decide) (SAMPLES + 4 * j) (by rw [h.s1]; simp)
    (by simp only [SAMPLES]; omega) (by simp only [SAMPLES]; omega)
  obtain ⟨s2, e2, p2, m2, r2⟩ := storeStep (prog := kernel) hp 37 (by decide) (by rw [m1]; exact hcode) p1
    (rs1 := S2) (rs2 := T2) (imm := 0) (by decide) (OUT + 4 * j)
    (by rw [reg_kept r1 (by decide), h.s2]; simp) (by simp only [OUT]; omega) (by simp only [OUT]; omega)
  have v2 : (s1.reg T2).toNat = readLE s1.mem (base + BitVec.ofNat 32 (SAMPLES + 4 * j)) 4 := by
    rw [reg_wrote r1 (by decide), m1, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)]
  have mem2 : s2.mem = copied m0 base SAMPLES OUT (j + 1) := by
    funext x
    rw [m2, v2, m1, h.mem]
    exact copied_step hp.fit (n := N) (by decide) (by decide) hj (fun _ => rfl) x
  have hc2 : CodeAt s2.mem base kernel := by rw [mem2]; exact code_of_copied hp.fit hc0 (j + 1) (by omega)
  have e3 := run_line (prog := kernel) hp stepLine (by decide) 38 s2 seg_stepLine (by decide) hc2 p2 (by decide)
  have p3 : (s2.line stepLine).pc = base + BitVec.ofNat 32 (4 * 41) := line_pc_at stepLine p2 (by decide)
  have hc3 : CodeAt (s2.line stepLine).mem base kernel := by rw [line_mem]; exact hc2
  have g1 : (s2.line stepLine).reg S1 = s2.reg S1 + 4 := by
    simp [Machine.line, stepLine, Machine.alu, reg_setReg, aluI, S1, S2, S3]
  have g2 : (s2.line stepLine).reg S2 = s2.reg S2 + 4 := by
    simp [Machine.line, stepLine, Machine.alu, reg_setReg, aluI, S1, S2, S3]
  have g3 : (s2.line stepLine).reg S3 = s2.reg S3 + (0xfff : BitVec 12).signExtend 32 := by
    simp [Machine.line, stepLine, Machine.alu, reg_setReg, aluI, S1, S2, S3]
  have c1 : (s2.line stepLine).reg S1 = base + BitVec.ofNat 32 (SAMPLES + 4 * (j + 1)) := by
    rw [g1, r2, reg_kept r1 (by decide), h.s1, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      off_add hp.fit _ _ (by simp only [SAMPLES]; omega)]; congr 2
  have c2 : (s2.line stepLine).reg S2 = base + BitVec.ofNat 32 (OUT + 4 * (j + 1)) := by
    rw [g2, r2, reg_kept r1 (by decide), h.s2, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      off_add hp.fit _ _ (by simp only [OUT]; omega)]; congr 2
  have c3 : (s2.line stepLine).reg S3 = BitVec.ofNat 32 (N - (j + 1)) := by
    rw [g3, r2, reg_kept r1 (by decide), h.s3]; exact countdown hj
  have tk : taken .bne ((s2.line stepLine).reg S3) ((s2.line stepLine).reg 0) = decide (j + 1 < N) := by
    rw [c3, reg_zero]; exact round_again hj
  have mem3 : (s2.line stepLine).mem = copied m0 base SAMPLES OUT (j + 1) := by rw [line_mem, mem2]
  by_cases hl : j + 1 < N
  · refine ⟨(s2.line stepLine).setPc ((s2.line stepLine).pc + ((0xff6 : BitVec 12) ++ 0#1).signExtend 32), ?_,
      ⟨by rw [setPc_pc, p3, back_to_36]; simp [hl], by rw [setPc_mem, mem3], by rw [setPc_reg, c1],
        by rw [setPc_reg, c2], by rw [setPc_reg, c3]⟩⟩
    rw [show 6 = 1 + (1 + (stepLine.length + 1)) by decide, run_add_running e1, run_add_running e2,
      run_add_running e3]
    exact (stepK hp 41 (by decide) hc3 p3 (i := .br .bne S3 0 0xff6) (by decide)
      (exec_br_taken (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)
  · refine ⟨(s2.line stepLine).next, ?_,
      ⟨by rw [next_pc, p3, pc_next hp.fit 41 (by decide)]; simp [hl], by rw [next_mem, mem3],
        by rw [next_reg, c1], by rw [next_reg, c2], by rw [next_reg, c3]⟩⟩
    rw [show 6 = 1 + (1 + (stepLine.length + 1)) by decide, run_add_running e1, run_add_running e2,
      run_add_running e3]
    exact (stepK hp 41 (by decide) hc3 p3 (i := .br .bne S3 0 0xff6) (by decide)
      (exec_br_not (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)

theorem copy_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv m0 base 0 s) :
    ∀ j ≤ N, ∃ s', run env (6 * j) s = .running s' ∧ CInv m0 base j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := copy_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 6 * (j + 1) = 6 * j + 6 by omega, run_add_running e, e'], hs''⟩

/-- From the verdict's healthy state: the copy's start, 1024 words, and HALT 0
— 6150 instructions. -/
theorem copy_run {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * 33))
    (hm : s.mem = m0) (h0 : s.reg S0 = base) (h2 : s.reg S2 = base + BitVec.ofNat 32 OUT) :
    ∃ s', run env 6150 s = .halted 0 s' ∧ s'.mem = copied m0 base SAMPLES OUT N := by
  have hcode : CodeAt s.mem base kernel := by rw [hm]; exact hc0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 33 (by decide) hcode hpc
    (i := .lui T1 1) (by decide) rfl
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have e2 := run_line (prog := kernel) hp startLine (by decide) 34 s1 seg_startLine (by decide) hc1 p1 (by decide)
  have c0 : CInv m0 base 0 (s1.line startLine) := by
    refine ⟨by rw [line_pc_at startLine p1 (by decide)]; rfl, by rw [line_mem, m1, hm, copied_zero], ?_, ?_, ?_⟩
    · have : (s1.line startLine).reg S1 = s1.reg S0 + s1.reg T1 := by
        simp [Machine.line, startLine, Machine.alu, reg_setReg, aluR, aluI, S0, S1, S3, T1]
      rw [this, reg_kept r1 (by decide), reg_wrote r1 (by decide), h0]; simp [SAMPLES]
    · rw [line_keeps _ _ S2 (by decide), reg_kept r1 (by decide), h2]; simp
    · simp [Machine.line, startLine, Machine.alu, reg_setReg, aluR, aluI, S0, S1, S3, T1, N]
  obtain ⟨sN, eN, hN⟩ := copy_loop hp hc0 c0 N (Nat.le_refl _)
  have pN : sN.pc = base + BitVec.ofNat 32 (4 * 42) := by rw [hN.pc]; simp [N]
  have hcN : CodeAt sN.mem base kernel := by rw [hN.mem]; exact code_of_copied hp.fit hc0 N (Nat.le_refl _)
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 42 (by decide) hcN pN
    (i := .opi .addi A0 0 0) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 43 (by decide) (by rw [m3]; exact hcN) p3
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : s4.reg T0 = 1 := by rw [reg_wrote r4 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : s4.reg A0 = 0 := by
    rw [reg_kept r4 (by decide), reg_wrote r3 (by decide)]; simp only [aluI, reg_zero]; decide
  have e5 := halts_at hp (s := s4) 44 (by decide) (by rw [m4, m3]; exact hcN) p4 (by decide) t0
  rw [a0] at e5
  refine ⟨s4, ?_, by rw [m4, m3, hN.mem]⟩
  rw [show 6150 = 1 + (startLine.length + (6 * N + (1 + (1 + 1)))) by decide, run_add_running e1,
    run_add_running e2, run_add_running eN, run_add_running e3, run_add_running e4, e5]

/-! ## The kernel, whole -/

/-- **The kernel withholds.** From `base`, with the kernel's bytes there:
- if the 1024 samples fail either test, it halts with 1 after exactly 17427
  instructions, and memory is just as it was — not a byte written, the
  output among them;
- if they pass both, it halts with 0 after exactly 23574, and memory is the
  original with the samples copied to the output and nothing else changed. -/
theorem withholds {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    (¬ Healthy s.mem base → ∃ s', run env 17427 s = .halted 1 s' ∧ s'.mem = s.mem) ∧
    (Healthy s.mem base →
      ∃ s', run env 23574 s = .halted 0 s' ∧ s'.mem = copied s.mem base SAMPLES OUT N) := by
  obtain ⟨s12, e12, inv0⟩ := setup_run hp s hpc hcode
  obtain ⟨sL, eL, invL⟩ := health_loop hp hcode inv0 N (Nat.le_refl _)
  obtain ⟨vn, vy⟩ := verdict_run hp hcode invL
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · obtain ⟨s', e', m'⟩ := vn hn
    exact ⟨s', by rw [show 17427 = 12 + (17 * N + 7) by decide, run_add_running e12, run_add_running eL, e'], m'⟩
  · obtain ⟨sv, ev, pv, mv, h0, h2⟩ := vy hy
    obtain ⟨s', e', m'⟩ := copy_run hp hcode pv mv h0 h2
    exact ⟨s', by rw [show 23574 = 12 + (17 * N + (4 + 6150)) by decide, run_add_running e12,
      run_add_running eL, run_add_running ev, e'], m'⟩

/-- **The output is the samples**, word for word, when they pass. -/
theorem output {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m0 : Word → Byte) {j : Nat} (hj : j < N) :
    readLE (copied m0 base SAMPLES OUT N) (base + BitVec.ofNat 32 (OUT + 4 * j)) 4 = sample m0 base j :=
  copied_word hfit (by decide) (by decide) hj

/-! ## The bytes are the kernel -/

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 192 ≤ img.size)
    (himg : ∀ d (h : d < 192), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **From the state the shell builds**: any image that begins with the
kernel's 192 bytes, the samples where the shell put them. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 192 ≤ img.size) (himg : ∀ d (h : d < 192), img.get d (by omega) = bytes.getD d 0) :
    let m0 := memOfImage base img
    (¬ Healthy m0 base → ∃ s', run env 17427 (boot env.region img) = .halted 1 s' ∧ s'.mem = m0) ∧
    (Healthy m0 base →
      ∃ s', run env 23574 (boot env.region img) = .halted 0 s' ∧ s'.mem = copied m0 base SAMPLES OUT N) := by
  intro m0
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = m0 := by simp [boot, hp.region, m0]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  have w := withholds hp _ hpc hcode
  rw [hmem] at w
  exact w

#print axioms body_regs
#print axioms health_loop
#print axioms verdict_run
#print axioms copy_run
#print axioms withholds
#print axioms output
#print axioms bytes_words
#print axioms from_boot

end Exp222

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp222.image
  | _ => pure ()
  for (i, k) in Exp222.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
