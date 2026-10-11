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

/-- A zeroed slot, a word of the element at 4, its length at 0. -/
theorem slot_word (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (A W n : Nat) (e : Elem)
    (hA : A + 84 < 0x10000) (hn : n ≤ 4) (hlen : e.length = n)
    (he : ∀ i < 4, BitVec.ofNat 8 (W / 256 ^ i) = e.getD i 0) :
    SlotAt (writeLE (writeLE (overlay m (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
      (base + BitVec.ofNat 32 (A + 4)) W 4) (base + BitVec.ofNat 32 A) n 4) base A e := by
  intro d hd
  rw [ev_writeLE hfit _ _ _ _ (by omega) (by omega), ev_writeLE hfit _ _ _ _ (by omega) (by omega),
    ev_overlay hfit _ _ _ _ _ (by omega) (by omega)]
  unfold slotBytes
  rcases (by omega : d < 4 ∨ (4 ≤ d ∧ d < 8) ∨ 8 ≤ d) with h | h | h
  · simp only [show A ≤ A + d ∧ A + d < A + 4 by omega, and_self, ↓reduceIte, h, show A + d - A = d by omega, hlen]
  · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show A + 4 ≤ A + d ∧ A + d < A + 4 + 4 by omega,
      and_self, ↓reduceIte, show ¬ d < 4 by omega, show A + d - (A + 4) = d - 4 by omega, false_and]
    exact he _ (by omega)
  · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show ¬ (A + 4 ≤ A + d ∧ A + d < A + 4 + 4) by omega,
      show A ≤ A + d ∧ A + d < A + 84 by omega, and_self, ↓reduceIte, show ¬ d < 4 by omega, false_and,
      show ¬ A + d < A + 4 by omega, and_false]
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]; rfl

/-- The same with one byte more, the sign's, after the word's `n`. -/
theorem slot_word_byte (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (A W n : Nat) (b : Byte) (e : Elem)
    (hA : A + 84 < 0x10000) (hn : n ≤ 4) (hlen : e.length = n + 1)
    (he : ∀ i < 4, i ≠ n → BitVec.ofNat 8 (W / 256 ^ i) = e.getD i 0) (hb : e.getD n 0 = b) :
    SlotAt (writeLE (writeByte (writeLE (overlay m (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
      (base + BitVec.ofNat 32 (A + 4)) W 4) (base + BitVec.ofNat 32 (A + n + 4)) b)
      (base + BitVec.ofNat 32 A) (n + 1) 4) base A e := by
  intro d hd
  rw [ev_writeLE hfit _ _ _ _ (by omega) (by omega), ev_writeByte hfit _ _ _ _ (by omega) (by omega),
    ev_writeLE hfit _ _ _ _ (by omega) (by omega), ev_overlay hfit _ _ _ _ _ (by omega) (by omega)]
  unfold slotBytes
  rcases (by omega : d < 4 ∨ d = n + 4 ∨ (4 ≤ d ∧ d < 8 ∧ d ≠ n + 4) ∨ (8 ≤ d ∧ d ≠ n + 4)) with h | h | h | h
  · simp only [show A ≤ A + d ∧ A + d < A + 4 by omega, and_self, ↓reduceIte, h, show A + d - A = d by omega, hlen]
  · subst h
    simp only [show A + (n + 4) = A + n + 4 by omega, show ¬ (A ≤ A + n + 4 ∧ A + n + 4 < A + 4) by omega,
      ↓reduceIte, show ¬ n + 4 < 4 by omega, show n + 4 - 4 = n by omega, hb]
  · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show ¬ A + d = A + n + 4 by omega,
      show A + 4 ≤ A + d ∧ A + d < A + 4 + 4 by omega, and_self, ↓reduceIte, show ¬ d < 4 by omega,
      show A + d - (A + 4) = d - 4 by omega, false_and]
    exact he _ (by omega) (by omega)
  · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show ¬ A + d = A + n + 4 by omega,
      show ¬ (A + 4 ≤ A + d ∧ A + d < A + 4 + 4) by omega,
      show A ≤ A + d ∧ A + d < A + 84 by omega, and_self, ↓reduceIte, show ¬ d < 4 by omega, false_and,
      show ¬ A + d < A + 4 by omega, and_false]
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]; rfl

