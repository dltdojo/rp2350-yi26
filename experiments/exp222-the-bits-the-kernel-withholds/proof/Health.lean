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

end Exp222

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp222.image
  | _ => pure ()
  for (i, k) in Exp222.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
