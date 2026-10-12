/-
SPDX-License-Identifier: Apache-2.0

# exp234 — the rate the proof predicts

exp232's world, proved. exp232's model is a ring of tissue with a tumour and
a dose that kills dividing cells, and its board ran a trial in a world the
model left something out of: a cell the tumour divides into is, now and
then, resistant, and a dose never kills a resistant cell or its daughters.
That world was C, unproved. Here it is a kernel, and a theorem, and the
random draw is an input — 64 masks, one a generation — so what is proved
holds for every draw.

The kernel reads the tumour, tissue and schedule at base + 0x200, 0x204 and
0x208 and the masks from 0x300, writes 64 generations — tumour, tissue,
resistant, 12 bytes each — from 0x400, and halts with 0.

- W1, `lives` and `from_boot`: after exactly 4043 instructions it halts with
  0 having written generations 1 to 64 of `wnext`, nothing else changed —
  for every input and every mask;
- W0, `still`: with every mask zero, the world is exp232's proved model; one
  kernel serves as both;
- M6, `resistance_stays`: one resistant cell, and whatever the schedule and
  the masks, the tumour never goes;
- M7, `cured_iff`: a patient is cured at generation 64 exactly when the
  model's is and no mask hit a cell the model's tumour divided into;
  `answer_world`: under exp232's answer, a lump of 1 to 6 cells anywhere
  leaves 0, 0, 1, 2, 3 or 8 such cells to chance — so with each mask bit one
  with probability 1/16, the treated fail at 1 − ((1 + 1 + q + q² + q³ +
  q⁸) / 6), q = 15/16: 12.71%;
- M8, `zero_stays`: a corrected endpoint — no tumour cell at all, not "none a
  scan sees" — and none ever comes back, in the world as in the model.

What none of it reaches: whether the TRNG's bits are independent ones with
probability 1/16 — the step from M7 to 12.71% assumes it — and whether any of
this is like a body.

   0-7    t, h, s into a0, a1, a2; a4 = 0; a5 the masks; t1 the history; t2 64
   8      lw a6, the mask
   9-63   one generation, 55 register instructions
   64-66  sw a0, a1, a4
   67-70  t1 += 12, a5 += 4, t2 -= 1, bne t2, x0, 8
   71-73  HALT 0
-/
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Ring
import Rv32.Tissue

namespace Exp234
open Rv32 Tissue

def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def T5 : Reg := 30
def T6 : Reg := 31
def R3 : Reg := 13
def R4 : Reg := 14
def R5 : Reg := 15
def R6 : Reg := 16
def R7 : Reg := 17

/-! ## The world: exp232's model, and resistance -/

/-- A body in the world: tumour, tissue, the resistant tumour cells, the schedule. -/
structure WBody where
  t : Word
  h : Word
  r : Word
  s : Word

/-- One generation of the world, with this generation's mutation mask `m`.
A dose kills what exp232's dose kills, except resistant cells; every cell the
tumour divides into is resistant where `m` has a one; a resistant cell's
daughter, the cell above it, is resistant. -/
def wnext (m : Word) (b : WBody) : WBody :=
  let k := (edge b.t b.h &&& dose b.s) &&& ~~~b.r
  let t1 := b.t &&& ~~~k
  let h1 := b.h &&& ~~~k
  let e := ~~~(t1 ||| h1)
  let t2 := t1 ||| up1 t1
  { t := t2, h := (h1 ||| (spread h1 &&& e)) &&& ~~~t2,
    r := ((b.r ||| up1 b.r) ||| ((~~~t1 &&& t2) &&& m)) &&& t2, s := b.s >>> 1 }

/-- Generation `n` of the world from `b`, generation `g`'s mask `ms g`. -/
def wgen (ms : Nat → Word) (b : WBody) : Nat → WBody
  | 0 => b
  | n + 1 => wnext (ms n) (wgen ms b n)

/-! ## The kernel -/

def setup : List Instr := [ .auipc T1 0, .ld .lw A0 T1 0x200, .ld .lw A1 T1 0x204, .ld .lw A2 T1 0x208,
  .opi .addi R4 0 0, .opi .addi R5 T1 0x300, .opi .addi T1 T1 0x400, .opi .addi T2 0 64 ]

/-- One generation in the registers: a0 tumour, a1 tissue, a2 schedule, a4
resistant, a6 the mask. 55 instructions. -/
def body : List Instr := [
  .opi .andi T3 A2 1, .op .sub T3 0 T3, .sh .srli A2 A2 1,
  .opi .xori T4 A0 0xfff, .sh .slli T5 T4 1, .sh .srli T6 T4 31, .op .or T5 T5 T6,
  .sh .srli T6 T4 1, .sh .slli T4 T4 31, .op .or T6 T6 T4, .op .or T5 T5 T6, .op .and T5 T5 A0,
  .opi .xori T4 A1 0xfff, .sh .slli T6 T4 1, .sh .srli R3 T4 31, .op .or T6 T6 R3,
  .sh .srli R3 T4 1, .sh .slli T4 T4 31, .op .or R3 R3 T4, .op .or T6 T6 R3, .op .and T6 T6 A1,
  .op .or T5 T5 T6, .op .and T5 T5 T3, .opi .xori T4 R4 0xfff, .op .and T5 T5 T4,
  .opi .xori T5 T5 0xfff, .op .and A0 A0 T5, .op .and A1 A1 T5, .opi .addi R7 A0 0,
  .op .or T3 A0 A1, .opi .xori T3 T3 0xfff,
  .sh .slli T4 A0 1, .sh .srli T5 A0 31, .op .or T4 T4 T5, .op .or A0 A0 T4,
  .sh .slli T4 A1 1, .sh .srli T5 A1 31, .op .or T4 T4 T5,
  .sh .srli T5 A1 1, .sh .slli T6 A1 31, .op .or T5 T5 T6, .op .or T4 T4 T5,
  .op .and T4 T4 T3, .op .or A1 A1 T4, .opi .xori T4 A0 0xfff, .op .and A1 A1 T4,
  .opi .xori T4 R7 0xfff, .op .and T4 T4 A0, .op .and T4 T4 R6,
  .sh .slli T5 R4 1, .sh .srli T6 R4 31, .op .or T5 T5 T6,
  .op .or R4 R4 T5, .op .or R4 R4 T4, .op .and R4 R4 A0 ]