/-- From `li t1, 1` to ENC_N: `t1` the number of bytes the magnitude takes. -/
theorem enc_n (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * (ENCODE + 22))) {m : Nat} (h0 : 0 < m) (hm : m < 2 ^ 32)
    (h12 : s.reg 12 = BitVec.ofNat 32 m) :
    ∃ k s', run env k s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * ENC_N) ∧ s'.mem = s.mem
      ∧ s'.reg 6 = BitVec.ofNat 32 (nbytes m) ∧ ∀ x : Reg, x ≠ 6 → x ≠ 7 → s'.reg x = s.reg x := by
  have li : ∀ (t : Machine) (i v : Nat), i < 881 → v < 2048 → kernel.getD i .ecall = .opi .addi 6 0 (BitVec.ofNat 12 v) →
      t.pc = base + BitVec.ofNat 32 (4 * i) → CodeAt t.mem base kernel →
      ∃ t', run env 1 t = .running t' ∧ t'.pc = base + BitVec.ofNat 32 (4 * (i + 1)) ∧ t'.mem = t.mem
        ∧ t'.reg 6 = BitVec.ofNat 32 v ∧ ∀ x : Reg, x ≠ 6 → t'.reg x = t.reg x := by
    intro t i v hi hv hI hp' hc
    obtain ⟨t', e, p, m', r⟩ := regStep (prog := kernel) hp i (by rw [kernel_length]; exact hi) hc hp' hI rfl
    refine ⟨t', e, p, m', by rw [r 6]; regsimp; simp only [aluI, reg_zero]; rw [se_small _ hv]; exact BitVec.zero_add _,
      fun x hx => by rw [r x]; simp only [hx, false_and, ↓reduceIte]⟩
  have chk : ∀ (t : Machine) (i k : Nat) (off : BitVec 12), i + 1 < 881 → k < 32 →
      kernel.getD i .ecall = .sh .srli 7 12 (BitVec.ofNat 5 k) →
      kernel.getD (i + 1) .ecall = .br .beq 7 0 off →
      BitVec.ofNat 32 (4 * (i + 1)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * ENC_N) →
      t.pc = base + BitVec.ofNat 32 (4 * i) → CodeAt t.mem base kernel → t.reg 12 = BitVec.ofNat 32 m →
      ∃ t', run env 2 t = .running t'
        ∧ t'.pc = (if m < 2 ^ k then base + BitVec.ofNat 32 (4 * ENC_N) else base + BitVec.ofNat 32 (4 * (i + 2)))
        ∧ t'.mem = t.mem ∧ ∀ x : Reg, x ≠ 7 → t'.reg x = t.reg x := by
    intro t i k off hi hk hI hJ hoff hp' hc h12'
    obtain ⟨t1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp i (by rw [kernel_length]; omega) hc hp' hI rfl
    obtain ⟨t2, e2, p2, m2, r2⟩ := brStep (prog := kernel) hp (i + 1) (by rw [kernel_length]; omega)
      (by rw [m1]; exact hc) p1 hJ hoff
    have tk : taken .beq (t1.reg 7) (t1.reg 0) = decide (m < 2 ^ k) := by
      simp only [taken]; rw [r1 7]; regsimp; rw [reg_zero]; simp only [shiftI]
      rw [h12', show (BitVec.ofNat 5 k).toNat = k by simp; omega, w_srli _ _ hm,
        show (0 : Word) = BitVec.ofNat 32 0 from rfl,
        beq_ofNat _ _ (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hm) (by decide)]
      simp only [decide_eq_decide]
      constructor
      · intro h; exact (Nat.div_eq_zero_iff_lt (Nat.pow_pos (by decide))).mp h
      · intro h; exact (Nat.div_eq_zero_iff_lt (Nat.pow_pos (by decide))).mpr h
    rw [tk] at p2
    refine ⟨t2, by rw [show 2 = 1 + 1 by rfl, run_add_running e1, e2], ?_, by rw [m2, m1],
      fun x hx => by rw [r2, r1 x]; simp only [hx, false_and, ↓reduceIte]⟩
    rw [p2]; by_cases h : m < 2 ^ k <;> simp [h]
  obtain ⟨s1, e1, p1, m1, a1, k1⟩ := li s (ENCODE + 22) 1 (by decide) (by decide) rfl hpc hcode
  obtain ⟨s2, e2, p2, m2, k2⟩ := chk s1 (ENCODE + 23) 8 _ (by decide) (by decide) rfl rfl (by jump) p1
    (by rw [m1]; exact hcode) (by rw [k1 12 (by decide), h12])
  have e2' : run env (1 + 2) s = .running s2 := by rw [run_add_running e1, e2]
  by_cases h8 : m < 2 ^ 8
  · simp only [h8, ↓reduceIte] at p2
    exact ⟨_, s2, e2', p2, by rw [m2, m1], by rw [k2 6 (by decide), a1]; unfold nbytes; simp [h8],
      fun x h6 h7 => by rw [k2 x h7, k1 x h6]⟩
  simp only [h8, ↓reduceIte] at p2
  obtain ⟨s3, e3, p3, m3, a3, k3⟩ := li s2 (ENCODE + 25) 2 (by decide) (by decide) rfl p2 (by rw [m2, m1]; exact hcode)
  obtain ⟨s4, e4, p4, m4, k4⟩ := chk s3 (ENCODE + 26) 16 _ (by decide) (by decide) rfl rfl (by jump) p3
    (by rw [m3, m2, m1]; exact hcode) (by rw [k3 12 (by decide), k2 12 (by decide), k1 12 (by decide), h12])
  have e4' : run env (1 + 2 + 1 + 2) s = .running s4 := by rw [run_add_running ((run_add_running e2').trans e3), e4]
  by_cases h16 : m < 2 ^ 16
  · simp only [h16, ↓reduceIte] at p4
    exact ⟨_, s4, e4', p4, by rw [m4, m3, m2, m1], by rw [k4 6 (by decide), a3]; unfold nbytes; simp [h8, h16],
      fun x h6 h7 => by rw [k4 x h7, k3 x h6, k2 x h7, k1 x h6]⟩
  simp only [h16, ↓reduceIte] at p4
  obtain ⟨s5, e5, p5, m5, a5, k5⟩ := li s4 (ENCODE + 28) 3 (by decide) (by decide) rfl p4
    (by rw [m4, m3, m2, m1]; exact hcode)
  obtain ⟨s6, e6, p6, m6, k6⟩ := chk s5 (ENCODE + 29) 24 _ (by decide) (by decide) rfl rfl (by jump) p5
    (by rw [m5, m4, m3, m2, m1]; exact hcode)
    (by rw [k5 12 (by decide), k4 12 (by decide), k3 12 (by decide), k2 12 (by decide), k1 12 (by decide), h12])
  have e6' : run env (1 + 2 + 1 + 2 + 1 + 2) s = .running s6 := by
    rw [run_add_running ((run_add_running e4').trans e5), e6]
  by_cases h24 : m < 2 ^ 24
  · simp only [h24, ↓reduceIte] at p6
    exact ⟨_, s6, e6', p6, by rw [m6, m5, m4, m3, m2, m1], by rw [k6 6 (by decide), a5]; unfold nbytes; simp [h8, h16, h24],
      fun x h6 h7 => by rw [k6 x h7, k5 x h6, k4 x h7, k3 x h6, k2 x h7, k1 x h6]⟩
  simp only [h24, ↓reduceIte] at p6
  obtain ⟨s7, e7, p7, m7, a7, k7⟩ := li s6 (ENCODE + 31) 4 (by decide) (by decide) rfl p6
    (by rw [m6, m5, m4, m3, m2, m1]; exact hcode)
  exact ⟨_, s7, by rw [run_add_running e6', e7], by rw [p7]; rfl, by rw [m7, m6, m5, m4, m3, m2, m1],
    by rw [a7]; unfold nbytes; simp [h8, h16, h24],
    fun x h6 h7 => by rw [k7 x h6, k6 x h7, k5 x h6, k4 x h7, k3 x h6, k2 x h7, k1 x h6]⟩

/-- **ENC_N to ENC_DONE**: the element kenc names, in the zeroed slot at `s4`. -/
theorem enc_tail (hp : Placed env base) {s : Machine} {M : Word → Byte}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * ENC_N)) {A sg m : Nat}
    (hA1 : 4 * 881 ≤ A) (hA2 : A + 84 < 0x10000) (hA4 : A % 4 = 0) (hs : sg ≤ 1) (h0 : 0 < m) (hm : m < 2 ^ 32)
    (h6 : s.reg 6 = BitVec.ofNat 32 (nbytes m)) (h11 : s.reg 11 = BitVec.ofNat 32 sg)
    (h12 : s.reg 12 = BitVec.ofNat 32 m) (h20 : s.reg 20 = base + BitVec.ofNat 32 A)
    (hM : s.mem = overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) (hcM : CodeAt M base kernel) :
    ∃ k s', run env k s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * ENC_DONE)
      ∧ SlotAt s'.mem base A (kenc sg m) ∧ Agree M s'.mem base A (A + 84)
      ∧ ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 → s'.reg x = s.reg x := by
  have hfit := hp.fit
  obtain ⟨hn1, hn4, hnlt, hnge⟩ := nbytes_facts m h0 hm
  generalize hn : nbytes m = n at *
  have hcode : CodeAt s.mem base kernel := by
    rw [hM]; exact code_of_overlay hfit hcM (by rw [kernel_length]; omega) (by omega) _
  have ag0 : Agree M s.mem base A (A + 84) := by rw [hM]; exact agree_overlay hfit _ _ (by omega)
  have hpow : 2 ^ (8 * n) = 256 ^ n := by rw [Nat.pow_mul]
  -- slli t3, t1, 3; addi t4, t3, -8; srl t2, a2, t4; andi t2, t2, 0x80
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp ENC_N (by decide) hcode hpc rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (ENC_N + 1) (by decide) (by rw [m1]; exact hcode) p1 rfl rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (ENC_N + 2) (by decide)
    (by rw [m2, m1]; exact hcode) p2 rfl rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp (ENC_N + 3) (by decide)
    (by rw [m3, m2, m1]; exact hcode) p3 rfl rfl
  have a28 : s1.reg 28 = BitVec.ofNat 32 (8 * n) := by
    rw [r1 28]; regsimp; simp only [shiftI]
    rw [h6, show (3 : BitVec 5).toNat = 3 from rfl, w_slli _ _ (by omega), show n * 2 ^ 3 = 8 * n by omega]
  have a29 : s2.reg 29 = BitVec.ofNat 32 (8 * n - 8) := by
    rw [r2 29]; regsimp; rw [a28]; simp only [aluI]
    rw [show (0xff8 : BitVec 12) = BitVec.ofNat 12 (4096 - 8) from rfl, w_addi_neg _ _ (by omega) (by omega) (by omega)]
  have a7 : s4.reg 7 = BitVec.ofNat 32 (128 * (m / 2 ^ (8 * n - 8) / 128 % 2)) := by
    rw [r4 7]; regsimp; simp only [aluI]; rw [r3 7]; regsimp; simp only [aluR]
    rw [r2 12]; regsimp; rw [r1 12]; regsimp; rw [h12, a29, w_srl _ _ hm (by omega),
      w_andi80 _ (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hm)]
  have mm4 : s4.mem = s.mem := by rw [m4, m3, m2, m1]
  have k4 : ∀ x : Reg, x ≠ 7 → x ≠ 28 → x ≠ 29 → s4.reg x = s.reg x := fun x h7 h28 h29 => by
    rw [r4 x]; simp only [h7, false_and, ↓reduceIte]; rw [r3 x]; simp only [h7, false_and, ↓reduceIte]
    rw [r2 x]; simp only [h29, false_and, ↓reduceIte]; rw [r1 x]; simp only [h28, false_and, ↓reduceIte]
  -- beq t2, zero, ENC_FITS
  obtain ⟨s5, e5, p5, m5, r5⟩ := brStep (prog := kernel) hp (ENC_N + 4) (by decide)
    (by rw [mm4]; exact hcode) p4 rfl (k' := ENC_FITS) (by jump)
  rw [show taken .beq (s4.reg 7) (s4.reg 0) = decide (m / 2 ^ (8 * n - 8) / 128 % 2 = 0) by
    simp only [taken]; rw [a7, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
      beq_ofNat _ _ (by omega) (by decide)]; simp only [decide_eq_decide]; omega] at p5
  have e5' : run env (1 + 1 + 1 + 1 + 1) s = .running s5 := by
    rw [run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3)).trans e4), e5]
  have mm5 : s5.mem = s.mem := by rw [m5, mm4]
  have c5 : CodeAt s5.mem base kernel := by rw [mm5]; exact hcode
  have b20 : s5.reg 20 = base + BitVec.ofNat 32 A := by
    rw [r5, k4 20 (by decide) (by decide) (by decide), h20]
  have b11 : s5.reg 11 = BitVec.ofNat 32 sg := by rw [r5, k4 11 (by decide) (by decide) (by decide), h11]
  have b12 : s5.reg 12 = BitVec.ofNat 32 m := by rw [r5, k4 12 (by decide) (by decide) (by decide), h12]
  have b6 : s5.reg 6 = BitVec.ofNat 32 n := by rw [r5, k4 6 (by decide) (by decide) (by decide), h6]
  have b28 : s5.reg 28 = BitVec.ofNat 32 (8 * n) := by
    rw [r5, r4 28]; regsimp; rw [r3 28]; regsimp; rw [r2 28]; regsimp; exact a28
  by_cases ht : m / 2 ^ (8 * n - 8) / 128 % 2 = 0
  · -- the top bit clear: the sign goes into it
    simp only [ht, decide_true, ↓reduceIte] at p5
    have hlt : m < 2 ^ (8 * n - 1) := by
      rcases (by omega : n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4) with rfl | rfl | rfl | rfl <;> simp at ht hnlt ⊢ <;> omega
    have hk : kenc sg m = bytesOf (m + sg * 2 ^ (8 * n - 1)) n := by
      unfold kenc; simp [show m ≠ 0 by omega, hn, ht]
    obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp ENC_FITS (by decide) c5 p5 rfl rfl
    obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (ENC_FITS + 1) (by decide)
      (by rw [m6]; exact c5) p6 rfl rfl
    obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp (ENC_FITS + 2) (by decide)
      (by rw [m7, m6]; exact c5) p7 rfl rfl
    have hsl : sg * 2 ^ (8 * n - 1) < 2 ^ 32 := by
      have : 2 ^ (8 * n - 1) ≤ 2 ^ 31 := Nat.pow_le_pow_right (by decide) (by omega)
      rcases (by omega : sg = 0 ∨ sg = 1) with rfl | rfl <;> omega
    have a12 : s8.reg 12 = BitVec.ofNat 32 (m + sg * 2 ^ (8 * n - 1)) := by
      rw [r8 12]; regsimp; simp only [aluR]; rw [r7 12]; regsimp; rw [r6 12]; regsimp; rw [b12, r7 30]; regsimp
      simp only [aluR]; rw [r6 11]; regsimp; rw [r6 29]; regsimp; simp only [aluI]; rw [b11, b28]
      rw [show (0xfff : BitVec 12) = BitVec.ofNat 12 (4096 - 1) from rfl, w_addi_neg _ _ (by omega) (by omega) (by omega),
        w_sll _ _ (by omega) hsl, w_or_top _ _ _ hs (by omega) hlt]
    obtain ⟨s9, e9, p9, m9, r9⟩ := storeStep (prog := kernel) hp (ENC_FITS + 3) (by decide)
      (by rw [m8, m7, m6]; exact c5) p8 rfl (A + 4)
      (by rw [r8 20]; regsimp; rw [r7 20]; regsimp; rw [r6 20]; regsimp; rw [b20]
          exact addi_pos hfit _ (by decide) (by decide) (by omega)) (by omega) (by omega)
    have c8 : CodeAt s8.mem base kernel := by rw [m8, m7, m6]; exact c5
    have c9 : CodeAt s9.mem base kernel := by
      rw [m9]; exact code_keep hfit c8 ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _))
        (by omega)
    obtain ⟨s10, e10, p10, m10, r10⟩ := storeStep (prog := kernel) hp (ENC_FITS + 4) (by decide) c9
      p9 rfl A (by rw [r9, r8 20]; regsimp; rw [r7 20]; regsimp; rw [r6 20]; regsimp; rw [b20]; simp)
      (by omega) hA4
    have W : (s9.reg 6).toNat = n := by
      rw [r9, r8 6]; regsimp; rw [r7 6]; regsimp; rw [r6 6]; regsimp; rw [b6, BitVec.toNat_ofNat]; omega
    have V : (s8.reg 12).toNat = m + sg * 2 ^ (8 * n - 1) := by
      rw [a12, BitVec.toNat_ofNat]; have : 2 ^ (8 * n - 1) ≤ 2 ^ 31 := Nat.pow_le_pow_right (by decide) (by omega)
      rcases (by omega : sg = 0 ∨ sg = 1) with rfl | rfl <;> simp <;> omega
    have mem10 : s10.mem = writeLE (writeLE (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (base + BitVec.ofNat 32 (A + 4)) (m + sg * 2 ^ (8 * n - 1)) 4) (base + BitVec.ofNat 32 A) n 4 := by
      rw [m10, W, m9, V, m8, m7, m6, mm5, hM]
    have hW : m + sg * 2 ^ (8 * n - 1) < 256 ^ n := by
      rw [← hpow]
      have : 2 ^ (8 * n) = 2 * 2 ^ (8 * n - 1) := by rw [← Nat.pow_succ']; congr 1; omega
      rcases (by omega : sg = 0 ∨ sg = 1) with rfl | rfl <;> omega
    refine ⟨1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1, s10, ?_, by rw [p10]; rfl, ?_, ?_, ?_⟩
    · rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running e5').trans
        e6)).trans e7)).trans e8)).trans e9), e10]
    · rw [mem10, hk]
      exact slot_word hfit _ _ _ _ _ (by omega) hn4 (bytesOf_length _ _) (fun i hi => by
        by_cases hin : i < n
        · rw [bytesOf_getD _ _ _ hin]
        · rw [byte_hi_zero _ _ _ hW (by omega), List.getD_eq_getElem?_getD,
            List.getElem?_eq_none (by rw [bytesOf_length]; omega)]; rfl)
    · rw [mem10]
      have a1 : Agree M (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) base A (A + 84) :=
        agree_overlay hfit _ _ (by omega)
      have a2 := (agree_writeLE hfit (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (m + sg * 2 ^ (8 * n - 1)) (c := A + 4) (by omega)).widen (lo' := A) (hi' := A + 84) (by omega) (by omega)
      have a3 := (agree_writeLE hfit (writeLE (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (base + BitVec.ofNat 32 (A + 4)) (m + sg * 2 ^ (8 * n - 1)) 4) n (c := A) (by omega)).widen
        (lo' := A) (hi' := A + 84) (by omega) (by omega)
      exact a1.trans (a2.trans a3)
    · intro x h6 h7 h12 h28 h29 h30 h31
      rw [r10, r9, r8 x]; simp only [h12, false_and, ↓reduceIte]; rw [r7 x]; simp only [h30, false_and, ↓reduceIte]
      rw [r6 x]; simp only [h29, false_and, ↓reduceIte]; rw [r5, k4 x h7 h28 h29]
  · -- the top bit set: a byte of its own for the sign
    simp only [ht, decide_false, Bool.false_eq_true, ↓reduceIte] at p5
    have hk : kenc sg m = bytesOf m n ++ [BitVec.ofNat 8 (sg * 128)] := by
      unfold kenc; simp [show m ≠ 0 by omega, hn, show m / 2 ^ (8 * n - 8) / 128 % 2 = 1 by omega]
    obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (ENC_N + 5) (by decide) c5 p5 rfl rfl
    obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (ENC_N + 6) (by decide)
      (by rw [m6]; exact c5) p6 rfl rfl
    have c7 : CodeAt s7.mem base kernel := by rw [m7, m6]; exact c5
    have a30 : s7.reg 30 = BitVec.ofNat 32 (sg * 2 ^ 7) := by
      rw [r7 30]; regsimp; rw [r6 30]; regsimp; simp only [shiftI]
      rw [b11, show (7 : BitVec 5).toNat = 7 from rfl, w_slli _ _ (by omega)]
    have a31 : s7.reg 31 = base + BitVec.ofNat 32 (A + n) := by
      rw [r7 31]; regsimp; simp only [aluR]; rw [r6 20]; regsimp; rw [r6 6]; regsimp; rw [b20, b6,
        off_add hfit _ _ (by omega)]
    -- sw a2, 4(s4)
    obtain ⟨s8, e8, p8, m8, r8⟩ := storeStep (prog := kernel) hp (ENC_N + 7) (by decide) c7 p7 rfl (A + 4)
      (by rw [r7 20]; regsimp; rw [r6 20]; regsimp; rw [b20]; exact addi_pos hfit _ (by decide) (by decide) (by omega))
      (by omega) (by omega)
    have c8 : CodeAt s8.mem base kernel := by
      rw [m8]; exact code_keep hfit c7 ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _))
        (by omega)
    -- sb t5, 4(t6)
    obtain ⟨s9, e9, p9, m9, r9⟩ := sbStep (prog := kernel) hp (ENC_N + 8) (by decide) c8 p8 rfl (A + n + 4)
      (by rw [r8, a31]; exact addi_pos hfit _ (by decide) (by decide) (by omega)) (by omega)
    have c9 : CodeAt s9.mem base kernel := by
      rw [m9]; exact code_keep hfit c8 ((agree_writeByte hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _))
        (by omega)
    -- addi t1, t1, 1; sw t1, 0(s4); j ENC_DONE
    obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp (ENC_N + 9) (by decide) c9 p9 rfl rfl
    obtain ⟨s11, e11, p11, m11, r11⟩ := storeStep (prog := kernel) hp (ENC_N + 10) (by decide)
      (by rw [m10]; exact c9) p10 rfl A
      (by rw [r10 20]; regsimp; rw [r9, r8, r7 20]; regsimp; rw [r6 20]; regsimp; rw [b20]; simp) (by omega) hA4
    have c11 : CodeAt s11.mem base kernel := by
      rw [m11]; exact code_keep hfit (by rw [m10]; exact c9)
        ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _)) (by omega)
    obtain ⟨s12, e12, p12, m12, r12⟩ := jStep (prog := kernel) hp (ENC_N + 11) (by decide) c11 p11 rfl
      (k' := ENC_DONE) (by jump)
    have W : (s10.reg 6).toNat = n + 1 := by
      rw [r10 6]; regsimp; simp only [aluI]; rw [r9, r8, r7 6]; regsimp; rw [r6 6]; regsimp; rw [b6]
      rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, w_addi_pos _ _ (by omega) (by decide), BitVec.toNat_ofNat]
      omega
    have V : (s7.reg 12).toNat = m := by
      rw [r7 12]; regsimp; rw [r6 12]; regsimp; rw [b12, BitVec.toNat_ofNat]; omega
    have B : BitVec.ofNat 8 (s8.reg 30).toNat = BitVec.ofNat 8 (sg * 128) := by
      rw [r8, a30, BitVec.toNat_ofNat]; apply ofNat_eq_mod; rcases (by omega : sg = 0 ∨ sg = 1) with rfl | rfl <;> rfl
    have mem12 : s12.mem = writeLE (writeByte (writeLE (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (base + BitVec.ofNat 32 (A + 4)) m 4) (base + BitVec.ofNat 32 (A + n + 4)) (BitVec.ofNat 8 (sg * 128)))
        (base + BitVec.ofNat 32 A) (n + 1) 4 := by
      rw [m12, m11, W, m10, m9, B, m8, V, m7, m6, mm5, hM]
    refine ⟨1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1, s12, ?_, p12, ?_, ?_, ?_⟩
    · rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running
        ((run_add_running e5').trans e6)).trans e7)).trans e8)).trans e9)).trans e10)).trans e11), e12]
    · rw [mem12, hk]
      exact slot_word_byte hfit _ _ _ _ _ _ (by omega) hn4 (by simp [bytesOf_length])
        (fun i hi hin => by
          by_cases hlt : i < n
          · rw [List.getD_eq_getElem?_getD, List.getElem?_append_left (by rw [bytesOf_length]; exact hlt),
              ← List.getD_eq_getElem?_getD, bytesOf_getD _ _ _ hlt]
          · rw [byte_hi_zero _ _ _ hnlt (by omega), List.getD_eq_getElem?_getD,
              List.getElem?_eq_none (by simp [bytesOf_length]; omega)]; rfl)
        (by rw [List.getD_eq_getElem?_getD, List.getElem?_append_right (by rw [bytesOf_length]; exact Nat.le_refl _), bytesOf_length]
            simp)
    · rw [mem12]
      have a1 : Agree M (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) base A (A + 84) :=
        agree_overlay hfit _ _ (by omega)
      have a2 := (agree_writeLE hfit (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        m (c := A + 4) (by omega)).widen (lo' := A) (hi' := A + 84) (by omega) (by omega)
      have a3 := (agree_writeByte hfit (writeLE (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (base + BitVec.ofNat 32 (A + 4)) m 4) (BitVec.ofNat 8 (sg * 128)) (c := A + n + 4) (by omega)).widen
        (lo' := A) (hi' := A + 84) (by omega) (by omega)
      have a4 := (agree_writeLE hfit (writeByte (writeLE (overlay M (base + BitVec.ofNat 32 A) 84 (fun _ => 0))
        (base + BitVec.ofNat 32 (A + 4)) m 4) (base + BitVec.ofNat 32 (A + n + 4)) (BitVec.ofNat 8 (sg * 128)))
        (n + 1) (c := A) (by omega)).widen (lo' := A) (hi' := A + 84) (by omega) (by omega)
      exact a1.trans (a2.trans (a3.trans a4))
    · intro x h6 h7 h12 h28 h29 h30 h31
      rw [r12, r11, r10 x]; simp only [h6, false_and, ↓reduceIte]; rw [r9, r8, r7 x]
      simp only [h31, false_and, ↓reduceIte]; rw [r6 x]; simp only [h30, false_and, ↓reduceIte]; rw [r5, k4 x h7 h28 h29]

/-- **ENCODE**: a zeroed slot at `s4`, then kenc's element in it. -/
theorem enc_block (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * ENCODE)) {A sg m : Nat}
    (hA1 : STACK ≤ A) (hA2 : A + 84 ≤ LIMIT) (hA4 : A % 4 = 0) (hs : sg ≤ 1) (hm : m < 2 ^ 32)
    (h11 : s.reg 11 = BitVec.ofNat 32 sg) (h12 : s.reg 12 = BitVec.ofNat 32 m)
    (h20 : s.reg 20 = base + BitVec.ofNat 32 A) :
    ∃ k s', run env k s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * ENC_DONE)
      ∧ SlotAt s'.mem base A (kenc sg m) ∧ Agree s.mem s'.mem base A (A + 84)
      ∧ ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 → s'.reg x = s.reg x := by
  have hfit := hp.fit
  simp only [STACK, LIMIT] at hA1 hA2
  obtain ⟨s1, e1, p1, m1, r1⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0) (a := A) (k0 := ENCODE)
    hp (by decide) (by decide) (by decide) (by omega) (by omega) (by rw [kernel_length]; omega)
    hpc hcode h20 (by decide) 21 (Nat.le_refl _)
  have mm1 : s1.mem = overlay s.mem (base + BitVec.ofNat 32 A) 84 (fun _ => 0) := by rw [m1, Nat.add_zero]
  have c1 : CodeAt s1.mem base kernel := by
    rw [mm1]; exact code_of_overlay hfit hcode (by rw [kernel_length]; omega) (by omega) _
  obtain ⟨s2, e2, p2, m2, r2⟩ := brStep (prog := kernel) hp (ENCODE + 21) (by decide) c1 p1 rfl
    (k' := ENC_DONE) (by jump)
  rw [show taken .beq (s1.reg 12) (s1.reg 0) = decide (m = 0) by
    simp only [taken]; rw [r1, h12, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
      beq_ofNat _ _ hm (by decide)]] at p2
  by_cases h0 : m = 0
  · simp only [h0, decide_true, ↓reduceIte] at p2
    subst h0
    refine ⟨21 + 1, s2, by rw [run_add_running e1, e2], p2, ?_, ?_, fun x _ _ _ _ _ _ _ => by rw [r2, r1]⟩
    · rw [m2, mm1, show kenc sg 0 = [] by simp [kenc]]; exact slot_zero hfit _ _ (by omega)
    · rw [m2, mm1]; exact agree_overlay hfit _ _ (by omega)
  simp only [h0, decide_false, Bool.false_eq_true, ↓reduceIte] at p2
  obtain ⟨k3, s3, e3, p3, m3, a6, k3'⟩ := enc_n hp (by rw [m2]; exact c1) p2 (m := m) (by omega) hm
    (by rw [r2, r1, h12])
  obtain ⟨k4, s4, e4, p4, slot, ag, k4'⟩ := enc_tail hp (M := s.mem) p3 (A := A) (sg := sg) (m := m)
    (by omega) (by omega) hA4 hs (by omega) hm a6
    (by rw [k3' 11 (by decide) (by decide), r2, r1, h11]) (by rw [k3' 12 (by decide) (by decide), r2, r1, h12])
    (by rw [k3' 20 (by decide) (by decide), r2, r1, h20]) (by rw [m3, m2, mm1]) hcode
  refine ⟨21 + 1 + k3 + k4, s4, by rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4],
    p4, slot, ag, fun x h6 h7 h12 h28 h29 h30 h31 => by rw [k4' x h6 h7 h12 h28 h29 h30 h31, k3' x h6 h7, r2, r1]⟩

/-- **CORE**: `(a3, a4) + (a5, a6)` into `(a1, a2)`, then ENCODE. -/
theorem core_block (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * CORE)) {s1 m1 s2 m2 : Nat}
    (hs1 : s1 ≤ 1) (hs2 : s2 ≤ 1) (hm1 : m1 < 2 ^ 31) (hm2 : m2 < 2 ^ 31)
    (h13 : s.reg 13 = BitVec.ofNat 32 s1) (h14 : s.reg 14 = BitVec.ofNat 32 m1)
    (h15 : s.reg 15 = BitVec.ofNat 32 s2) (h16 : s.reg 16 = BitVec.ofNat 32 m2) :
    ∃ k s', run env k s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * ENCODE) ∧ s'.mem = s.mem
      ∧ s'.reg 11 = BitVec.ofNat 32 (kcore s1 m1 s2 m2).1 ∧ s'.reg 12 = BitVec.ofNat 32 (kcore s1 m1 s2 m2).2
      ∧ ∀ x : Reg, x ≠ 11 → x ≠ 12 → s'.reg x = s.reg x := by
  obtain ⟨t1, e1, p1, n1, q1⟩ := brStep (prog := kernel) hp CORE (by decide) hcode hpc rfl (k' := CORE_DIFF) (by jump)
  rw [show taken .bne (s.reg 13) (s.reg 15) = !decide (s1 = s2) by
    simp only [taken, bne]; rw [h13, h15, beq_ofNat _ _ (by omega) (by omega)]] at p1
  have c1 : CodeAt t1.mem base kernel := by rw [n1]; exact hcode
  have add0 : ∀ x : Word, x + (0 : BitVec 12).signExtend 32 = x := fun x => by
    rw [show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]
  have wsub : ∀ a b : Nat, b ≤ a → a < 2 ^ 32 → BitVec.ofNat 32 a - BitVec.ofNat 32 b = BitVec.ofNat 32 (a - b) :=
    fun a b h1 h2 => by
      apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_sub, BitVec.toNat_ofNat]; omega
  have wadd : ∀ a b : Nat, a + b < 2 ^ 32 → BitVec.ofNat 32 a + BitVec.ofNat 32 b = BitVec.ofNat 32 (a + b) :=
    fun a b h => by
      apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega
  have kq : ∀ r, t1.reg r = s.reg r := q1
  by_cases hsame : s1 = s2
  · simp only [hsame, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p1
    obtain ⟨t2, e2, p2, n2, q2⟩ := regStep (prog := kernel) hp (CORE + 1) (by decide) c1 p1 rfl rfl
    obtain ⟨t3, e3, p3, n3, q3⟩ := regStep (prog := kernel) hp (CORE + 2) (by decide) (by rw [n2]; exact c1) p2 rfl rfl
    obtain ⟨t4, e4, p4, n4, q4⟩ := jStep (prog := kernel) hp (CORE + 3) (by decide) (by rw [n3, n2]; exact c1) p3 rfl
      (k' := ENCODE) (by jump)
    have hk : kcore s1 m1 s2 m2 = (s1, m1 + m2) := by simp [kcore, hsame]
    refine ⟨1 + 1 + 1 + 1, t4, by rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4],
      p4, by rw [n4, n3, n2, n1], ?_, ?_, fun x h11 h12 => ?_⟩
    · rw [q4, q3 11]; regsimp; simp only [aluI]; rw [q2 13]; regsimp; rw [kq, h13, add0, hk]
    · rw [q4, q3 12]; regsimp; rw [q2 12]; regsimp; simp only [aluR]; rw [kq, kq, h14, h16, hk, wadd _ _ (by omega)]
    · rw [q4, q3 x]; simp only [h11, false_and, ↓reduceIte]; rw [q2 x]; simp only [h12, false_and, ↓reduceIte]; rw [kq]
  simp only [hsame, decide_false, Bool.not_false, ↓reduceIte] at p1
  obtain ⟨t2, e2, p2, n2, q2⟩ := brStep (prog := kernel) hp CORE_DIFF (by decide) c1 p1 rfl (k' := CORE_LT) (by jump)
  rw [show taken .bltu (t1.reg 14) (t1.reg 16) = decide (m1 < m2) by
    simp only [taken]; rw [kq, kq, h14, h16, ult_ofNat' _ _ (by omega) (by omega)]] at p2
  have c2 : CodeAt t2.mem base kernel := by rw [n2, n1]; exact hcode
  have kq2 : ∀ r, t2.reg r = s.reg r := fun r => by rw [q2, kq]
  by_cases hlt : m1 < m2
  · simp only [hlt, decide_true, ↓reduceIte] at p2
    obtain ⟨t3, e3, p3, n3, q3⟩ := regStep (prog := kernel) hp CORE_LT (by decide) c2 p2 rfl rfl
    obtain ⟨t4, e4, p4, n4, q4⟩ := regStep (prog := kernel) hp (CORE_LT + 1) (by decide) (by rw [n3]; exact c2) p3 rfl rfl
    have hk : kcore s1 m1 s2 m2 = (s2, m2 - m1) := by simp [kcore, hsame, hlt]
    refine ⟨1 + 1 + 1 + 1, t4, by rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4],
      by rw [p4]; rfl, by rw [n4, n3, n2, n1], ?_, ?_, fun x h11 h12 => ?_⟩
    · rw [q4 11]; regsimp; simp only [aluI]; rw [q3 15]; regsimp; rw [kq2, h15, add0, hk]
    · rw [q4 12]; regsimp; rw [q3 12]; regsimp; simp only [aluR]; rw [kq2, kq2, h14, h16, hk, wsub _ _ (by omega) (by omega)]
    · rw [q4 x]; simp only [h11, false_and, ↓reduceIte]; rw [q3 x]; simp only [h12, false_and, ↓reduceIte]; rw [kq2]
  · simp only [hlt, decide_false, Bool.false_eq_true, ↓reduceIte] at p2
    obtain ⟨t3, e3, p3, n3, q3⟩ := regStep (prog := kernel) hp (CORE_DIFF + 1) (by decide) c2 p2 rfl rfl
    obtain ⟨t4, e4, p4, n4, q4⟩ := regStep (prog := kernel) hp (CORE_DIFF + 2) (by decide) (by rw [n3]; exact c2) p3 rfl rfl
    obtain ⟨t5, e5, p5, n5, q5⟩ := jStep (prog := kernel) hp (CORE_DIFF + 3) (by decide) (by rw [n4, n3]; exact c2) p4 rfl
      (k' := ENCODE) (by jump)
    have hk : kcore s1 m1 s2 m2 = (s1, m1 - m2) := by simp [kcore, hsame, hlt]
    refine ⟨1 + 1 + 1 + 1 + 1, t5, by rw [run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans
      e2)).trans e3)).trans e4), e5], p5, by rw [n5, n4, n3, n2, n1], ?_, ?_, fun x h11 h12 => ?_⟩
    · rw [q5, q4 11]; regsimp; simp only [aluI]; rw [q3 13]; regsimp; rw [kq2, h13, add0, hk]
    · rw [q5, q4 12]; regsimp; rw [q3 12]; regsimp; simp only [aluR]; rw [kq2, kq2, h14, h16, hk, wsub _ _ (by omega) (by omega)]
    · rw [q5, q4 x]; simp only [h11, false_and, ↓reduceIte]; rw [q3 x]; simp only [h12, false_and, ↓reduceIte]; rw [kq2]

end Exp228
