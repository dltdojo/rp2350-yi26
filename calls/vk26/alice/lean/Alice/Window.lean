/-
SPDX-License-Identifier: Apache-2.0

# A window of SP 800-90B's health tests, the repetition count carried in

`lean/Rv32/Health.lean`'s `front` runs both tests over one window of 1024
samples, and starts the repetition count afresh: its setup sets the last
sample to 2 (none yet) and the run to 0. Over a stream of windows that is not
what SP 800-90B's repetition count is, nor what exp114's crate does: there the
run goes on across a window's edge, and 21 alike in a row fail even when 11 of
them end one window and 10 begin the next.

`win` is the same tests with the count carried in. Its setup takes the
window's reference and zeroes the adaptive proportion's count and the sample
counter, and touches nothing else; the 17-instruction loop over the samples
and the 3-instruction verdict are `Health.health` and `Health.verdictLine`,
unchanged. Whatever the last sample, the run and the failure flag were in
`s4`, `s5` and `s6` on the way in, they are the stream's on the way out.
-/
import Rv32.Health
import Rv32.Blocks

namespace Alice.Window
open Rv32 Rv32.Health

/-- The window's setup: its reference bit, and its own two counts. `s4`,
`s5` and `s6` are left as the windows before left them. -/
def head : List Instr := [
  .ld .lw S7 S1 0, .opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024 ]

/-- The block: setup, 1024 samples, the verdict in `s6`. -/
def win : List Instr := head ++ health ++ verdictLine

theorem win_length : win.length = 24 := by decide

/-! ## What the block is held to

The stream is the samples from `base + src`, `N` to a window; window `w` is
samples `N·w` to `N·w + N`. The repetition count is `Health.rct` over the
stream from its start, so it runs across every edge; the adaptive proportion
is `Health.agree` over the window alone, from its first sample. -/

/-- **Window `w` passes**: no run of 21 alike up to its end, and fewer than
589 of its samples equal its first. -/
def WinOk (m : Word → Byte) (base : Word) (src w : Nat) : Prop :=
  (rct m base src (N * (w + 1))).bad = false ∧ agree m base (src + 4 * (N * w)) N < APT_CUTOFF

instance (m : Word → Byte) (base : Word) (src w : Nat) : Decidable (WinOk m base src w) := by
  unfold WinOk; infer_instance

/-- Sample `i` of window `w` is sample `N·w + i` of the stream. -/
theorem bit_window (m : Word → Byte) (base : Word) (src w i : Nat) :
    bit m base (src + 4 * (N * w)) i = bit m base src (N * w + i) := by
  simp only [bit, sample]
  rw [show src + 4 * (N * w) + 4 * i = src + 4 * (N * w + i) by omega]

/-- While nothing has failed, the run is below the cutoff. -/
theorem run_lt (m : Word → Byte) (base : Word) (src n : Nat) :
    (rct m base src n).bad = false → (rct m base src n).run < RCT_CUTOFF := by
  induction n with
  | zero => intro _; simp [rct, bits, rctInit, RCT_CUTOFF]
  | succ n _ =>
    rw [rct_succ]
    simp only [rctStep, Bool.or_eq_false_iff, decide_eq_false_iff_not]
    intro h; omega

/-! ## One sample's line, once something has failed -/

/-- After a failure the flag stays set, whatever the run: `or` with 1. -/
theorem or_one (c : Bool) : 1#32 ||| ((if c = true then 1#32 else 0#32) ^^^ 1#32) = 1#32 := by
  cases c <;> decide

