/-
SPDX-License-Identifier: Apache-2.0

# SP 800-90B's two continuous health tests, as a block of a kernel

NIST SP 800-90B's repetition count and adaptive proportion tests, as exp114
wrote them in `crates/entropy-health`, over one adaptive-proportion window of
1024 samples at `base + src`, one sample each in bit 0 of a word:

  Repetition Count Test   fail if 21 samples in a row are the same
  Adaptive Proportion     fail if 589 or more of the 1024 equal the first

`front` is the 27 instructions that run them, wherever in a kernel they sit:
`s1` pointing at the samples on the way in, and `s6` zero on the way out
exactly when both tests passed. Nothing is stored. What comes before (where
`s1` points) and after (what `s6` decides) is each kernel's own.

  0      lw s7, 0(s1)                the window's reference
  1-6    s7 = bit 0; s4 = 2 (no last sample yet); s5 = s6 = s8 = 0; s3 = 1024
  7      per sample: lw t1, 0(s1)
  8-22   t1 = bit; run = (t1 = last ? run : 0) + 1; last = t1;
         bad |= run ≥ 21; matches += (t1 = ref); next
  23     bne s3, x0 → 7
  24-26  bad |= matches ≥ 589

exp222 wrote this for one kernel, with the samples at 0x1000 and the block at
instruction 5; exp223 needed it second, at instruction 3 with the samples at
0x3000, so here both are parameters. `front_run` is all a kernel needs.
-/
import Rv32.Blocks
import Rv32.Line

namespace Rv32.Health
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

def setupLine : List Instr := [
  .opi .andi S7 S7 1, .opi .addi S4 0 2, .opi .addi S5 0 0, .opi .addi S6 0 0,
  .opi .addi S8 0 0, .opi .addi S3 0 1024 ]

/-- One sample's straight line, after its load: no branch. -/
def body : List Instr := [
  .opi .andi T1 T1 1,
  .op .xor T2 T1 S4, .opi .sltiu T2 T2 1, .op .sub T2 0 T2, .op .and S5 S5 T2,
  .opi .addi S5 S5 1, .opi .addi S4 T1 0,
  .opi .sltiu T2 S5 21, .opi .xori T2 T2 1, .op .or S6 S6 T2,
  .op .xor T2 T1 S7, .opi .xori T2 T2 1, .op .add S8 S8 T2,
  .opi .addi S1 S1 4, .opi .addi S3 S3 0xfff ]

def health : List Instr := [.ld .lw T1 S1 0] ++ body ++ [.br .bne S3 0 0xfe0]

def verdictLine : List Instr := [ .opi .sltiu T2 S8 589, .opi .xori T2 T2 1, .op .or S6 S6 T2 ]

/-- The block: the reference, the four values at their starts, 1024 samples,
and the verdict in `s6`. -/
def front : List Instr := [.ld .lw S7 S1 0] ++ setupLine ++ health ++ verdictLine

theorem front_length : front.length = 27 := by decide

/-! ## What the block is held to -/

def N : Nat := 1024
def RCT_CUTOFF : Nat := 21
def APT_CUTOFF : Nat := 589

/-- Sample `i`, as the word the shell wrote at `base + src + 4i`. -/
def sample (m : Word → Byte) (base : Word) (src i : Nat) : Nat :=
  readLE m (base + BitVec.ofNat 32 (src + 4 * i)) 4

/-- The bit the tests see: bit 0. -/
def bit (m : Word → Byte) (base : Word) (src i : Nat) : Nat := sample m base src i % 2

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

def bits (m : Word → Byte) (base : Word) (src n : Nat) : List Nat := (List.range n).map (bit m base src)

def rct (m : Word → Byte) (base : Word) (src n : Nat) : Rct := (bits m base src n).foldl rctStep rctInit

/-- How many of the first `n` bits equal the window's first. -/
def agree (m : Word → Byte) (base : Word) (src n : Nat) : Nat :=
  ((bits m base src n).filter (· = bit m base src 0)).length

