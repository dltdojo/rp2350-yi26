/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-2 — the hash tested first

Before a kernel trusts `HASH` with its samples, it asks `HASH` for the digest
of 64 bytes whose digest it already has, and stops if the answer differs.
Then SP 800-90B's start-up test (§4.3 item 4: the continuous tests over at
least 1024 consecutive samples), whose samples are discarded, and one more
window, the repetition count carried across the edge, whose digest is the
output.

   0       s0 = base
   1-6     HASH of the 64 bytes at 0x300, to 0x360 (the KAT's scratch)
   7-38    the 32 bytes at 0x360 against the 32 at 0x340, eight words, no
           early exit (`Blocks.compare_words`); s6 = 0 iff all equal
   39      bne s6 → KAT FAIL
   40-42   s1 = base + 0x400, s4 = 2 (no sample yet), s5 = 0
   43-66   window 0, the start-up test (`Alice.Window.win`)
   67      bne s6 → START FAIL
   68-91   window 1
   92      bne s6 → FAIL
   93-99   HASH of window 1's 4096 bytes, to base + 0x2400
   100     HALT 0
   103     START FAIL: HALT 1
   106     KAT FAIL: HALT 2
   109     FAIL: HALT 3
-/
import Alice.Window
import Alice.Addr
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Flow

set_option maxRecDepth 20000

namespace Trust
open Rv32 Rv32.Health Alice.Window Alice.Addr

def katSet : List Instr := [
  .opi .addi A0 S0 0x300, .opi .addi A1 0 64, .opi .addi A2 S0 0x360, .opi .addi T0 0 0, .opi .addi S6 0 0 ]

def katCmp : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T1 A2 (BitVec.ofNat 12 (4 * j)), .ld .lw T2 S0 (BitVec.ofNat 12 (0x340 + 4 * j)),
     .op .xor T1 T1 T2, .op .or S6 S6 T1]

def healthSet : List Instr := [ .opi .addi S1 S0 0x400, .opi .addi S4 0 2, .opi .addi S5 0 0 ]

/-- `a0` = the window just tested, `a1` = 4096, `a2` = where it ends, `t0` = HASH.
Two lines for the proof's sake: `simp` over all six at once, the two
`addi …, -2048` and the `slli` together, ran out of 13 GB. -/
def outA : List Instr := [ .opi .addi A0 S1 0x800, .opi .addi A0 A0 0x800 ]
def outB : List Instr := [ .opi .addi A1 0 1, .sh .slli A1 A1 12, .opi .addi A2 S1 0, .opi .addi T0 0 0 ]
def outSet : List Instr := outA ++ outB

def halt (c : Nat) : List Instr := [ .opi .addi A0 0 (BitVec.ofNat 12 c), .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  [.auipc S0 0] ++ katSet ++ [.ecall] ++ katCmp ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (106 - 39)))]
  ++ healthSet ++ win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (103 - 67)))]
  ++ win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (109 - 92)))]
  ++ outSet ++ [.ecall] ++ halt 0 ++ halt 1 ++ halt 2 ++ halt 3

theorem kernel_length : kernel.length = 112 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-! ## The specification -/

def KMSG : Nat := 0x300
def KWANT : Nat := 0x340
def KGOT : Nat := 0x360
def SMP : Nat := 0x400
def OUT : Nat := 0x2400

/-- The KAT's 64-byte message, as HASH reads it. -/
def katMsg (m : Word → Byte) (base : Word) : List Byte := readBytes m (base + BitVec.ofNat 32 KMSG) 64