/-- What one sample's line leaves once `s6` is 1: still 1, and the agreement,
the pointer and the counter as ever. The run is no longer followed. -/
theorem body_bad (s : Machine) (ag rf : Nat) (hrf : rf ≤ 1)
    (h6 : s.reg S6 = 1#32) (h7 : s.reg S7 = BitVec.ofNat 32 rf) (h8 : s.reg S8 = BitVec.ofNat 32 ag) :
    let b := (s.reg T1).toNat % 2
    (s.line body).reg S6 = 1#32 ∧
    (s.line body).reg S8 = BitVec.ofNat 32 (ag + if b = rf then 1 else 0) ∧
    (s.line body).reg S1 = s.reg S1 + 4 ∧
    (s.line body).reg S3 = s.reg S3 + (0xfff : BitVec 12).signExtend 32 := by
  intro b
  have hb : b ≤ 1 := by omega
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
  refine ⟨by rw [g6, h6]; exact or_one _, ?_, g1, g3⟩
  rw [g8, h8, h7, and_one]; exact agree_word ag b rf hb hrf

/-! ## Where the block is in a kernel -/

structure At (prog : List Instr) (k0 : Nat) : Prop where
  seg : (prog.drop k0).take 24 = win
  fits : k0 + 24 ≤ prog.length
  len : 4 * prog.length < 0x10000

/-- At the top of sample `i` of window `w`, or at the verdict once `i` is
1024: memory as it was; the pointer at sample `N·w + i` of the stream and the
counter `i` on; the failure flag as the stream has it; the last sample and
the run as the stream has them, while nothing has failed; the window's
reference and its count of agreements; and every register the block does
not write as it was. -/
structure Inv (m0 : Word → Byte) (base : Word) (src k0 w : Nat) (keep : Reg → Word) (i : Nat) (s : Machine) :
    Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + if i < N then 4 else 21))
  mem : s.mem = m0
  s1 : s.reg S1 = base + BitVec.ofNat 32 (src + 4 * (N * w + i))
  s3 : s.reg S3 = BitVec.ofNat 32 (N - i)
  s6 : s.reg S6 = BitVec.ofNat 32 (if (rct m0 base src (N * w + i)).bad then 1 else 0)
  s45 : (rct m0 base src (N * w + i)).bad = false →
    s.reg S4 = BitVec.ofNat 32 (rct m0 base src (N * w + i)).last ∧
    s.reg S5 = BitVec.ofNat 32 (rct m0 base src (N * w + i)).run
  s7 : s.reg S7 = BitVec.ofNat 32 (bit m0 base src (N * w))
  s8 : s.reg S8 = BitVec.ofNat 32 (agree m0 base (src + 4 * (N * w)) i)
  kept : ∀ r, r ∉ written → s.reg r = keep r

variable {env : Env} {base : Word} {prog : List Instr} {k0 src w : Nat}

/-- Four instructions: the reference bit and the window's counts. -/
theorem start_run (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * (N * (w + 1)) < 0x10000)
    (hs4 : src % 4 = 0) (s : Machine) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0))
    (hcode : CodeAt s.mem base prog) (h1 : s.reg S1 = base + BitVec.ofNat 32 (src + 4 * (N * w)))
    (h6 : s.reg S6 = BitVec.ofNat 32 (if (rct s.mem base src (N * w)).bad then 1 else 0))
    (h45 : (rct s.mem base src (N * w)).bad = false →
      s.reg S4 = BitVec.ofNat 32 (rct s.mem base src (N * w)).last ∧
      s.reg S5 = BitVec.ofNat 32 (rct s.mem base src (N * w)).run) :
    ∃ s', run env 4 s = .running s' ∧ Inv s.mem base src k0 w s.reg 0 s' := by
  have hlen := ha.len
  have hfits := ha.fits
  have hNw : N * (w + 1) = N * w + N := by rw [Nat.mul_succ]
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 0) (by omega) hcode (by simpa using hpc)
    (rd := S7) (rs1 := S1) (imm := 0) (by rw [Health.getD_of ha.seg (by decide)]; rfl) (src + 4 * (N * w))
    (by rw [h1]; simp) (by simp only [N] at hs hNw ⊢; omega) (by omega) hlen
  have hc1 : CodeAt s1.mem base prog := by rw [m1]; exact hcode
  have e2 := run_line hp [.opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024] (by decide) (k0 + 0 + 1) s1
    (by rw [show k0 + 0 + 1 = k0 + 1 by omega, Health.seg_of ha.seg (by decide)]; decide) (by simp; omega)
    hc1 p1 hlen
  refine ⟨s1.line [.opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024], ?_, ?_⟩
  · exact run_cons e1 e2
  have kw : ∀ r, r ∉ written → (s1.line [.opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024]).reg r = s.reg r := by
    intro r hr
    rw [line_keeps _ _ r (keeps_of (by decide) hr), reg_kept r1 (fun e => hr (by rw [e]; decide))]
  have k1 : ∀ r, r ≠ S7 → r ≠ S8 → r ≠ S3 →
      (s1.line [.opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024]).reg r = s.reg r := by
    intro r a b c
    rw [line_keeps _ _ r (by simp [rdOf]; exact ⟨Ne.symm a, Ne.symm b, Ne.symm c⟩), reg_kept r1 (fun e => a e)]
  constructor
  · rw [line_pc_at _ p1 (by simp; omega)]; simp [N]
  · rw [line_mem, m1]
  · rw [k1 S1 (by decide) (by decide) (by decide), h1]; simp
  · simp [Machine.line, Machine.alu, reg_setReg, aluI, S7, S8, S3, N]
  · rw [k1 S6 (by decide) (by decide) (by decide), h6]; simp
  · intro hb
    rw [k1 S4 (by decide) (by decide) (by decide), k1 S5 (by decide) (by decide) (by decide)]
    simpa using h45 (by simpa using hb)
  · have v : (s1.line [.opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024]).reg S7 = s1.reg S7 &&& 1#32 := by
      simp [Machine.line, Machine.alu, reg_setReg, aluI, S7, S8, S3]
    rw [v, reg_wrote r1 (by decide), and_one]
    rw [read_bit s.mem base src (N * w)]
  · simp [Machine.line, Machine.alu, reg_setReg, aluI, S7, S8, S3, agree, bits]
  · exact kw

