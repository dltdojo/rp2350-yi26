import Dev.Equal
import Dev.Num

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- The first word of a slot's element, when the element fits in it. -/
theorem word_of_slot (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {A : Nat} {e : Elem}
    (h : SlotAt m base A e) (hA : A + 84 < 0x10000) (hl : e.length ≤ 4) :
    readLE m (base + BitVec.ofNat 32 (A + 4)) 4 = leNat e ∧ leNat e < 2 ^ (8 * e.length) := by
  rw [readLE_off hfit _ _ (by omega)]
  have b : ∀ i < 4, m (base + BitVec.ofNat 32 (A + 4 + i)) = e.getD i 0 := fun i hi => by
    rw [show A + 4 + i = A + (4 + i) by omega, h _ (by omega)]
    unfold slotBytes; simp only [show ¬ 4 + i < 4 by omega, ↓reduceIte, show 4 + i - 4 = i by omega]
  have b0 := b 0 (by decide); have b1 := b 1 (by decide); have b2 := b 2 (by decide); have b3 := b 3 (by decide)
  simp only [Nat.add_zero] at b0
  rw [b0, b1, b2, b3]
  rcases e with _ | ⟨x0, _ | ⟨x1, _ | ⟨x2, _ | ⟨x3, _ | ⟨x4, rest⟩⟩⟩⟩⟩
  · simp [leNat]
  · have := x0.isLt; simp [leNat]; try omega
  · have := x0.isLt; have := x1.isLt; simp [leNat]; try omega
  · have := x0.isLt; have := x1.isLt; have := x2.isLt; simp [leNat]; try omega
  · have := x0.isLt; have := x1.isLt; have := x2.isLt; have := x3.isLt; simp [leNat]; try omega
  · simp at hl

/-- DEC_OK to the return: the sign from the last byte's top bit, the magnitude
with that bit cleared. -/
theorem dec_ok (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * DEC_OK)) {n w R : Nat} (hn : 1 ≤ n ∧ n ≤ 4) (hw : w < 2 ^ (8 * n))
    (h7 : s.reg 7 = BitVec.ofNat 32 (w / 2 ^ (8 * n - 8))) (h28 : s.reg 28 = BitVec.ofNat 32 w)
    (h29 : s.reg 29 = BitVec.ofNat 32 (8 * n)) (h1 : s.reg 1 = base + BitVec.ofNat 32 (4 * R)) (hR : R < 881) :
    ∃ s', run env 7 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * R) ∧ s'.mem = s.mem
      ∧ s'.reg 11 = BitVec.ofNat 32 (w / 2 ^ (8 * n - 8) / 128)
      ∧ s'.reg 12 = BitVec.ofNat 32 (w % 2 ^ (8 * n - 1))
      ∧ ∀ x : Reg, x ≠ 11 → x ≠ 12 → x ≠ 30 → x ≠ 31 → s'.reg x = s.reg x := by
  have hw32 : w < 2 ^ 32 := Nat.lt_of_lt_of_le hw (Nat.pow_le_pow_right (by decide) (by omega))
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp DEC_OK (by decide) hcode hpc rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (DEC_OK + 1) (by decide) (by rw [m1]; exact hcode) p1 rfl rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (DEC_OK + 2) (by decide) (by rw [m2, m1]; exact hcode) p2 rfl rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp (DEC_OK + 3) (by decide) (by rw [m3, m2, m1]; exact hcode) p3 rfl rfl
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (DEC_OK + 4) (by decide) (by rw [m4, m3, m2, m1]; exact hcode) p4 rfl rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (DEC_OK + 5) (by decide) (by rw [m5, m4, m3, m2, m1]; exact hcode) p5 rfl rfl
  have a30 : s2.reg 30 = BitVec.ofNat 32 (8 * n - 1) := by
    rw [r2 30]; regsimp; rw [r1 29]; regsimp; rw [h29]; simp only [aluI]
    rw [show (0xfff : BitVec 12) = BitVec.ofNat 12 (4096 - 1) from rfl, w_addi_neg _ _ (by omega) (by omega) (by omega)]
  have a31 : s5.reg 31 = BitVec.ofNat 32 (2 ^ (8 * n - 1) ^^^ (2 ^ 32 - 1)) := by
    rw [r5 31]; regsimp; rw [r4 31]; regsimp; rw [r3 31]; regsimp; simp only [aluI, aluR, reg_zero]
    rw [show (0 : Word) + (1 : BitVec 12).signExtend 32 = BitVec.ofNat 32 1 by decide, r3 30]; regsimp
    rw [a30, w_sll1 _ (by omega), w_xori1 _ (Nat.pow_lt_pow_right (by decide) (by omega))]
  obtain ⟨s7, e7, p7, m7, r7⟩ := jalrStep (prog := kernel) hp (DEC_OK + 6) (by decide)
    (by rw [m6, m5, m4, m3, m2, m1]; exact hcode) p6 rfl (k' := R)
    (by rw [r6 1]; regsimp; rw [r5 1]; regsimp; rw [r4 1]; regsimp; rw [r3 1]; regsimp; rw [r2 1]; regsimp
        rw [r1 1]; regsimp; exact h1) (by omega)
  refine ⟨s7, ?_, p7, by rw [m7, m6, m5, m4, m3, m2, m1], ?_, ?_, ?_⟩
  · rw [show 7 = 1 + (1 + (1 + (1 + (1 + (1 + 1))))) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3, run_add_running e4, run_add_running e5, run_add_running e6, e7]
  · rw [r7, r6 11]; regsimp; rw [r5 11]; regsimp; rw [r4 11]; regsimp; rw [r3 11]; regsimp; rw [r2 11]; regsimp
    rw [r1 11]; regsimp; simp only [shiftI]; rw [h7, w_srli _ _ (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw32)]
    rfl
  · rw [r7, r6 12]; regsimp; simp only [aluR]
    rw [r5 28]; regsimp; rw [r4 28]; regsimp; rw [r3 28]; regsimp; rw [r2 28]; regsimp; rw [r1 28]; regsimp
    rw [h28, a31, w_and _ _ hw32 (Nat.xor_lt_two_pow (Nat.pow_lt_pow_right (by decide) (by omega)) (by decide)),
      clear_top _ _ (by omega) (by rw [show 8 * n - 1 + 1 = 8 * n by omega]; exact hw)]
  · intro x h11 h12 h30 h31
    rw [r7, r6 x]; simp only [h12, false_and, ↓reduceIte]; rw [r5 x]; simp only [h31, false_and, ↓reduceIte]
    rw [r4 x]; simp only [h31, false_and, ↓reduceIte]; rw [r3 x]; simp only [h31, false_and, ↓reduceIte]
    rw [r2 x]; simp only [h30, false_and, ↓reduceIte]; rw [r1 x]; simp only [h11, false_and, ↓reduceIte]

theorem f_num (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_NUM)) : Goes env base m0 scr s (.done C_NUM) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem beq_ofNat (a b : Nat) (ha : a < 2 ^ 32) (hb : b < 2 ^ 32) :
    (BitVec.ofNat 32 a == BitVec.ofNat 32 b) = decide (a = b) := by
  by_cases h : a = b
  · subst h; simp
  · rw [decide_eq_false h]; apply beq_false_of_ne
    intro h'; have := congrArg BitVec.toNat h'; simp only [BitVec.toNat_ofNat] at this; omega