/-- **The hash passed its known-answer test**: what `H` gives for the image's
message is, byte for byte, the digest the image says it should be. -/
def Trusted (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Prop :=
  ∀ i : Fin 32, H (katMsg m base) i = m (base + BitVec.ofNat 32 (KWANT + i))

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Decidable (Trusted H m base) := by
  unfold Trusted; infer_instance

/-- The halt code: 2 if the hash failed its KAT, 1 if the start-up window
failed, 3 if the next did, 0 if the output was written. -/
def code (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Word :=
  if ¬ Trusted H m base then 2 else if ¬ WinOk m base SMP 0 then 1 else if ¬ WinOk m base SMP 1 then 3 else 0

/-- Instructions to the halt. -/
def cost (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Nat :=
  if ¬ Trusted H m base then 43 else if ¬ WinOk m base SMP 0 then 17462
  else if ¬ WinOk m base SMP 1 then 34878 else 34885

/-- Memory once the KAT has run: its answer at the scratch. -/
def katted (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Word → Byte :=
  writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base))

/-- Memory at the halt: the KAT's answer at its scratch, always; the output,
`H` of window 1's bytes, only when everything passed. -/
def after (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Word → Byte :=
  if Trusted H m base ∧ WinOk m base SMP 0 ∧ WinOk m base SMP 1 then
    writeBytes (katted H m base) (base + BitVec.ofNat 32 OUT) (H (windowBytes m base SMP 1))
  else katted H m base

/-! ## The KAT's scratch, and what it leaves alone -/

variable {env : Env} {base : Word}

/-- Byte `i` of what HASH wrote at offset `o`. -/
theorem writeBytes_in (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (f : Fin 32 → Byte) {o i : Nat}
    (hi : i < 32) (ho : o + 32 ≤ 0x10000) :
    writeBytes m (base + BitVec.ofNat 32 o) f (base + BitVec.ofNat 32 (o + i)) = f ⟨i, hi⟩ := by
  rw [writeBytes_apply]
  have : (base + BitVec.ofNat 32 (o + i) - (base + BitVec.ofNat 32 o)).toNat = i := by
    rw [← off_add hfit o i (by omega), BitVec.add_comm (base + BitVec.ofNat 32 o), BitVec.add_sub_cancel,
      BitVec.toNat_ofNat]; omega
  simp only [this, hi, ↓reduceDIte]

/-- **The comparison the kernel makes is the KAT**: the eight words at the
scratch equal the eight at the expected digest exactly when the hash passed. -/
theorem compare_iff (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte) :
    (∀ j < 8, readLE (writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base)))
                (base + BitVec.ofNat 32 (KGOT + 0 + 4 * j)) 4
          = readLE (writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base)))
                (base + BitVec.ofNat 32 (0 + KWANT + 4 * j)) 4)
      ↔ Trusted H m base := by
  have got : ∀ i (hi : i < 32), writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base))
      (base + BitVec.ofNat 32 (KGOT + i)) = H (katMsg m base) ⟨i, hi⟩ :=
    fun i hi => writeBytes_in hfit _ _ hi (by simp only [KGOT] <;> omega)
  have want : ∀ i, i < 32 → writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base))
      (base + BitVec.ofNat 32 (KWANT + i)) = m (base + BitVec.ofNat 32 (KWANT + i)) :=
    fun i hi => (keeps_writeBytes hfit m _ (S := KGOT) (N := 32) (c := KGOT) (Nat.le_refl _) (Nat.le_refl _)
      (by simp only [KGOT] <;> omega)).off hfit (by simp only [KGOT] <;> omega) (by simp only [KWANT]; omega)
      (Or.inl (by simp only [KGOT, KWANT]; omega))
  constructor
  · intro h i
    obtain ⟨i, hi⟩ := i
    have hj := h (i / 4) (by omega)
    have b1 := readLE_four_byte (writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base)))
      (base + BitVec.ofNat 32 (KGOT + 0 + 4 * (i / 4))) (i % 4) (Nat.mod_lt _ (by decide))
    have b2 := readLE_four_byte (writeBytes m (base + BitVec.ofNat 32 KGOT) (H (katMsg m base)))
      (base + BitVec.ofNat 32 (0 + KWANT + 4 * (i / 4))) (i % 4) (Nat.mod_lt _ (by decide))
    rw [hj, b2, off_add hfit _ _ (by simp only [KWANT]; omega)] at b1
    rw [off_add hfit _ _ (by simp only [KGOT] <;> omega)] at b1
    rw [show KGOT + 0 + 4 * (i / 4) + i % 4 = KGOT + i by omega, got i hi,
      show 0 + KWANT + 4 * (i / 4) + i % 4 = KWANT + i by omega, want i hi] at b1
    exact b1.symm
  · intro h j hj
    apply readLE_four_eq
    intro d hd
    rw [off_add hfit _ _ (by simp only [KGOT] <;> omega), off_add hfit _ _ (by simp only [KWANT]; omega),
      show KGOT + 0 + 4 * j + d = KGOT + (4 * j + d) by omega, got _ (by omega),
      show 0 + KWANT + 4 * j + d = KWANT + (4 * j + d) by omega, want _ (by omega)]
    exact h ⟨4 * j + d, by omega⟩

/-! ## The known-answer test -/

theorem hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide

theorem cmp_at : ∀ j < 8, kernel.getD (7 + 4 * j) .ecall = .ld .lw T1 A2 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (7 + 4 * j + 1) .ecall = .ld .lw T2 S0 (BitVec.ofNat 12 (KWANT + 4 * j))
    ∧ kernel.getD (7 + 4 * j + 2) .ecall = .op .xor T1 T1 T2
    ∧ kernel.getD (7 + 4 * j + 3) .ecall = .op .or S6 S6 T1 := by
  intro j hj
  obtain rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3 ∨ j = 4 ∨ j = 5 ∨ j = 6 ∨ j = 7 := by
    omega
  all_goals exact ⟨rfl, rfl, rfl, rfl⟩

