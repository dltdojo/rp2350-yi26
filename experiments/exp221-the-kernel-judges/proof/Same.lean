/-
SPDX-License-Identifier: Apache-2.0

# exp221 — the kernel that judges

Seventy-three RV32IM instructions that compare sixteen words at `base +
0x1000` with sixteen at `base + 0x2000`, with no early exit, and halt with
0 if every pair matched and 1 if any did not — writing nothing. On the chip
the first sixteen are what exp220's two PIO blocks gave back one way round
and the second sixteen the other way round, so the kernel, not the shell,
decides whether the two orders agreed.

  0     auipc s0, 0                  s0 = base
  1-2   s1 = base + 0x1000           the first list
  3-4   s2 = base + 0x2000           the second
  5     s6 = 0                       the accumulator
  6-37  words 0..7:  lw t2; lw t3; xor t2, t2, t3; or s6, s6, t2
  38-69 words 8..15: the same, 32 bytes on
  70    sltu a0, x0, s6              a0 = (s6 ≠ 0)
  71    addi t0, x0, 1
  72    ecall                        HALT a0

The two compare blocks are `lean/Rv32/Blocks.lean`'s `compare_words`, which
exp204 and exp205 already stand on.
-/
import Rv32.Blocks
import Rv32.Asm

namespace Exp221
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S6 : Reg := 22
def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28

def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S1 S0 T1,
  .lui T1 2, .op .add S2 S0 T1,
  .opi .addi S6 0 0 ]

def compare (o : Nat) : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T2 S1 (BitVec.ofNat 12 (o + 4 * j)), .ld .lw T3 S2 (BitVec.ofNat 12 (o + 4 * j)),
     .op .xor T2 T2 T3, .op .or S6 S6 T2]

def finish : List Instr := [ .op .sltu A0 0 S6, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := setup ++ compare 0 ++ compare 32 ++ finish

/-- The kernel as bytes: `kernel.bin`, and the only thing on the chip the
theorems are about. -/
def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 73 := by decide

/-- The two lists. -/
def FIRST : Nat := 0x1000
def SECOND : Nat := 0x2000

/-- Word `j` of a list at offset `o` from `base`. -/
def word (m : Word → Byte) (base : Word) (o j : Nat) : Nat := readLE m (base + BitVec.ofNat 32 (o + 4 * j)) 4

/-- **The two lists are the same**, word by word. -/
def Same (m : Word → Byte) (base : Word) : Prop := ∀ j < 16, word m base FIRST j = word m base SECOND j

instance (m : Word → Byte) (base : Word) : Decidable (Same m base) := by unfold Same; infer_instance

theorem at_cmp (o k0 : Nat) (h : (o = 0 ∧ k0 = 6) ∨ (o = 32 ∧ k0 = 38)) : ∀ j < 8,
    kernel.getD (k0 + 4 * j) .ecall = .ld .lw T2 S1 (BitVec.ofNat 12 (o + 4 * j))
    ∧ kernel.getD (k0 + 4 * j + 1) .ecall = .ld .lw T3 S2 (BitVec.ofNat 12 (o + 4 * j))
    ∧ kernel.getD (k0 + 4 * j + 2) .ecall = .op .xor T2 T2 T3
    ∧ kernel.getD (k0 + 4 * j + 3) .ecall = .op .or S6 S6 T2 := by
  rcases h with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> decide

/-- Six instructions that only set registers. -/
theorem setup_regs {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 6 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 6) ∧ s'.mem = s.mem
      ∧ s'.reg S1 = base + BitVec.ofNat 32 FIRST ∧ s'.reg S2 = base + BitVec.ofNat 32 SECOND
      ∧ s'.reg S6 = 0 := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) hc1 p1
      (i := .lui T1 1) (by decide) rfl
  have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) hc2 p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) hc3 p3
      (i := .lui T1 2) (by decide) rfl
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) hc4 p4
      (i := .op .add S2 S0 T1) (by decide) rfl
  have hc5 : CodeAt s5.mem base kernel := by rw [m5]; exact hc4
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) hc5 p5
      (i := .opi .addi S6 0 0) (by decide) rfl
  refine ⟨s6, run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 e6)))), p6,
    by rw [m6, m5, m4, m3, m2, m1], ?_, ?_, ?_⟩ <;>
    simp [r6, r5, r4, r3, r2, r1, hpc, S0, S1, S2, S6, T1, aluR, aluI, FIRST, SECOND] <;> rfl

