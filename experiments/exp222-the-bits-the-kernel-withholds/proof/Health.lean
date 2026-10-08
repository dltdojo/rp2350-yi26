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
  5-31   the tests: lean/Rv32/Health.lean's `front`, whose `s6` is zero
         exactly when the samples pass
  32     bne s6, x0 → 45
  33-41  copy the 1024 words to the output
  42-44  HALT 0
  45-47  HALT 1

The tests themselves are in the library since exp223, which runs them second;
what is here is where this kernel points them, and what it does with the
verdict.
-/
import Rv32.Health
import Rv32.Copy
import Rv32.Asm

namespace Exp222
open Rv32
open Rv32.Health (S0 S1 S2 S3 S6 T1 T2 front N countdown round_again)

def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S1 S0 T1,
  .lui T1 2, .op .add S2 S0 T1 ]

def verdict : List Instr := [ .br .bne S6 0 0x01a ]

def startLine : List Instr := [ .op .add S1 S0 T1, .opi .addi S3 0 1024 ]
def stepLine : List Instr := [ .opi .addi S1 S1 4, .opi .addi S2 S2 4, .opi .addi S3 S3 0xfff ]

def copy : List Instr :=
  [ .lui T1 1 ] ++ startLine ++ [ .ld .lw T2 S1 0, .st .sw S2 T2 0 ] ++ stepLine ++ [ .br .bne S3 0 0xff6 ]

def finish : List Instr := [
  .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall,
  .opi .addi A0 0 1, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := setup ++ front ++ verdict ++ copy ++ finish

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 48 := by decide

def SAMPLES : Nat := 0x1000
def OUT : Nat := 0x2000

/-- **Healthy**: neither test fails over the 1024 samples at `base + 0x1000`
— lean/Rv32/Health.lean's, at this kernel's place for them. -/
abbrev Healthy (m : Word → Byte) (base : Word) : Prop := Health.Healthy m base SAMPLES

/-- Where the kernel has the tests: instruction 5 on. -/
theorem at_front : Health.At kernel 5 := ⟨by decide, by decide, by decide⟩

/-- Five instructions: the pointers. -/
theorem setup_run {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 5 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 5) ∧ s'.mem = s.mem
      ∧ s'.reg S0 = base ∧ s'.reg S1 = base + BitVec.ofNat 32 SAMPLES ∧ s'.reg S2 = base + BitVec.ofNat 32 OUT := by
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
  refine ⟨s5, ?_, p5, by rw [m5, m4, m3, m2, m1], ?_, ?_, ?_⟩
  · rw [show 5 = 1 + (1 + (1 + (1 + 1))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 e5)))
  · rw [reg_kept r5 (by decide), reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide),
      reg_wrote r1 (by decide), hpc]; simp
  · rw [reg_kept r5 (by decide), reg_kept r4 (by decide), reg_wrote r3 (by decide)]
    simp only [aluR]; rw [reg_kept r2 (by decide), reg_wrote r1 (by decide), reg_wrote r2 (by decide), hpc]
    simp [SAMPLES]
  · rw [reg_wrote r5 (by decide)]
    simp only [aluR]; rw [reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide),
      reg_wrote r1 (by decide), reg_wrote r4 (by decide), hpc]
    simp [OUT]

/-! ## The verdict -/

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

