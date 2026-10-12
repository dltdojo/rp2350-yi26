/-
SPDX-License-Identifier: Apache-2.0

# exp232 — the cure the proof predicts

A ring of 32 cells, each empty, tissue or tumour: two words, the tumour `t`
and the tissue `h`. Each generation a dose may come, by the schedule's low
bit, and kill every cell at the edge of its own kind — chemotherapy kills the
cells that divide. Then the tumour invades the cell above each of its cells,
whatever is there, and the tissue fills the gaps beside it.

The kernel reads the tumour, the tissue and the schedule at base + 0x100,
0x104 and 0x108, writes 64 generations, tumour then tissue, from base +
0x200, and halts with 0. What is proved:

- M1, `models` and `from_boot`: after exactly 3081 instructions it halts with
  0, the 512 bytes from 0x200 generations 1 to 64 of `next`, nothing else
  changed — for every input;
- M2, the mechanism: a cell between two of its own kind survives a dose
  (`inside_survives`, `tissue_survives`), a healthy body loses nothing to one
  (`healthy_untouched`), and tissue beside a tumour does (`off_target`);
- M3, `untreated_fills`: untreated, any tumour fills the ring by generation 31;
- M4, `answer_cures`: the schedule the chip's search answers with meets the
  trial's endpoint for every enrolled patient, wherever the lump sits, and
  the tumour is gone from generation 24 on — in the model;
- M5, `loophole_relapses`: another schedule the search accepted meets the
  same endpoint, and a lump of six is still there, two cells no scan sees,
  and fills the ring by 64.

What none of it reaches: the world the trial runs in, which has something the
model does not — resistance — and whether any of this is like a body.

   0-5    the tumour, tissue and schedule into a0, a1, a2; t1 the history; t2 64
   6-48   one generation, in the registers, 43 instructions
   49-50  sw a0, sw a1
   51-53  t1 += 8, t2 -= 1, bne t2, x0, 6
   54-56  HALT 0
-/
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Ring
import Rv32.Tissue

namespace Exp232
open Rv32 Tissue

def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def T5 : Reg := 30
def T6 : Reg := 31
def A3 : Reg := 13

def setup : List Instr := [ .auipc T1 0, .ld .lw A0 T1 0x100, .ld .lw A1 T1 0x104, .ld .lw A2 T1 0x108,
  .opi .addi T1 T1 0x200, .opi .addi T2 0 64 ]

def body : List Instr := [
  .opi .andi T3 A2 1, .op .sub T3 0 T3, .sh .srli A2 A2 1,
  .opi .xori T4 A0 0xfff, .sh .slli T5 T4 1, .sh .srli T6 T4 31, .op .or T5 T5 T6,
  .sh .srli T6 T4 1, .sh .slli T4 T4 31, .op .or T6 T6 T4, .op .or T5 T5 T6, .op .and T5 T5 A0,
  .opi .xori T4 A1 0xfff, .sh .slli T6 T4 1, .sh .srli A3 T4 31, .op .or T6 T6 A3,
  .sh .srli A3 T4 1, .sh .slli T4 T4 31, .op .or A3 A3 T4, .op .or T6 T6 A3, .op .and T6 T6 A1,
  .op .or T5 T5 T6, .op .and T5 T5 T3, .opi .xori T5 T5 0xfff, .op .and A0 A0 T5, .op .and A1 A1 T5,
  .op .or T3 A0 A1, .opi .xori T3 T3 0xfff,
  .sh .slli T4 A0 1, .sh .srli T5 A0 31, .op .or T4 T4 T5, .op .or A0 A0 T4,
  .sh .slli T4 A1 1, .sh .srli T5 A1 31, .op .or T4 T4 T5,
  .sh .srli T5 A1 1, .sh .slli T6 A1 31, .op .or T5 T5 T6, .op .or T4 T4 T5,
  .op .and T4 T4 T3, .op .or A1 A1 T4, .opi .xori T4 A0 0xfff, .op .and A1 A1 T4 ]

theorem body_length : body.length = 43 := by decide

