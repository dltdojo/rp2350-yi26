/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-1 — the run across the seam

SP 800-90B's repetition count and adaptive proportion tests over four windows
of 1024 samples, the repetition count carried across every window's edge, and
nothing written after the first window that fails.

The samples are at base + 0x400, four windows one after another, one sample
in bit 0 of each word. For each window in turn the kernel runs both tests
(`Alice.Window.win`). If the window passes, it asks `HASH` for the 32 bytes of
its 4096 and writes them at base + 0x4400 + 32w, and goes on to the next. If
it fails, it halts at once with the window's number, 1 to 4. If all four
pass, it halts with 0.

   0-11    s1 = base + 0x400 (the samples), a2 = base + 0x4400 (where the
           first digest goes), a1 = 4096 and t0 = 0 (HASH's length and
           call); s4 = 2 (no sample yet), s5 = 0 (the run), s6 = 0 (no
           failure), s2 = 0 (windows passed)
   12 + 30w  window w:
     +0    win: the reference, the counts, 1024 samples, the verdict in s6
     +24   bne s6, x0 → FAIL
     +25   a0 = s1 - 4096; HASH; a2 += 32; s2 += 1
   132     HALT 0
   135     FAIL: HALT s2 + 1

Nothing between the setup and the halt writes `a1`, `a2` (but the step
after each HASH) or `t0`: the window's block leaves every register outside
`Health.written` alone, and HASH writes only memory.
-/
import Alice.Window
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Flow

set_option maxRecDepth 20000

namespace Seam
open Rv32 Rv32.Health Alice.Window

def init : List Instr := [
  .opi .addi S1 S0 0x400, .opi .addi T1 0 1, .sh .slli T1 T1 14, .op .add A2 S1 T1,
  .opi .addi A1 0 1, .sh .slli A1 A1 12, .opi .addi T0 0 0,
  .opi .addi S4 0 2, .opi .addi S5 0 0, .opi .addi S6 0 0, .opi .addi S2 0 0 ]

/-- After a window passes: HASH of the 4096 bytes before `s1`, to `a2`. -/
def preHash : List Instr := [ .opi .addi A0 S1 0x800, .opi .addi A0 A0 0x800 ]
def postHash : List Instr := [ .opi .addi A2 A2 32, .opi .addi S2 S2 1 ]

/-- Window `w`: its tests, the branch to FAIL at 135 from 36 + 30w, its digest. -/
def window (w : Nat) : List Instr :=
  win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (99 - 30 * w)))] ++ preHash ++ [.ecall] ++ postHash