/-- Setup and both compare blocks: the accumulator is zero exactly when the
lists are the same, and memory is untouched. -/
theorem compared {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 70 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 70) ∧ s'.mem = s.mem
      ∧ (s'.reg S6 = 0 ↔ Same s.mem base) := by
  obtain ⟨s6, e6, p6, m6, h1, h2, h0⟩ := setup_regs hp s hpc hcode
  have hc6 : CodeAt s6.mem base kernel := by rw [m6]; exact hcode
  obtain ⟨sa, ea, pa, ma, za, ka⟩ := compare_words (prog := kernel) hp (k0 := 6) (oa := 0) (ob := 0)
    (a := FIRST) (b := SECOND) (at_cmp 0 6 (.inl ⟨rfl, rfl⟩)) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) p6 hc6 h1 h2 (by decide) 8 (Nat.le_refl _)
  have hca : CodeAt sa.mem base kernel := by rw [ma]; exact hc6
  obtain ⟨sb, eb, pb, mb, zb, -⟩ := compare_words (prog := kernel) hp (k0 := 38) (oa := 32) (ob := 32)
    (a := FIRST) (b := SECOND) (at_cmp 32 38 (.inr ⟨rfl, rfl⟩)) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) pa hca
    (by rw [ka _ (by decide) (by decide) (by decide), h1]) (by rw [ka _ (by decide) (by decide) (by decide), h2])
    (by decide) 8 (Nat.le_refl _)
  refine ⟨sb, ?_, pb, by rw [mb, ma, m6], ?_⟩
  · rw [show 70 = 6 + (32 + 32) by rfl, run_add_running e6, run_add_running ea, eb]
  · rw [zb, za, h0, ma, m6]
    simp only [true_and, Same, word, FIRST, SECOND]
    constructor
    · rintro ⟨h0', h8⟩ j hj
      rcases (by omega : j < 8 ∨ 8 ≤ j) with hl | hl
      · simpa using h0' j hl
      · have := h8 (j - 8) (by omega)
        rw [show 0x1000 + 32 + 4 * (j - 8) = 0x1000 + 4 * j by omega,
          show 0x2000 + 32 + 4 * (j - 8) = 0x2000 + 4 * j by omega] at this
        exact this
    · intro hall
      refine ⟨fun j hj => by simpa using hall j (by omega), fun j hj => ?_⟩
      have := hall (j + 8) (by omega)
      rw [show 0x1000 + 4 * (j + 8) = 0x1000 + 32 + 4 * j by omega,
        show 0x2000 + 4 * (j + 8) = 0x2000 + 32 + 4 * j by omega] at this
      exact this

/-! ## The bytes are the kernel -/

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 292 ≤ img.size)
    (himg : ∀ d (h : d < 292), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **The kernel judges.** From `base`, with the kernel's 292 bytes there, it
halts after exactly 73 instructions — whatever the lists hold — with 0 if
the two lists of sixteen words are the same and 1 if they are not, and
memory just as it was. -/
theorem judges {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    (∃ s1, run env 72 s = .running s1) ∧
    ∃ s', run env 73 s = .halted (if Same s.mem base then 0 else 1) s' ∧ s'.mem = s.mem := by
  obtain ⟨s70, e70, p70, m70, z⟩ := compared hp s hpc hcode
  have hc : CodeAt s70.mem base kernel := by rw [m70]; exact hcode
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 70 (by decide) hc p70
    (i := .op .sltu A0 0 S6) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 71 (by decide) (by rw [m1]; exact hc) p1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : s2.reg T0 = 1 := by rw [reg_wrote r2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : s2.reg A0 = if Same s.mem base then 0 else 1 := by
    rw [reg_kept r2 (by decide), reg_wrote r1 (by decide)]
    simp only [aluR, reg_zero]
    rw [sltu_zero]
    by_cases hv : Same s.mem base
    · simp [hv, z.mpr hv]
    · have hn : ¬ s70.reg S6 = 0 := fun e => hv (z.mp e)
      rw [ite_eq_right_of_eq_false _ _ (eq_false hn), ite_eq_right_of_eq_false _ _ (eq_false hv)]
  have e72 : run env 72 s = .running s2 := by
    rw [show 72 = 70 + (1 + 1) by rfl, run_add_running e70, run_cons e1 e2]
  refine ⟨⟨s2, e72⟩, s2, ?_, by rw [m2, m1, m70]⟩
  rw [show 73 = 72 + 1 by rfl, run_add_running e72, ← a0]
  exact (step_of_code (k := 72) (by rw [kernel_length]; decide) (by rw [m2, m1]; exact hc)
      (by rw [p2])
      (by rw [p2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [p2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[72]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-- **From the state the shell builds**: any image that begins with the
kernel's 292 bytes. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 292 ≤ img.size) (himg : ∀ d (h : d < 292), img.get d (by omega) = bytes.getD d 0) :
    ∃ s', run env 73 (boot env.region img)
        = .halted (if Same (memOfImage base img) base then 0 else 1) s'
      ∧ s'.mem = memOfImage base img := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  obtain ⟨-, s', e, h⟩ := judges hp _ hpc hcode
  rw [hmem] at e h
  exact ⟨s', e, h⟩

#print axioms bytes_words
#print axioms compared
#print axioms judges
#print axioms from_boot

end Exp221

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp221.image
  | _ => pure ()
  for (i, k) in Exp221.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