theorem ult_ofNat' (a b : Nat) (ha : a < 2 ^ 32) (hb : b < 2 ^ 32) :
    (BitVec.ofNat 32 a).ult (BitVec.ofNat 32 b) = decide (a < b) := ult_ofNat a b ha hb

/-- **DECODE**, called with the slot at `a0` and the return at `ra`: to F_NUM
when kdec says nothing, back with the sign in `a1` and the magnitude in `a2`
otherwise. -/
theorem dec_block (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * DECODE)) {A : Nat} {e : Elem}
    (hA1 : STACK ≤ A) (hA2 : A + 84 ≤ LIMIT) (hA4 : A % 4 = 0) (h10 : s.reg 10 = base + BitVec.ofNat 32 A)
    (hslot : SlotAt s.mem base A e) (hle : e.length ≤ 80)
    {R : Nat} (h1 : s.reg 1 = base + BitVec.ofNat 32 (4 * R)) (hR : R < 881) :
    (kdec e.length (readLE s.mem (base + BitVec.ofNat 32 (A + 4)) 4) = none →
        Goes env base m0 scr s (.done C_NUM))
    ∧ ∀ sg mg, kdec e.length (readLE s.mem (base + BitVec.ofNat 32 (A + 4)) 4) = some (sg, mg) →
      ∃ n s', run env n s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * R) ∧ s'.mem = s.mem
        ∧ s'.reg 11 = BitVec.ofNat 32 sg ∧ s'.reg 12 = BitVec.ofNat 32 mg
        ∧ ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 →
          s'.reg x = s.reg x := by
  have hfit := hp.fit
  simp only [STACK, LIMIT] at hA1 hA2
  generalize hw : readLE s.mem (base + BitVec.ofNat 32 (A + 4)) 4 = w
  have hw32 : w < 2 ^ 32 := hw ▸ readLE_four_lt _ _
  -- lw t1, 0(a0)
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp DECODE (by decide) hcode hpc rfl A
    (by rw [h10]; simp) (by omega) hA4
  have a6 : s1.reg 6 = BitVec.ofNat 32 e.length := by
    rw [r1 6]; regsimp; rw [slot_len hfit hslot (by omega) (by omega)]
  -- li a1, 0; li a2, 0
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (DECODE + 1) (by decide) (by rw [m1]; exact hcode) p1 rfl rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (DECODE + 2) (by decide)
    (by rw [m2, m1]; exact hcode) p2 rfl rfl
  have z11 : s3.reg 11 = 0 := by rw [r3 11]; regsimp; rw [r2 11]; regsimp; simp only [aluI, reg_zero]; rfl
  have z12 : s3.reg 12 = 0 := by rw [r3 12]; regsimp; simp only [aluI, reg_zero]; rfl
  have k3 : ∀ x : Reg, x ≠ 6 → x ≠ 11 → x ≠ 12 → s3.reg x = s.reg x := fun x h6 h11 h12 => by
    rw [r3 x]; simp only [h12, false_and, ↓reduceIte]; rw [r2 x]; simp only [h11, false_and, ↓reduceIte]
    rw [r1 x]; simp only [h6, false_and, ↓reduceIte]
  have b6 : s3.reg 6 = BitVec.ofNat 32 e.length := by rw [r3 6]; regsimp; rw [r2 6]; regsimp; exact a6
  have mm3 : s3.mem = s.mem := by rw [m3, m2, m1]
  -- beq t1, zero, DEC_RET
  obtain ⟨s4, e4, p4, m4, r4⟩ := brStep (prog := kernel) hp (DECODE + 3) (by decide)
    (by rw [mm3]; exact hcode) p3 rfl (k' := DEC_RET) (by jump)
  rw [show taken .beq (s3.reg 6) (s3.reg 0) = decide (e.length = 0) by
    simp only [taken]; rw [b6, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
      beq_ofNat _ _ (by omega) (by decide)]] at p4
  by_cases hz : e.length = 0
  · -- the empty element: zero, straight back
    simp only [hz, decide_true, ↓reduceIte] at p4
    have hk : kdec e.length w = some (0, 0) := by rw [hz]; rfl
    refine ⟨fun h => (by rw [hk] at h; cases h), fun sg mg h => ?_⟩
    rw [hk] at h; cases h
    obtain ⟨s5, e5, p5, m5, r5⟩ := jalrStep (prog := kernel) hp DEC_RET (by decide) (by rw [m4, mm3]; exact hcode)
      p4 rfl (k' := R) (by rw [r4, k3 1 (by decide) (by decide) (by decide), h1]) (by omega)
    refine ⟨1 + 1 + 1 + 1 + 1, s5, ?_, p5, by rw [m5, m4, mm3], by rw [r5, r4, z11]; rfl, by rw [r5, r4, z12]; rfl, ?_⟩
    · rw [run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3)).trans e4), e5]
    · intro x h6 _ h11 h12 _ _ _ _; rw [r5, r4, k3 x h6 h11 h12]
  simp only [hz, decide_false, Bool.false_eq_true, ↓reduceIte] at p4
  -- li t2, 4; bltu t2, t1, F_NUM
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (DECODE + 4) (by decide)
    (by rw [m4, mm3]; exact hcode) p4 rfl rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := brStep (prog := kernel) hp (DECODE + 5) (by decide)
    (by rw [m5, m4, mm3]; exact hcode) p5 rfl (k' := F_NUM) (by jump)
  rw [show taken .bltu (s5.reg 7) (s5.reg 6) = decide (4 < e.length) by
    simp only [taken]; rw [r5 7]; regsimp; rw [r5 6]; regsimp; rw [r4 6, b6]; simp only [aluI, reg_zero]
    rw [show (0 : Word) + (4 : BitVec 12).signExtend 32 = BitVec.ofNat 32 4 by decide,
      ult_ofNat' _ _ (by decide) (by omega)]] at p6
  have mm6 : s6.mem = s.mem := by rw [m6, m5, m4, mm3]
  have e6' : run env (1 + 1 + 1 + 1 + 1 + 1) s = .running s6 := by
    rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans
      e2)).trans e3)).trans e4)).trans e5), e6]
  by_cases h4 : 4 < e.length
  · simp only [h4, decide_true, ↓reduceIte] at p6
    have hk : kdec e.length w = none := by unfold kdec; simp [hz, h4]
    exact ⟨fun _ => Goes.prepend e6' (f_num hp (by rw [mm6]; exact hcode) p6),
      fun sg mg h => by rw [hk] at h; cases h⟩
  simp only [h4, decide_false, Bool.false_eq_true, ↓reduceIte] at p6
  have hwl : w = leNat e ∧ leNat e < 2 ^ (8 * e.length) := by
    rw [← hw]; exact word_of_slot hfit hslot (by omega) (by omega)
  have hwn : w < 2 ^ (8 * e.length) := hwl.1 ▸ hwl.2
  have k6 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → s6.reg x = s.reg x := fun x h6 h7 h11 h12 => by
    rw [r6, r5 x]; simp only [h7, false_and, ↓reduceIte]; rw [r4, k3 x h6 h11 h12]
  have c6 : CodeAt s6.mem base kernel := by rw [mm6]; exact hcode
  -- lw t3, 4(a0)
  obtain ⟨s7, e7, p7, m7, r7⟩ := loadStep (prog := kernel) hp (DECODE + 6) (by decide) c6 p6 rfl (A + 4)
    (by rw [k6 10 (by decide) (by decide) (by decide) (by decide), h10]
        exact addi_pos hfit _ (by decide) (by decide) (by omega)) (by omega) (by omega)
  have a28 : s7.reg 28 = BitVec.ofNat 32 w := by rw [r7 28]; regsimp; rw [mm6, hw]
  have a6' : s7.reg 6 = BitVec.ofNat 32 e.length := by
    rw [r7 6]; regsimp; rw [r6, r5 6]; regsimp; rw [r4, b6]
  -- slli t4, t1, 3; addi t5, t4, -8; srl t2, t3, t5; andi t6, t2, 0x7f
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp (DECODE + 7) (by decide) (by rw [m7]; exact c6) p7 rfl rfl
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp (DECODE + 8) (by decide)
    (by rw [m8, m7]; exact c6) p8 rfl rfl
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp (DECODE + 9) (by decide)
    (by rw [m9, m8, m7]; exact c6) p9 rfl rfl
  obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp (DECODE + 10) (by decide)
    (by rw [m10, m9, m8, m7]; exact c6) p10 rfl rfl
  have a29 : s8.reg 29 = BitVec.ofNat 32 (8 * e.length) := by
    rw [r8 29]; regsimp; simp only [shiftI]
    rw [a6', show (3 : BitVec 5).toNat = 3 from rfl, w_slli _ _ (by omega), show e.length * 2 ^ 3 = 8 * e.length by omega]
  have a30 : s9.reg 30 = BitVec.ofNat 32 (8 * e.length - 8) := by
    rw [r9 30]; regsimp; rw [a29]; simp only [aluI]
    rw [show (0xff8 : BitVec 12) = BitVec.ofNat 12 (4096 - 8) from rfl, w_addi_neg _ _ (by omega) (by omega) (by omega)]
  have a7 : s10.reg 7 = BitVec.ofNat 32 (w / 2 ^ (8 * e.length - 8)) := by
    rw [r10 7]; regsimp; simp only [aluR]; rw [a30, r9 28]; regsimp; rw [r8 28]; regsimp; rw [a28, w_srl _ _ hw32 (by omega)]
  have a31 : s11.reg 31 = BitVec.ofNat 32 (w / 2 ^ (8 * e.length - 8) % 128) := by
    rw [r11 31]; regsimp; simp only [aluI]; rw [a7, w_andi7f _ (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw32)]
  have mm11 : s11.mem = s.mem := by rw [m11, m10, m9, m8, m7, mm6]
  have k11 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 →
      s11.reg x = s.reg x := fun x h6 h7 h11 h12 h28 h29 h30 h31 => by
    rw [r11 x]; simp only [h31, false_and, ↓reduceIte]; rw [r10 x]; simp only [h7, false_and, ↓reduceIte]
    rw [r9 x]; simp only [h30, false_and, ↓reduceIte]; rw [r8 x]; simp only [h29, false_and, ↓reduceIte]
    rw [r7 x]; simp only [h28, false_and, ↓reduceIte]; exact k6 x h6 h7 h11 h12
  have e11' : run env (1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1) s = .running s11 := by
    rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running e6').trans
      e7)).trans e8)).trans e9)).trans e10), e11]
  -- bne t6, zero, DEC_OK
  obtain ⟨s12, e12, p12, m12, r12⟩ := brStep (prog := kernel) hp (DECODE + 11) (by decide)
    (by rw [mm11]; exact hcode) p11 rfl (k' := DEC_OK) (by jump)
  rw [show taken .bne (s11.reg 31) (s11.reg 0) = !decide (w / 2 ^ (8 * e.length - 8) % 128 = 0) by
    simp only [taken, bne]; rw [a31, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
      beq_ofNat _ _ (by omega) (by decide)]] at p12
  -- the end, from DEC_OK, for any path that gets there
  have fin : ∀ (sF : Machine) (nF : Nat), run env nF s = .running sF → sF.pc = base + BitVec.ofNat 32 (4 * DEC_OK) →
      sF.mem = s.mem → (∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 →
        sF.reg x = s.reg x) → sF.reg 7 = s10.reg 7 → sF.reg 28 = s7.reg 28 → sF.reg 29 = s8.reg 29 →
      kdec e.length w = some (w / 2 ^ (8 * e.length - 8) / 128, w % 2 ^ (8 * e.length - 1)) →
      (kdec e.length w = none → Goes env base m0 scr s (.done C_NUM))
      ∧ ∀ sg mg, kdec e.length w = some (sg, mg) →
        ∃ n s', run env n s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * R) ∧ s'.mem = s.mem
          ∧ s'.reg 11 = BitVec.ofNat 32 sg ∧ s'.reg 12 = BitVec.ofNat 32 mg
          ∧ ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 →
            s'.reg x = s.reg x := by
    intro sF nF eF pF mF kF f7 f28 f29 hk
    refine ⟨fun h => (by rw [hk] at h; cases h), fun sg mg h => ?_⟩
    rw [hk] at h; cases h
    obtain ⟨s', e', p', m', a11, a12, k'⟩ := dec_ok hp (by rw [mF]; exact hcode) pF (n := e.length) (w := w) (R := R)
      ⟨by omega, by omega⟩ hwn (by rw [f7, a7]) (by rw [f28, a28]) (by rw [f29, a29])
      (by rw [kF 1 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h1])
      hR
    exact ⟨nF + 7, s', by rw [run_add_running eF, e'], p', by rw [m', mF], a11, a12,
      fun x h6 h7 h11 h12 h28 h29 h30 h31 => by rw [k' x h11 h12 h30 h31, kF x h6 h7 h11 h12 h28 h29 h30 h31]⟩
  by_cases hx : w / 2 ^ (8 * e.length - 8) % 128 = 0
  · simp only [hx, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p12
    have mm12 : s12.mem = s.mem := by rw [m12, mm11]
    -- li t6, 1; beq t1, t6, F_NUM
    obtain ⟨s13, e13, p13, m13, r13⟩ := regStep (prog := kernel) hp (DECODE + 12) (by decide)
      (by rw [mm12]; exact hcode) p12 rfl rfl
    obtain ⟨s14, e14, p14, m14, r14⟩ := brStep (prog := kernel) hp (DECODE + 13) (by decide)
      (by rw [m13, mm12]; exact hcode) p13 rfl (k' := F_NUM) (by jump)
    rw [show taken .beq (s13.reg 6) (s13.reg 31) = decide (e.length = 1) by
      simp only [taken]; rw [r13 6]; regsimp; rw [r13 31]; regsimp; simp only [aluI, reg_zero]
      rw [r12, r11 6]; regsimp; rw [r10 6]; regsimp; rw [r9 6]; regsimp; rw [r8 6]; regsimp; rw [a6',
        show (0 : Word) + (1 : BitVec 12).signExtend 32 = BitVec.ofNat 32 1 by decide,
        beq_ofNat _ _ (by omega) (by decide)]] at p14
    have e14' : run env (1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1) s = .running s14 := by
      rw [run_add_running ((run_add_running ((run_add_running e11').trans e12)).trans e13), e14]
    have mm14 : s14.mem = s.mem := by rw [m14, m13, mm12]
    by_cases h1' : e.length = 1
    · simp only [h1', decide_true, ↓reduceIte] at p14
      have hk : kdec e.length w = none := by
        unfold kdec; simp only [h1'] at hx ⊢; simp at hx; simp [hx]
      exact ⟨fun _ => Goes.prepend e14' (f_num hp (by rw [mm14]; exact hcode) p14),
        fun sg mg h => by rw [hk] at h; cases h⟩
    simp only [h1', decide_false, Bool.false_eq_true, ↓reduceIte] at p14
    -- addi t5, t4, -16; srl t6, t3, t5; andi t6, t6, 0x80; beq t6, zero, F_NUM
    obtain ⟨s15, e15, p15, m15, r15⟩ := regStep (prog := kernel) hp (DECODE + 14) (by decide)
      (by rw [mm14]; exact hcode) p14 rfl rfl
    obtain ⟨s16, e16, p16, m16, r16⟩ := regStep (prog := kernel) hp (DECODE + 15) (by decide)
      (by rw [m15, mm14]; exact hcode) p15 rfl rfl
    obtain ⟨s17, e17, p17, m17, r17⟩ := regStep (prog := kernel) hp (DECODE + 16) (by decide)
      (by rw [m16, m15, mm14]; exact hcode) p16 rfl rfl
    have b29 : s14.reg 29 = BitVec.ofNat 32 (8 * e.length) := by
      rw [r14, r13 29]; regsimp; rw [r12, r11 29]; regsimp; rw [r10 29]; regsimp; rw [r9 29]; regsimp; exact a29
    have b28 : s15.reg 28 = BitVec.ofNat 32 w := by
      rw [r15 28]; regsimp; rw [r14, r13 28]; regsimp; rw [r12, r11 28]; regsimp; rw [r10 28]; regsimp
      rw [r9 28]; regsimp; rw [r8 28]; regsimp; exact a28
    have b30 : s15.reg 30 = BitVec.ofNat 32 (8 * e.length - 16) := by
      rw [r15 30]; regsimp; rw [b29]; simp only [aluI]
      rw [show (0xff0 : BitVec 12) = BitVec.ofNat 12 (4096 - 16) from rfl, w_addi_neg _ _ (by omega) (by omega)
        (by omega)]
    have b31 : s17.reg 31 = BitVec.ofNat 32 (128 * (w / 2 ^ (8 * e.length - 16) / 128 % 2)) := by
      rw [r17 31]; regsimp; simp only [aluI]; rw [r16 31]; regsimp; simp only [aluR]
      rw [b28, b30, w_srl _ _ hw32 (by omega), w_andi80 _ (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hw32)]
    obtain ⟨s18, e18, p18, m18, r18⟩ := brStep (prog := kernel) hp (DECODE + 17) (by decide)
      (by rw [m17, m16, m15, mm14]; exact hcode) p17 rfl (k' := F_NUM) (by jump)
    rw [show taken .beq (s17.reg 31) (s17.reg 0) = decide (w / 2 ^ (8 * e.length - 16) / 128 % 2 = 0) by
      simp only [taken]; rw [b31, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
        beq_ofNat _ _ (by omega) (by decide)]; simp only [decide_eq_decide]; omega] at p18
    have e18' : run env (1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1) s = .running s18 := by
      rw [run_add_running ((run_add_running ((run_add_running ((run_add_running e14').trans e15)).trans e16)).trans
        e17), e18]
    have mm18 : s18.mem = s.mem := by rw [m18, m17, m16, m15, mm14]
    by_cases hb : w / 2 ^ (8 * e.length - 16) / 128 % 2 = 0
    · simp only [hb, decide_true, ↓reduceIte] at p18
      have hk : kdec e.length w = none := by unfold kdec; simp [hz, h4, hx, hb]
      exact ⟨fun _ => Goes.prepend e18' (f_num hp (by rw [mm18]; exact hcode) p18),
        fun sg mg h => by rw [hk] at h; cases h⟩
    simp only [hb, decide_false, Bool.false_eq_true, ↓reduceIte] at p18
    have hk : kdec e.length w = some (w / 2 ^ (8 * e.length - 8) / 128, w % 2 ^ (8 * e.length - 1)) := by
      unfold kdec; simp [hz, h4, hx, hb, h1']
    exact fin s18 _ e18' (by rw [p18]; rfl) mm18
      (fun x h6 h7 h11 h12 h28 h29 h30 h31 => by
        rw [r18, r17 x]; simp only [h31, false_and, ↓reduceIte]; rw [r16 x]; simp only [h31, false_and, ↓reduceIte]
        rw [r15 x]; simp only [h30, false_and, ↓reduceIte]; rw [r14, r13 x]; simp only [h31, false_and, ↓reduceIte]
        rw [r12, k11 x h6 h7 h11 h12 h28 h29 h30 h31])
      (by rw [r18, r17 7]; regsimp; rw [r16 7]; regsimp; rw [r15 7]; regsimp; rw [r14, r13 7]; regsimp
          rw [r12, r11 7]; regsimp)
      (by rw [r18, r17 28]; regsimp; rw [r16 28]; regsimp; exact b28.trans a28.symm)
      (by rw [r18, r17 29]; regsimp; rw [r16 29]; regsimp; rw [r15 29]; regsimp; rw [b29, a29]) hk
  · simp only [hx, decide_false, Bool.not_false, ↓reduceIte] at p12
    have hk : kdec e.length w = some (w / 2 ^ (8 * e.length - 8) / 128, w % 2 ^ (8 * e.length - 1)) := by
      unfold kdec; simp [hz, h4, hx]
    exact fin s12 _ (by rw [run_add_running e11', e12]) p12 (by rw [m12, mm11])
      (fun x h6 h7 h11 h12 h28 h29 h30 h31 => by rw [r12, k11 x h6 h7 h11 h12 h28 h29 h30 h31])
      (by rw [r12, r11 7]; regsimp) (by rw [r12, r11 28]; regsimp; rw [r10 28]; regsimp; rw [r9 28]; regsimp; rw [r8 28]; regsimp)
      (by rw [r12, r11 29]; regsimp; rw [r10 29]; regsimp; rw [r9 29]; regsimp) hk

end Exp228