/-- **Healthy**: neither test fails over the 1024 samples at `base + src`. -/
def Healthy (m : Word → Byte) (base : Word) (src : Nat) : Prop :=
  (rct m base src N).bad = false ∧ agree m base src N < APT_CUTOFF

instance (m : Word → Byte) (base : Word) (src : Nat) : Decidable (Healthy m base src) := by
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

theorem bits_succ (m : Word → Byte) (base : Word) (src n : Nat) :
    bits m base src (n + 1) = bits m base src n ++ [bit m base src n] := by
  simp [bits, List.range_succ]

theorem rct_succ (m : Word → Byte) (base : Word) (src n : Nat) :
    rct m base src (n + 1) = rctStep (rct m base src n) (bit m base src n) := by
  simp [rct, bits_succ, List.foldl_append]

theorem agree_succ (m : Word → Byte) (base : Word) (src n : Nat) :
    agree m base src (n + 1) = agree m base src n + if bit m base src n = bit m base src 0 then 1 else 0 := by
  simp only [agree, bits_succ, List.filter_append, List.length_append]
  by_cases h : bit m base src n = bit m base src 0 <;> simp [h]

theorem bit_le (m : Word → Byte) (base : Word) (src n : Nat) : bit m base src n ≤ 1 := by
  simp only [bit]; omega

theorem rct_bounds (m : Word → Byte) (base : Word) (src n : Nat) :
    (rct m base src n).last ≤ 2 ∧ (rct m base src n).run ≤ n := by
  induction n with
  | zero => simp [rct, bits, rctInit]
  | succ n ih =>
    rw [rct_succ]
    simp only [rctStep]
    have := bit_le m base src n
    constructor
    · omega
    · split <;> omega

theorem agree_le (m : Word → Byte) (base : Word) (src n : Nat) : agree m base src n ≤ n := by
  induction n with
  | zero => simp [agree, bits]
  | succ n ih => rw [agree_succ]; split <;> omega

theorem read_bit (m : Word → Byte) (base : Word) (src i : Nat) :
    (BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 (src + 4 * i)) 4)).toNat % 2 = bit m base src i := by
  rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)]; rfl

/-! ## Where the block is in a kernel -/

/-- A run of `prog` that is `L`, from instruction `k`, has `L`'s pieces where
they belong. -/
theorem seg_of {prog L : List Instr} {k n : Nat} (h : (prog.drop k).take n = L) {j m : Nat}
    (hjm : j + m ≤ n) : (prog.drop (k + j)).take m = (L.drop j).take m := by
  rw [← h, List.drop_take, List.take_take, Nat.min_eq_left (by omega), List.drop_drop, Nat.add_comm]

theorem getD_of {prog L : List Instr} {k n : Nat} (h : (prog.drop k).take n = L) {j : Nat} (hj : j < n) :
    prog.getD (k + j) .ecall = L.getD j .ecall := by
  have := seg_of h (j := j) (m := 1) (by omega)
  have e := congrArg List.head? this
  rw [List.head?_take, List.head?_take, List.head?_drop, List.head?_drop] at e
  simp only [Nat.add_one_ne_zero, ↓reduceIte] at e
  rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, e]

/-- Where a kernel has the block: instruction `k0` on, and the kernel small
enough for the region. -/
structure At (prog : List Instr) (k0 : Nat) : Prop where
  seg : (prog.drop k0).take 27 = front
  fits : k0 + 27 ≤ prog.length
  len : 4 * prog.length < 0x10000

/-- The registers the block writes, and so the ones it keeps. -/
def written : List Reg := [T1, T2, S1, S3, S4, S5, S6, S7, S8]

