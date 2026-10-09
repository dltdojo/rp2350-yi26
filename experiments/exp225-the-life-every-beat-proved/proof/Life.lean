/-
SPDX-License-Identifier: Apache-2.0

# exp225 — the life every beat proved

A one-dimensional cellular automaton, Wolfram's Rule 30, on a ring of 32
cells: one word, bit i a cell. Each generation, every cell becomes

  left XOR (centre OR right)

where bit i's left is bit i+1 and its right is bit i-1, round the ring. From a
single live cell its centre column looks like noise and is not: every bit of it
is fixed by the seed. On the Pico 2 that column is the LED.

The kernel reads the seed at base + 0x100, writes 256 generations, a word
each, from base + 0x200, and halts with 0. It is proved to do exactly that:

- `lives`: after exactly 3079 instructions it halts with 0, and memory is what
  it was but for the 1024 bytes from 0x200, which hold generations 1 to 256 of
  `life` from the seed;
- `not_before`: after 3078 it is still running;
- `rule30`: `life` is Rule 30, cell by cell;
- `from_boot`: all of it, from the state the shell builds.

   0      auipc t1, 0
   1      lw    t0, 0x100(t1)        the seed
   2      addi  t1, t1, 0x200        where generation 1 goes
   3      addi  t2, x0, 256          generations to go
   4-11   t0 = life t0               eight register instructions
   12     sw    t0, 0(t1)
   13-14  t1 += 4, t2 -= 1
   15     bne   t2, x0, 4
   16-18  HALT 0
-/
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm

namespace Exp225
open Rv32

def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def T5 : Reg := 30

def setup : List Instr := [ .auipc T1 0, .ld .lw T0 T1 0x100, .opi .addi T1 T1 0x200, .opi .addi T2 0 256 ]

/-- One generation, in the register: left, then centre OR right, then XOR. -/
def body : List Instr := [
  .sh .srli T3 T0 1, .sh .slli T4 T0 31, .op .or T3 T3 T4,
  .sh .slli T4 T0 1, .sh .srli T5 T0 31, .op .or T4 T4 T5,
  .op .or T4 T4 T0, .op .xor T0 T3 T4 ]

def stepLine : List Instr := [ .opi .addi T1 T1 4, .opi .addi T2 T2 0xfff ]

def finishLine : List Instr := [ .opi .addi T0 0 1, .opi .addi A0 0 0 ]

def kernel : List Instr :=
  setup ++ body ++ [ .st .sw T1 T0 0 ] ++ stepLine ++ [ .br .bne T2 0 0xfea ] ++ finishLine ++ [ .ecall ]

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 19 := by decide

/-! ## The specification -/

def SEED : Nat := 0x100
def HIST : Nat := 0x200
def N : Nat := 256

/-- One generation of the ring. -/
def life (x : Word) : Word := (x >>> 1 ||| x <<< 31) ^^^ ((x <<< 1 ||| x >>> 31) ||| x)

/-- Generation `n` from `x`. -/
def gen (x : Word) : Nat → Word
  | 0 => x
  | n + 1 => life (gen x n)

/-- The seed: the word at base + 0x100. -/
def seedOf (m : Word → Byte) (base : Word) : Word := BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 SEED) 4)

/-- Byte `d` of the history: generation `d / 4 + 1`, little-endian. -/
def hist (x : Word) (d : Nat) : Byte := BitVec.ofNat 8 ((gen x (d / 4 + 1)).toNat / 256 ^ (d % 4))

/-- Memory after `i` generations: the first `4 i` bytes from 0x200 are the
history, everything else as it was. -/
def lived (m0 : Word → Byte) (base : Word) (i : Nat) : Word → Byte :=
  overlay m0 (base + BitVec.ofNat 32 HIST) (4 * i) (hist (seedOf m0 base))

/-! ## `life` is Rule 30 -/

/-- **Cell by cell, Rule 30**: cell i becomes its left neighbour (i+1) XOR
(itself OR its right neighbour, i-1), round the ring of 32. -/
theorem rule30 (x : Word) (i : Nat) (hi : i < 32) :
    (life x).getLsbD i = (x.getLsbD ((i + 1) % 32) ^^ (x.getLsbD i || x.getLsbD ((i + 31) % 32))) := by
  rcases (by omega : i = 0 ∨ i = 31 ∨ (0 < i ∧ i < 31)) with h | h | ⟨h0, h1⟩
  · subst h; simp [life, Bool.or_comm]
  · subst h; simp [life, Bool.or_comm]
  · have a : (i + 1) % 32 = 1 + i := by omega
    have b : (i + 31) % 32 = i - 1 := by omega
    simp [life, a, b, h1, BitVec.getLsbD_of_ge x (31 + i) (by omega), show ¬ i < 1 by omega]
    cases x.getLsbD i <;> cases x.getLsbD (i - 1) <;> simp <;> omega