theorem body_length : body.length = 55 := by decide

theorem xor_ones (x : Word) : x ^^^ 4294967295#32 = ~~~x := by
  rw [show (4294967295#32 : Word) = BitVec.allOnes 32 by decide, BitVec.xor_allOnes]

def wOf (st : Machine) : WBody := ⟨st.reg A0, st.reg A1, st.reg R4, st.reg A2⟩

theorem body_t (st : Machine) : (st.line body).reg A0 = (wnext (st.reg R6) (wOf st)).t := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, wnext, wOf, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, R3, R4, R6, R7, xor_ones]

theorem body_h (st : Machine) : (st.line body).reg A1 = (wnext (st.reg R6) (wOf st)).h := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, wnext, wOf, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, R3, R4, R6, R7, xor_ones]

theorem body_r (st : Machine) : (st.line body).reg R4 = (wnext (st.reg R6) (wOf st)).r := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, wnext, wOf, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, R3, R4, R6, R7, xor_ones]

theorem body_s (st : Machine) : (st.line body).reg A2 = (wnext (st.reg R6) (wOf st)).s := by
  simp [body, Machine.line, Machine.alu, reg_setReg, shiftI, aluR, aluI, wnext, wOf, edge, dose, spread, up1, dn1,
    A0, A1, A2, T3, T4, T5, T6, R3, R4, R6, R7, xor_ones]

theorem body_keeps1 (st : Machine) : (st.line body).reg T1 = st.reg T1 := by
  simp [body, Machine.line, Machine.alu, reg_setReg, A0, A1, A2, T1, T3, T4, T5, T6, R3, R4, R7]

theorem body_keeps2 (st : Machine) : (st.line body).reg T2 = st.reg T2 := by
  simp [body, Machine.line, Machine.alu, reg_setReg, A0, A1, A2, T2, T3, T4, T5, T6, R3, R4, R7]

theorem body_keeps5 (st : Machine) : (st.line body).reg R5 = st.reg R5 := by
  simp [body, Machine.line, Machine.alu, reg_setReg, A0, A1, A2, R5, T3, T4, T5, T6, R3, R4, R7]

def stepLine : List Instr := [ .opi .addi T1 T1 12, .opi .addi R5 R5 4, .opi .addi T2 T2 0xfff ]

def finishLine : List Instr := [ .opi .addi T0 0 1, .opi .addi A0 0 0 ]

def kernel : List Instr :=
  setup ++ [ .ld .lw R6 R5 0 ] ++ body ++ [ .st .sw T1 A0 0, .st .sw T1 A1 4, .st .sw T1 R4 8 ] ++ stepLine
    ++ [ .br .bne T2 0 0xf84 ] ++ finishLine ++ [ .ecall ]

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 74 := by decide

/-! ## The specification over the history -/

def INIT : Nat := 0x200
def MASKS : Nat := 0x300
def HIST : Nat := 0x400
def N : Nat := 64

def wordAt (m : Word → Byte) (base : Word) (off : Nat) : Word :=
  BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 off) 4)

/-- What the kernel starts from: the tumour, tissue and schedule at 0x200, 0x204
and 0x208, and nothing resistant yet. -/
def initOf (m : Word → Byte) (base : Word) : WBody :=
  ⟨wordAt m base INIT, wordAt m base (INIT + 4), 0, wordAt m base (INIT + 8)⟩

/-- Generation `g`'s mask: the word at 0x300 + 4g. -/
def maskOf (m : Word → Byte) (base : Word) (g : Nat) : Word := wordAt m base (MASKS + 4 * g)

/-- Byte `d` of the history: generation `d / 12 + 1`, its tumour, tissue and
resistant cells, four bytes each, little-endian. -/
def hist (m0 : Word → Byte) (base : Word) (d : Nat) : Byte :=
  let g := wgen (maskOf m0 base) (initOf m0 base) (d / 12 + 1)
  BitVec.ofNat 8 ((if d % 12 < 4 then g.t else if d % 12 < 8 then g.h else g.r).toNat / 256 ^ (d % 4))

def lived (m0 : Word → Byte) (base : Word) (i : Nat) : Word → Byte :=
  overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (3 * i)) (hist m0 base)

/-! ## The loop -/

structure Inv (m0 : Word → Byte) (base : Word) (i : Nat) (st : Machine) : Prop where
  pc : st.pc = base + BitVec.ofNat 32 (4 * (if i < N then 8 else 71))
  w : wOf st = wgen (maskOf m0 base) (initOf m0 base) i
  p : st.reg T1 = base + BitVec.ofNat 32 (HIST + 12 * i)
  q : st.reg R5 = base + BitVec.ofNat 32 (MASKS + 4 * i)
  n : st.reg T2 = BitVec.ofNat 32 (N - i)
  mem : st.mem = lived m0 base i

variable {env : Env} {base : Word}

theorem seg_body : (kernel.drop 9).take body.length = body := by decide
theorem seg_step : (kernel.drop 67).take stepLine.length = stepLine := by decide
theorem seg_finish : (kernel.drop 71).take finishLine.length = finishLine := by decide

theorem lived_code (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 : Word → Byte} (hc : CodeAt m0 base kernel)
    {i : Nat} (hi : i ≤ N) : CodeAt (lived m0 base i) base kernel :=
  code_of_overlay hfit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _

theorem back (base : Word) :
    base + BitVec.ofNat 32 (4 * 70) + ((0xf84 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 8) := by
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

/-- The masks lie below the history, so what the loop has written never reaches them. -/
theorem mask_read (hfit : base.toNat + 0x10000 ≤ 2^32) (m0 : Word → Byte) {i : Nat} (hi : i < N) :
    readLE (lived m0 base i) (base + BitVec.ofNat 32 (MASKS + 4 * i)) 4
      = readLE m0 (base + BitVec.ofNat 32 (MASKS + 4 * i)) 4 := by
  apply readLE_four_congr
  intro d hd
  rw [off_add hfit _ _ (by simp only [MASKS, N] at hi ⊢; omega)]
  unfold lived
  exact overlay_off_out hfit m0 _ (by simp only [HIST, N] at hi ⊢; omega) (by simp only [MASKS, N] at hi ⊢; omega)
    (Or.inl (by simp only [MASKS, HIST, N] at hi ⊢; omega))

theorem hist_byte (m0 : Word → Byte) (base : Word) (i k d : Nat) (hk : k < 3) (hd : d < 4) :
    hist m0 base (4 * (3 * i + k) + d) =
      BitVec.ofNat 8 ((if k = 0 then (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).t
        else if k = 1 then (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).h
        else (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).r).toNat / 256 ^ d) := by
  simp only [hist]
  rw [show (4 * (3 * i + k) + d) / 12 = i by omega, show (4 * (3 * i + k) + d) % 4 = d by omega,
    show (4 * (3 * i + k) + d) % 12 = 4 * k + d by omega]
  rcases (by omega : k = 0 ∨ k = 1 ∨ k = 2) with h | h | h <;> subst h
  · simp [hd]
  · simp [show ¬ 4 + d < 4 by omega, show 4 + d < 8 by omega]
  · simp [show ¬ 8 + d < 4 by omega, show ¬ 8 + d < 8 by omega]

theorem body_w (st : Machine) : wOf (st.line body) = wnext (st.reg R6) (wOf st) := by
  have e : wOf (st.line body) = ⟨(st.line body).reg A0, (st.line body).reg A1, (st.line body).reg R4, (st.line body).reg A2⟩ := rfl
  rw [e, body_t, body_h, body_r, body_s]

/-- **One generation**: from the top of generation `i`, 63 instructions on,
the top of generation `i + 1` — or, after the last, the finish. -/
theorem iter (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {i : Nat} (hi : i < N)
    {st : Machine} (h : Inv m0 base i st) : ∃ st', run env 63 st = .running st' ∧ Inv m0 base (i + 1) st' := by
  have fit := hp.fit
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 8) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code fit hc (by omega)
  -- the mask
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp 8 (by decide) hcode hpc
    (rd := R6) (rs1 := R5) (imm := 0) (by decide) (MASKS + 4 * i) (by rw [h.q]; simp)
    (by simp only [MASKS, N] at hi ⊢; omega) (by simp only [MASKS]; omega)
  have k1 : ∀ r, r ≠ R6 → s1.reg r = st.reg r := fun r hr => by rw [r1]; simp [hr]
  have mk : s1.reg R6 = maskOf m0 base i := by
    rw [r1]; simp only [show R6 ≠ 0 by decide, and_self, ne_eq, not_false_eq_true, ↓reduceIte]
    rw [h.mem, mask_read fit m0 hi]; rfl
  have w1 : wOf s1 = wOf st := by
    simp only [wOf, k1 A0 (by decide), k1 A1 (by decide), k1 R4 (by decide), k1 A2 (by decide)]
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  -- the generation
  have e2 := run_line (prog := kernel) hp body (by decide) 9 s1 seg_body (by decide) hc1 p1 (by decide)
  have p2 : (s1.line body).pc = base + BitVec.ofNat 32 (4 * 64) := line_pc_at body p1 (by decide)
  have wg : wOf (s1.line body) = wgen (maskOf m0 base) (initOf m0 base) (i + 1) := by
    rw [body_w, mk, w1, h.w]; rfl
  have xt : (s1.line body).reg A0 = (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).t := by rw [← wg]; rfl
  have xh : (s1.line body).reg A1 = (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).h := by rw [← wg]; rfl
  have xr : (s1.line body).reg R4 = (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).r := by rw [← wg]; rfl
  have t1 : (s1.line body).reg T1 = st.reg T1 := by rw [body_keeps1, k1 T1 (by decide)]
  have t2 : (s1.line body).reg T2 = st.reg T2 := by rw [body_keeps2, k1 T2 (by decide)]
  have t5 : (s1.line body).reg R5 = st.reg R5 := by rw [body_keeps5, k1 R5 (by decide)]
  have hc2 : CodeAt (s1.line body).mem base kernel := by rw [line_mem]; exact hc1
  -- three stores: tumour, tissue, resistant
  have addr : ∀ k (imm : BitVec 12), k < 3 → imm.signExtend 32 = BitVec.ofNat 32 (4 * k) →
      st.reg T1 + imm.signExtend 32 = base + BitVec.ofNat 32 (HIST + 4 * (3 * i + k)) := by
    intro k imm hk e
    rw [e, h.p, off_add fit _ _ (by simp only [HIST, N] at hi ⊢; omega)]
    congr 2; omega
  have hb : ∀ k d, k < 3 → d < 4 → ∀ v : Word,
      v = (if k = 0 then (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).t
        else if k = 1 then (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).h
        else (wgen (maskOf m0 base) (initOf m0 base) (i + 1)).r) →
      BitVec.ofNat 8 (v.toNat / 256 ^ d) = hist m0 base (4 * (3 * i + k) + d) := by
    intro k d hk hd v hv; rw [hist_byte m0 base i k d hk hd, hv]
  have bound : ∀ k, k < 3 → HIST + 4 * (3 * i + k) + 4 ≤ 0x10000 := by
    intro k hk; simp only [HIST, N] at hi ⊢; omega
  obtain ⟨s3, e3, p3, m3, r3⟩ := storeStep (prog := kernel) hp 64 (by decide) (s := s1.line body) hc2 p2
    (rs1 := T1) (rs2 := A0) (imm := 0) (by decide) (HIST + 4 * (3 * i + 0))
    (by rw [t1]; exact addr 0 0 (by decide) (by decide)) (by have := bound 0 (by decide); omega) (by simp only [HIST]; omega)
  have mem3 : s3.mem = overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (3 * i + 0 + 1)) (hist m0 base) := by
    rw [m3, line_mem, m1, h.mem]
    exact store_mem fit m0 _ (3 * i + 0) _ (bound 0 (by decide)) (fun d hd => hb 0 d (by decide) hd _ (by rw [xt]; rfl))
  obtain ⟨s4, e4, p4, m4, r4⟩ := storeStep (prog := kernel) hp 65 (by decide) (s := s3)
    (by rw [mem3]; exact code_of_overlay fit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _) p3
    (rs1 := T1) (rs2 := A1) (imm := 4) (by decide) (HIST + 4 * (3 * i + 1))
    (by rw [r3, t1]; exact addr 1 4 (by decide) (by decide)) (by have := bound 1 (by decide); omega) (by simp only [HIST]; omega)
  have mem4 : s4.mem = overlay m0 (base + BitVec.ofNat 32 HIST) (4 * (3 * i + 1 + 1)) (hist m0 base) := by
    rw [m4, mem3]
    exact store_mem fit m0 _ (3 * i + 1) _ (bound 1 (by decide)) (fun d hd => hb 1 d (by decide) hd _ (by rw [r3, xh]; rfl))
  obtain ⟨s5, e5, p5, m5, r5⟩ := storeStep (prog := kernel) hp 66 (by decide) (s := s4)
    (by rw [mem4]; exact code_of_overlay fit hc (by rw [kernel_length]; decide) (by simp only [N, HIST] at hi ⊢; omega) _) p4
    (rs1 := T1) (rs2 := R4) (imm := 8) (by decide) (HIST + 4 * (3 * i + 2))
    (by rw [r4, r3, t1]; exact addr 2 8 (by decide) (by decide)) (by have := bound 2 (by decide); omega) (by simp only [HIST]; omega)
  have mem5 : s5.mem = lived m0 base (i + 1) := by
    rw [m5, mem4]
    unfold lived
    rw [show 4 * (3 * (i + 1)) = 4 * (3 * i + 2 + 1) by omega]
    exact store_mem fit m0 _ (3 * i + 2) _ (bound 2 (by decide)) (fun d hd => hb 2 d (by decide) hd _ (by rw [r4, r3, xr]; rfl))
  have hc5 : CodeAt s5.mem base kernel := by rw [mem5]; exact lived_code fit hc (by omega)
  have k5 : ∀ r, s5.reg r = (s1.line body).reg r := fun r => by rw [r5, r4, r3]
  -- on to the next generation
  have e6 := run_line (prog := kernel) hp stepLine (by decide) 67 s5 seg_step (by decide) hc5 p5 (by decide)
  have p6 : (s5.line stepLine).pc = base + BitVec.ofNat 32 (4 * 70) := line_pc_at stepLine p5 (by decide)
  have g1 : (s5.line stepLine).reg T1 = s5.reg T1 + (12 : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2, R5]
  have g5 : (s5.line stepLine).reg R5 = s5.reg R5 + (4 : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2, R5]
  have g2 : (s5.line stepLine).reg T2 = s5.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, T1, T2, R5]
  have k0 : ∀ r, r ≠ T1 → r ≠ T2 → r ≠ R5 → (s5.line stepLine).reg r = s5.reg r := by
    intro r a b c
    simp [stepLine, Machine.line, Machine.alu, reg_setReg, aluI, a, b, c]
  have c1 : (s5.line stepLine).reg T1 = base + BitVec.ofNat 32 (HIST + 12 * (i + 1)) := by
    rw [g1, k5, t1, h.p, show BitVec.signExtend 32 (12 : BitVec 12) = BitVec.ofNat 32 12 by decide,
      off_add fit _ _ (by simp only [HIST, N] at hi ⊢; omega)]
    congr 2
  have c5 : (s5.line stepLine).reg R5 = base + BitVec.ofNat 32 (MASKS + 4 * (i + 1)) := by
    rw [g5, k5, t5, h.q, show BitVec.signExtend 32 (4 : BitVec 12) = BitVec.ofNat 32 4 by decide,
      off_add fit _ _ (by simp only [MASKS, N] at hi ⊢; omega)]
    congr 2
  have c2 : (s5.line stepLine).reg T2 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g2, k5, t2, h.n, show N - i = N - (i + 1) + 1 by simp only [N] at hi ⊢; omega]
    exact dec_one _ (by simp only [N]; omega)
  have cw : wOf (s5.line stepLine) = wgen (maskOf m0 base) (initOf m0 base) (i + 1) := by
    simp only [wOf, k0 A0 (by decide) (by decide) (by decide), k0 A1 (by decide) (by decide) (by decide),
      k0 R4 (by decide) (by decide) (by decide), k0 A2 (by decide) (by decide) (by decide), k5]
    exact wg
  have hcl : CodeAt (s5.line stepLine).mem base kernel := by rw [line_mem]; exact hc5
  have tk : taken .bne ((s5.line stepLine).reg T2) ((s5.line stepLine).reg 0) = decide (i + 1 < N) := by
    rw [c2, reg_zero]
    simp only [taken, N] at hi ⊢
    by_cases hl : i + 1 < 64
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e; simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      apply BitVec.eq_of_toNat_eq; simp; omega
  have run6 : ∀ st', run env 1 (s5.line stepLine) = .running st' → run env 63 st = .running st' := by
    intro st' e
    rw [show 63 = 1 + (body.length + (1 + (1 + (1 + (stepLine.length + 1))))) by rfl, run_add_running e1,
      run_add_running e2, run_add_running e3, run_add_running e4, run_add_running e5, run_add_running e6, e]
  have wOf_setPc : ∀ (x : Machine) v, wOf (x.setPc v) = wOf x := fun x v => by simp [wOf, setPc_reg]
  have wOf_next : ∀ (x : Machine), wOf x.next = wOf x := fun x => by simp [wOf, next_reg]
  by_cases hl : i + 1 < N
  · refine ⟨(s5.line stepLine).setPc ((s5.line stepLine).pc + ((0xf84 : BitVec 12) ++ 0#1).signExtend 32),
      run6 _ ((stepK hp 70 (by decide) hcl p6 (i := .br .bne T2 0 0xf84) (by decide)
        (exec_br_taken (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [setPc_pc, p6, back]; simp [hl]
    · rw [wOf_setPc, cw]
    · rw [setPc_reg, c1]
    · rw [setPc_reg, c5]
    · rw [setPc_reg, c2]
    · rw [setPc_mem, line_mem, mem5]
  · refine ⟨(s5.line stepLine).next,
      run6 _ ((stepK hp 70 (by decide) hcl p6 (i := .br .bne T2 0 0xf84) (by decide)
        (exec_br_not (by rw [tk]; simp [hl])) 0).trans (run_zero _ _)), ⟨?_, ?_, ?_, ?_, ?_, ?_⟩⟩
    · rw [next_pc, p6, pc_next fit 70 (by decide)]; simp [hl]
    · rw [wOf_next, cw]
    · rw [next_reg, c1]
    · rw [next_reg, c5]
    · rw [next_reg, c2]
    · rw [next_mem, line_mem, mem5]

/-- All 64 generations, by induction. -/
theorem loop (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base 0 st) : ∀ j ≤ N, ∃ st', run env (63 * j) st = .running st' ∧ Inv m0 base j st' := by
  intro j hj
  induction j with
  | zero => exact ⟨st, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := iter hp hc (by omega) hs'
    exact ⟨s'', by rw [show 63 * (j + 1) = 63 * j + 63 by omega, run_add_running e, e'], hs''⟩

theorem setup_run (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 8 st = .running st' ∧ Inv st.mem base 0 st' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc T1 0) (by decide) rfl
  have b1 : s1.reg T1 = base := by rw [reg_wrote r1 (by decide), hpc]; simp
  obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (rd := A0) (rs1 := T1) (imm := 0x200) (by decide) INIT
      (by rw [b1, show BitVec.signExtend 32 (0x200 : BitVec 12) = BitVec.ofNat 32 INIT by decide])
      (by decide) (by decide)
  obtain ⟨s3, e3, p3, m3, r3⟩ := loadStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (rd := A1) (rs1 := T1) (imm := 0x204) (by decide) (INIT + 4)
      (by rw [reg_kept r2 (by decide), b1, show BitVec.signExtend 32 (0x204 : BitVec 12) = BitVec.ofNat 32 (INIT + 4) by decide])
      (by decide) (by decide)
  obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (rd := A2) (rs1 := T1) (imm := 0x208) (by decide) (INIT + 8)
      (by rw [reg_kept r3 (by decide), reg_kept r2 (by decide), b1,
        show BitVec.signExtend 32 (0x208 : BitVec 12) = BitVec.ofNat 32 (INIT + 8) by decide])
      (by decide) (by decide)
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) (by rw [m4, m3, m2, m1]; exact hcode) p4
      (i := .opi .addi R4 0 0) (by decide) rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) (by rw [m5, m4, m3, m2, m1]; exact hcode) p5
      (i := .opi .addi R5 T1 0x300) (by decide) rfl
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp 6 (by decide) (by rw [m6, m5, m4, m3, m2, m1]; exact hcode) p6
      (i := .opi .addi T1 T1 0x400) (by decide) rfl
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 7 (by decide) (by rw [m7, m6, m5, m4, m3, m2, m1]; exact hcode) p7
      (i := .opi .addi T2 0 64) (by decide) rfl
  have tb : s6.reg T1 = base := by
    rw [reg_kept r6 (by decide), reg_kept r5 (by decide), reg_kept r4 (by decide), reg_kept r3 (by decide),
      reg_kept r2 (by decide), b1]
  refine ⟨s8, ?_, ⟨by rw [p8]; rfl, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 8 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + 1)))))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7 e8))))))
  · have ra0 : s8.reg A0 = wordAt st.mem base INIT := by
      rw [reg_kept r8 (by decide), reg_kept r7 (by decide), reg_kept r6 (by decide), reg_kept r5 (by decide),
        reg_kept r4 (by decide), reg_kept r3 (by decide), reg_wrote r2 (by decide), m1]; rfl
    have ra1 : s8.reg A1 = wordAt st.mem base (INIT + 4) := by
      rw [reg_kept r8 (by decide), reg_kept r7 (by decide), reg_kept r6 (by decide), reg_kept r5 (by decide),
        reg_kept r4 (by decide), reg_wrote r3 (by decide), m2, m1]; rfl
    have ra2 : s8.reg A2 = wordAt st.mem base (INIT + 8) := by
      rw [reg_kept r8 (by decide), reg_kept r7 (by decide), reg_kept r6 (by decide), reg_kept r5 (by decide),
        reg_wrote r4 (by decide), m3, m2, m1]; rfl
    have rr4 : s8.reg R4 = 0 := by
      rw [reg_kept r8 (by decide), reg_kept r7 (by decide), reg_kept r6 (by decide), reg_wrote r5 (by decide)]
      simp [aluI]
    show (⟨s8.reg A0, s8.reg A1, s8.reg R4, s8.reg A2⟩ : WBody) = initOf st.mem base
    rw [ra0, ra1, rr4, ra2]; rfl
  · rw [reg_kept r8 (by decide), reg_wrote r7 (by decide)]
    simp only [aluI]
    rw [tb, show BitVec.signExtend 32 (0x400 : BitVec 12) = BitVec.ofNat 32 (HIST + 12 * 0) by decide]
  · rw [reg_kept r8 (by decide), reg_kept r7 (by decide), reg_wrote r6 (by decide)]
    simp only [aluI]
    rw [reg_kept r5 (by decide), reg_kept r4 (by decide), reg_kept r3 (by decide), reg_kept r2 (by decide), b1,
      show BitVec.signExtend 32 (0x300 : BitVec 12) = BitVec.ofNat 32 (MASKS + 4 * 0) by decide]
  · rw [reg_wrote r8 (by decide)]; simp [aluI, N]
  · rw [m8, m7, m6, m5, m4, m3, m2, m1]; simp [lived, overlay_zero]