/-! ## The health loop -/

/-- `bne s3, x0` at `k0 + 20` back to the loop's top at `k0 + 4`. -/
theorem back_to_top' (base : Word) (hk : 4 * (k0 + 20) < 0x10000) :
    base + BitVec.ofNat 32 (4 * (k0 + 4 + 1 + body.length)) + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32
      = base + BitVec.ofNat 32 (4 * (k0 + 4)) := by
  have e : ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 4294967232 := by decide
  have t : BitVec.ofNat 32 (4 * (k0 + 4 + 1 + body.length)) + BitVec.ofNat 32 4294967232
      = BitVec.ofNat 32 (4 * (k0 + 4)) := by
    rw [show body.length = 15 by rfl]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat,
      show (2:Nat) ^ 32 = 4294967296 by rfl,
      Nat.mod_eq_of_lt (show 4 * (k0 + 4 + 1 + 15) < 4294967296 by omega),
      Nat.mod_eq_of_lt (show 4294967232 < 4294967296 by decide),
      show 4 * (k0 + 4 + 1 + 15) + 4294967232 = 4 * (k0 + 4) + 4294967296 by omega, Nat.add_mod_right]
  rw [BitVec.add_assoc, e, t]

/-- **One sample**: seventeen instructions take the invariant from `i` to `i + 1`. -/
theorem win_iter (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * (N * (w + 1)) < 0x10000)
    (hs4 : src % 4 = 0) {m0 : Word → Byte} (hc0 : CodeAt m0 base prog) {keep : Reg → Word} {i : Nat}
    (hi : i < N) {s : Machine} (h : Inv m0 base src k0 w keep i s) :
    ∃ s', run env 17 s = .running s' ∧ Inv m0 base src k0 w keep (i + 1) s' := by
  have hlen := ha.len
  have hfits := ha.fits
  have hNw : N * (w + 1) = N * w + N := by rw [Nat.mul_succ]
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + 4)) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base prog := by rw [h.mem]; exact hc0
  have hi' : i < 1024 := hi
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 4) (by omega) hcode hpc
    (rd := T1) (rs1 := S1) (imm := 0) (by rw [Health.getD_of ha.seg (by decide)]; rfl) (src + 4 * (N * w + i))
    (by rw [h.s1]; simp) (by simp only [N] at hs hNw ⊢; omega) (by omega) hlen
  have hc1 : CodeAt s1.mem base prog := by rw [m1]; exact hcode
  have e2 := run_line hp body (by decide) (k0 + 4 + 1) s1
    (by rw [show k0 + 4 + 1 = k0 + 5 by omega, Health.seg_of ha.seg (by decide)]; decide)
    (by simp [body]; omega) hc1 p1 hlen
  have bT1 : (s1.reg T1).toNat % 2 = bit m0 base src (N * w + i) := by
    rw [reg_wrote r1 (by decide), h.mem]; exact read_bit m0 base src (N * w + i)
  have hag := agree_le m0 base (src + 4 * (N * w)) i
  have hrf := bit_le m0 base src (N * w)
  let st := rct m0 base src (N * w + i)
  have hst : rct m0 base src (N * w + (i + 1)) = rctStep st (bit m0 base src (N * w + i)) := by
    rw [show N * w + (i + 1) = (N * w + i) + 1 by omega, rct_succ]
  have hagr : agree m0 base (src + 4 * (N * w)) (i + 1)
      = agree m0 base (src + 4 * (N * w)) i + if bit m0 base src (N * w + i) = bit m0 base src (N * w) then 1 else 0 := by
    rw [agree_succ, bit_window, bit_window, Nat.add_zero]
  -- What the body leaves in s6, s8, s1, s3, whichever way the flag is.
  obtain ⟨g6, g8, g1, g3, g45⟩ : (s1.line body).reg S6 = BitVec.ofNat 32 (if (rctStep st (bit m0 base src (N * w + i))).bad then 1 else 0)
      ∧ (s1.line body).reg S8 = BitVec.ofNat 32 (agree m0 base (src + 4 * (N * w)) (i + 1))
      ∧ (s1.line body).reg S1 = s1.reg S1 + 4
      ∧ (s1.line body).reg S3 = s1.reg S3 + (0xfff : BitVec 12).signExtend 32
      ∧ ((rctStep st (bit m0 base src (N * w + i))).bad = false →
          (s1.line body).reg S4 = BitVec.ofNat 32 (rctStep st (bit m0 base src (N * w + i))).last ∧
          (s1.line body).reg S5 = BitVec.ofNat 32 (rctStep st (bit m0 base src (N * w + i))).run) := by
    by_cases hb : st.bad = true
    · have h6 : s1.reg S6 = 1#32 := by rw [reg_kept r1 (by decide), h.s6]; simp [st] at hb; simp [hb]
      obtain ⟨b6, b8, b1, b3⟩ := body_bad s1 (agree m0 base (src + 4 * (N * w)) i) (bit m0 base src (N * w)) hrf
        h6 (by rw [reg_kept r1 (by decide), h.s7]) (by rw [reg_kept r1 (by decide), h.s8])
      simp only [bT1] at b8
      refine ⟨?_, by rw [b8, hagr], b1, b3, ?_⟩
      · rw [b6]; simp [rctStep, hb]
      · intro h'; simp [rctStep, hb] at h'
    · simp only [Bool.not_eq_true] at hb
      obtain ⟨h4, h5⟩ := h.s45 hb
      have hr := run_lt m0 base src (N * w + i) hb
      have hl := (rct_bounds m0 base src (N * w + i)).1
      obtain ⟨b4, b5, b6, b8, b1, b3⟩ := body_regs s1 st.last st.run 0 (agree m0 base (src + 4 * (N * w)) i)
        (bit m0 base src (N * w)) hl (by show (rct m0 base src (N * w + i)).run < 1024; simp only [RCT_CUTOFF] at hr; omega) (by omega) hrf
        (by rw [reg_kept r1 (by decide), h4]) (by rw [reg_kept r1 (by decide), h5])
        (by rw [reg_kept r1 (by decide), h.s6]; simp [st] at hb; simp [hb]) (by rw [reg_kept r1 (by decide), h.s7])
        (by rw [reg_kept r1 (by decide), h.s8])
      simp only [bT1] at b4 b5 b6 b8
      refine ⟨?_, by rw [b8, hagr], b1, b3, fun _ => ⟨by rw [b4]; rfl, by rw [b5]; rfl⟩⟩
      rw [b6]
      simp only [rctStep, hb, RCT_CUTOFF, Bool.false_or]
      generalize (if bit m0 base src (N * w + i) = st.last then st.run + 1 else 1) = X
      by_cases h21 : 21 ≤ X <;> simp [h21]
  have p2 : (s1.line body).pc = base + BitVec.ofNat 32 (4 * (k0 + 4 + 1 + body.length)) :=
    line_pc_at body p1 (by simp [body]; omega)
  have hc2 : CodeAt (s1.line body).mem base prog := by rw [line_mem]; exact hc1
  have hbr : prog.getD (k0 + 4 + 1 + body.length) .ecall = .br .bne S3 0 0xfe0 := by
    rw [show k0 + 4 + 1 + body.length = k0 + 20 by rfl, Health.getD_of ha.seg (by decide)]; rfl
  have keep7 : ∀ r, r ∉ written → (s1.line body).reg r = keep r := by
    intro r hr
    rw [line_keeps _ _ r (keeps_of (by decide) hr), reg_kept r1 (fun e => hr (by rw [e]; decide)), h.kept r hr]
  have keepS7 : (s1.line body).reg S7 = s.reg S7 := by
    rw [line_keeps _ _ S7 (by simp [body, rdOf, S7, T1, T2, S4, S5, S6, S8, S1, S3]), reg_kept r1 (by decide)]
  have c3 : (s1.line body).reg S3 = BitVec.ofNat 32 (N - (i + 1)) := by
    rw [g3, reg_kept r1 (by decide), h.s3]; exact countdown hi
  have c1 : (s1.line body).reg S1 = base + BitVec.ofNat 32 (src + 4 * (N * w + (i + 1))) := by
    rw [g1, reg_kept r1 (by decide), h.s1, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      off_add hp.fit _ _ (by simp only [N] at hs hi hNw ⊢; omega)]
    congr 2
  have tk : taken .bne ((s1.line body).reg S3) ((s1.line body).reg 0) = decide (i + 1 < N) := by
    rw [c3, reg_zero]; exact round_again hi
  have mem2 : (s1.line body).mem = m0 := by rw [line_mem, m1, h.mem]
  have regs : ∀ s' : Machine, s'.mem = m0 → (∀ r, s'.reg r = (s1.line body).reg r) →
      s'.pc = base + BitVec.ofNat 32 (4 * (k0 + if i + 1 < N then 4 else 21)) →
      Inv m0 base src k0 w keep (i + 1) s' := by
    intro s' hm hr hp'
    refine ⟨hp', hm, by rw [hr, c1], by rw [hr, c3], by rw [hr, g6, hst], fun hb => ?_,
      by rw [hr, keepS7, h.s7], by rw [hr, g8], fun r hr' => by rw [hr, keep7 r hr']⟩
    rw [hst] at hb ⊢
    obtain ⟨a, b⟩ := g45 hb
    exact ⟨by rw [hr, a], by rw [hr, b]⟩
  by_cases hl : i + 1 < N
  · refine ⟨(s1.line body).setPc ((s1.line body).pc + ((0xfe0 : BitVec 12) ++ 0#1).signExtend 32), ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp _ (by simp [body]; omega) hc2 p2 hbr
        (exec_br_taken (by rw [tk]; simp [hl])) 0 hlen).trans (run_zero _ _)
    · exact regs _ (by rw [setPc_mem, mem2]) (fun r => by rw [setPc_reg])
        (by rw [setPc_pc, p2, back_to_top' base (by omega)]; simp [hl])
  · refine ⟨(s1.line body).next, ?_, ?_⟩
    · rw [show 17 = 1 + (body.length + 1) by decide, run_add_running e1, run_add_running e2]
      exact (stepK hp _ (by simp [body]; omega) hc2 p2 hbr
        (exec_br_not (by rw [tk]; simp [hl])) 0 hlen).trans (run_zero _ _)
    · exact regs _ (by rw [next_mem, mem2]) (fun r => by rw [next_reg])
        (by rw [next_pc, p2, pc_next hp.fit _ (by simp [body]; omega)]; simp [hl, body])

/-- 1024 samples, by induction. -/
theorem win_loop (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * (N * (w + 1)) < 0x10000)
    (hs4 : src % 4 = 0) {m0 : Word → Byte} (hc0 : CodeAt m0 base prog) {keep : Reg → Word} {s : Machine}
    (h : Inv m0 base src k0 w keep 0 s) :
    ∀ j ≤ N, ∃ s', run env (17 * j) s = .running s' ∧ Inv m0 base src k0 w keep j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := win_iter hp ha hs hs4 hc0 (by omega) hs'
    exact ⟨s'', by rw [show 17 * (j + 1) = 17 * j + 17 by omega, run_add_running e, e'], hs''⟩

/-! ## The verdict -/

/-- After the 1024th sample: the adaptive proportion's cutoff joins the flag,
and `s6` is zero exactly when the window passes. -/
theorem win_verdict (hp : Placed env base) (ha : At prog k0) {m0 : Word → Byte} (hc0 : CodeAt m0 base prog)
    {keep : Reg → Word} {s : Machine} (h : Inv m0 base src k0 w keep N s) :
    ∃ s', run env 3 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 24)) ∧ s'.mem = m0
      ∧ s'.reg S6 = (if WinOk m0 base src w then 0#32 else 1#32)
      ∧ s'.reg S1 = s.reg S1
      ∧ (WinOk m0 base src w →
          s'.reg S4 = BitVec.ofNat 32 (rct m0 base src (N * (w + 1))).last ∧
          s'.reg S5 = BitVec.ofNat 32 (rct m0 base src (N * (w + 1))).run)
      ∧ ∀ r, r ∉ written → s'.reg r = keep r := by
  have hlen := ha.len
  have hfits := ha.fits
  have hNw : N * w + N = N * (w + 1) := by rw [Nat.mul_succ]
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * (k0 + 21)) := by rw [h.pc]; simp [N]
  have hcode : CodeAt s.mem base prog := by rw [h.mem]; exact hc0
  have e1 := run_line hp verdictLine (by decide) (k0 + 21) s
    (by rw [Health.seg_of ha.seg (by decide)]; decide) (by simp [verdictLine]; omega) hcode hpc hlen
  have g6 : (s.line verdictLine).reg S6 = s.reg S6 |||
      (if BitVec.ult (s.reg S8) 589#32 = true then 1#32 else 0#32) ^^^ 1#32 := by
    simp [Machine.line, verdictLine, Machine.alu, reg_setReg, aluR, aluI, T2, S6, S8]; rfl
  have hag := agree_le m0 base (src + 4 * (N * w)) N
  have v6 : (s.line verdictLine).reg S6 = BitVec.ofNat 32
      (if (if (rct m0 base src (N * w + N)).bad then 1 else 0) = 1 ∨ APT_CUTOFF ≤ agree m0 base (src + 4 * (N * w)) N
        then 1 else 0) := by
    rw [g6, h.s6, h.s8]
    exact bad_word 589 _ _ (by decide) (by split <;> omega) hag
  have kv : ∀ r, r ≠ T2 → r ≠ S6 → (s.line verdictLine).reg r = s.reg r := by
    intro r a b
    rw [line_keeps _ _ r (by simp [verdictLine, rdOf]; exact ⟨Ne.symm a, Ne.symm b⟩)]
  refine ⟨s.line verdictLine, e1, ?_, by rw [line_mem, h.mem], ?_, kv S1 (by decide) (by decide), ?_,
    fun r hr => ?_⟩
  · rw [line_pc_at verdictLine hpc (by simp [verdictLine]; omega)]; rfl
  · rw [v6, hNw]
    simp only [WinOk, APT_CUTOFF]
    by_cases hb : (rct m0 base src (N * (w + 1))).bad = true
    · simp [hb]
    · simp only [Bool.not_eq_true] at hb
      by_cases hA : 589 ≤ agree m0 base (src + 4 * (N * w)) N
      · simp [hb, hA]
      · simp [hb, hA]
  · intro hok
    have hb : (rct m0 base src (N * w + N)).bad = false := by rw [hNw]; exact hok.1
    obtain ⟨a, b⟩ := h.s45 hb
    rw [kv S4 (by decide) (by decide), kv S5 (by decide) (by decide), a, b, hNw]
    exact ⟨rfl, rfl⟩
  · rw [line_keeps _ _ r (keeps_of (by decide) hr), h.kept r hr]

/-! ## The block, whole -/

/-- **A window, the repetition count carried in**: from instruction `k0`,
with `s1` at sample `N·w` of the stream and `s4`, `s5`, `s6` as the stream
left them, `4 + 17 · 1024 + 3` instructions later the run is at `k0 + 24`,
nothing has been written, `s1` is at the next window, `s6` is zero exactly
when window `w` passes — no run of 21 alike up to its end, counted from the
stream's start, and fewer than 589 of its samples equal its first — and
then `s4` and `s5` are the stream's for the next window. Every register
outside `written` is as it was. -/
theorem win_run (hp : Placed env base) (ha : At prog k0) (hs : src + 4 * (N * (w + 1)) < 0x10000)
    (hs4 : src % 4 = 0) (s : Machine) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0))
    (hcode : CodeAt s.mem base prog) (h1 : s.reg S1 = base + BitVec.ofNat 32 (src + 4 * (N * w)))
    (h6 : s.reg S6 = BitVec.ofNat 32 (if (rct s.mem base src (N * w)).bad then 1 else 0))
    (h45 : (rct s.mem base src (N * w)).bad = false →
      s.reg S4 = BitVec.ofNat 32 (rct s.mem base src (N * w)).last ∧
      s.reg S5 = BitVec.ofNat 32 (rct s.mem base src (N * w)).run) :
    ∃ s', run env (4 + 17 * N + 3) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 24))
      ∧ s'.mem = s.mem
      ∧ s'.reg S1 = base + BitVec.ofNat 32 (src + 4 * (N * (w + 1)))
      ∧ s'.reg S6 = (if WinOk s.mem base src w then 0#32 else 1#32)
      ∧ (WinOk s.mem base src w →
          s'.reg S4 = BitVec.ofNat 32 (rct s.mem base src (N * (w + 1))).last ∧
          s'.reg S5 = BitVec.ofNat 32 (rct s.mem base src (N * (w + 1))).run)
      ∧ ∀ r, r ∉ written → s'.reg r = s.reg r := by
  obtain ⟨s4, e4, inv0⟩ := start_run hp ha hs hs4 s hpc hcode h1 h6 h45
  obtain ⟨sL, eL, invL⟩ := win_loop hp ha hs hs4 hcode inv0 N (Nat.le_refl _)
  obtain ⟨sV, eV, pV, mV, gV, g1, g45, kV⟩ := win_verdict hp ha hcode invL
  refine ⟨sV, by rw [Nat.add_assoc, run_add_running e4, run_add_running eL, eV], pV, mV, ?_, gV, g45, kV⟩
  rw [g1, invL.s1, show N * w + N = N * (w + 1) by rw [Nat.mul_succ]]

/-! ## The tests read only the samples

What the stream's tests say depends on the samples' bit 0 and nothing else:
memory that agrees with `m` on those bits gives the same counts and the same
verdict. A kernel that writes elsewhere (a digest, a known-answer test's
scratch) leaves every later window's verdict as it was. -/

theorem rct_congr {m m' : Word → Byte} {src n : Nat} (h : ∀ j < n, bit m' base src j = bit m base src j) :
    rct m' base src n = rct m base src n := by
  unfold rct bits
  congr 1
  exact List.map_congr_left (fun j hj => h j (List.mem_range.1 hj))

theorem agree_congr {m m' : Word → Byte} {src n : Nat} (h : ∀ j < n, bit m' base src j = bit m base src j)
    (h0 : 0 < n) : agree m' base src n = agree m base src n := by
  unfold agree bits
  rw [List.map_congr_left (fun j hj => h j (List.mem_range.1 hj)), h 0 h0]

theorem winOk_congr {m m' : Word → Byte} (h : ∀ j < N * (w + 1), bit m' base src j = bit m base src j) :
    WinOk m' base src w ↔ WinOk m base src w := by
  unfold WinOk
  rw [rct_congr h, agree_congr (m := m) (m' := m') (fun i hi => by
      rw [bit_window, bit_window]; exact h _ (by simp only [N] at hi ⊢; omega)) (by decide)]

/-- The 4096 bytes of window `w` of the stream at `src`, as HASH reads them. -/
def windowBytes (m : Word → Byte) (base : Word) (src w : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (src + 4 * (N * w))) (4 * N)

/-- **A write elsewhere leaves the samples' bits alone**: memory that changed
only in the `n` bytes from `S` (a digest, a known-answer test's scratch)
gives the same bit for every one of `K` samples from `src`, if the two places
do not overlap. -/
theorem bit_of_keeps (hfit : base.toNat + 0x10000 ≤ 2^32) {S n src K : Nat} {m m' : Word → Byte}
    (h : Keeps (base + BitVec.ofNat 32 S) n m m') (hSn : S + n < 0x10000) (hK : src + 4 * K ≤ 0x10000)
    (hsep : S + n ≤ src ∨ src + 4 * K ≤ S) : ∀ j < K, bit m' base src j = bit m base src j := by
  intro j hj
  simp only [bit, sample]
  congr 1
  apply readLE_four_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit hSn (by omega) (by omega)

/-- …and every window's bytes. -/
theorem windowBytes_of_keeps (hfit : base.toNat + 0x10000 ≤ 2^32) {S n src w : Nat} {m m' : Word → Byte}
    (h : Keeps (base + BitVec.ofNat 32 S) n m m') (hSn : S + n < 0x10000)
    (hw : src + 4 * (N * (w + 1)) ≤ 0x10000)
    (hsep : S + n ≤ src + 4 * (N * w) ∨ src + 4 * (N * (w + 1)) ≤ S) :
    windowBytes m' base src w = windowBytes m base src w := by
  unfold windowBytes
  apply readBytes_congr
  intro d hd
  simp only [N] at *
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit hSn (c := src + 4 * (1024 * w) + d) (by omega) (by omega)

#print axioms win_run
#print axioms winOk_congr
#print axioms bit_of_keeps
#print axioms windowBytes_of_keeps

end Alice.Window