/-! ## The loop -/

structure Inv (m0 : Word → Byte) (base : Word) (i : Nat) (st : Machine) : Prop where
  pc : st.pc = base + BitVec.ofNat 32 (4 * (if i < N then 4 else 16))
  x : st.reg T0 = gen (seedOf m0 base) i
  p : st.reg T1 = base + BitVec.ofNat 32 (HIST + 4 * i)
  n : st.reg T2 = BitVec.ofNat 32 (N - i)
  mem : st.mem = lived m0 base i

variable {env : Env} {base : Word}

theorem seg_body : (kernel.drop 4).take body.length = body := by decide
theorem seg_step : (kernel.drop 13).take stepLine.length = stepLine := by decide
theorem seg_finish : (kernel.drop 16).take finishLine.length = finishLine := by decide

theorem body_x (st : Machine) : (st.line body).reg T0 = life (st.reg T0) := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, life, T0, T3, T4, T5]

theorem body_keeps (st : Machine) (r : Reg) (h1 : r ≠ T0) (h3 : r ≠ T3) (h4 : r ≠ T4) (h5 : r ≠ T5) :
    (st.line body).reg r = st.reg r :=
  line_keeps st body r (by
    intro i hi; simp only [body, List.mem_cons, List.mem_nil_iff, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp only [rdOf, ne_eq, Option.some.injEq] <;>
      first | exact fun e => h1 e.symm | exact fun e => h3 e.symm | exact fun e => h4 e.symm | exact fun e => h5 e.symm)

theorem lived_code (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte} (hc : CodeAt m0 base kernel)
    {i : Nat} (hi : i ≤ N) : CodeAt (lived m0 base i) base kernel :=
  code_of_overlay hfit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _

theorem back4 (base : Word) :
    base + BitVec.ofNat 32 (4 * 15) + ((0xfea : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 4) := by
  rw [BitVec.add_assoc]; congr 1

/-- **One generation**: from the top of generation `i`, twelve instructions
on, the top of generation `i + 1` — or, after the last, the halt. -/
theorem iter (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {i : Nat} (hi : i < N)
    {st : Machine} (h : Inv m0 base i st) : ∃ st', run env 12 st = .running st' ∧ Inv m0 base (i + 1) st' := by
  have fit := hp.fit
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 4) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code fit hc (by omega)
  -- the generation, in t0
  have e1 := run_line (prog := kernel) hp body (by decide) 4 st seg_body (by decide) hcode hpc (by decide)
  have p1 : (st.line body).pc = base + BitVec.ofNat 32 (4 * 12) := line_pc_at body hpc (by decide)
  have x1 : (st.line body).reg T0 = gen (seedOf m0 base) (i + 1) := by rw [body_x, h.x]; rfl
  have t1 : (st.line body).reg T1 = st.reg T1 := body_keeps st T1 (by decide) (by decide) (by decide) (by decide)
  have t2 : (st.line body).reg T2 = st.reg T2 := body_keeps st T2 (by decide) (by decide) (by decide) (by decide)
  -- stored
  obtain ⟨s2, e2, p2, m2, r2⟩ := storeStep (prog := kernel) hp 12 (by decide) (s := st.line body)
    (by rw [line_mem]; exact hcode) p1 (rs1 := T1) (rs2 := T0) (imm := 0) (by decide) (HIST + 4 * i)
    (by rw [t1, h.p]; simp) (by simp only [HIST, N] at hi ⊢; omega) (by simp only [HIST]; omega)
  have mem2 : s2.mem = lived m0 base (i + 1) := by
    rw [m2, line_mem, h.mem]
    funext y
    unfold lived
    rw [show base + BitVec.ofNat 32 (HIST + 4 * i) = base + BitVec.ofNat 32 HIST + BitVec.ofNat 32 (4 * i) by
      rw [BitVec.add_assoc, BitVec.ofNat_add]]
    apply overlay_step
    · rw [toNat_off fit _ (by simp only [HIST]; omega)]; simp only [HIST, N] at hi ⊢; omega
    · intro d hd
      rw [x1]; simp only [hist]
      rw [show (4 * i + d) / 4 = i by omega, show (4 * i + d) % 4 = d by omega]
  have hc2 : CodeAt s2.mem base kernel := by rw [mem2]; exact lived_code fit hc (by omega)
  -- on to the next word, one fewer to go
  have e3 := run_line (prog := kernel) hp stepLine (by decide) 13 s2 seg_step (by decide) hc2
    (by rw [p2]) (by decide)
  have p3 : (s2.line stepLine).pc = base + BitVec.ofNat 32 (4 * 15) := line_pc_at stepLine (by rw [p2]) (by decide)
  have g1 : (s2.line stepLine).reg T1 = s2.reg T1 + (4 : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2]
  have g2 : (s2.line stepLine).reg T2 = s2.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2]
  have g0 : (s2.line stepLine).reg T0 = s2.reg T0 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, T1, T2]
  have c1 : (s2.line stepLine).reg T1 = base + BitVec.ofNat 32 (HIST + 4 * (i + 1)) := by
    rw [g1, r2, t1, h.p, show BitVec.signExtend 32 (4 : BitVec 12) = BitVec.ofNat 32 4 by decide, off_add fit _ _ (by simp only [HIST, N] at hi ⊢; omega)]
    congr 2
  have c2 : (s2.line stepLine).reg T2 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g2, r2, t2, h.n, show N - i = N - (i + 1) + 1 by simp only [N] at hi ⊢; omega]
    exact dec_one _ (by simp only [N]; omega)
  have c0 : (s2.line stepLine).reg T0 = gen (seedOf m0 base) (i + 1) := by rw [g0, r2, x1]
  have hcl : CodeAt (s2.line stepLine).mem base kernel := by rw [line_mem]; exact hc2
  have tk : taken .bne ((s2.line stepLine).reg T2) ((s2.line stepLine).reg 0) = decide (i + 1 < N) := by
    rw [c2, reg_zero]
    simp only [taken, N] at hi ⊢
    by_cases hl : i + 1 < 256
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e; simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      apply BitVec.eq_of_toNat_eq; simp; omega
  have run3 : ∀ st', run env 1 (s2.line stepLine) = .running st' → run env 12 st = .running st' := by
    intro st' e
    rw [show 12 = body.length + (1 + (stepLine.length + 1)) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3, e]
  by_cases hl : i + 1 < N
  · refine ⟨(s2.line stepLine).setPc ((s2.line stepLine).pc + ((0xfea : BitVec 12) ++ 0#1).signExtend 32),
      run3 _ ((stepK hp 15 (by decide) hcl p3 (i := .br .bne T2 0 0xfea) (by decide)
        (exec_br_taken (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [setPc_pc, p3, back4]; simp [hl]
    · rw [setPc_reg, c0]
    · rw [setPc_reg, c1]
    · rw [setPc_reg, c2]
    · rw [setPc_mem, line_mem, mem2]
  · refine ⟨(s2.line stepLine).next,
      run3 _ ((stepK hp 15 (by decide) hcl p3 (i := .br .bne T2 0 0xfea) (by decide)
        (exec_br_not (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [next_pc, p3, pc_next fit 15 (by decide)]; simp [hl]
    · rw [next_reg, c0]
    · rw [next_reg, c1]
    · rw [next_reg, c2]
    · rw [next_mem, line_mem, mem2]

/-- All 256 generations, by induction. -/
theorem loop (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base 0 st) : ∀ j ≤ N, ∃ st', run env (12 * j) st = .running st' ∧ Inv m0 base j st' := by
  intro j hj
  induction j with
  | zero => exact ⟨st, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := iter hp hc (by omega) hs'
    exact ⟨s'', by rw [show 12 * (j + 1) = 12 * j + 12 by omega, run_add_running e, e'], hs''⟩

theorem setup_run (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 4 st = .running st' ∧ Inv st.mem base 0 st' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc T1 0) (by decide) rfl
  have b1 : s1.reg T1 = base := by rw [reg_wrote r1 (by decide), hpc]; simp
  obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (rd := T0) (rs1 := T1) (imm := 0x100) (by decide) SEED (by rw [b1, show BitVec.signExtend 32 (0x100 : BitVec 12) = BitVec.ofNat 32 SEED by decide])
      (by decide) (by decide)
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (i := .opi .addi T1 T1 0x200) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (i := .opi .addi T2 0 256) (by decide) rfl
  refine ⟨s4, ?_, ⟨by rw [p4]; rfl, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 4 = 1 + (1 + (1 + 1)) by rfl]; exact run_cons e1 (run_cons e2 (run_cons e3 e4))
  · rw [reg_kept r4 (by decide), reg_kept r3 (by decide), reg_wrote r2 (by decide), m1]; rfl
  · rw [reg_kept r4 (by decide), reg_wrote r3 (by decide)]
    simp only [aluI]; rw [reg_kept r2 (by decide), b1, show BitVec.signExtend 32 (0x200 : BitVec 12) = BitVec.ofNat 32 (HIST + 4 * 0) by decide]
  · rw [reg_wrote r4 (by decide)]; simp [aluI, N]
  · rw [m4, m3, m2, m1]; simp [lived, overlay_zero]

/-- HALT, at the `ecall`, with `t0 = 1`. -/
theorem halts_at (hp : Placed env base) {st : Machine} (hcode : CodeAt st.mem base kernel)
    (hpc : st.pc = base + BitVec.ofNat 32 (4 * 18)) (ht0 : st.reg T0 = 1) :
    run env 1 st = .halted (st.reg A0) st := by
  have hk' : 18 < kernel.length := by rw [kernel_length]; decide
  have hi : kernel.getD 18 .ecall = .ecall := by decide
  have : kernel[18] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk']
  exact run_code_halt 0 hk' hcode hpc (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (by rw [this]; exact exec_halt ht0)

theorem finish_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base N st) :
    ∃ s1 st', run env 2 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived m0 base N := by
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 16) := by rw [h.pc]; rfl
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code hp.fit hc (by decide)
  have e1 := run_line (prog := kernel) hp finishLine (by decide) 16 st seg_finish (by decide) hcode hpc (by decide)
  have p1 : (st.line finishLine).pc = base + BitVec.ofNat 32 (4 * 18) := line_pc_at finishLine hpc (by decide)
  have t1 : (st.line finishLine).reg T0 = 1 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have a1 : (st.line finishLine).reg A0 = 0 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have e2 := halts_at hp (st := st.line finishLine) (by rw [line_mem]; exact hcode) p1 t1
  rw [a1] at e2
  exact ⟨_, _, e1, e2, by rw [line_mem, h.mem]⟩

/-- Setup, 256 generations and the two instructions before the `ecall`: 3078
instructions, and the machine they leave. -/
theorem to_the_ecall (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1 st', run env 3078 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s0, e0, i0⟩ := setup_run hp st hpc hcode
  obtain ⟨sN, eN, iN⟩ := loop hp hcode i0 N (Nat.le_refl _)
  obtain ⟨s1, st', e2, e1, m⟩ := finish_run hp hcode iN
  exact ⟨s1, st', by rw [show 3078 = 4 + (12 * N + 2) by rfl, run_add_running e0, run_add_running eN, e2], e1, m⟩

/-- **The kernel lives.** From `base`, with the kernel's bytes there, it halts
with 0 after exactly 3079 instructions; the 1024 bytes from 0x200 are then
generations 1 to 256 of Rule 30 from the seed at 0x100, and every other byte
is what it was. For every `base` the region fits at, every value of every
byte, every register. -/
theorem lives (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 3079 st = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s1, st', e, e1, m⟩ := to_the_ecall hp st hpc hcode
  exact ⟨st', by rw [show 3079 = 3078 + 1 by rfl, run_add_running e, e1], m⟩

/-- **And not before**: after 3078 it is still running, whatever the seed. -/
theorem not_before (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1, run env 3078 st = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp st hpc hcode
  exact ⟨s1, e⟩

/-! ## The bytes are the kernel -/

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- **From the state the shell builds**: any image that begins with the
kernel's 76 bytes, the seed at 0x100. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 76 ≤ img.size)
    (himg : ∀ d (h : d < 76), img.get d (by omega) = bytes.getD d 0) :
    let m0 := memOfImage base img
    (∃ s1, run env 3078 (boot env.region img) = .running s1) ∧
    ∃ st', run env 3079 (boot env.region img) = .halted 0 st' ∧ st'.mem = lived m0 base N := by
  intro m0
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = m0 := by simp [boot, hp.region, m0]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]
    exact code_of_image hp.fit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
      (fun d h => himg d (by rw [kernel_length] at h; exact h))
  refine ⟨not_before hp _ hpc hcode, ?_⟩
  obtain ⟨st', e, m⟩ := lives hp _ hpc hcode
  rw [hmem] at m
  exact ⟨st', e, m⟩

#print axioms rule30
#print axioms iter
#print axioms lives
#print axioms not_before
#print axioms bytes_words
#print axioms from_boot

end Exp225

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp225.image
  | _ => pure ()
  for (i, k) in Exp225.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