/-- HALT, at the `ecall`, with `t0 = 1`. -/
theorem halts_at (hp : Placed env base) {st : Machine} (hcode : CodeAt st.mem base kernel)
    (hpc : st.pc = base + BitVec.ofNat 32 (4 * 73)) (ht0 : st.reg T0 = 1) :
    run env 1 st = .halted (st.reg A0) st := by
  have hk' : 73 < kernel.length := by rw [kernel_length]; decide
  have hi : kernel.getD 73 .ecall = .ecall := by decide
  have : kernel[73] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk']
  exact run_code_halt 0 hk' hcode hpc (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (by rw [this]; exact exec_halt ht0)

theorem finish_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base N st) :
    ∃ s1 st', run env 2 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived m0 base N := by
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 71) := by rw [h.pc]; rfl
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact lived_code hp.fit hc (by decide)
  have e1 := run_line (prog := kernel) hp finishLine (by decide) 71 st seg_finish (by decide) hcode hpc (by decide)
  have p1 : (st.line finishLine).pc = base + BitVec.ofNat 32 (4 * 73) := line_pc_at finishLine hpc (by decide)
  have t1 : (st.line finishLine).reg T0 = 1 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have a1 : (st.line finishLine).reg A0 = 0 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have e2 := halts_at hp (st := st.line finishLine) (by rw [line_mem]; exact hcode) p1 t1
  rw [a1] at e2
  exact ⟨_, _, e1, e2, by rw [line_mem, h.mem]⟩