theorem keeps_of {blk : List Instr} (hblk : (blk.filterMap rdOf).all (fun rd => written.contains rd) = true)
    {r : Reg} (hr : r ∉ written) : ∀ i ∈ blk, rdOf i ≠ some r := by
  intro i hi heq
  have hm : r ∈ blk.filterMap rdOf := List.mem_filterMap.2 ⟨i, hi, heq⟩
  have := List.all_eq_true.1 hblk r hm
  simp only [List.contains_iff_mem] at this
  exact hr this

/-- At the top of sample `i`, or once `i` is 1024 at the verdict: memory as
it was, the pointer and the counter `i` on, the four values the tests carry
as the specification has them after `i` samples, and every register the
block does not write as it was on the way in, in `keep`. -/
structure Inv (m0 : Word → Byte) (base : Word) (src k0 : Nat) (keep : Reg → Word) (i : Nat) (s : Machine) :
    Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + if i < N then 7 else 24))
  mem : s.mem = m0
  s1 : s.reg S1 = base + BitVec.ofNat 32 (src + 4 * i)
  s3 : s.reg S3 = BitVec.ofNat 32 (N - i)
  s4 : s.reg S4 = BitVec.ofNat 32 (rct m0 base src i).last
  s5 : s.reg S5 = BitVec.ofNat 32 (rct m0 base src i).run
  s6 : s.reg S6 = BitVec.ofNat 32 (if (rct m0 base src i).bad then 1 else 0)
  s7 : s.reg S7 = BitVec.ofNat 32 (bit m0 base src 0)
  s8 : s.reg S8 = BitVec.ofNat 32 (agree m0 base src i)
  kept : ∀ r, r ∉ written → s.reg r = keep r

variable {env : Env} {base : Word} {prog : List Instr} {k0 src : Nat}

/-- Seven instructions: the reference bit, and the four values at their starts. -/
theorem start_run (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * N < 0x10000) (hs4 : src % 4 = 0)
    (s : Machine) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 src) :
    ∃ s', run env 7 s = .running s' ∧ Inv s.mem base src k0 s.reg 0 s' := by
  have hlen := ha.len
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 0) (by have := ha.fits; omega) hcode hpc
    (rd := S7) (rs1 := S1) (imm := 0) (by rw [getD_of ha.seg (by decide)]; rfl) src
    (by rw [h1]; simp) (by simp only [N] at hs; omega) hs4 hlen
  have hc1 : CodeAt s1.mem base prog := by rw [m1]; exact hcode
  have e2 := run_line hp setupLine (by decide) (k0 + 0 + 1) s1
    (by rw [show k0 + 0 + 1 = k0 + 1 by omega, seg_of ha.seg (by decide)]; decide) (by have := ha.fits; simp [setupLine]; omega)
    hc1 p1 hlen
  refine ⟨s1.line setupLine, ?_, ?_⟩
  · rw [show 7 = 1 + setupLine.length by rfl]; exact run_cons e1 e2
  have k6 : ∀ r, r ∉ written → (s1.line setupLine).reg r = s.reg r := by
    intro r hr
    rw [line_keeps _ _ r (keeps_of (by decide) hr), reg_kept r1 (fun e => hr (by rw [e]; decide))]
  constructor
  · rw [line_pc_at setupLine p1 (by simp [setupLine]; have := ha.fits; omega)]; simp [setupLine, N]
  · rw [line_mem, m1]
  · rw [line_keeps _ _ S1 (by simp [setupLine, rdOf, S1, S7, S4, S5, S6, S8, S3]),
      reg_kept r1 (by decide), h1]; simp
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, N]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, rct, bits, rctInit]
  · have v : (s1.line setupLine).reg S7 = s1.reg S7 &&& 1#32 := by
      simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3]
    rw [v, reg_wrote r1 (by decide), and_one]
    have := read_bit s.mem base src 0
    simp only [Nat.mul_zero, Nat.add_zero] at this
    rw [this]
  · simp [Machine.line, setupLine, Machine.alu, reg_setReg, aluI, S7, S4, S5, S6, S8, S3, agree, bits]
  · exact k6

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