/-- **The KAT**: 39 instructions from the boot state. The KAT's answer is at
its scratch, nothing else is written, and `s6` is zero exactly when the hash
passed. -/
theorem kat_run (hp : Placed env base) (s : Machine) (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 39 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 39)
      ∧ s'.mem = katted env.hash s.mem base
      ∧ s'.reg S0 = base
      ∧ (s'.reg S6 = 0 ↔ Trusted env.hash s.mem base) := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep hp 0 (by rw [kernel_length]; decide) hcode (by simpa using hpc)
    (i := .auipc S0 0) (by decide) (rd := S0) (v := s.pc + ((0 : BitVec 20) ++ 0#12)) rfl hlen
  have h0 : s1.reg S0 = base := by
    rw [reg_wrote r1 (by decide), hpc, show ((0 : BitVec 20) ++ 0#12) = (0 : Word) by decide]; simp
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have e2 := run_line hp katSet (by decide) 1 s1 (by decide) (by rw [kernel_length]; decide) hc1 p1 hlen
  generalize hs2 : s1.line katSet = s2 at e2
  have ga0 : s2.reg A0 = base + BitVec.ofNat 32 KMSG := by
    have : s2.reg A0 = s1.reg S0 + (0x300 : BitVec 12).signExtend 32 := by
      rw [← hs2]; simp [Machine.line, katSet, Machine.alu, reg_setReg, aluI, S0, A0, A1, A2, T0, S6]
    rw [this, h0, show (0x300 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x300 from se_small 0x300 (by decide)]; rfl
  have ga2 : s2.reg A2 = base + BitVec.ofNat 32 KGOT := by
    have : s2.reg A2 = s1.reg S0 + (0x360 : BitVec 12).signExtend 32 := by
      rw [← hs2]; simp [Machine.line, katSet, Machine.alu, reg_setReg, aluI, S0, A0, A1, A2, T0, S6]
    rw [this, h0, show (0x360 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x360 from se_small 0x360 (by decide)]; rfl
  have ga1 : s2.reg A1 = BitVec.ofNat 32 64 := by
    rw [← hs2]; simp [Machine.line, katSet, Machine.alu, reg_setReg, aluI, S0, A0, A1, A2, T0, S6]
  have gt0 : s2.reg T0 = 0 := by
    rw [← hs2]; simp [Machine.line, katSet, Machine.alu, reg_setReg, aluI, S0, A0, A1, A2, T0, S6]
  have g6 : s2.reg S6 = 0 := by
    rw [← hs2]; simp [Machine.line, katSet, Machine.alu, reg_setReg, aluI, S0, A0, A1, A2, T0, S6]
  have g0 : s2.reg S0 = base := by
    rw [← hs2, line_keeps _ _ S0 (by simp [katSet, rdOf, S0, A0, A1, A2, T0, S6]), h0]
  have p2 : s2.pc = base + BitVec.ofNat 32 (4 * 6) := by
    rw [← hs2, line_pc_at katSet p1 (by rw [show katSet.length = 5 by rfl]; decide)]; rfl
  have m2 : s2.mem = s.mem := by rw [← hs2, line_mem, m1]
  have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hcode
  -- HASH of the KAT's message
  have hexec := exec_hash (env := env) (s := s2) gt0 (by rw [ga1]; decide)
    (by rw [ga0]; exact align_off hp.align hp.fit _ (by simp only [KMSG] <;> omega) (by simp only [KMSG] <;> omega))
    (by rw [ga2]; exact align_off hp.align hp.fit _ (by simp only [KGOT] <;> omega) (by simp only [KGOT] <;> omega))
    (by rw [ga0, ga1]; exact ok_off hp KMSG 64 (by simp only [KMSG] <;> omega) (by simp only [KMSG] <;> omega))
    (by rw [ga2]; exact ok_off hp KGOT 32 (by simp only [KGOT] <;> omega) (by simp only [KGOT] <;> omega))
  have eH := stepK hp 6 (by rw [kernel_length]; decide) hc2 p2 (by rfl) hexec 0 hlen
  generalize hsH : ({ s2 with mem := writeBytes s2.mem (s2.reg A2) (env.hash (readBytes s2.mem (s2.reg A0) (s2.reg A1).toNat)) } : Machine).next = sH at eH
  have eH1 : run env 1 s2 = .running sH := eH.trans (run_zero _ _)
  have mH : sH.mem = katted env.hash s.mem base := by
    rw [← hsH, next_mem]
    show writeBytes s2.mem (s2.reg A2) (env.hash (readBytes s2.mem (s2.reg A0) (s2.reg A1).toNat)) = _
    rw [ga2, ga0, ga1, m2]; rfl
  have kH : ∀ r, sH.reg r = s2.reg r := fun r => by rw [← hsH]; rfl
  have pH : sH.pc = base + BitVec.ofNat 32 (4 * 7) := by
    rw [← hsH, next_pc]; show s2.pc + 4 = _; rw [p2, pc_next hp.fit 6 (by decide)]
  have hcH : CodeAt sH.mem base kernel := by
    rw [mH]; unfold katted
    exact (keeps_writeBytes hp.fit s.mem _ (S := KGOT) (N := 32) (c := KGOT) (Nat.le_refl _) (Nat.le_refl _)
      (by simp only [KGOT] <;> omega)).code hp.fit (by simp only [KGOT] <;> omega)
      (by rw [kernel_length]; simp only [KGOT]; omega) hcode
  -- the eight words compared
  obtain ⟨sC, eC, pC, mC, zC, kC⟩ := compare_words hp (k0 := 7) (ra := A2) (rb := S0) (acc := S6) (t := T1) (u := T2)
    (oa := 0) (ob := KWANT) (a := KGOT) (b := 0) cmp_at (by rw [kernel_length]; decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) pH hcH (by rw [kH, ga2]) (by rw [kH, g0]; simp) hlen 8 (Nat.le_refl _)
  refine ⟨sC, ?_, by rw [pC], by rw [mC, mH], ?_, ?_⟩
  · rw [show 39 = 1 + (katSet.length + (1 + 4 * 8)) by rfl, run_add_running e1, run_add_running e2,
      run_add_running eH1, eC]
  · rw [kC S0 (by decide) (by decide) (by decide), kH, g0]
  · rw [zC, kH, g6, mH]
    simp only [true_and]
    exact compare_iff hp.fit env.hash s.mem

/-! ## What the KAT's write leaves alone -/

theorem katted_keeps (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte) :
    Keeps (base + BitVec.ofNat 32 KGOT) 32 m (katted H m base) :=
  keeps_writeBytes hfit m _ (S := KGOT) (N := 32) (c := KGOT) (Nat.le_refl _) (Nat.le_refl _)
    (by simp only [KGOT]; omega)

theorem katted_code (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) {m : Word → Byte}
    (hc : CodeAt m base kernel) : CodeAt (katted H m base) base kernel :=
  (katted_keeps hfit H m).code hfit (by simp only [KGOT]; omega) (by rw [kernel_length]; simp only [KGOT]; omega) hc

theorem katted_bit (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte) :
    ∀ j < 2 * N, bit (katted H m base) base SMP j = bit m base SMP j :=
  bit_of_keeps hfit (katted_keeps hfit H m) (by simp only [KGOT]; omega) (by simp only [SMP, N]; omega)
    (Or.inl (by simp only [KGOT, SMP]; omega))

theorem katted_winOk (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte)
    {w : Nat} (hw : w < 2) : WinOk (katted H m base) base SMP w ↔ WinOk m base SMP w :=
  winOk_congr (fun j hj => katted_bit hfit H m j (by simp only [N] at hj ⊢; omega))

theorem katted_rct (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte)
    {n : Nat} (hn : n ≤ 2 * N) : rct (katted H m base) base SMP n = rct m base SMP n :=
  rct_congr (fun j hj => katted_bit hfit H m j (by omega))

theorem katted_window (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte) :
    windowBytes (katted H m base) base SMP 1 = windowBytes m base SMP 1 :=
  windowBytes_of_keeps hfit (katted_keeps hfit H m) (by simp only [KGOT]; omega) (by simp only [SMP, N]; omega)
    (Or.inl (by simp only [KGOT, SMP, N]; omega))

/-! ## A halt -/

def haltSet (c : Nat) : List Instr := [ .opi .addi A0 0 (BitVec.ofNat 12 c), .opi .addi T0 0 1 ]

/-- `halt c` at `k`: two instructions running, the third halts with `c`; memory untouched. -/
theorem halts (hp : Placed env base) {c k : Nat} (hc : c < 2048) (hat : (kernel.drop k).take 2 = haltSet c)
    (hk : k + 3 ≤ kernel.length) (he : kernel.getD (k + 2) .ecall = .ecall) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 2 s = .running s' ∧ run env 1 s' = .halted (BitVec.ofNat 32 c) s' ∧ s'.mem = s.mem := by
  have hk' := hk; rw [kernel_length] at hk'
  have e := run_line hp (haltSet c) (by rfl) k s hat (by simp only [haltSet, List.length]; omega) hcode hpc hlen
  have gA0 : (s.line (haltSet c)).reg A0 = BitVec.ofNat 32 c := by
    have : (s.line (haltSet c)).reg A0 = 0 + (BitVec.ofNat 12 c).signExtend 32 := by
      simp [Machine.line, haltSet, Machine.alu, reg_setReg, aluI, A0, T0]
    rw [this, se_small c hc]; simp
  have gT0 : (s.line (haltSet c)).reg T0 = 1#32 := by
    simp [Machine.line, haltSet, Machine.alu, reg_setReg, aluI, A0, T0]
  have pH : (s.line (haltSet c)).pc = base + BitVec.ofNat 32 (4 * (k + 2)) :=
    line_pc_at (haltSet c) hpc (by simp only [haltSet, List.length]; omega)
  have hH := haltStep hp (k + 2) (by omega) (by rw [line_mem]; exact hcode) pH he gT0 hlen 0
  exact ⟨s.line (haltSet c), e, by rw [hH, gA0], line_mem _ _⟩

/-! ## A window and its branch -/

theorem at_win {w : Nat} (hw : w < 2) : Alice.Window.At kernel (43 + 25 * w) := by
  rcases (by omega : w = 0 ∨ w = 1) with rfl | rfl <;> exact ⟨rfl, by rw [kernel_length]; decide, hlen⟩

/-- Where window `w`'s branch goes when the window fails: START FAIL, then FAIL. -/
def failAt (w : Nat) : Nat := 103 + 6 * w

theorem at_bne {w : Nat} (hw : w < 2) :
    kernel.getD (67 + 25 * w) .ecall = .br .bne S6 0 (BitVec.ofNat 12 (2 * (failAt w - (67 + 25 * w)))) := by
  rcases (by omega : w = 0 ∨ w = 1) with rfl | rfl <;> rfl

theorem bne_off {w : Nat} (hw : w < 2) :
    BitVec.ofNat 32 (4 * (67 + 25 * w)) + ((BitVec.ofNat 12 (2 * (failAt w - (67 + 25 * w)))) ++ 0#1).signExtend 32
      = BitVec.ofNat 32 (4 * failAt w) := by
  rcases (by omega : w = 0 ∨ w = 1) with rfl | rfl
  · exact jump_ok (BitVec.ofNat 12 72) (by decide) 67 103 (by decide) (by decide) (by decide)
  · exact jump_ok (BitVec.ofNat 12 34) (by decide) 92 109 (by decide) (by decide) (by decide)

/-- **One window**: its block and its branch, 17416 instructions. If it failed,
at its FAIL; if it passed, at the next instruction, the run carried on in
`s4` and `s5`. Memory untouched; `s0` kept. -/
theorem window_step (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {w : Nat} (hw : w < 2)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * (43 + 25 * w)))
    (hmem : s.mem = katted env.hash m0 base)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * w))) (h6 : s.reg S6 = 0)
    (hok : (rct m0 base SMP (N * w)).bad = false)
    (h4 : s.reg S4 = BitVec.ofNat 32 (rct m0 base SMP (N * w)).last)
    (h5 : s.reg S5 = BitVec.ofNat 32 (rct m0 base SMP (N * w)).run) :
    ∃ s', run env (4 + 17 * N + 3 + 1) s = .running s' ∧ s'.mem = s.mem ∧ s'.reg S0 = s.reg S0
      ∧ (¬ WinOk m0 base SMP w → s'.pc = base + BitVec.ofNat 32 (4 * failAt w))
      ∧ (WinOk m0 base SMP w → s'.pc = base + BitVec.ofNat 32 (4 * (68 + 25 * w))
          ∧ s'.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * (w + 1))) ∧ s'.reg S6 = 0
          ∧ s'.reg S4 = BitVec.ofNat 32 (rct m0 base SMP (N * (w + 1))).last
          ∧ s'.reg S5 = BitVec.ofNat 32 (rct m0 base SMP (N * (w + 1))).run) := by
  have hcode : CodeAt s.mem base kernel := by rw [hmem]; exact katted_code hp.fit _ hc0
  have r0 : rct s.mem base SMP (N * w) = rct m0 base SMP (N * w) := by
    rw [hmem]; exact katted_rct hp.fit _ _ (by simp only [N]; omega)
  have r1 : rct s.mem base SMP (N * (w + 1)) = rct m0 base SMP (N * (w + 1)) := by
    rw [hmem]; exact katted_rct hp.fit _ _ (by simp only [N]; omega)
  have hokS : WinOk s.mem base SMP w ↔ WinOk m0 base SMP w := by
    rw [hmem]; exact katted_winOk hp.fit _ _ hw
  obtain ⟨sV, eV, pV, mV, g1, g6, g45, kV⟩ := win_run hp (at_win hw) (src := SMP) (w := w)
    (by simp only [SMP, N]; omega) (by decide) s (by rw [hpc]) hcode h1
    (by rw [h6, r0, hok]; rfl) (fun _ => by rw [r0]; exact ⟨h4, h5⟩)
  have hcV : CodeAt sV.mem base kernel := by rw [mV]; exact hcode
  obtain ⟨sB, eB, pB, mB, rB⟩ := brStep hp (67 + 25 * w) (by rw [kernel_length]; omega) hcV
    (by rw [pV, show 43 + 25 * w + 24 = 67 + 25 * w by omega]) (at_bne hw) (k' := failAt w) (bne_off hw) hlen
  refine ⟨sB, by rw [show 4 + 17 * N + 3 + 1 = (4 + 17 * N + 3) + 1 by rfl, run_add_running eV, eB],
    by rw [mB, mV], by rw [rB, kV S0 (by decide)], fun hbad => ?_, fun hgood => ?_⟩
  · have : sV.reg S6 = 1#32 := by rw [g6]; simp [show ¬ WinOk s.mem base SMP w from fun h => hbad (hokS.1 h)]
    rw [pB, this]; simp [taken]
  · have : sV.reg S6 = 0#32 := by rw [g6]; simp [hokS.2 hgood]
    refine ⟨by rw [pB, this, reg_zero, ite_eq_right (by decide), show 67 + 25 * w + 1 = 68 + 25 * w by omega],
      by rw [rB, g1], by rw [rB, this]; rfl, ?_, ?_⟩
    · rw [rB, ← r1]; exact (g45 (hokS.2 hgood)).1
    · rw [rB, ← r1]; exact (g45 (hokS.2 hgood)).2

/-! ## The output -/

/-- What `outB` leaves, for any machine: proved here, outside `output_run`,
because inside it the same `simp` (and `rfl`) on `a2` did not finish. -/
theorem outB_regs (s : Machine) : (s.line outB).reg A1 = BitVec.ofNat 32 4096
    ∧ (s.line outB).reg A2 = s.reg S1 ∧ (s.line outB).reg T0 = 0 := by
  refine ⟨?_, ?_, ?_⟩ <;> simp [Machine.line, outB, Machine.alu, reg_setReg, aluI, shiftI, A1, A2, S1, T0]

/-- **The output**: from instruction 93, with both windows passed, `s1` at the
end of the samples. Seven instructions, HASH of window 1 written at the
output, and the halt with 0 three after. -/
theorem output_run (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * 93)) (hmem : s.mem = katted env.hash m0 base)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * (1 + 1)))) :
    ∃ s', run env 7 s = .running s'
      ∧ s'.mem = writeBytes (katted env.hash m0 base) (base + BitVec.ofNat 32 OUT)
          (env.hash (windowBytes m0 base SMP 1))
      ∧ s'.pc = base + BitVec.ofNat 32 (4 * 100) := by
  have hcode : CodeAt s.mem base kernel := by rw [hmem]; exact katted_code hp.fit _ hc0
  have eA := run_line hp outA (by decide) 93 s (by rfl) (by rw [kernel_length]; decide) hcode hpc hlen
  generalize hsA : s.line outA = sA at eA
  have gA0 : sA.reg A0 = base + BitVec.ofNat 32 (SMP + 4 * (N * 1)) := by
    have : sA.reg A0 = s.reg S1 + (0x800 : BitVec 12).signExtend 32 + (0x800 : BitVec 12).signExtend 32 := by
      rw [← hsA]; simp [Machine.line, outA, Machine.alu, reg_setReg, aluI, A0, S1]
    rw [this, h1, back4096 _ (by simp only [SMP, N]; omega) (by simp only [SMP, N]; omega)]
    congr 2
  have kA : ∀ r, r ≠ A0 → sA.reg r = s.reg r := fun r hr => by
    rw [← hsA, line_keeps _ _ r (by simp [outA, rdOf]; exact Ne.symm hr)]
  have pA : sA.pc = base + BitVec.ofNat 32 (4 * 95) := by
    rw [← hsA, line_pc_at outA hpc (by rw [show outA.length = 2 by rfl]; decide)]; rfl
  have mA : sA.mem = s.mem := by rw [← hsA, line_mem]
  have eB := run_line hp outB (by decide) 95 sA (by rfl) (by rw [kernel_length]; decide)
    (by rw [mA]; exact hcode) pA hlen
  generalize hsP : sA.line outB = sP at eB
  have gB : sP.reg A1 = BitVec.ofNat 32 4096 ∧ sP.reg A2 = sA.reg S1 ∧ sP.reg T0 = 0 := by
    rw [← hsP]; exact outB_regs sA
  have gA1 : sP.reg A1 = BitVec.ofNat 32 4096 := gB.1
  have gT0 : sP.reg T0 = 0 := gB.2.2
  have gA2 : sP.reg A2 = base + BitVec.ofNat 32 OUT := by
    rw [gB.2.1, kA S1 (by decide), h1]; rfl
  have gA0' : sP.reg A0 = base + BitVec.ofNat 32 (SMP + 4 * (N * 1)) := by
    rw [← hsP, line_keeps _ _ A0 (by simp [outB, rdOf, A0, A1, A2, T0]), gA0]
  have pP : sP.pc = base + BitVec.ofNat 32 (4 * 99) := by
    rw [← hsP, line_pc_at outB pA (by rw [show outB.length = 4 by rfl]; decide)]; rfl
  have mP : sP.mem = katted env.hash m0 base := by rw [← hsP, line_mem, mA, hmem]
  have al0 : (sP.reg A0).toNat % 4 = 0 := by
    rw [gA0']; exact align_off hp.align hp.fit _ (by simp only [SMP, N]; omega) (by simp only [SMP, N] <;> omega)
  have al2 : (sP.reg A2).toNat % 4 = 0 := by
    rw [gA2]; exact align_off hp.align hp.fit _ (by simp only [OUT]; omega) (by simp only [OUT] <;> omega)
  have ok0 : env.region.ok (sP.reg A0) (sP.reg A1).toNat := by
    rw [gA0', gA1]
    exact ok_off hp (SMP + 4 * (N * 1)) 4096 (by simp only [SMP, N]; omega) (by simp only [SMP, N] <;> omega)
  have ok2 : env.region.ok (sP.reg A2) 32 := by
    rw [gA2]; exact ok_off hp OUT 32 (by simp only [OUT]; omega) (by simp only [OUT] <;> omega)
  have hexec := exec_hash (env := env) (s := sP) gT0 (by rw [gA1]; decide) al0 al2 ok0 ok2
  have eH := stepK hp 99 (by rw [kernel_length]; decide) (by rw [mP]; exact katted_code hp.fit _ hc0) pP
    (by rfl) hexec 0 hlen
  generalize hsH : ({ sP with mem := writeBytes sP.mem (sP.reg A2) (env.hash (readBytes sP.mem (sP.reg A0) (sP.reg A1).toNat)) } : Machine).next = sH at eH
  refine ⟨sH, ?_, ?_, ?_⟩
  · rw [show 7 = outA.length + (outB.length + 1) by rfl, run_add_running eA, run_add_running eB, eH, run_zero]
  · rw [← hsH, next_mem]
    show writeBytes sP.mem (sP.reg A2) (env.hash (readBytes sP.mem (sP.reg A0) (sP.reg A1).toNat)) = _
    -- the length as 4 * N before anything is compared: `rfl` against 4096
    -- would unfold `readBytes` 4096 deep (and did, to 13 GB)
    have hw4 : (sP.reg A1).toNat = 4 * N := by rw [gA1]; rfl
    rw [hw4, gA2, gA0', mP, ← katted_window hp.fit env.hash m0]
    unfold windowBytes
    rfl
  · rw [← hsH, next_pc]; show sP.pc + 4 = _; rw [pP, pc_next hp.fit 99 (by decide)]

/-! ## From the boot -/

theorem ends {a : Nat} {s s1 s2 : Machine} {c : Word} (h1 : run env a s = .running s1)
    (h2 : run env 2 s1 = .running s2) (h3 : run env 1 s2 = .halted c s2) :
    run env (a + 2) s = .running s2 ∧ run env (a + 3) s = .halted c s2 :=
  ⟨by rw [run_add_running h1, h2], by rw [show a + 3 = a + (2 + 1) by rfl, run_add_running h1, run_add_running h2, h3]⟩

/-- **From the boot**: the image starts with the kernel's 448 bytes. After
exactly `cost` instructions the kernel halts with `code` — 2 if the hash
failed its known-answer test, 1 if the start-up window failed, 3 if the
next did, 0 if neither — and memory is `after`: the image with the KAT's
answer at its scratch, and `HASH` of window 1's bytes at the output only
with 0. One instruction earlier it is still running. For any `HASH`. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 448 ≤ img.size)
    (himg : ∀ d (h : d < 448), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (cost env.hash (memOfImage base img) base - 1) (boot env.region img) = .running s1) ∧
    ∃ s', run env (cost env.hash (memOfImage base img) base) (boot env.region img)
        = .halted (code env.hash (memOfImage base img) base) s'
      ∧ s'.mem = after env.hash (memOfImage base img) base := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hc0 : CodeAt (memOfImage base img) base kernel :=
    code_of_image hp.fit (by rw [kernel_length]; decide) (toBytes_words kernel) img
      (by rw [kernel_length]; omega) (fun d h => himg d (by rw [kernel_length] at h; omega))
  generalize memOfImage base img = m0 at hc0 hmem ⊢
  generalize boot env.region img = s0 at hpc hmem ⊢
  obtain ⟨sK, eK, pK, mK, k0, zK⟩ := kat_run hp s0 hpc (by rw [hmem]; exact hc0)
  rw [hmem] at mK zK
  have hcK : CodeAt sK.mem base kernel := by rw [mK]; exact katted_code hp.fit _ hc0
  obtain ⟨sB, eB, pB, mB, rB⟩ := brStep hp 39 (by rw [kernel_length]; decide) hcK pK
    (op := .bne) (rs1 := S6) (rs2 := 0) (off := BitVec.ofNat 12 134) rfl (k' := 106)
    (jump_ok (BitVec.ofNat 12 134) (by decide) 39 106 (by decide) (by decide) (by decide)) hlen
  have hcB : CodeAt sB.mem base kernel := by rw [mB]; exact hcK
  by_cases hT : Trusted env.hash m0 base
  · have h6 : sK.reg S6 = 0 := zK.2 hT
    have pB' : sB.pc = base + BitVec.ofNat 32 (4 * 40) := by
      rw [pB, h6, reg_zero, ite_eq_right (by decide)]
    have eS := run_line hp healthSet (by decide) 40 sB (by rfl) (by rw [kernel_length]; decide) hcB pB' hlen
    generalize hsS : sB.line healthSet = sS at eS
    have gS1 : sS.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * 0)) := by
      have : sS.reg S1 = sB.reg S0 + (0x400 : BitVec 12).signExtend 32 := by
        rw [← hsS]; simp [Machine.line, healthSet, Machine.alu, reg_setReg, aluI, S0, S1, S4, S5]
      rw [this, rB, k0, show (0x400 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x400 from se_small 0x400 (by decide)]
      rfl
    have gS4 : sS.reg S4 = BitVec.ofNat 32 (rct m0 base SMP (N * 0)).last := by
      rw [← hsS]; simp [Machine.line, healthSet, Machine.alu, reg_setReg, aluI, S0, S1, S4, S5, rct, bits, rctInit]
    have gS5 : sS.reg S5 = BitVec.ofNat 32 (rct m0 base SMP (N * 0)).run := by
      rw [← hsS]; simp [Machine.line, healthSet, Machine.alu, reg_setReg, aluI, S0, S1, S4, S5, rct, bits, rctInit]
    have gS6 : sS.reg S6 = 0 := by
      rw [← hsS, line_keeps _ _ S6 (by simp [healthSet, rdOf, S1, S4, S5, S6]), rB, h6]
    have gS0 : sS.reg S0 = base := by
      rw [← hsS, line_keeps _ _ S0 (by simp [healthSet, rdOf, S0, S1, S4, S5]), rB, k0]
    have pS : sS.pc = base + BitVec.ofNat 32 (4 * (43 + 25 * 0)) := by
      rw [← hsS, line_pc_at healthSet pB' (by rw [show healthSet.length = 3 by rfl]; decide)]; rfl
    have mS : sS.mem = katted env.hash m0 base := by rw [← hsS, line_mem, mB, mK]
    have e0 : run env (39 + 1 + 3) s0 = .running sS := by
      rw [show 39 + 1 + 3 = 39 + (1 + healthSet.length) by rfl, run_add_running eK, run_add_running eB, eS]
    obtain ⟨sW, eW, mW, kW, fW, gW⟩ := window_step hp hc0 (w := 0) (by decide) pS mS gS1 gS6
      (by simp [rct, bits, rctInit]) gS4 gS5
    have e1 : run env (39 + 1 + 3 + (4 + 17 * N + 3 + 1)) s0 = .running sW := by rw [run_add_running e0, eW]
    by_cases hW0 : WinOk m0 base SMP 0
    · obtain ⟨pW, w1, w6, w4, w5⟩ := gW hW0
      obtain ⟨sX, eX, mX, kX, fX, gX⟩ := window_step hp hc0 (w := 1) (by decide) pW (by rw [mW, mS]) w1 w6
        hW0.1 w4 w5
      have e2 := (run_add_running e1).trans eX
      by_cases hW1 : WinOk m0 base SMP 1
      · obtain ⟨pX, x1, -, -, -⟩ := gX hW1
        obtain ⟨sO, eO, mO, pO⟩ := output_run hp hc0 pX (by rw [mX, mW, mS]) x1
        have e3 := (run_add_running e2).trans eO
        have kO : Keeps (base + BitVec.ofNat 32 OUT) 32 (katted env.hash m0 base)
            (writeBytes (katted env.hash m0 base) (base + BitVec.ofNat 32 OUT) (env.hash (windowBytes m0 base SMP 1))) :=
          keeps_writeBytes hp.fit _ _ (Nat.le_refl _) (Nat.le_refl _) (by simp only [OUT]; omega)
        have cO : CodeAt sO.mem base kernel := by
          rw [mO]
          exact kO.code hp.fit (by simp only [OUT]; omega) (by rw [kernel_length]; simp only [OUT]; omega)
            (katted_code hp.fit _ hc0)
        obtain ⟨sZ, eZ2, eZ1, mZ⟩ := halts hp (c := 0) (k := 100) (by decide) rfl (by rw [kernel_length]; decide) rfl pO cO
        have fin := ends e3 eZ2 eZ1
        simp only [cost, code, after, hT, hW0, hW1, not_true_eq_false, ↓reduceIte, and_self]
        exact ⟨⟨sZ, fin.1⟩, sZ, fin.2, by rw [mZ, mO]⟩
      · obtain ⟨sZ, eZ2, eZ1, mZ⟩ := halts hp (c := 3) (k := 109) (by decide) rfl (by rw [kernel_length]; decide) rfl
          (fX hW1) (by rw [mX, mW, mS]; exact katted_code hp.fit _ hc0)
        have fin := ends e2 eZ2 eZ1
        simp only [cost, code, after, hT, hW0, hW1, not_true_eq_false, not_false_eq_true, ↓reduceIte, and_false]
        exact ⟨⟨sZ, fin.1⟩, sZ, fin.2, by rw [mZ, mX, mW, mS]⟩
    · obtain ⟨sZ, eZ2, eZ1, mZ⟩ := halts hp (c := 1) (k := 103) (by decide) rfl (by rw [kernel_length]; decide) rfl
        (fW hW0) (by rw [mW, mS]; exact katted_code hp.fit _ hc0)
      have fin := ends e1 eZ2 eZ1
      simp only [cost, code, after, hT, hW0, not_true_eq_false, not_false_eq_true, ↓reduceIte, false_and, and_false]
      exact ⟨⟨sZ, fin.1⟩, sZ, fin.2, by rw [mZ, mW, mS]⟩
  · have h6 : sK.reg S6 ≠ 0 := fun h => hT (zK.1 h)
    have pB' : sB.pc = base + BitVec.ofNat 32 (4 * 106) := by
      have h6' : sK.reg S6 ≠ 0#32 := h6
      rw [pB, reg_zero]; simp [taken, h6']
    obtain ⟨sZ, eZ2, eZ1, mZ⟩ := halts hp (c := 2) (k := 106) (by decide) rfl (by rw [kernel_length]; decide) rfl
      pB' hcB
    have fin := ends ((run_add_running eK).trans eB) eZ2 eZ1
    simp only [cost, code, after, hT, not_false_eq_true, ↓reduceIte, false_and]
    exact ⟨⟨sZ, fin.1⟩, sZ, fin.2, by rw [mZ, mB, mK]⟩

/-- **Trusted only after its known-answer test** (the plan's
`trusts_after_kat`), for any `HASH`:

* if the hash fails its KAT, the kernel halts with 2 after 43 instructions,
  and the only bytes it has written are its answer, at the KAT's scratch;
* if it halts with 0, the hash passed its KAT, and the 32 bytes at the
  output are `HASH` of window 1's bytes: the start-up window's samples are in
  no output byte. -/
theorem trusts_after_kat (hp : Placed env base) (img : ByteArray) (hsize : 448 ≤ img.size)
    (himg : ∀ d (h : d < 448), img.get d (by omega) = bytes.getD d 0) :
    (¬ Trusted env.hash (memOfImage base img) base →
      ∃ s', run env 43 (boot env.region img) = .halted 2 s'
        ∧ s'.mem = katted env.hash (memOfImage base img) base) ∧
    (∀ s', run env (cost env.hash (memOfImage base img) base) (boot env.region img) = .halted 0 s' →
      Trusted env.hash (memOfImage base img) base ∧ ∀ i : Fin 32,
        s'.mem (base + BitVec.ofNat 32 (OUT + i)) = env.hash (windowBytes (memOfImage base img) base SMP 1) i) := by
  obtain ⟨-, s'', e, m⟩ := from_boot hp img hsize himg
  generalize memOfImage base img = m0 at e m ⊢
  refine ⟨fun hT => ?_, fun s' h => ?_⟩
  · simp only [cost, code, after, hT, not_false_eq_true, ↓reduceIte, false_and] at e m
    exact ⟨s'', e, m⟩
  · rw [e] at h
    injection h with hc hs
    subst hs
    by_cases hT : Trusted env.hash m0 base
    · by_cases hW0 : WinOk m0 base SMP 0
      · by_cases hW1 : WinOk m0 base SMP 1
        · simp only [after, hT, hW0, hW1, and_self, ↓reduceIte] at m
          refine ⟨hT, fun i => ?_⟩
          rw [m]
          exact writeBytes_in hp.fit _ _ i.isLt (by simp only [OUT]; omega)
        · simp only [code, hT, hW0, hW1, not_true_eq_false, not_false_eq_true, ↓reduceIte] at hc
          exact absurd hc (by decide)
      · simp only [code, hT, hW0, not_true_eq_false, not_false_eq_true, ↓reduceIte] at hc
        exact absurd hc (by decide)
    · simp only [code, hT, not_false_eq_true, ↓reduceIte] at hc
      exact absurd hc (by decide)

end Trust
