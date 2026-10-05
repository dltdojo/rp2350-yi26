/-
SPDX-License-Identifier: Apache-2.0

# exp205 — a WOTS (w = 16) verify kernel, proved

The kernel, as data; its bytes, which are `kernel.bin`; and what they do,
for every message, signature, public key and HASH.

Its first 69 instructions — setup, the digits and their checksum, and each
chain's copy and walk — are `Rv32.Wots.head`, with what they do proved in
`lean/Rv32/Wots.lean`, because exp206's MSS verifier starts with the same 69.
What is here is the rest: each chain's end compared with the public key, and
the verdict.
-/
import Rv32.Wots
import Rv32.Asm

namespace Exp205
open Rv32 Rv32.Wots

def compare : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T2 S5 (BitVec.ofNat 12 (4 * j)), .ld .lw T3 S2 (BitVec.ofNat 12 (4 * j)),
     .op .xor T2 T2 T3, .op .or S6 S6 T2]

def advance : List Instr := [
  .opi .addi S1 S1 32, .opi .addi S2 S2 32, .opi .addi A4 A4 1, .br .bne A4 S7 0xf8c ]

def finish : List Instr := [ .op .sltu A0 0 S6, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr := Wots.head ++ compare ++ advance ++ finish

/-- The kernel as bytes. This is `kernel.bin`, and the only thing on the chip
the theorems are about. -/
def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 108 := by rfl

/-- The kernel starts with `head`, so everything `lean/Rv32/Wots.lean` proves
of the first 69 instructions holds of it. -/
theorem starts : Starts kernel where
  pre := fun k hk => by
    simp only [kernel, List.append_assoc, List.getD_eq_getElem?_getD,
      List.getElem?_append_left (show k < head.length by rw [head_length]; exact hk)]
  long := by rw [kernel_length]; decide
  below := by rw [kernel_length]; decide

/-- The public key: chain `i`'s end at `KEY + 32 i`. -/
def pkAt (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (KEY + 32 * i)) 32

/-- Chain `i` checks: `15 - dᵢ` more steps from the signature reach the key. -/
def Good (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) : Prop :=
  chain H (sigAt m base i) (15 - digit m base i) = pkAt m base i

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) :
    Decidable (Good H m base i) := by unfold Good; infer_instance

/-- **The signature verifies**: all 67 chains do. -/
def Verifies (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Prop :=
  ∀ i < 67, Good H m base i

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    Decidable (Verifies H m base) := by unfold Verifies; infer_instance

theorem at_cmp : ∀ j < 8, kernel.getD (69 + 4 * j) .ecall = .ld .lw T2 S5 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (69 + 4 * j + 1) .ecall = .ld .lw T3 S2 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (69 + 4 * j + 2) .ecall = .op .xor T2 T2 T3
    ∧ kernel.getD (69 + 4 * j + 3) .ecall = .op .or S6 S6 T2 := by
  decide

/-- At the top of chain `i` — or, once `i` is 67, at the verdict: what
`Chains` says, with the input itself as the memory outside scratch, and
`s2` at the key, and `s6` zero exactly when every chain so far checked. -/
structure CInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (i : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 67 then 46 else 105))
  ch : Chains base m0 m0 i s
  s2 : s.reg S2 = base + BitVec.ofNat 32 (KEY + 32 * i)
  acc : s.reg S6 = 0 ↔ ∀ j < i, Good H m0 base j

/-! ## Block 4: one chain — the compare, and on to the next -/