theorem back_to_top (base : Word) (hk : 4 * (k0 + 23) < 0x10000) :
    base + BitVec.ofNat 32 (4 * (k0 + 7 + 1 + body.length)) + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32
      = base + BitVec.ofNat 32 (4 * (k0 + 7)) := by
  have e : ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 4294967232 := by decide
  have t : BitVec.ofNat 32 (4 * (k0 + 7 + 1 + body.length)) + BitVec.ofNat 32 4294967232
      = BitVec.ofNat 32 (4 * (k0 + 7)) := by
    rw [show body.length = 15 by rfl]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat,
      show (2:Nat) ^ 32 = 4294967296 by rfl,
      Nat.mod_eq_of_lt (show 4 * (k0 + 7 + 1 + 15) < 4294967296 by omega),
      Nat.mod_eq_of_lt (show 4294967232 < 4294967296 by decide),
      show 4 * (k0 + 7 + 1 + 15) + 4294967232 = 4 * (k0 + 7) + 4294967296 by omega, Nat.add_mod_right]
  rw [BitVec.add_assoc, e, t]

/-- **One sample**: seventeen instructions take the invariant from `i` to `i + 1`. -/
theorem health_iter (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * N < 0x10000) (hs4 : src % 4 = 0)
    {m0 : Word → Byte} (hc0 : CodeAt m0 base prog) {keep : Reg → Word} {i : Nat} (hi : i < N) {s : Machine}
    (h : Inv m0 base src k0 keep i s) :
    ∃ s', run env 17 s = .running s' ∧ Inv m0 base src k0 keep (i + 1) s' := by
  have hlen := ha.len
  have hfits := ha.fits
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + 7)) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base prog := by rw [h.mem]; exact hc0
  have hi' : i < 1024 := hi
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 7) (by omega) hcode hpc
    (rd := T1) (rs1 := S1) (imm := 0) (by rw [getD_of ha.seg (by decide)]; rfl) (src + 4 * i)
    (by rw [h.s1]; simp) (by simp only [N] at hs; omega) (by omega) hlen
  have hc1 : CodeAt s1.mem base prog := by rw [m1]; exact hcode
  have e2 := run_line hp body (by decide) (k0 + 7 + 1) s1
    (by rw [show k0 + 7 + 1 = k0 + 8 by omega, seg_of ha.seg (by decide)]; decide)
    (by simp [body]; omega) hc1 p1 hlen
  have bT1 : (s1.reg T1).toNat % 2 = bit m0 base src i := by
    rw [reg_wrote r1 (by decide), h.mem]; exact read_bit m0 base src i
  have hb := rct_bounds m0 base src i
  have hag := agree_le m0 base src i
  obtain ⟨g4, g5, g6, g8, g1, g3⟩ := body_regs s1 (rct m0 base src i).last (rct m0 base src i).run
    (if (rct m0 base src i).bad then 1 else 0) (agree m0 base src i) (bit m0 base src 0) hb.1 (by omega)
    (by split <;> omega) (bit_le m0 base src 0)
    (by rw [reg_kept r1 (by decide), h.s4]) (by rw [reg_kept r1 (by decide), h.s5])
    (by rw [reg_kept r1 (by decide), h.s6]) (by rw [reg_kept r1 (by decide), h.s7])
    (by rw [reg_kept r1 (by decide), h.s8])
  simp only [bT1] at g4 g5 g6 g8
  have p2 : (s1.line body).pc = base + BitVec.ofNat 32 (4 * (k0 + 7 + 1 + body.length)) :=
    line_pc_at body p1 (by simp [body]; omega)
  have hc2 : CodeAt (s1.line body).mem base prog := by rw [line_mem]; exact hc1
  have hbr : prog.getD (k0 + 7 + 1 + body.length) .ecall = .br .bne S3 0 0xfe0 := by
    rw [show k0 + 7 + 1 + body.length = k0 + 23 by rfl, getD_of ha.seg (by decide)]; rfl
  have keep7 : ∀ r, r ∉ written → (s1.line body).reg r = keep r := by
    intro r hr
    rw [line_keeps _ _ r (keeps_of (by decide) hr), reg_kept r1 (fun e => hr (by rw [e]; decide)), h.kept r hr]
  have keepS7 : (s1.line body).reg S7 = s.reg S7 := by
    rw [line_keeps _ _ S7 (by simp [body, rdOf, S7, T1, T2, S4, S5, S6, S8, S1, S3]), reg_kept r1 (by decide)]
  have c3 : (s1.line body).reg S3 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g3, reg_kept r1 (by decide), h.s3]; exact countdown hi
  have c1 : (s1.line body).reg S1 = base + BitVec.ofNat 32 (src + 4 * (i + 1)) := by
    rw [g1, reg_kept r1 (by decide), h.s1, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      off_add hp.fit _ _ (by simp only [N] at hs hi; omega)]
    congr 2
  have tk : taken .bne ((s1.line body).reg S3) ((s1.line body).reg 0) = decide (i + 1 < N) := by
    rw [c3, reg_zero]; exact round_again hi
  have mem2 : (s1.line body).mem = m0 := by rw [line_mem, m1, h.mem]
  have regs : ∀ s' : Machine, s'.mem = m0 → (∀ r, s'.reg r = (s1.line body).reg r) →
      s'.pc = base + BitVec.ofNat 32 (4 * (k0 + if i + 1 < N then 7 else 24)) →
      Inv m0 base src k0 keep (i + 1) s' := by
    intro s' hm hr hp'
    refine ⟨hp', hm, by rw [hr, c1], by rw [hr, c3], ?_, ?_, ?_,
      by rw [hr, keepS7, h.s7], ?_, fun r hr' => by rw [hr, keep7 r hr']⟩
    · rw [hr, g4, rct_succ]; rfl
    · rw [hr, g5, rct_succ]; rfl
    · rw [hr, g6, rct_succ]
      simp only [rctStep, RCT_CUTOFF]
      by_cases hbd : (rct m0 base src i).bad = true
      · simp [hbd]
      · simp only [Bool.not_eq_true] at hbd
        simp only [hbd, Bool.false_eq_true, ↓reduceIte, Bool.false_or]
        generalize (if bit m0 base src i = (rct m0 base src i).last then (rct m0 base src i).run + 1 else 1) = X
        by_cases h21 : 21 ≤ X <;> simp [h21]
    · rw [hr, g8, agree_succ]
  by_cases hl : i + 1 < N
  · refine ⟨(s1.line body).setPc ((s1.line body).pc + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32), ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp _ (by simp [body]; omega) hc2 p2 hbr
        (exec_br_taken (by rw [tk]; simp [hl])) 0 hlen).trans (run_zero _ _)
    · exact regs _ (by rw [setPc_mem, mem2]) (fun r => by rw [setPc_reg])
        (by rw [setPc_pc, p2, back_to_top base (by omega)]; simp [hl])
  · refine ⟨(s1.line body).next, ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp _ (by simp [body]; omega) hc2 p2 hbr
        (exec_br_not (by rw [tk]; simp [hl])) 0 hlen).trans (run_zero _ _)
    · exact regs _ (by rw [next_mem, mem2]) (fun r => by rw [next_reg])
        (by rw [next_pc, p2, pc_next hp.fit _ (by simp [body]; omega)]; simp [hl, body])