theorem xor_ones (x : Word) : x ^^^ 4294967295#32 = ~~~x := by
  rw [show (4294967295#32 : Word) = BitVec.allOnes 32 by decide, BitVec.xor_allOnes]

theorem body_t (st : Machine) :
    (st.line body).reg A0 = (next ⟨st.reg A0, st.reg A1, st.reg A2⟩).t := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, next, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, A3, xor_ones]

theorem body_h (st : Machine) :
    (st.line body).reg A1 = (next ⟨st.reg A0, st.reg A1, st.reg A2⟩).h := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, next, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, A3, xor_ones]

theorem body_s (st : Machine) :
    (st.line body).reg A2 = (next ⟨st.reg A0, st.reg A1, st.reg A2⟩).s := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, next, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, A3, xor_ones]


theorem body_keeps1 (st : Machine) : (st.line body).reg T1 = st.reg T1 := by
  simp [body, Machine.line, Machine.alu, reg_setReg, A0, A1, A2, T1, T3, T4, T5, T6, A3]

theorem body_keeps2 (st : Machine) : (st.line body).reg T2 = st.reg T2 := by
  simp [body, Machine.line, Machine.alu, reg_setReg, A0, A1, A2, T2, T3, T4, T5, T6, A3]

def stepLine : List Instr := [ .opi .addi T1 T1 8, .opi .addi T2 T2 0xfff ]

def finishLine : List Instr := [ .opi .addi T0 0 1, .opi .addi A0 0 0 ]

def kernel : List Instr :=
  setup ++ body ++ [ .st .sw T1 A0 0, .st .sw T1 A1 4 ] ++ stepLine ++ [ .br .bne T2 0 0xfa2 ] ++ finishLine ++ [ .ecall ]

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 57 := by decide

/-! ## The specification over the history -/

def INIT : Nat := 0x100
def HIST : Nat := 0x200
def N : Nat := 64


def wordAt (m : Word → Byte) (base : Word) (off : Nat) : Word :=
  BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 off) 4)

/-- What the kernel starts from: the tumour at 0x100, the tissue at 0x104,
the schedule at 0x108. -/
def initOf (m : Word → Byte) (base : Word) : Body :=
  ⟨wordAt m base INIT, wordAt m base (INIT + 4), wordAt m base (INIT + 8)⟩

/-- Byte `d` of the history: generation `d / 8 + 1`, its tumour in the first
four bytes, its tissue in the next four, little-endian. -/
def hist (b : Body) (d : Nat) : Byte :=
  let g := gen b (d / 8 + 1)
  BitVec.ofNat 8 ((if d % 8 < 4 then g.t else g.h).toNat / 256 ^ (d % 4))

/-- Memory after `i` generations: the first `8 i` bytes from 0x200 are the
history, everything else as it was. -/
def lived (m0 : Word → Byte) (base : Word) (i : Nat) : Word → Byte :=
  overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (2 * i)) (hist (initOf m0 base))

/-! ## The loop -/

structure Inv (m0 : Word → Byte) (base : Word) (i : Nat) (st : Machine) : Prop where
  pc : st.pc = base + BitVec.ofNat 32 (4 * (if i < N then 6 else 54))
  t : st.reg A0 = (gen (initOf m0 base) i).t
  h : st.reg A1 = (gen (initOf m0 base) i).h
  s : st.reg A2 = (gen (initOf m0 base) i).s
  p : st.reg T1 = base + BitVec.ofNat 32 (HIST + 8 * i)
  n : st.reg T2 = BitVec.ofNat 32 (N - i)
  mem : st.mem = lived m0 base i

variable {env : Env} {base : Word}

theorem seg_body : (kernel.drop 6).take body.length = body := by decide
theorem seg_step : (kernel.drop 51).take stepLine.length = stepLine := by decide
theorem seg_finish : (kernel.drop 54).take finishLine.length = finishLine := by decide

theorem lived_code (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte} (hc : CodeAt m0 base kernel)
    {i : Nat} (hi : i ≤ N) : CodeAt (lived m0 base i) base kernel :=
  code_of_overlay hfit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _

theorem back (base : Word) :
    base + BitVec.ofNat 32 (4 * 53) + ((0xfa2 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 6) := by
  rw [BitVec.add_assoc]; congr 1

theorem store_mem (hfit : base.toNat + 0x10000 ≤ 2^32) (m0 : Word → Byte) (f : Nat → Byte) (j v : Nat)
    (hj : HIST + 4 * j + 4 ≤ 0x10000)
    (hv : ∀ d < 4, BitVec.ofNat 8 (v / 256 ^ d) = f (4 * j + d)) :
    writeLE (overlay m0 (base + BitVec.ofNat 32 HIST) (4 * j) f) (base + BitVec.ofNat 32 (HIST + 4 * j)) v 4
      = overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (j + 1)) f := by
  funext y
  rw [show base + BitVec.ofNat 32 (HIST + 4 * j) = base + BitVec.ofNat 32 HIST + BitVec.ofNat 32 (4 * j) by
    rw [BitVec.add_assoc, BitVec.ofNat_add]]
  apply overlay_step
  · rw [toNat_off hfit _ (by simp only [HIST]; omega)]; simp only [HIST] at hj ⊢; omega
  · exact hv

/-- **One generation**: from the top of generation `i`, 48 instructions on,
the top of generation `i + 1` — or, after the last, the finish. -/
theorem iter (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {i : Nat} (hi : i < N)
    {st : Machine} (h : Inv m0 base i st) : ∃ st', run env 48 st = .running st' ∧ Inv m0 base (i + 1) st' := by
  have fit := hp.fit
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 6) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code fit hc (by omega)
  have e1 := run_line (prog := kernel) hp body (by decide) 6 st seg_body (by decide) hcode hpc (by decide)
  have p1 : (st.line body).pc = base + BitVec.ofNat 32 (4 * 49) := line_pc_at body hpc (by decide)
  have g1 : next (gen (initOf m0 base) i) = gen (initOf m0 base) (i + 1) := rfl
  have x1 : (st.line body).reg A0 = (gen (initOf m0 base) (i + 1)).t := by rw [body_t, h.t, h.h, h.s, ← g1]
  have y1 : (st.line body).reg A1 = (gen (initOf m0 base) (i + 1)).h := by rw [body_h, h.t, h.h, h.s, ← g1]
  have z1 : (st.line body).reg A2 = (gen (initOf m0 base) (i + 1)).s := by rw [body_s, h.t, h.h, h.s, ← g1]
  have t1 : (st.line body).reg T1 = st.reg T1 := body_keeps1 st
  have t2 : (st.line body).reg T2 = st.reg T2 := body_keeps2 st
  -- the tumour, stored
  obtain ⟨s2, e2, p2, m2, r2⟩ := storeStep (prog := kernel) hp 49 (by decide) (s := st.line body)
    (by rw [line_mem]; exact hcode) p1 (rs1 := T1) (rs2 := A0) (imm := 0) (by decide) (HIST + 4 * (2 * i))
    (by rw [t1, h.p]; simp; congr 2; omega) (by simp only [HIST, N] at hi ⊢; omega) (by simp only [HIST]; omega)
  have mem2 : s2.mem = overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (2 * i + 1)) (hist (initOf m0 base)) := by
    rw [m2, line_mem, h.mem]
    apply store_mem fit m0 _ (2 * i) _ (by simp only [HIST, N] at hi ⊢; omega)
    intro d hd
    rw [x1]; simp only [hist]
    rw [show (4 * (2 * i) + d) / 8 = i by omega, show (4 * (2 * i) + d) % 8 = d by omega,
      show (4 * (2 * i) + d) % 4 = d by omega]
    simp [hd]
  have hc2 : CodeAt s2.mem base kernel := by
    rw [mem2]; exact code_of_overlay fit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _
  -- the tissue, stored
  obtain ⟨s3, e3, p3, m3, r3⟩ := storeStep (prog := kernel) hp 50 (by decide) (s := s2)
    hc2 p2 (rs1 := T1) (rs2 := A1) (imm := 4) (by decide) (HIST + 4 * (2 * i + 1))
    (by rw [r2, t1, h.p, show BitVec.signExtend 32 (4 : BitVec 12) = BitVec.ofNat 32 4 by decide,
      off_add fit _ _ (by simp only [HIST, N] at hi ⊢; omega),
      show HIST + 8 * i + 4 = HIST + 4 * (2 * i + 1) by omega])
    (by simp only [HIST, N] at hi ⊢; omega) (by simp only [HIST]; omega)
  have mem3 : s3.mem = lived m0 base (i + 1) := by
    rw [m3, mem2]
    unfold lived
    rw [show 4 * (2 * (i + 1)) = 4 * (2 * i + 1 + 1) by omega]
    apply store_mem fit m0 _ (2 * i + 1) _ (by simp only [HIST, N] at hi ⊢; omega)
    intro d hd
    rw [r2, y1]; simp only [hist]
    rw [show (4 * (2 * i + 1) + d) / 8 = i by omega, show (4 * (2 * i + 1) + d) % 8 = 4 + d by omega,
      show (4 * (2 * i + 1) + d) % 4 = d by omega]
    simp [show ¬ (4 + d < 4) by omega]
  have hc3 : CodeAt s3.mem base kernel := by rw [mem3]; exact lived_code fit hc (by omega)
  -- on to the next generation, one fewer to go
  have e4 := run_line (prog := kernel) hp stepLine (by decide) 51 s3 seg_step (by decide) hc3
    (by rw [p3]) (by decide)
  have p4 : (s3.line stepLine).pc = base + BitVec.ofNat 32 (4 * 53) := line_pc_at stepLine (by rw [p3]) (by decide)
  have g1 : (s3.line stepLine).reg T1 = s3.reg T1 + (8 : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2]
  have g2 : (s3.line stepLine).reg T2 = s3.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2]
  have k0 : ∀ r, r ≠ T1 → r ≠ T2 → (s3.line stepLine).reg r = s3.reg r := by
    intro r a b
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, a, b]
  have c1 : (s3.line stepLine).reg T1 = base + BitVec.ofNat 32 (HIST + 8 * (i + 1)) := by
    rw [g1, r3, r2, t1, h.p, show BitVec.signExtend 32 (8 : BitVec 12) = BitVec.ofNat 32 8 by decide,
      off_add fit _ _ (by simp only [HIST, N] at hi ⊢; omega)]
    congr 2
  have c2 : (s3.line stepLine).reg T2 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g2, r3, r2, t2, h.n, show N - i = N - (i + 1) + 1 by simp only [N] at hi ⊢; omega]
    exact dec_one _ (by simp only [N]; omega)
  have ca : (s3.line stepLine).reg A0 = (gen (initOf m0 base) (i + 1)).t := by
    rw [k0 A0 (by decide) (by decide), r3, r2, x1]
  have cb : (s3.line stepLine).reg A1 = (gen (initOf m0 base) (i + 1)).h := by
    rw [k0 A1 (by decide) (by decide), r3, r2, y1]
  have cs : (s3.line stepLine).reg A2 = (gen (initOf m0 base) (i + 1)).s := by
    rw [k0 A2 (by decide) (by decide), r3, r2, z1]
  have hcl : CodeAt (s3.line stepLine).mem base kernel := by rw [line_mem]; exact hc3
  have tk : taken .bne ((s3.line stepLine).reg T2) ((s3.line stepLine).reg 0) = decide (i + 1 < N) := by
    rw [c2, reg_zero]
    simp only [taken, N] at hi ⊢
    by_cases hl : i + 1 < 64
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e; simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      apply BitVec.eq_of_toNat_eq; simp; omega
  have run4 : ∀ st', run env 1 (s3.line stepLine) = .running st' → run env 48 st = .running st' := by
    intro st' e
    rw [show 48 = body.length + (1 + (1 + (stepLine.length + 1))) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3, run_add_running e4, e]
  by_cases hl : i + 1 < N
  · refine ⟨(s3.line stepLine).setPc ((s3.line stepLine).pc + ((0xfa2 : BitVec 12) ++ 0#1).signExtend 32),
      run4 _ ((stepK hp 53 (by decide) hcl p4 (i := .br .bne T2 0 0xfa2) (by decide)
        (exec_br_taken (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [setPc_pc, p4, back]; simp [hl]
    · rw [setPc_reg, ca]
    · rw [setPc_reg, cb]
    · rw [setPc_reg, cs]
    · rw [setPc_reg, c1]
    · rw [setPc_reg, c2]
    · rw [setPc_mem, line_mem, mem3]
  · refine ⟨(s3.line stepLine).next,
      run4 _ ((stepK hp 53 (by decide) hcl p4 (i := .br .bne T2 0 0xfa2) (by decide)
        (exec_br_not (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [next_pc, p4, pc_next fit 53 (by decide)]; simp [hl]
    · rw [next_reg, ca]
    · rw [next_reg, cb]
    · rw [next_reg, cs]
    · rw [next_reg, c1]
    · rw [next_reg, c2]
    · rw [next_mem, line_mem, mem3]

/-- All 64 generations, by induction. -/
theorem loop (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base 0 st) : ∀ j ≤ N, ∃ st', run env (48 * j) st = .running st' ∧ Inv m0 base j st' := by
  intro j hj
  induction j with
  | zero => exact ⟨st, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := iter hp hc (by omega) hs'
    exact ⟨s'', by rw [show 48 * (j + 1) = 48 * j + 48 by omega, run_add_running e, e'], hs''⟩

theorem setup_run (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 6 st = .running st' ∧ Inv st.mem base 0 st' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc T1 0) (by decide) rfl
  have b1 : s1.reg T1 = base := by rw [reg_wrote r1 (by decide), hpc]; simp
  obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (rd := A0) (rs1 := T1) (imm := 0x100) (by decide) INIT
      (by rw [b1, show BitVec.signExtend 32 (0x100 : BitVec 12) = BitVec.ofNat 32 INIT by decide])
      (by decide) (by decide)
  obtain ⟨s3, e3, p3, m3, r3⟩ := loadStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (rd := A1) (rs1 := T1) (imm := 0x104) (by decide) (INIT + 4)
      (by rw [reg_kept r2 (by decide), b1, show BitVec.signExtend 32 (0x104 : BitVec 12) = BitVec.ofNat 32 (INIT + 4) by decide])
      (by decide) (by decide)
  obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (rd := A2) (rs1 := T1) (imm := 0x108) (by decide) (INIT + 8)
      (by rw [reg_kept r3 (by decide), reg_kept r2 (by decide), b1,
        show BitVec.signExtend 32 (0x108 : BitVec 12) = BitVec.ofNat 32 (INIT + 8) by decide])
      (by decide) (by decide)
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) (by rw [m4, m3, m2, m1]; exact hcode) p4
      (i := .opi .addi T1 T1 0x200) (by decide) rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) (by rw [m5, m4, m3, m2, m1]; exact hcode) p5
      (i := .opi .addi T2 0 64) (by decide) rfl
  refine ⟨s6, ?_, ⟨by rw [p6]; rfl, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 6 = 1 + (1 + (1 + (1 + (1 + 1)))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 e6))))
  · rw [reg_kept r6 (by decide), reg_kept r5 (by decide), reg_kept r4 (by decide), reg_kept r3 (by decide),
      reg_wrote r2 (by decide), m1]; rfl
  · rw [reg_kept r6 (by decide), reg_kept r5 (by decide), reg_kept r4 (by decide), reg_wrote r3 (by decide),
      m2, m1]; rfl
  · rw [reg_kept r6 (by decide), reg_kept r5 (by decide), reg_wrote r4 (by decide), m3, m2, m1]; rfl
  · rw [reg_kept r6 (by decide), reg_wrote r5 (by decide)]
    simp only [aluI]
    rw [reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide), b1,
      show BitVec.signExtend 32 (0x200 : BitVec 12) = BitVec.ofNat 32 (HIST + 8 * 0) by decide]
  · rw [reg_wrote r6 (by decide)]; simp [aluI, N]
  · rw [m6, m5, m4, m3, m2, m1]; simp [lived, overlay_zero]

/-- HALT, at the `ecall`, with `t0 = 1`. -/
theorem halts_at (hp : Placed env base) {st : Machine} (hcode : CodeAt st.mem base kernel)
    (hpc : st.pc = base + BitVec.ofNat 32 (4 * 56)) (ht0 : st.reg T0 = 1) :
    run env 1 st = .halted (st.reg A0) st := by
  have hk' : 56 < kernel.length := by rw [kernel_length]; decide
  have hi : kernel.getD 56 .ecall = .ecall := by decide
  have : kernel[56] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk']
  exact run_code_halt 0 hk' hcode hpc (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (by rw [this]; exact exec_halt ht0)

theorem finish_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base N st) :
    ∃ s1 st', run env 2 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived m0 base N := by
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 54) := by rw [h.pc]; rfl
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code hp.fit hc (by decide)
  have e1 := run_line (prog := kernel) hp finishLine (by decide) 54 st seg_finish (by decide) hcode hpc (by decide)
  have p1 : (st.line finishLine).pc = base + BitVec.ofNat 32 (4 * 56) := line_pc_at finishLine hpc (by decide)
  have t1 : (st.line finishLine).reg T0 = 1 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have a1 : (st.line finishLine).reg A0 = 0 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have e2 := halts_at hp (st := st.line finishLine) (by rw [line_mem]; exact hcode) p1 t1
  rw [a1] at e2
  exact ⟨_, _, e1, e2, by rw [line_mem, h.mem]⟩

/-- Setup, 64 generations and the two instructions before the `ecall`: 3080. -/
theorem to_the_ecall (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1 st', run env 3080 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s0, e0, i0⟩ := setup_run hp st hpc hcode
  obtain ⟨sN, eN, iN⟩ := loop hp hcode i0 N (Nat.le_refl _)
  obtain ⟨s1, st', e2, e1, m⟩ := finish_run hp hcode iN
  exact ⟨s1, st', by rw [show 3080 = 6 + (48 * N + 2) by rfl, run_add_running e0, run_add_running eN, e2], e1, m⟩

/-- **M1, the kernel is the model.** From `base`, with the kernel's bytes
there, it halts with 0 after exactly 3081 instructions; the 512 bytes from
0x200 are then generations 1 to 64 of `next` — tumour, tissue — from the
tumour, tissue and schedule at 0x100, and every other byte is what it was.
For every `base` the region fits at, every value of every byte, every
register. -/
theorem models (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 3081 st = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s1, st', e, e1, m⟩ := to_the_ecall hp st hpc hcode
  exact ⟨st', by rw [show 3081 = 3080 + 1 by rfl, run_add_running e, e1], m⟩

/-- **And not before**: after 3080 it is still running, whatever it was given. -/
theorem not_before (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1, run env 3080 st = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp st hpc hcode
  exact ⟨s1, e⟩

/-! ## The bytes are the kernel -/

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- **From the state the shell builds**: any image that begins with the
kernel's 228 bytes, the tumour, tissue and schedule at 0x100. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 228 ≤ img.size)
    (himg : ∀ d (h : d < 228), img.get d (by omega) = bytes.getD d 0) :
    let m0 := memOfImage base img
    (∃ s1, run env 3080 (boot env.region img) = .running s1) ∧
    ∃ st', run env 3081 (boot env.region img) = .halted 0 st' ∧ st'.mem = lived m0 base N := by
  intro m0
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = m0 := by simp [boot, hp.region, m0]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]
    exact code_of_image hp.fit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
      (fun d h => himg d (by rw [kernel_length] at h; exact h))
  refine ⟨not_before hp _ hpc hcode, ?_⟩
  obtain ⟨st', e, m⟩ := models hp _ hpc hcode
  rw [hmem] at m
  exact ⟨st', e, m⟩

/-! ## M2: the mechanism — a dose reaches only the edges -/

/-- Tumour and tissue never share a cell after a generation, whatever came in. -/
theorem apart (b : Body) : (next b).t &&& (next b).h = 0 := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [next, BitVec.getLsbD_and, BitVec.getLsbD_not, hi, decide_true, Bool.true_and]
  cases ((b.t &&& ~~~(edge b.t b.h &&& dose b.s)) ||| up1 (b.t &&& ~~~(edge b.t b.h &&& dose b.s))).getLsbD i <;> simp

/-- **M2a.** A tumour cell between two tumour cells is never killed by a
dose: the drug reaches a lump only at its edges. -/
theorem inside_survives (t h : Word) (i : Nat) (hi : i < 32) (ht : t.getLsbD i = true)
    (hh : h.getLsbD i = false) (hu : t.getLsbD ((i + 31) % 32) = true) (hd : t.getLsbD ((i + 1) % 32) = true) :
    (edge t h).getLsbD i = false := by
  unfold edge spread
  simp only [BitVec.getLsbD_or, BitVec.getLsbD_and, up1_bit _ i hi, dn1_bit _ i hi, BitVec.getLsbD_not,
    show (i + 31) % 32 < 32 by omega, show (i + 1) % 32 < 32 by omega, decide_true, Bool.true_and, ht, hh, hu, hd]
  simp

/-- And a tissue cell between two tissue cells. -/
theorem tissue_survives (t h : Word) (i : Nat) (hi : i < 32) (ht : t.getLsbD i = false)
    (hh : h.getLsbD i = true) (hu : h.getLsbD ((i + 31) % 32) = true) (hd : h.getLsbD ((i + 1) % 32) = true) :
    (edge t h).getLsbD i = false := by
  unfold edge spread
  simp only [BitVec.getLsbD_or, BitVec.getLsbD_and, up1_bit _ i hi, dn1_bit _ i hi, BitVec.getLsbD_not,
    show (i + 31) % 32 < 32 by omega, show (i + 1) % 32 < 32 by omega, decide_true, Bool.true_and, ht, hh, hu, hd]
  simp

/-- **M2c.** But a dose is not aimed at the tumour: tissue beside a tumour
cell is at the edge of its kind too, and dies with it. -/
theorem off_target : edge 1 (~~~1) &&& ~~~1 ≠ 0 := by decide

/-- **M2b.** A body with no tumour and no gap loses nothing to a dose. -/
theorem healthy_untouched (s : Word) : next ⟨0, BitVec.allOnes 32, s⟩ = ⟨0, BitVec.allOnes 32, s >>> 1⟩ := by
  simp [next, edge, spread, up1, dn1]

/-! ## M3: untreated, any tumour fills the ring -/

theorem and_ones (x : Word) : x &&& 4294967295#32 = x := by
  rw [show (4294967295#32 : Word) = BitVec.allOnes 32 by decide, BitVec.and_allOnes]

theorem next_untreated (b : Body) (hs : b.s = 0) : (next b).t = b.t ||| up1 b.t ∧ (next b).s = 0 := by
  simp [next, dose, hs, and_ones]

/-- Untreated, generation `n` holds every cell up to `n` above a tumour cell. -/
theorem spreads (b : Body) (hs : b.s = 0) (j : Nat) (hj : j < 32) (ht : b.t.getLsbD j = true) :
    ∀ n, (gen b n).s = 0 ∧ ∀ k ≤ n, (gen b n).t.getLsbD ((j + k) % 32) = true := by
  intro n
  induction n with
  | zero => exact ⟨hs, fun k hk => by rw [show k = 0 by omega, Nat.add_zero, Nat.mod_eq_of_lt hj]; exact ht⟩
  | succ n ih =>
    obtain ⟨h0, h1⟩ := ih
    obtain ⟨e, s1⟩ := next_untreated (gen b n) h0
    refine ⟨s1, fun k hk => ?_⟩
    show (next (gen b n)).t.getLsbD _ = true
    rw [e, BitVec.getLsbD_or]
    rcases (by omega : k ≤ n ∨ k = n + 1) with hk | hk
    · rw [h1 k hk]; simp
    · rw [up1_bit _ _ (by omega), show ((j + k) % 32 + 31) % 32 = (j + n) % 32 by omega, h1 n (Nat.le_refl _)]
      simp

/-- **M3.** Untreated, any tumour at all fills the whole ring by generation
31 — whatever the tissue. -/
theorem untreated_fills (t h : Word) (ht : t ≠ 0) : (gen ⟨t, h, 0⟩ 31).t = BitVec.allOnes 32 := by
  obtain ⟨j, hj, hb⟩ : ∃ j, j < 32 ∧ t.getLsbD j = true := by
    apply Classical.byContradiction; intro hn
    apply ht; apply BitVec.eq_of_getLsbD_eq; intro i hi
    cases e : t.getLsbD i
    · simp
    · exact absurd ⟨i, hi, e⟩ hn
  have := (spreads ⟨t, h, 0⟩ rfl j hj hb 31).2
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  have e := this ((i + 32 - j) % 32) (by omega)
  rw [show (j + (i + 32 - j) % 32) % 32 = i by omega] at e
  rw [e, BitVec.getLsbD_allOnes]; simp [hi]



/-! ## M4: what Lean predicts for the search's answer -/

/-- The schedule the chip's search answers with: of 1024 it tried, the one
meeting the endpoint for every enrolled width with fewest doses — nine. -/
def ANSWER : Word := 0x51af

set_option maxRecDepth 100000 in
theorem answer_zero : ∀ w < 6, met (patient (w + 1) 0 ANSWER) ∧ (gen (patient (w + 1) 0 ANSWER) 24).t = 0 := by
  decide

/-- **M4.** In the model, the answer meets the endpoint for every enrolled
patient — every lump of 1 to 6 cells, wherever it sits on the ring — and the
tumour is not merely unseen at generation 24 but gone, for good. -/
theorem answer_cures (w p : Nat) (hw : 1 ≤ w ∧ w ≤ 6) :
    met (patient w p ANSWER) ∧ ∀ n ≥ 24, (gen (patient w p ANSWER) n).t = 0 := by
  obtain ⟨m, g⟩ := answer_zero (w - 1) (by omega)
  rw [show w - 1 + 1 = w by omega] at m g
  refine ⟨(met_iter w p ANSWER).2 m, fun n hn => (gone_iter w p n ANSWER).2 ?_⟩
  obtain ⟨k, rfl⟩ : ∃ k, n = 24 + k := ⟨n - 24, by omega⟩
  induction k with
  | zero => exact g
  | succ k ih =>
    show (next (gen _ (24 + k))).t = 0
    rw [show (next (gen (patient w 0 ANSWER) (24 + k))).t = _ from rfl]
    simp only [next, ih (by omega)]
    simp [up1]

/-! ## M5: what the endpoint lets through -/

/-- Another schedule the search accepted: the first of the 34 whose
tumours, in the model, come back. -/
def LOOPHOLE : Word := 0xf917d1

set_option maxRecDepth 100000 in
theorem loophole_zero : (∀ w < 6, met (patient (w + 1) 0 LOOPHOLE)) ∧
    pc (gen (patient 6 0 LOOPHOLE) 24).t 32 = 2 ∧ (gen (patient 6 0 LOOPHOLE) 64).t = BitVec.allOnes 32 := by
  decide

/-- **M5.** The loophole meets the stated endpoint for every enrolled
patient, wherever the lump sits — and yet a lump of six cells is still there
at generation 24, two cells a scan cannot see, and fills the ring by 64. Lean
proves both halves as readily as it proved M4: it proves what it is asked. -/
theorem loophole_relapses (w p : Nat) (hw : 1 ≤ w ∧ w ≤ 6) :
    met (patient w p LOOPHOLE) ∧ (gen (patient 6 p LOOPHOLE) 24).t ≠ 0 ∧
      pc (gen (patient 6 p LOOPHOLE) 64).t 32 = 32 := by
  obtain ⟨m, two, full⟩ := loophole_zero
  have m := m (w - 1) (by omega)
  rw [show w - 1 + 1 = w by omega] at m
  refine ⟨(met_iter w p LOOPHOLE).2 m, fun z => ?_, ?_⟩
  · rw [gone_iter 6 p 24 LOOPHOLE] at z; rw [z] at two; exact absurd two (by decide)
  · rw [gen_iter 6 p LOOPHOLE 64, show (gen (patient 6 0 LOOPHOLE) 64).t = _ from full, pc_iter]; decide

#print axioms apart
#print axioms inside_survives
#print axioms healthy_untouched
#print axioms off_target
#print axioms untreated_fills
#print axioms answer_cures
#print axioms loophole_relapses
#print axioms body_t
#print axioms iter
#print axioms models
#print axioms not_before
#print axioms bytes_words
#print axioms from_boot

end Exp232

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp232.image
  | _ => pure ()
  for (i, k) in Exp232.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
