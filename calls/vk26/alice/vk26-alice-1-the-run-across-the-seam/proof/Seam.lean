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
import Alice.Addr
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Flow

set_option maxRecDepth 20000

namespace Seam
open Rv32 Rv32.Health Alice.Window Alice.Addr

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

theorem wrote_winOk (hfit : base.toNat + 0x10000 ≤ 2^32) {H : List Byte → Fin 32 → Byte} {m : Word → Byte}
    {k w : Nat} (hk : k ≤ 4) (hw : w < 4) :
    WinOk (wrote H m base k) base SMP w ↔ WinOk m base SMP w :=
  winOk_congr (fun j hj => wrote_bit hfit hk (by simp only [N] at hj ⊢; omega))

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

/-! ## Arithmetic on addresses: `Alice.Addr` -/

/-- Each window's branch to FAIL, by the numbers. -/
theorem bne_off {w : Nat} (hw : w < 4) :
    BitVec.ofNat 32 (4 * (36 + 30 * w)) + ((BitVec.ofNat 12 (2 * (99 - 30 * w))) ++ 0#1).signExtend 32
      = BitVec.ofNat 32 (4 * 135) := by
  rcases cases4 hw with rfl | rfl | rfl | rfl
  · exact jump_ok (BitVec.ofNat 12 198) (by decide) 36 135 (by decide) (by decide) (by decide)
  · exact jump_ok (BitVec.ofNat 12 138) (by decide) 66 135 (by decide) (by decide) (by decide)
  · exact jump_ok (BitVec.ofNat 12 78) (by decide) 96 135 (by decide) (by decide) (by decide)
  · exact jump_ok (BitVec.ofNat 12 18) (by decide) 126 135 (by decide) (by decide) (by decide)

/-! ## A window -/

/-- Window `w`'s tests, from its top to its branch: `s6` says whether it passed. -/
theorem window_head (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {w : Nat}
    (hw : w < 4) {s : Machine} (he : Entry env m0 base w s) :
    ∃ s', run env (4 + 17 * N + 3) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (36 + 30 * w))
      ∧ s'.mem = wrote env.hash m0 base w
      ∧ s'.reg S1 = base + BitVec.ofNat 32 (SMP + 4 * (N * (w + 1)))
      ∧ s'.reg S6 = (if WinOk m0 base SMP w then 0#32 else 1#32)
      ∧ (WinOk m0 base SMP w →
          s'.reg S4 = BitVec.ofNat 32 (rct m0 base SMP (N * (w + 1))).last ∧
          s'.reg S5 = BitVec.ofNat 32 (rct m0 base SMP (N * (w + 1))).run)
      ∧ s'.reg A1 = s.reg A1 ∧ s'.reg A2 = s.reg A2 ∧ s'.reg T0 = s.reg T0 ∧ s'.reg S2 = s.reg S2 := by
  have hcode : CodeAt s.mem base kernel := by rw [he.mem]; exact wrote_code hp.fit (by omega) hc0
  have r0 : rct s.mem base SMP (N * w) = rct m0 base SMP (N * w) := by
    rw [he.mem]; exact wrote_rct hp.fit (by omega) (by simp only [N]; omega)
  have r1 : rct s.mem base SMP (N * (w + 1)) = rct m0 base SMP (N * (w + 1)) := by
    rw [he.mem]; exact wrote_rct hp.fit (by omega) (by simp only [N]; omega)
  have hok : WinOk s.mem base SMP w ↔ WinOk m0 base SMP w := by
    rw [he.mem]; exact wrote_winOk hp.fit (by omega) hw
  obtain ⟨sV, eV, pV, mV, g1, g6, g45, kV⟩ := win_run hp (at_win hw) (src := SMP) (w := w)
    (by simp only [SMP, N]; omega) (by decide) s (by rw [he.pc]) hcode he.s1
    (by rw [he.s6, r0, he.ok]; rfl) (fun _ => by rw [r0]; exact ⟨he.s4, he.s5⟩)
  refine ⟨sV, eV, by rw [pV, show 12 + 30 * w + 24 = 36 + 30 * w by omega], by rw [mV, he.mem], g1,
    by rw [g6]; simp only [hok], fun h => by rw [← r1]; exact g45 (hok.2 h),
    kV A1 (by decide), kV A2 (by decide), kV T0 (by decide), kV S2 (by decide)⟩

/-- **A window that fails**: after 17418 instructions the kernel is still
running, and the next halts it with the window's number; nothing written
since the window began. -/
theorem window_fail (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {w : Nat}
    (hw : w < 4) (hbad : ¬ WinOk m0 base SMP w) {s : Machine} (he : Entry env m0 base w s) :
    ∃ s1, run env 17418 s = .running s1 ∧ run env 1 s1 = .halted (BitVec.ofNat 32 (w + 1)) s1
      ∧ s1.mem = wrote env.hash m0 base w := by
  obtain ⟨sV, eV, pV, mV, -, g6, -, -, -, -, k2⟩ := window_head hp hc0 hw he
  have hcV : CodeAt sV.mem base kernel := by rw [mV]; exact wrote_code hp.fit (by omega) hc0
  have h6 : sV.reg S6 = 1#32 := by rw [g6]; simp [hbad]
  obtain ⟨sB, eB, pB, mB, rB⟩ := brStep hp (36 + 30 * w) (by rw [kernel_length]; omega) hcV pV (at_bne hw)
    (k' := 135) (bne_off hw) hlen
  have pB' : sB.pc = base + BitVec.ofNat 32 (4 * 135) := by
    rw [pB, h6]; simp [taken]
  have hcB : CodeAt sB.mem base kernel := by rw [mB]; exact hcV
  have eF := run_line hp failSet (by decide) 135 sB at_fail (by rw [kernel_length]; decide) hcB pB' hlen
  have gA0 : (sB.line failSet).reg A0 = BitVec.ofNat 32 (w + 1) := by
    have : (sB.line failSet).reg A0 = sB.reg S2 + (1 : BitVec 12).signExtend 32 := by
      simp [Machine.line, failSet, Machine.alu, reg_setReg, aluI, A0, T0, S2]
    rw [this, rB, k2, he.s2]; exact count_up w 1 (by decide)
  have gT0 : (sB.line failSet).reg T0 = 1#32 := by
    simp [Machine.line, failSet, Machine.alu, reg_setReg, aluI, A0, T0, S2]
  have pF : (sB.line failSet).pc = base + BitVec.ofNat 32 (4 * 137) := line_pc_at failSet pB' (by decide)
  have hH := haltStep hp 137 (by rw [kernel_length]; decide) (by rw [line_mem]; exact hcB) pF rfl gT0 hlen 0
  refine ⟨sB.line failSet, ?_, by rw [hH, gA0], by rw [line_mem, mB, mV]⟩
  rw [show 17418 = (4 + 17 * N + 3) + (1 + failSet.length) by rfl, run_add_running eV, run_add_running eB, eF]

/-- **A window that passes**: 17421 instructions, its digest written, and
the next window's top. -/
theorem window_pass (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {w : Nat}
    (hw : w < 4) (hgood : WinOk m0 base SMP w) {s : Machine} (he : Entry env m0 base w s) :
    ∃ s', run env 17421 s = .running s' ∧ Entry env m0 base (w + 1) s' := by
  obtain ⟨sV, eV, pV, mV, g1, g6, g45, k1, k2, k0, kS2⟩ := window_head hp hc0 hw he
  have hcV : CodeAt sV.mem base kernel := by rw [mV]; exact wrote_code hp.fit (by omega) hc0
  have h6 : sV.reg S6 = 0#32 := by rw [g6]; simp [hgood]
  obtain ⟨sB, eB, pB, mB, rB⟩ := brStep hp (36 + 30 * w) (by rw [kernel_length]; omega) hcV pV (at_bne hw)
    (k' := 135) (bne_off hw) hlen
  have pB' : sB.pc = base + BitVec.ofNat 32 (4 * (37 + 30 * w)) := by
    rw [pB, h6, reg_zero, ite_eq_right (by decide), show 36 + 30 * w + 1 = 37 + 30 * w by omega]
  have hcB : CodeAt sB.mem base kernel := by rw [mB]; exact hcV
  -- a0 = s1 - 4096: the window just tested
  have eP := run_line hp preHash (by decide) (37 + 30 * w) sB (at_pre hw)
    (by rw [kernel_length, show preHash.length = 2 by rfl]; omega) hcB pB' hlen
  generalize hsP : sB.line preHash = sP at eP
  have gA0 : sP.reg A0 = base + BitVec.ofNat 32 (SMP + 4 * (N * w)) := by
    have : sP.reg A0 = sB.reg S1 + (0x800 : BitVec 12).signExtend 32 + (0x800 : BitVec 12).signExtend 32 := by
      rw [← hsP]; simp [Machine.line, preHash, Machine.alu, reg_setReg, aluI, A0, S1]
    rw [this, rB, g1, back4096 _ (by simp only [SMP, N]; omega) (by simp only [SMP, N]; omega)]
    congr 2
  have kP : ∀ r, r ≠ A0 → sP.reg r = sB.reg r := fun r hr => by
    rw [← hsP, line_keeps _ _ r (by simp [preHash, rdOf]; exact Ne.symm hr)]
  have pP : sP.pc = base + BitVec.ofNat 32 (4 * (39 + 30 * w)) := by
    rw [← hsP, line_pc_at preHash pB' (by rw [show preHash.length = 2 by rfl]; omega),
      show preHash.length = 2 by rfl, show 37 + 30 * w + 2 = 39 + 30 * w by omega]
  have hcP : CodeAt sP.mem base kernel := by rw [← hsP, line_mem]; exact hcB
  -- HASH
  have ha1 : sP.reg A1 = BitVec.ofNat 32 4096 := by rw [kP A1 (by decide), rB, k1, he.a1]
  have ha2 : sP.reg A2 = base + BitVec.ofNat 32 (DIG + 32 * w) := by rw [kP A2 (by decide), rB, k2, he.a2]
  have ht0 : sP.reg T0 = 0 := by rw [kP T0 (by decide), rB, k0, he.t0]
  have hexec := exec_hash (env := env) (s := sP) ht0 (by rw [ha1]; decide)
    (by rw [gA0]; exact align_off hp.align hp.fit _ (by simp only [SMP, N]; omega) (by simp only [SMP]; omega))
    (by rw [ha2]; exact align_off hp.align hp.fit _ (by simp only [DIG]; omega) (by simp only [DIG]; omega))
    (by rw [gA0, ha1]; exact ok_off hp _ _ (by simp only [SMP, N]; omega) (by simp only [SMP, N]; simp; omega))
    (by rw [ha2]; exact ok_off hp _ _ (by simp only [DIG]; omega) (by simp only [DIG]; omega))
  have eH := stepK hp (39 + 30 * w) (by rw [kernel_length]; omega) hcP pP (at_hash hw) hexec 0 hlen
  generalize hsH : ({ sP with mem := writeBytes sP.mem (sP.reg A2) (env.hash (readBytes sP.mem (sP.reg A0) (sP.reg A1).toNat)) } : Machine).next = sH at eH
  have eH1 : run env 1 sP = .running sH := eH.trans (run_zero _ _)
  have mH : sH.mem = wrote env.hash m0 base (w + 1) := by
    have hm : sP.mem = wrote env.hash m0 base w := by rw [← hsP, line_mem, mB, mV]
    have hw4 : (sP.reg A1).toNat = 4 * N := by rw [ha1]; rfl
    rw [← hsH, next_mem]
    show writeBytes sP.mem (sP.reg A2) (env.hash (readBytes sP.mem (sP.reg A0) (sP.reg A1).toNat)) = _
    rw [hw4, gA0, ha2, hm]
    show _ = writeBytes (wrote env.hash m0 base w) (base + BitVec.ofNat 32 (DIG + 32 * w)) (env.hash (windowBytes m0 base w))
    rw [← wrote_window hp.fit (H := env.hash) (m := m0) (k := w) (by omega) hw]
    rfl
  have pH : sH.pc = base + BitVec.ofNat 32 (4 * (40 + 30 * w)) := by
    rw [← hsH, next_pc]; show sP.pc + 4 = _; rw [pP, pc_next hp.fit (39 + 30 * w) (by omega), show 39 + 30 * w + 1 = 40 + 30 * w by omega]
  have kH : ∀ r, sH.reg r = sP.reg r := fun r => by rw [← hsH]; rfl
  have hcH : CodeAt sH.mem base kernel := by rw [mH]; exact wrote_code hp.fit (by omega) hc0
  -- a2 += 32, s2 += 1
  have eQ := run_line hp postHash (by decide) (40 + 30 * w) sH (at_post hw)
    (by rw [kernel_length, show postHash.length = 2 by rfl]; omega) hcH pH hlen
  have kQ : ∀ r, r ≠ A2 → r ≠ S2 → (sH.line postHash).reg r = sH.reg r := fun r a b => by
    rw [line_keeps _ _ r (by simp [postHash, rdOf]; exact ⟨Ne.symm a, Ne.symm b⟩)]
  refine ⟨sH.line postHash, ?_, ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 17421 = (4 + 17 * N + 3) + (1 + (preHash.length + (1 + postHash.length))) by rfl,
      run_add_running eV, run_add_running eB, run_add_running eP, run_add_running eH1, eQ]
  · rw [line_pc_at postHash pH (by rw [show postHash.length = 2 by rfl]; omega)]
    rw [show 40 + 30 * w + postHash.length = 12 + 30 * (w + 1) by rw [show postHash.length = 2 by rfl]; omega]
  · rw [line_mem, mH]
  · rw [kQ S1 (by decide) (by decide), kH, kP S1 (by decide), rB, g1]
  · have : (sH.line postHash).reg A2 = sH.reg A2 + (32 : BitVec 12).signExtend 32 := by
      simp [Machine.line, postHash, Machine.alu, reg_setReg, aluI, A2, S2]
    rw [this, kH, ha2, show (32 : BitVec 12) = BitVec.ofNat 12 32 from rfl, se_small 32 (by decide),
      off_add hp.fit _ _ (by simp only [DIG]; omega)]
    congr 2
  · rw [kQ A1 (by decide) (by decide), kH, ha1]
  · rw [kQ T0 (by decide) (by decide), kH, ht0]
  · have : (sH.line postHash).reg S2 = sH.reg S2 + (1 : BitVec 12).signExtend 32 := by
      simp [Machine.line, postHash, Machine.alu, reg_setReg, aluI, A2, S2]
    rw [this, kH, kP S2 (by decide), rB, kS2, he.s2]; exact count_up w 1 (by decide)
  · rw [kQ S6 (by decide) (by decide), kH, kP S6 (by decide), rB, h6]; rfl
  · rw [kQ S4 (by decide) (by decide), kH, kP S4 (by decide), rB]; exact (g45 hgood).1
  · rw [kQ S5 (by decide) (by decide), kH, kP S5 (by decide), rB]; exact (g45 hgood).2
  · exact hgood.1

/-- **All four passed**: three more instructions halt it with 0. -/
theorem all_pass (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {s : Machine}
    (he : Entry env m0 base 4 s) :
    ∃ s1, run env 2 s = .running s1 ∧ run env 1 s1 = .halted 0 s1 ∧ s1.mem = wrote env.hash m0 base 4 := by
  have hcode : CodeAt s.mem base kernel := by rw [he.mem]; exact wrote_code hp.fit (by omega) hc0
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 132) := he.pc
  have eS := run_line hp passSet (by decide) 132 s at_pass (by rw [kernel_length]; decide) hcode hpc hlen
  have gA0 : (s.line passSet).reg A0 = 0 := by simp [Machine.line, passSet, Machine.alu, reg_setReg, aluI, A0, T0]
  have gT0 : (s.line passSet).reg T0 = 1#32 := by simp [Machine.line, passSet, Machine.alu, reg_setReg, aluI, A0, T0]
  have pS : (s.line passSet).pc = base + BitVec.ofNat 32 (4 * 134) := line_pc_at passSet hpc (by decide)
  have hH := haltStep hp 134 (by rw [kernel_length]; decide) (by rw [line_mem]; exact hcode) pS rfl gT0 hlen 0
  exact ⟨s.line passSet, eS, by rw [hH, gA0], by rw [line_mem, he.mem]⟩

/-! ## From the boot -/

/-- Every window before the stop is entered: `12 + 17421k` instructions to
window `k`'s top. -/
theorem runs_to (hp : Placed env base) {m0 : Word → Byte} (hc0 : CodeAt m0 base kernel) {s0 : Machine}
    (hpc : s0.pc = base) (hm : s0.mem = m0) :
    ∀ k ≤ stop m0 base, ∃ s, run env (12 + 17421 * k) s0 = .running s ∧ Entry env m0 base k s
  | 0, _ => by
    obtain ⟨s, e, h⟩ := setup_run hp s0 hpc (by rw [hm]; exact hc0)
    exact ⟨s, e, hm ▸ h⟩
  | k + 1, hk => by
    obtain ⟨s, e, h⟩ := runs_to hp hc0 hpc hm k (by omega)
    have h4 := stop_le m0 base
    obtain ⟨s', e', h'⟩ := window_pass hp hc0 (by omega) ((stop_spec m0 base).1 k (by omega)) h
    exact ⟨s', by rw [show 12 + 17421 * (k + 1) = (12 + 17421 * k) + 17421 by omega, run_add_running e, e'], h'⟩

/-- **From the boot**: the image starts with the kernel's 552 bytes. Then
after exactly `cost (stop …)` instructions the kernel halts — with 0 if all
four windows passed, else with the first failing window's number — and the
region is the image with one digest, `HASH` of that window's 4096 bytes, for
each window before the stop, and nothing else changed. One instruction
earlier it is still running. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 552 ≤ img.size)
    (himg : ∀ d (h : d < 552), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (cost (stop (memOfImage base img) base) - 1) (boot env.region img) = .running s1) ∧
    ∃ s', run env (cost (stop (memOfImage base img) base)) (boot env.region img)
        = .halted (code (memOfImage base img) base) s'
      ∧ s'.mem = wrote env.hash (memOfImage base img) base (stop (memOfImage base img) base) := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hc0 : CodeAt (memOfImage base img) base kernel :=
    code_of_image hp.fit (by rw [kernel_length]; decide) (toBytes_words kernel) img
      (by rw [kernel_length]; omega) (fun d h => himg d (by rw [kernel_length] at h; omega))
  generalize memOfImage base img = m0 at hc0 hmem ⊢
  have h4 := stop_le m0 base
  have hfail := (stop_spec m0 base).2
  obtain ⟨s, e, h⟩ := runs_to hp hc0 hpc hmem (stop m0 base) (Nat.le_refl _)
  unfold code
  generalize stop m0 base = k at h4 hfail e h ⊢
  by_cases hk : k = 4
  · subst hk
    obtain ⟨s1, e1, h1, m1⟩ := all_pass hp hc0 h
    refine ⟨⟨s1, ?_⟩, s1, ?_, m1⟩
    · rw [show cost 4 - 1 = (12 + 17421 * 4) + 2 by decide, run_add_running e, e1]
    · rw [show cost 4 = (12 + 17421 * 4) + (2 + 1) by decide, run_add_running e, run_add_running e1, h1]; rfl
  · obtain ⟨s1, e1, h1, m1⟩ := window_fail hp hc0 (by omega) (hfail (by omega)) h
    have hc : cost k = (12 + 17421 * k) + (17418 + 1) := by simp only [cost, hk, ↓reduceIte]; omega
    refine ⟨⟨s1, ?_⟩, s1, ?_, m1⟩
    · rw [hc, show 12 + 17421 * k + (17418 + 1) - 1 = (12 + 17421 * k) + 17418 by omega, run_add_running e, e1]
    · rw [hc, run_add_running e, run_add_running e1, h1]; simp only [hk, ↓reduceIte]

#print axioms init_regs
#print axioms setup_run
#print axioms window_head
#print axioms window_fail
#print axioms window_pass
#print axioms all_pass
#print axioms runs_to
#print axioms from_boot

end Seam

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Seam.image
  | _ => pure ()
  for (i, k) in Seam.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