theorem to_the_ecall (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1 st', run env 4042 st = .running s1 ∧ run env 1 s1 = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s0, e0, i0⟩ := setup_run hp st hpc hcode
  obtain ⟨sN, eN, iN⟩ := loop hp hcode i0 N (Nat.le_refl _)
  obtain ⟨s1, st', e2, e1, m⟩ := finish_run hp hcode iN
  exact ⟨s1, st', by rw [show 4042 = 8 + (63 * N + 2) by rfl, run_add_running e0, run_add_running eN, e2], e1, m⟩

/-- **W1, the kernel is the world.** From `base`, with the kernel's bytes
there, it halts with 0 after exactly 4043 instructions; the 768 bytes from
0x400 are then generations 1 to 64 of `wnext` — tumour, tissue, resistant —
from the tumour, tissue and schedule at 0x200, nothing resistant, and the 64
masks at 0x300; every other byte is what it was. For every mask: whatever
the random words, the kernel lives exactly the world they draw. -/
theorem lives (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 4043 st = .halted 0 st' ∧ st'.mem = lived st.mem base N := by
  obtain ⟨s1, st', e, e1, m⟩ := to_the_ecall hp st hpc hcode
  exact ⟨st', by rw [show 4043 = 4042 + 1 by rfl, run_add_running e, e1], m⟩

theorem not_before (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ s1, run env 4042 st = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp st hpc hcode
  exact ⟨s1, e⟩

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- **From the state the shell builds**: any image that begins with the
kernel's 296 bytes. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 296 ≤ img.size)
    (himg : ∀ d (h : d < 296), img.get d (by omega) = bytes.getD d 0) :
    let m0 := memOfImage base img
    (∃ s1, run env 4042 (boot env.region img) = .running s1) ∧
    ∃ st', run env 4043 (boot env.region img) = .halted 0 st' ∧ st'.mem = lived m0 base N := by
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

/-! ## The world and the model -/

/-- A body of the model, in the world: nothing resistant. -/
def lift (b : Body) : WBody := ⟨b.t, b.h, 0, b.s⟩

/-- The cells the model's tumour divides into this generation. -/
def born (b : Body) : Word := ~~~(b.t &&& ~~~(edge b.t b.h &&& dose b.s)) &&& (next b).t

/-- Every resistant cell is a tumour cell. -/
def inside (b : WBody) : Prop := b.r &&& ~~~b.t = 0

theorem wnext_lift (m : Word) (b : Body) :
    wnext m (lift b) = ⟨(next b).t, (next b).h, ((0 ||| up1 0) ||| (born b &&& m)) &&& (next b).t, (next b).s⟩ := by
  have k : (edge b.t b.h &&& dose b.s) &&& ~~~(0 : Word) = edge b.t b.h &&& dose b.s := by
    rw [show ~~~(0 : Word) = BitVec.allOnes 32 by decide, BitVec.and_allOnes]
  simp only [wnext, lift, k, next, born]

theorem up1_zero : up1 (0 : Word) = 0 := by decide

theorem and_twice (a b c : Word) : ((a &&& b) &&& c) &&& b = (a &&& b) &&& c := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [BitVec.getLsbD_and]
  cases a.getLsbD i <;> cases b.getLsbD i <;> cases c.getLsbD i <;> rfl

/-- **W0.** Where no mask hits a cell the model's tumour divides into, the
world takes the model's step and nothing becomes resistant. -/
theorem quiet_step (m : Word) (b : Body) (hm : born b &&& m = 0) : wnext m (lift b) = lift (next b) := by
  rw [wnext_lift, hm, up1_zero]
  simp [lift]

/-- And where one does, a resistant cell is born. -/
theorem hit_step (m : Word) (b : Body) (hm : born b &&& m ≠ 0) : (wnext m (lift b)).r ≠ 0 := by
  rw [wnext_lift, up1_zero]
  show (((0 : Word) ||| 0) ||| (born b &&& m)) &&& (next b).t ≠ 0
  rw [show ((0 : Word) ||| 0) = 0 by decide, show ∀ x : Word, (0 : Word) ||| x = x from fun x => by simp]
  unfold born at hm ⊢
  rw [and_twice]; exact hm

theorem inside_step (m : Word) (b : WBody) : inside (wnext m b) := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  simp only [wnext, BitVec.getLsbD_and, BitVec.getLsbD_not, hi, decide_true, Bool.true_and]
  cases ((b.t &&& ~~~((edge b.t b.h &&& dose b.s) &&& ~~~b.r)) |||
    up1 (b.t &&& ~~~((edge b.t b.h &&& dose b.s) &&& ~~~b.r))).getLsbD i <;> simp

/-- A resistant cell stays: a dose never kills it, and it is a tumour cell, so
it is still one, and still resistant, a generation on. -/
theorem keeps (m : Word) (b : WBody) (hin : inside b) : b.r &&& ~~~(wnext m b).r = 0 := by
  apply BitVec.eq_of_getLsbD_eq; intro i hi
  have hb := congrArg (fun x : Word => x.getLsbD i) hin
  simp only [BitVec.getLsbD_and, BitVec.getLsbD_not, hi, decide_true, Bool.true_and] at hb
  simp only [wnext, BitVec.getLsbD_and, BitVec.getLsbD_not, BitVec.getLsbD_or, hi, decide_true, Bool.true_and]
  cases hr : b.r.getLsbD i <;> cases ht : b.t.getLsbD i <;> simp_all

theorem wgen_add (ms : Nat → Word) (b : WBody) (a : Nat) :
    ∀ n, wgen ms b (a + n) = wgen (fun k => ms (a + k)) (wgen ms b a) n
  | 0 => rfl
  | n + 1 => by
    show wnext (ms (a + n)) (wgen ms b (a + n)) = wnext (ms (a + n)) (wgen _ _ n)
    rw [wgen_add ms b a n]

/-- **M6. Resistance stays.** From any body whose resistant cells are tumour
cells, with one resistant cell, whatever the masks — whatever the TRNG draws
— and whatever the schedule: every generation after still has a resistant
cell, so still a tumour. No schedule of this drug cures it. -/
theorem resistance_stays (ms : Nat → Word) (b : WBody) (hin : inside b) (hr : b.r ≠ 0) :
    ∀ n, (wgen ms b n).r ≠ 0 ∧ (wgen ms b n).t ≠ 0 ∧ inside (wgen ms b n) := by
  have tumour : ∀ x : WBody, inside x → x.r ≠ 0 → x.t ≠ 0 := by
    intro x hx hxr ht
    apply hxr
    have := hx; simp only [inside, ht] at this
    rw [show ~~~(0 : Word) = BitVec.allOnes 32 by decide, BitVec.and_allOnes] at this; exact this
  intro n
  induction n with
  | zero => exact ⟨hr, tumour b hin hr, hin⟩
  | succ n ih =>
    obtain ⟨r0, -, i0⟩ := ih
    have k := keeps (ms n) _ i0
    have r1 : (wgen ms b (n + 1)).r ≠ 0 := by
      intro z
      apply r0
      show (wgen ms b n).r = 0
      have : (wgen ms b n).r &&& ~~~(wnext (ms n) (wgen ms b n)).r = 0 := k
      rw [show (wnext (ms n) (wgen ms b n)).r = (wgen ms b (n + 1)).r from rfl, z,
        show ~~~(0 : Word) = BitVec.allOnes 32 by decide, BitVec.and_allOnes] at this
      exact this
    exact ⟨r1, tumour _ (inside_step _ _) r1, inside_step _ _⟩

/-- The world from a body of the model, every mask so far missing every
division: still the model, nothing resistant. -/
theorem quiet (ms : Nat → Word) (B : Body) :
    ∀ n, (∀ g < n, born (gen B g) &&& ms g = 0) → wgen ms (lift B) n = lift (gen B n)
  | 0, _ => rfl
  | n + 1, h => by
    show wnext (ms n) (wgen ms (lift B) n) = lift (next (gen B n))
    rw [quiet ms B n (fun g hg => h g (by omega))]
    exact quiet_step _ _ (h n (by omega))

/-- **W0.** With no mutation at all, the world is the proved model. -/
theorem still (B : Body) (n : Nat) : wgen (fun _ => 0) (lift B) n = lift (gen B n) :=
  quiet _ B n (fun g _ => by simp)

theorem first_hit (P : Nat → Prop) : ∀ n, ¬ (∀ g < n, P g) → ∃ g < n, (∀ j < g, P j) ∧ ¬ P g
  | 0, h => absurd (fun g hg => absurd hg (Nat.not_lt_zero g)) h
  | n + 1, h => by
    by_cases hn : ∀ g < n, P g
    · exact ⟨n, by omega, hn, fun hp => h (fun g hg => by
        rcases (by omega : g < n ∨ g = n) with h' | h'
        · exact hn g h'
        · subst h'; exact hp)⟩
    · obtain ⟨g, hg, h1, h2⟩ := first_hit P n hn
      exact ⟨g, by omega, h1, h2⟩

/-- **M7. Cured, exactly when nothing mutated.** In the world, a patient of
the model — nothing resistant to start — is free of tumour at generation 64
if and only if the model's is, and not one of the cells the model's tumour
divided into, in any of the 64 generations, drew a one from its mask. For
every mask. -/
theorem cured_iff (ms : Nat → Word) (B : Body) :
    (wgen ms (lift B) 64).t = 0 ↔ (gen B 64).t = 0 ∧ ∀ g < 64, born (gen B g) &&& ms g = 0 := by
  constructor
  · intro h0
    by_cases hq : ∀ g < 64, born (gen B g) &&& ms g = 0
    · refine ⟨?_, hq⟩
      rw [quiet ms B 64 hq] at h0; exact h0
    · obtain ⟨g, hg, before, hit⟩ := first_hit _ 64 hq
      have at_g := quiet ms B g before
      have r1 : (wgen ms (lift B) (g + 1)).r ≠ 0 := by
        show (wnext (ms g) (wgen ms (lift B) g)).r ≠ 0
        rw [at_g]; exact hit_step _ _ hit
      have i1 : inside (wgen ms (lift B) (g + 1)) := inside_step _ _
      have := (resistance_stays (fun k => ms (g + 1 + k)) _ i1 r1 (63 - g)).2.1
      rw [← wgen_add, show g + 1 + (63 - g) = 64 by omega] at this
      exact absurd h0 this
  · rintro ⟨h0, hq⟩
    rw [quiet ms B 64 hq]; exact h0

/-- **M8. A corrected endpoint.** If no tumour cell is left at all — not
"none a scan can see", none — then none ever comes back, in the world as in
the model, whatever the masks. -/
theorem zero_stays (ms : Nat → Word) (b : WBody) (hin : inside b) (h0 : b.t = 0) :
    ∀ n, (wgen ms b n).t = 0 ∧ inside (wgen ms b n) := by
  intro n
  induction n with
  | zero => exact ⟨h0, hin⟩
  | succ n ih =>
    obtain ⟨t0, i0⟩ := ih
    have r0 : (wgen ms b n).r = 0 := by
      have := i0; simp only [inside, t0] at this
      rw [show ~~~(0 : Word) = BitVec.allOnes 32 by decide, BitVec.and_allOnes] at this; exact this
    refine ⟨?_, inside_step _ _⟩
    show (wnext (ms n) (wgen ms b n)).t = 0
    simp [wnext, t0, r0, up1]

/-! ## M7b: how many divisions the answer leaves to chance -/

/-- exp232's answer, the schedule the chip's search finds. -/
def ANSWER : Word := 0x51af

/-- The cells the model's tumour divides into, all 64 generations: each one
a cell whose mask bit decides, by M7, whether the patient is cured. -/
def divisions (b : Body) : Nat → Nat
  | 0 => 0
  | n + 1 => divisions b n + pc (born (gen b n)) 32

theorem born_up1 (b : Body) : born ⟨up1 b.t, up1 b.h, b.s⟩ = up1 (born b) := by
  simp only [born, next, edge, up1_and, up1_or, up1_not, ← spread_up1, dose_up1]

theorem born_rot (b : Body) : ∀ p, born ⟨rot p b.t, rot p b.h, b.s⟩ = rot p (born b)
  | 0 => rfl
  | p + 1 => by
    show born ⟨up1 (rot p b.t), up1 (rot p b.h), b.s⟩ = up1 (rot p (born b))
    rw [born_up1 ⟨rot p b.t, rot p b.h, b.s⟩, born_rot b p]

theorem divisions_iter (w p : Nat) (s : Word) : ∀ n, divisions (patient w p s) n = divisions (patient w 0 s) n
  | 0 => rfl
  | n + 1 => by
    simp only [divisions, divisions_iter w p s n, gen_iter w p s n, born_rot, pc_iter]

/-- The divisions a lump of `w` cells leaves to chance under the answer. -/
def D : Nat → Nat
  | 3 => 1 | 4 => 2 | 5 => 3 | 6 => 8 | _ => 0

set_option maxRecDepth 100000 in
theorem answer_zero : ∀ w < 6, divisions (patient (w + 1) 0 ANSWER) 64 = D (w + 1)
    ∧ (gen (patient (w + 1) 0 ANSWER) 64).t = 0 := by
  decide

/-- **M7, for the trial.** Every patient the trial enrols — a lump of 1 to 6
cells, anywhere on the ring — treated with the answer, whatever the masks:
cured at generation 64 if and only if none of the cells the model's tumour
divides into drew a one, and there are exactly `D w` of those — 0, 0, 1, 2,
3 and 8. So if each of a mask's bits is one with probability 1/16, all
independently, a lump of `w` is cured with probability (15/16)^(D w): the
rest is arithmetic, and done outside Lean. -/
theorem answer_world (ms : Nat → Word) (w p : Nat) (hw : 1 ≤ w ∧ w ≤ 6) :
    ((wgen ms (lift (patient w p ANSWER)) 64).t = 0 ↔ ∀ g < 64, born (gen (patient w p ANSWER) g) &&& ms g = 0)
    ∧ divisions (patient w p ANSWER) 64 = D w := by
  obtain ⟨d, g⟩ := answer_zero (w - 1) (by omega)
  rw [show w - 1 + 1 = w by omega] at d g
  refine ⟨?_, by rw [divisions_iter]; exact d⟩
  rw [cured_iff]
  have : (gen (patient w p ANSWER) 64).t = 0 := (gone_iter w p 64 ANSWER).2 g
  simp only [this, true_and]

#print axioms lives
#print axioms from_boot
#print axioms still
#print axioms resistance_stays
#print axioms cured_iff
#print axioms zero_stays
#print axioms answer_world

end Exp234

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp234.image
  | _ => pure ()
  for (i, k) in Exp234.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