/-- The tests, and the branch on their verdict. Unhealthy, it is HALT 1 four
instructions on, with memory untouched; healthy, the copy starts. -/
theorem verdict_run {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * 5)) (hcode : CodeAt s.mem base kernel)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 SAMPLES) :
    (¬ Healthy s.mem base → ∃ s', run env (7 + 17 * N + 3 + 4) s = .halted 1 s' ∧ s'.mem = s.mem) ∧
    (Healthy s.mem base → ∃ s', run env (7 + 17 * N + 3 + 1) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 33)
      ∧ s'.mem = s.mem ∧ s'.reg S0 = s.reg S0 ∧ s'.reg S2 = s.reg S2) := by
  obtain ⟨sV, eV, pV, mV, gV, kV⟩ :=
    Health.front_run hp at_front (by decide) (by decide) s hpc hcode h1
  have hcV : CodeAt sV.mem base kernel := by rw [mV]; exact hcode
  have tk : taken .bne (sV.reg S6) (sV.reg 0) = decide (¬ Healthy s.mem base) := by
    rw [gV, reg_zero]
    by_cases hh : Health.Healthy s.mem base SAMPLES <;> simp [hh, taken, Healthy]
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · have tt : taken .bne (sV.reg S6) (sV.reg 0) = true := by rw [tk]; simp [hn]
    have e2 : run env 1 sV = .running (sV.setPc (sV.pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK hp 32 (by decide) hcV pV (i := .br .bne S6 0 0x01a) (by decide) (exec_br_taken tt) 0).trans
        (run_zero _ _)
    have p2 : (sV.setPc (sV.pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)).pc
        = base + BitVec.ofNat 32 (4 * 45) := by rw [setPc_pc, pV, to_45]
    have hc2 : CodeAt (sV.setPc (sV.pc + ((0x01a : BitVec 12) ++ 0#1).signExtend 32)).mem base kernel := by
      rw [setPc_mem]; exact hcV
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 45 (by decide) hc2 p2
      (i := .opi .addi A0 0 1) (by decide) rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 46 (by decide) (by rw [m3]; exact hc2) p3
      (i := .opi .addi T0 0 1) (by decide) rfl
    have t0 : s4.reg T0 = 1 := by rw [reg_wrote r4 (by decide)]; simp only [aluI, reg_zero]; decide
    have a0 : s4.reg A0 = 1 := by
      rw [reg_kept r4 (by decide), reg_wrote r3 (by decide)]; simp only [aluI, reg_zero]; decide
    have e5 := halts_at hp (s := s4) 47 (by decide) (by rw [m4, m3]; exact hc2) p4 (by decide) t0
    rw [a0] at e5
    refine ⟨s4, ?_, by rw [m4, m3, setPc_mem, mV]⟩
    rw [show 7 + 17 * N + 3 + 4 = (7 + 17 * N + 3) + (1 + (1 + (1 + 1))) by rfl, run_add_running eV,
      run_add_running e2, run_add_running e3, run_add_running e4, e5]
  · have tf : taken .bne (sV.reg S6) (sV.reg 0) = false := by rw [tk]; simp [hy]
    refine ⟨sV.next, ?_, by rw [next_pc, pV]; exact pc_next hp.fit 32 (by decide),
      by rw [next_mem, mV], by rw [next_reg, kV _ (by decide)], by rw [next_reg, kV _ (by decide)]⟩
    rw [run_add_running eV]
    exact (stepK hp 32 (by decide) hcV pV (i := .br .bne S6 0 0x01a) (by decide) (exec_br_not tf) 0).trans
      (run_zero _ _)

/-! ## The copy, when healthy -/

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
  obtain ⟨s5, e5, p5, m5, h0, h1, h2⟩ := setup_run hp s hpc hcode
  have hc5 : CodeAt s5.mem base kernel := by rw [m5]; exact hcode
  obtain ⟨vn, vy⟩ := verdict_run hp s5 p5 hc5 h1
  rw [m5] at vn vy
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · obtain ⟨s', e', m'⟩ := vn hn
    exact ⟨s', by rw [show 17427 = 5 + (7 + 17 * N + 3 + 4) by decide, run_add_running e5, e'], m'⟩
  · obtain ⟨sv, ev, pv, mv, g0, g2⟩ := vy hy
    obtain ⟨s', e', m'⟩ := copy_run hp hcode pv mv (by rw [g0, h0]) (by rw [g2, h2])
    exact ⟨s', by rw [show 23574 = 5 + ((7 + 17 * N + 3 + 1) + 6150) by decide, run_add_running e5,
      run_add_running ev, e'], m'⟩

/-- **The output is the samples**, word for word, when they pass. -/
theorem output {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m0 : Word → Byte) {j : Nat} (hj : j < N) :
    readLE (copied m0 base SAMPLES OUT N) (base + BitVec.ofNat 32 (OUT + 4 * j)) 4 = Health.sample m0 base SAMPLES j :=
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

#print axioms setup_run
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