/-- **What the compare decided is the definition.** With the walked chain in
the buffer and the public key untouched, the eight words matching is exactly
`Good`: `15 - d` steps from the signature reach the key. -/
theorem good_iff {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 M : Word → Byte} {i : Nat} (hi : i < 67) (hout : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M)
    (hbuf : readBytes M (base + BitVec.ofNat 32 SCR) 32 = chain H (sigAt m0 base i) (15 - digit m0 base i)) :
    (∀ j < 8, readLE M (base + BitVec.ofNat 32 (SCR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (KEY + 32 * i + 0 + 4 * j)) 4) ↔ Good H m0 base i := by
  have e : ∀ j < 8, (readLE M (base + BitVec.ofNat 32 (SCR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (KEY + 32 * i + 0 + 4 * j)) 4)
      = (readLE M (base + BitVec.ofNat 32 SCR + BitVec.ofNat 32 (4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (KEY + 32 * i) + BitVec.ofNat 32 (4 * j)) 4) := by
    intro j hj
    rw [Nat.add_zero, Nat.add_zero, off_add hfit _ _ (by simp only [SCR]; omega),
      off_add hfit _ _ (by simp only [KEY]; omega)]
  rw [show (∀ j < 8, _) ↔ (∀ j < 8, _) from forall_congr' fun j => imp_congr_right fun hj => by rw [e j hj],
    words_iff_bytes, bytes_iff_readBytes, hbuf]
  unfold Good pkAt
  rw [readBytes_congr (m' := m0) (fun d hd => by
    rw [off_add hfit _ _ (by simp only [KEY]; omega)]
    exact hout.off hfit (by simp only [SCR]; omega) (by simp only [KEY]; omega)
      (by left; simp only [KEY, SCR]; omega))]

/-- **One chain**: `56 + 3 (15 - dᵢ)` instructions, from the invariant for
`i` to the invariant for `i + 1`. -/
theorem chain_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 67) {s : Machine} (h : CInv env.hash base m0 i s) :
    ∃ s', run env (56 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
  have fit := hp.fit
  have hd := digit_lt m0 base i
  obtain ⟨sf, ef, pf, tf, bf, of, lf, df, kf⟩ := fetch starts hp hc0 hi (by rw [h.pc]; simp [hi]) h.ch
  obtain ⟨sw, ew, pw, ww, kw⟩ := skip_or_walk starts hp hc0 (x := sigAt m0 base i) (15 - digit m0 base i) (by omega)
    pf tf (by rw [kf _ (by decide) (by decide) (by decide), h.ch.t0])
    (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a0]) (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a1])
    (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a2]) ⟨by rw [bf]; rfl, of, lf, df⟩
  -- every register the walk and the fetch leave alone
  have kfw : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → sw.reg r = s.reg r := fun r a b c => (kw r b).trans (kf r a b c)
  have hcw : CodeAt sw.mem base kernel := ww.out.code fit (by simp only [SCR]; omega) (by decide) hc0
  obtain ⟨sq, eq, pq, mq, zq, kq⟩ := (compare_words (prog := kernel) hp (k0 := 69) (ra := S5) (rb := S2)
    (acc := S6) (t := T2) (u := T3) (oa := 0) (ob := 0) (a := SCR) (b := KEY + 32 * i) at_cmp
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by simp only [SCR]; omega) (by simp only [KEY]; omega) (by decide) (by simp only [KEY]; omega)
    pw hcw (by rw [kfw _ (by decide) (by decide) (by decide), h.ch.s5])
    (by rw [kfw _ (by decide) (by decide) (by decide), h.s2])) 8 (Nat.le_refl _)
  have kwq : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → sq.reg r = s.reg r :=
    fun r a b c d => (kq r d c b).trans (kfw r a b c)
  have hcq : CodeAt sq.mem base kernel := by rw [mq]; exact hcw
  -- addi s1, s1, 32; addi s2, s2, 32; addi a4, a4, 1
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 101 (by decide) hcq pq
    (i := .opi .addi S1 S1 32) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 102 (by decide) (by rw [m1]; exact hcq) p1
    (i := .opi .addi S2 S2 32) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 103 (by decide) (by rw [m2, m1]; exact hcq) p2
    (i := .opi .addi A4 A4 1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3, m2, m1]; exact hcq
  have k3 : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → s3.reg r = s.reg r :=
    fun r a b c d e f g => by rw [reg_kept r3 c, reg_kept r2 b, reg_kept r1 a, kwq r d e f g]
  have v_a4 : s3.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + (i + 1)) := by
    rw [reg_wrote r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide),
      kwq _ (by decide) (by decide) (by decide) (by decide), h.ch.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by simp only [SCR]; omega), Nat.add_assoc]
  have v_s7 : s3.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67) := by
    rw [k3 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.s7]
  have ht : taken .bne (s3.reg A4) (s3.reg S7) = decide (i + 1 < 67) := by
    rw [v_a4, v_s7]; simp only [taken]
    by_cases hl : i + 1 < 67
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by simp only [SCR]; omega), toNat_off fit _ (by simp only [SCR]; omega)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show i + 1 = 67 by omega]
  have hmem : s3.mem = sw.mem := by rw [m3, m2, m1, mq]
  -- What the branch leaves, whichever way it goes.
  have finish : ∀ s4 : Machine, run env 1 s3 = .running s4 → (∀ r, s4.reg r = s3.reg r) →
      s4.mem = s3.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if i + 1 < 67 then 46 else 105)) →
      ∃ s', run env (56 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → r ≠ S6 → s4.reg r = s.reg r :=
      fun r a b c d e f g => by rw [b4, k3 r a b c d e f g]
    have mm : s4.mem = sw.mem := by rw [m4, hmem]
    refine ⟨s4, ?_, p4, ⟨?_, by rw [b4, v_a4], ?_, by rw [b4, v_s7], ?_, ?_, ?_, ?_,
      by rw [mm]; exact ww.out, by rw [mm]; exact ww.tail, by rw [mm]; exact ww.dig⟩, ?_, ?_⟩
    · rw [show 56 + 3 * (15 - digit m0 base i) = 19 + ((1 + 3 * (15 - digit m0 base i)) + (32 + (1 + (1 + (1 + 1)))))
        by omega, run_add_running ef, run_add_running ew, run_add_running eq]
      exact run_cons e1 (run_cons e2 (run_cons e3 e4))
    · rw [b4, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
        kwq _ (by decide) (by decide) (by decide) (by decide), h.ch.s1]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [SIG]; omega)]
      congr 2
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a2]
    · rw [b4, reg_kept r3 (by decide), reg_wrote r2 (by decide), reg_kept r1 (by decide),
        kwq _ (by decide) (by decide) (by decide) (by decide), h.s2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [KEY]; omega)]
      congr 2
    · rw [b4, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), zq,
        kfw _ (by decide) (by decide) (by decide), h.acc,
        good_iff fit hi ww.out ww.buf]
      constructor
      · rintro ⟨hall, hgood⟩ j hj
        rcases (by omega : j < i ∨ j = i) with hj | hj
        · exact hall j hj
        · subst hj; exact hgood
      · intro hall
        exact ⟨fun j hj => hall j (by omega), hall i (by omega)⟩
  by_cases hl : i + 1 < 67
  · have e4 : run env 1 s3 = .running (s3.setPc (s3.pc + ((0xf8c : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 104 (by decide) hc3 p3 (i := .br .bne A4 S7 0xf8c) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p3]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 s3 = .running s3.next :=
      (stepK (prog := kernel) hp 104 (by decide) hc3 p3 (i := .br .bne A4 S7 0xf8c) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p3]
    exact pc_next fit 104 (by decide)

/-! ## The whole kernel -/

/-- The instructions the first `n` chains take: each `56 + 3 (15 - dᵢ)`. -/
def loopCount (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 56 + 3 * (15 - digit m base i)).sum

def stepsTo (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 15 - digit m base i).sum

theorem loopCount_eq (m : Word → Byte) (base : Word) (n : Nat) :
    loopCount m base n = 56 * n + 3 * stepsTo m base n := by
  induction n with
  | zero => simp [loopCount, stepsTo]
  | succ n ih =>
    simp only [loopCount, stepsTo, List.range_succ, List.map_append, List.sum_append, List.map_cons,
      List.map_nil, List.sum_cons, List.sum_nil] at *
    rw [ih]; omega

/-- 67 chains, by induction: after `j` of them, the invariant holds for `j`. -/
theorem chain_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 0 s) :
    ∀ j ≤ 67, ∃ s', run env (loopCount m0 base j) s = .running s' ∧ CInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := chain_iter hp hc0 (by omega) hs'
    refine ⟨s'', ?_, hs''⟩
    rw [show loopCount m0 base (j + 1) = loopCount m0 base j + (56 + 3 * (15 - digit m0 base j)) by
      simp [loopCount, List.range_succ, List.sum_append], run_add_running e, e']

/-- Three instructions after the last chain: the verdict, and HALT. -/
theorem halt {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 67 s) :
    ∃ s1 s2, run env 2 s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash m0 base then 0 else 1) s2 ∧ s2.mem = s.mem := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 105) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.ch.out.code hp.fit (by simp only [SCR]; omega) (by decide) hc0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 105 (by decide) hcode hpc
    (i := .op .sltu A0 0 S6) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 106 (by decide) (by rw [m1]; exact hcode) p1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : s2.reg T0 = 1 := by rw [reg_wrote r2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : s2.reg A0 = if Verifies env.hash m0 base then 0 else 1 := by
    rw [reg_kept r2 (by decide), reg_wrote r1 (by decide)]
    simp only [aluR, reg_zero]
    rw [sltu_zero]
    have : s.reg S6 = 0 ↔ Verifies env.hash m0 base := h.acc
    by_cases hv : Verifies env.hash m0 base
    · simp [hv, this.mpr hv]
    · have hn : ¬ s.reg S6 = 0 := fun e => hv (this.mp e)
      rw [ite_eq_right_of_eq_false _ _ (eq_false hn), ite_eq_right_of_eq_false _ _ (eq_false hv)]
  refine ⟨s2, s2, run_cons e1 e2, ?_, by rw [m2, m1]⟩
  rw [← a0]
  exact (step_of_code (k := 107) (by rw [kernel_length]; decide) (by rw [m2, m1]; exact hcode)
      (by rw [p2])
      (by rw [p2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [p2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[107]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-- Everything up to the `ecall` that halts: `4141 + 3 · steps` instructions. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env (4141 + 3 * steps s.mem base) s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash s.mem base then 0 else 1) s2
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 s.mem s2.mem := by
  obtain ⟨s22, e22, dinv, rg, h1, h2, h6⟩ := front starts hp s hpc hcode
  obtain ⟨sd, ed, dinv'⟩ := digits_loop starts hp
    (keeps_overlay hp.fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
    (code_of_overlay hp.fit hcode (by decide) (by decide) _) dinv 32 (Nat.le_refl _)
  obtain ⟨sm, em, pm, chm, frm⟩ := middle starts hp hcode dinv' rg h1
  have cinv : CInv env.hash base s.mem 0 sm :=
    ⟨by rw [pm]; rfl, chm,
     by rw [frm _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide), h2]; rfl,
     by rw [frm _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide), h6]; simp⟩
  obtain ⟨sl, el, cinv'⟩ := chain_loop hp hcode cinv 67 (Nat.le_refl _)
  obtain ⟨s1, s2, e2, e1, hm⟩ := halt hp hcode cinv'
  refine ⟨s1, s2, ?_, e1, by rw [hm]; exact cinv'.ch.out⟩
  rw [show 4141 + 3 * steps s.mem base = 22 + (11 * 32 + (13 + (loopCount s.mem base 67 + 2))) by
    rw [loopCount_eq]; unfold steps stepsTo; omega,
    run_add_running e22, run_add_running ed, run_add_running em, run_add_running el, e2]

/-- **The kernel verifies a WOTS signature.** From `base`, with the kernel's
432 bytes there, it halts with 0 if all 67 chains reach the public key and
with 1 if any does not — for every message, signature, key and `HASH` — and
it writes nothing outside its 131 bytes of scratch. It takes
`4142 + 3 · steps` instructions, where `steps = Σ (15 - dᵢ)` is the number of
HASH calls: the count depends on the message, and is exactly this. -/
theorem verifies {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env (4142 + 3 * steps s.mem base) s
        = .halted (if Verifies env.hash s.mem base then 0 else 1) s'
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 s.mem s'.mem := by
  obtain ⟨s1, s2, e, e1, hm⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s2, by rw [show 4142 + 3 * steps s.mem base = 4141 + 3 * steps s.mem base + 1 by omega,
    run_add_running e, e1], hm⟩

/-- **And in exactly that many.** After one fewer it is still running, for
every input: the count is not a bound. -/
theorem exactly {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1, run env (4141 + 3 * steps s.mem base) s = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp s hpc hcode
  refine ⟨s1, ?_⟩
  rw [e]

/-- The number of HASH calls is at most `67 · 15`, and the count at most
`4142 + 3 · 1005 = 7157`. -/
theorem steps_le (m : Word → Byte) (base : Word) : steps m base ≤ 1005 := by
  have : ∀ n, stepsTo m base n ≤ 15 * n := by
    intro n; induction n with
    | zero => simp [stepsTo]
    | succ n ih =>
      simp only [stepsTo, List.range_succ, List.map_append, List.sum_append, List.map_cons, List.map_nil,
        List.sum_cons, List.sum_nil] at *
      omega
  exact this 67

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction
`k`. A hundred and eight cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 432 ≤ img.size)
    (himg : ∀ d (h : d < 432), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **From the state the shell builds**: any image that begins with the
kernel's 432 bytes. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 432 ≤ img.size) (himg : ∀ d (h : d < 432), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (4141 + 3 * steps (memOfImage base img) base) (boot env.region img) = .running s1) ∧
    ∃ s', run env (4142 + 3 * steps (memOfImage base img) base) (boot env.region img)
        = .halted (if Verifies env.hash (memOfImage base img) base then 0 else 1) s'
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 (memOfImage base img) s'.mem := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  obtain ⟨s1, e1⟩ := exactly hp _ hpc hcode
  obtain ⟨s', e, h⟩ := verifies hp _ hpc hcode
  rw [hmem] at e1 e h
  exact ⟨⟨s1, e1⟩, s', e, h⟩

#print axioms bytes_words
#print axioms code_of_image
#print axioms digit_iter
#print axioms middle
#print axioms walk_chain
#print axioms good_iff
#print axioms chain_iter
#print axioms chain_loop
#print axioms halt
#print axioms verifies
#print axioms exactly
#print axioms steps_le
#print axioms from_boot

end Exp205

/-- `lean --run Wots.lean OUT` writes `image` to OUT — that is `kernel.bin` —
and prints the listing: offset, word, instruction. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp205.image
  | _ => pure ()
  for (i, k) in Exp205.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