/-- 1024 samples, by induction. -/
theorem health_loop (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * N < 0x10000) (hs4 : src % 4 = 0)
    {m0 : Word → Byte} (hc0 : CodeAt m0 base prog) {keep : Reg → Word} {s : Machine}
    (h : Inv m0 base src k0 keep 0 s) :
    ∀ j ≤ N, ∃ s', run env (17 * j) s = .running s' ∧ Inv m0 base src k0 keep j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := health_iter hp ha hs hs4 hc0 (by omega) hs'
    exact ⟨s'', by rw [show 17 * (j + 1) = 17 * j + 17 by omega, run_add_running e, e'], hs''⟩

/-! ## The verdict -/

/-- After the 1024th sample: the adaptive proportion's cutoff joins the flag,
and `s6` is zero exactly when the samples are healthy. -/
theorem verdict_run (hp : Placed env base) (ha : At prog k0) {m0 : Word → Byte} (hc0 : CodeAt m0 base prog)
    {keep : Reg → Word} {s : Machine} (h : Inv m0 base src k0 keep N s) :
    ∃ s', run env 3 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 27)) ∧ s'.mem = m0
      ∧ s'.reg S6 = (if Healthy m0 base src then 0#32 else 1#32)
      ∧ ∀ r, r ∉ written → s'.reg r = keep r := by
  have hlen := ha.len
  have hfits := ha.fits
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + 24)) := by rw [h.pc]; simp [N]
  have hcode : CodeAt s.mem base prog := by rw [h.mem]; exact hc0
  have e1 := run_line hp verdictLine (by decide) (k0 + 24) s
    (by rw [seg_of ha.seg (by decide)]; decide) (by simp [verdictLine]; omega) hcode hpc hlen
  have g6 : (s.line verdictLine).reg S6 = s.reg S6 |||
      (if BitVec.ult (s.reg S8) 589#32 = true then 1#32 else 0#32) ^^^ 1#32 := by
    simp [Machine.line, verdictLine, Machine.alu, reg_setReg, aluR, aluI, T2, S6, S8]; rfl
  have hag := agree_le m0 base src N
  have v6 : (s.line verdictLine).reg S6 = BitVec.ofNat 32
      (if (if (rct m0 base src N).bad then 1 else 0) = 1 ∨ APT_CUTOFF ≤ agree m0 base src N then 1 else 0) := by
    rw [g6, h.s6, h.s8]
    exact bad_word 589 _ _ (by decide) (by split <;> omega) hag
  refine ⟨s.line verdictLine, e1, ?_, by rw [line_mem, h.mem], ?_, fun r hr => ?_⟩
  · rw [line_pc_at verdictLine hpc (by simp [verdictLine]; omega)]; rfl
  · rw [v6]
    simp only [Healthy, APT_CUTOFF]
    by_cases hb : (rct m0 base src N).bad = true
    · simp [hb]
    · simp only [Bool.not_eq_true] at hb
      by_cases hA : 589 ≤ agree m0 base src N
      · simp [hb, hA]
      · simp [hb, hA]
  · rw [line_keeps _ _ r (keeps_of (by decide) hr), h.kept r hr]

/-! ## The block, whole -/

/-- **The health tests, wherever a kernel has them**: from instruction `k0`,
with `s1` at the samples, 7 + 17 · 1024 + 3 instructions later the run is at
`k0 + 27`, nothing has been written, `s6` is zero exactly when the 1024
samples pass both tests, and every register outside `written` is as it was. -/
theorem front_run (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * N < 0x10000) (hs4 : src % 4 = 0)
    (s : Machine) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 src) :
    ∃ s', run env (7 + 17 * N + 3) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 27))
      ∧ s'.mem = s.mem ∧ s'.reg S6 = (if Healthy s.mem base src then 0#32 else 1#32)
      ∧ ∀ r, r ∉ written → s'.reg r = s.reg r := by
  obtain ⟨s7, e7, inv0⟩ := start_run hp ha hs hs4 s hpc hcode h1
  obtain ⟨sL, eL, invL⟩ := health_loop hp ha hs hs4 hcode inv0 N (Nat.le_refl _)
  obtain ⟨sV, eV, pV, mV, gV, kV⟩ := verdict_run hp ha hcode invL
  exact ⟨sV, by rw [Nat.add_assoc, run_add_running e7, run_add_running eL, eV], pV, mV, gV, kV⟩

#print axioms body_regs
#print axioms health_loop
#print axioms front_run

end Rv32.Health