def passLine : List Instr := [ .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]
def failLine : List Instr := [ .opi .addi A0 S2 1, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  [.auipc S0 0] ++ init ++ window 0 ++ window 1 ++ window 2 ++ window 3 ++ passLine ++ failLine

theorem kernel_length : kernel.length = 138 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-! ## The specification -/

def SMP : Nat := 0x400
def DIG : Nat := 0x4400

/-- The 4096 bytes of window `w`, as HASH reads them. -/
def windowBytes (m : Word → Byte) (base : Word) (w : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (SMP + 4 * (N * w))) (4 * N)

/-- Memory once the first `k` windows' digests are written: window `j`'s at
`DIG + 32j`, each `H` of that window's bytes. -/
def wrote (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Nat → Word → Byte
  | 0 => m
  | k + 1 => writeBytes (wrote H m base k) (base + BitVec.ofNat 32 (DIG + 32 * k)) (H (windowBytes m base k))

/-- **Where it stops**: the first window that fails, 0 to 3, or 4 if none does. -/
def stop (m : Word → Byte) (base : Word) : Nat :=
  if ¬ WinOk m base SMP 0 then 0 else if ¬ WinOk m base SMP 1 then 1
  else if ¬ WinOk m base SMP 2 then 2 else if ¬ WinOk m base SMP 3 then 3 else 4

/-- The halt code: 0 if every window passed, else the failing window's number, 1 to 4. -/
def code (m : Word → Byte) (base : Word) : Word :=
  if stop m base = 4 then 0 else BitVec.ofNat 32 (stop m base + 1)

/-- Instructions to the halt, when it stops at window `k`. -/
def cost (k : Nat) : Nat := if k = 4 then 69699 else 17431 + 17421 * k

theorem stop_le (m : Word → Byte) (base : Word) : stop m base ≤ 4 := by
  unfold stop; split <;> (try split) <;> (try split) <;> (try split) <;> omega

/-- Every window before the stop passed; the stop's, if any, did not. -/
theorem stop_spec (m : Word → Byte) (base : Word) :
    (∀ i < stop m base, WinOk m base SMP i) ∧ (stop m base < 4 → ¬ WinOk m base SMP (stop m base)) := by
  unfold stop
  by_cases h0 : WinOk m base SMP 0
  · by_cases h1 : WinOk m base SMP 1
    · by_cases h2 : WinOk m base SMP 2
      · by_cases h3 : WinOk m base SMP 3
        · simp only [h0, h1, h2, h3, not_true_eq_false, ↓reduceIte]
          refine ⟨fun i hi => ?_, fun h => absurd h (by decide)⟩
          obtain rfl | rfl | rfl | rfl : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by omega
          · exact h0
          · exact h1
          · exact h2
          · exact h3
        · simp only [h0, h1, h2, h3, not_true_eq_false, not_false_eq_true, ↓reduceIte]
          refine ⟨fun i hi => ?_, fun _ => trivial⟩
          obtain rfl | rfl | rfl : i = 0 ∨ i = 1 ∨ i = 2 := by omega
          · exact h0
          · exact h1
          · exact h2
      · simp only [h0, h1, h2, not_true_eq_false, not_false_eq_true, ↓reduceIte]
        refine ⟨fun i hi => ?_, fun _ => trivial⟩
        obtain rfl | rfl : i = 0 ∨ i = 1 := by omega
        · exact h0
        · exact h1
    · simp only [h0, h1, not_true_eq_false, not_false_eq_true, ↓reduceIte]
      exact ⟨fun i hi => by obtain rfl : i = 0 := by omega
                            exact h0, fun _ => trivial⟩
  · simp only [h0, not_false_eq_true, ↓reduceIte]
    exact ⟨fun i hi => absurd hi (by omega), fun _ => trivial⟩

/-! ## The samples stay as they were -/

variable {env : Env} {base : Word}

theorem wrote_keeps (hfit : base.toNat + 0x10000 ≤ 2^32) (H : List Byte → Fin 32 → Byte) (m : Word → Byte) :
    ∀ k ≤ 4, Keeps (base + BitVec.ofNat 32 DIG) 128 m (wrote H m base k)
  | 0, _ => Keeps.refl _ _ _
  | k + 1, hk => (wrote_keeps hfit H m k (by omega)).trans
      (keeps_writeBytes hfit _ _ (by simp [DIG]) (by simp only [DIG]; omega) (by decide))

theorem wrote_below (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k : Nat} (hk : k ≤ 4) {c : Nat} (hc : c < DIG) :
    wrote H m base k (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) :=
  (wrote_keeps hfit H m k hk).off hfit (by decide) (by simp only [DIG] at hc; omega) (Or.inl hc)

theorem wrote_bit (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k : Nat} (hk : k ≤ 4) {j : Nat} (hj : j < 4 * N) :
    bit (wrote H m base k) base SMP j = bit m base SMP j := by
  simp only [bit, sample]
  congr 1
  apply readLE_four_congr
  intro d hd
  simp only [N] at hj
  rw [off_add hfit _ _ (by simp only [SMP]; omega), wrote_below hfit hk (by simp only [SMP, DIG]; omega)]

theorem rct_congr {m m' : Word → Byte} {src n : Nat} (h : ∀ j < n, bit m' base src j = bit m base src j) :
    rct m' base src n = rct m base src n := by
  unfold rct bits
  congr 1
  exact List.map_congr_left (fun j hj => h j (List.mem_range.1 hj))

theorem agree_congr {m m' : Word → Byte} {src n : Nat} (h : ∀ j < n, bit m' base src j = bit m base src j)
    (h0 : 0 < n) : agree m' base src n = agree m base src n := by
  unfold agree bits
  rw [List.map_congr_left (fun j hj => h j (List.mem_range.1 hj)), h 0 h0]

theorem wrote_winOk (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k w : Nat} (hk : k ≤ 4) (hw : w < 4) :
    WinOk (wrote H m base k) base SMP w ↔ WinOk m base SMP w := by
  unfold WinOk
  rw [rct_congr (fun j hj => wrote_bit hfit hk (by simp only [N] at hj ⊢; omega)),
    agree_congr (m := m) (m' := wrote H m base k) (fun i hi => by
      rw [bit_window, bit_window]; exact wrote_bit hfit hk (by simp only [N] at hi ⊢; omega)) (by decide)]

theorem wrote_rct (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k n : Nat} (hk : k ≤ 4) (hn : n ≤ 4 * N) :
    rct (wrote H m base k) base SMP n = rct m base SMP n :=
  rct_congr (fun j hj => wrote_bit hfit hk (by omega))

theorem wrote_window (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k w : Nat} (hk : k ≤ 4) (hw : w < 4) :
    windowBytes (wrote H m base k) base w = windowBytes m base w := by
  unfold windowBytes
  apply readBytes_congr
  intro d hd
  simp only [N] at hd
  rw [off_add hfit _ _ (by simp only [SMP, N]; omega), wrote_below hfit hk (by simp only [SMP, DIG, N]; omega)]

theorem wrote_code (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k : Nat} (hk : k ≤ 4) (hc : CodeAt m base kernel) : CodeAt (wrote H m base k) base kernel :=
  (wrote_keeps hfit H m k hk).code hfit (by decide) (by rw [kernel_length]; decide) hc


/-! ## The setup -/

/-- What the eleven register instructions after `auipc` leave, from `s0 = base`. -/
theorem init_regs (hfit : base.toNat + 0x10000 ≤ 2^32) (s : Machine) (h0 : s.reg S0 = base) :
    (s.line init).reg S1 = base + BitVec.ofNat 32 SMP ∧
    (s.line init).reg A2 = base + BitVec.ofNat 32 DIG ∧
    (s.line init).reg A1 = BitVec.ofNat 32 4096 ∧
    (s.line init).reg T0 = 0 ∧
    (s.line init).reg S4 = BitVec.ofNat 32 2 ∧
    (s.line init).reg S5 = 0 ∧
    (s.line init).reg S6 = 0 ∧
    (s.line init).reg S2 = 0 := by
  have e1 : (s.line init).reg S1 = s.reg S0 + (0x400 : BitVec 12).signExtend 32 := by
    simp [Machine.line, init, Machine.alu, reg_setReg, aluI, aluR, shiftI, S0, S1, T1, A1, A2, T0, S2, S4, S5, S6]
  have e2 : (s.line init).reg A2 = (s.reg S0 + (0x400 : BitVec 12).signExtend 32) + (1#32 <<< 14) := by
    simp [Machine.line, init, Machine.alu, reg_setReg, aluI, aluR, shiftI, S0, S1, T1, A1, A2, T0, S2, S4, S5, S6]
  have se4 : (0x400 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x400 := se_small 0x400 (by decide)
  refine ⟨by rw [e1, h0, se4]; rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [e2, h0, se4, show (1#32 <<< 14 : Word) = BitVec.ofNat 32 0x4000 by decide, off_add hfit _ _ (by decide)]; rfl
  all_goals simp [Machine.line, init, Machine.alu, reg_setReg, aluI, aluR, shiftI, S0, S1, T1, A1, A2, T0, S2, S4, S5, S6]

/-- At the top of window `w`, with `w` windows passed: the digests so far
written, the pointers at window `w`'s samples and its digest's place, HASH's
length and call ready, `w` counted, and the repetition count as the stream
left it, nothing failed. -/
structure Entry (env : Env) (m0 : Word → Byte) (base : Word) (w : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (12 + 30 * w))
  mem : s.mem = wrote env.hash m0 base w
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * w))
  a2 : s.reg A2 = base + BitVec.ofNat 32 (DIG + 32 * w)
  a1 : s.reg A1 = BitVec.ofNat 32 4096
  t0 : s.reg T0 = 0
  s2 : s.reg S2 = BitVec.ofNat 32 w
  s6 : s.reg S6 = 0
  s4 : s.reg S4 = BitVec.ofNat 32 (rct m0 base SMP (N * w)).last
  s5 : s.reg S5 = BitVec.ofNat 32 (rct m0 base SMP (N * w)).run
  ok : (rct m0 base SMP (N * w)).bad = false

/-- **The setup**: twelve instructions from the boot state to window 0. -/
theorem setup_run (hp : Placed env base) (s : Machine) (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 12 s = .running s' ∧ Entry env s.mem base 0 s' := by
  have hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep hp 0 (by rw [kernel_length]; decide) hcode (by simpa using hpc)
    (i := .auipc S0 0) (by decide) (rd := S0) (v := s.pc + ((0 : BitVec 20) ++ 0#12)) rfl hlen
  have h0 : s1.reg S0 = base := by
    rw [reg_wrote r1 (by decide), hpc, show ((0 : BitVec 20) ++ 0#12) = (0 : Word) by decide]; simp
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have e2 := run_line hp init (by decide) 1 s1 (by decide) (by rw [kernel_length]; decide) hc1 p1 hlen
  obtain ⟨g1, ga2, ga1, gt0, g4, g5, g6, g2⟩ := init_regs hp.fit s1 h0
  refine ⟨s1.line init, run_cons e1 e2, ?_, by rw [line_mem, m1]; rfl, by rw [g1]; simp [SMP],
    by rw [ga2]; simp [DIG], ga1, gt0, by rw [g2]; rfl, g6, ?_, ?_, ?_⟩
  · rw [line_pc_at init p1 (by rw [show init.length = 11 by rfl]; decide)]; rfl
  · rw [g4]; simp [rct, bits, rctInit]
  · rw [g5]; simp [rct, bits, rctInit]
  · simp [rct, bits, rctInit]

/-! ## Where each piece is -/

theorem hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide

theorem cases4 {w : Nat} (hw : w < 4) : w = 0 ∨ w = 1 ∨ w = 2 ∨ w = 3 := by omega

theorem at_win {w : Nat} (hw : w < 4) : Alice.Window.At kernel (12 + 30 * w) := by
  rcases cases4 hw with rfl | rfl | rfl | rfl <;> exact ⟨rfl, by rw [kernel_length]; decide, hlen⟩

theorem at_bne {w : Nat} (hw : w < 4) :
    kernel.getD (36 + 30 * w) .ecall = .br .bne S6 0 (BitVec.ofNat 12 (2 * (99 - 30 * w))) := by
  rcases cases4 hw with rfl | rfl | rfl | rfl <;> rfl

theorem at_pre {w : Nat} (hw : w < 4) : (kernel.drop (37 + 30 * w)).take preHash.length = preHash := by
  rcases cases4 hw with rfl | rfl | rfl | rfl <;> rfl

theorem at_hash {w : Nat} (hw : w < 4) : kernel.getD (39 + 30 * w) .ecall = .ecall := by
  rcases cases4 hw with rfl | rfl | rfl | rfl <;> rfl

theorem at_post {w : Nat} (hw : w < 4) : (kernel.drop (40 + 30 * w)).take postHash.length = postHash := by
  rcases cases4 hw with rfl | rfl | rfl | rfl <;> rfl

def failSet : List Instr := [ .opi .addi A0 S2 1, .opi .addi T0 0 1 ]
def passSet : List Instr := [ .opi .addi A0 0 0, .opi .addi T0 0 1 ]

theorem at_fail : (kernel.drop 135).take failSet.length = failSet := rfl
theorem at_pass : (kernel.drop 132).take passSet.length = passSet := rfl

/-! ## Arithmetic on addresses -/

/-- `addi a0, s1, -2048; addi a0, a0, -2048`: 4096 back. -/
theorem back4096 (c : Nat) (h1 : 4096 ≤ c) (h2 : c < 0x10000) :
    base + BitVec.ofNat 32 c + (0x800 : BitVec 12).signExtend 32 + (0x800 : BitVec 12).signExtend 32
      = base + BitVec.ofNat 32 (c - 4096) := by
  rw [show (0x800 : BitVec 12) = BitVec.ofNat 12 2048 from rfl, se_neg 2048 (by decide) (by decide)]
  have hb := base.isLt
  bv_omega

/-- `addi r, r, d` for a small `d`. -/
theorem count_up (n d : Nat) (hd : d < 2048) :
    BitVec.ofNat 32 n + (BitVec.ofNat 12 d).signExtend 32 = BitVec.ofNat 32 (n + d) := by
  rw [se_small d hd, BitVec.ofNat_add]

end Seam

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Seam.image
  | _ => pure ()
  for (i, k) in Seam.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
