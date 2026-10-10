import Dev.Cast

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- A slot's bytes say which element it holds. -/
theorem slot_inj {a b : Elem} (ha : a.length ≤ 80) (hb : b.length ≤ 80)
    (h : ∀ d < 84, slotBytes a d = slotBytes b d) : a = b := by
  have hl : a.length = b.length := by
    have := congrArg BitVec.toNat (h 0 (by decide))
    simp only [slotBytes, show (0 : Nat) < 4 by decide, ↓reduceIte, Nat.pow_zero, Nat.div_one,
      BitVec.toNat_ofNat] at this
    omega
  apply List.ext_getElem hl
  intro i h1 h2
  have := h (i + 4) (by omega)
  simp only [slotBytes, show ¬ i + 4 < 4 by omega, ↓reduceIte, show i + 4 - 4 = i by omega,
    List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h1, List.getElem?_eq_getElem h2, Option.getD_some] at this
  exact this

/-- **Two slots compared a word at a time**: all 21 words equal exactly when
the elements are. -/
theorem slots_equal (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {A B : Nat} {a b : Elem}
    (hA : SlotAt m base A a) (hB : SlotAt m base B b) (hA' : A + 84 < 0x10000) (hB' : B + 84 < 0x10000)
    (ha : a.length ≤ 80) (hb : b.length ≤ 80) :
    (∀ j < 21, readLE m (base + BitVec.ofNat 32 (A + 0 + 4 * j)) 4 = readLE m (base + BitVec.ofNat 32 (B + 0 + 4 * j)) 4)
      ↔ a = b := by
  constructor
  · intro h
    apply slot_inj ha hb
    intro d hd
    have w := congrArg (fun v => BitVec.ofNat 8 (v / 256 ^ (d % 4))) (h (d / 4) (by omega))
    rw [readLE_four_byte _ _ _ (by omega), readLE_four_byte _ _ _ (by omega), off_add hfit _ _ (by omega),
      off_add hfit _ _ (by omega), show A + 0 + 4 * (d / 4) + d % 4 = A + d by omega,
      show B + 0 + 4 * (d / 4) + d % 4 = B + d by omega, hA d hd, hB d hd] at w
    exact w
  · rintro rfl j hj
    apply readLE_four_eq
    intro d hd
    rw [off_add hfit _ _ (by omega), off_add hfit _ _ (by omega),
      show A + 0 + 4 * j + d = A + (4 * j + d) by omega, show B + 0 + 4 * j + d = B + (4 * j + d) by omega,
      hA _ (by omega), hB _ (by omega)]

/-- What OP_EQUAL (`v = false`) and OP_EQUALVERIFY (`v = true`) do. -/
def eqRes (v : Bool) (c : Cfg) : Res :=
  match c.st with
  | a :: b :: r =>
    if v then (if a = b then .next ⟨c.pc + 1, r, c.sigs⟩ else .done C_EQV)
    else .next ⟨c.pc + 1, (if a = b then [1] else []) :: r, c.sigs⟩
  | _ => .done C_UNDER

theorem f_eqv (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_EQV)) : Goes env base m0 scr s (.done C_EQV) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-- **EQ**, the body both share, with `t6` saying which. -/
theorem eq_core (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine} (v : Bool)
    (hc : Core base m0 scr c s) (hpc : s.pc = base + BitVec.ofNat 32 (4 * EQ))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1)) (h31 : s.reg 31 = if v then 1#32 else 0#32)
    (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (eqRes v c) := by
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    simp only [eqRes, hst]
    exact need_fail (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump) (by decide) (by simp [hst])
  | [_] =>
    simp only [eqRes, hst]
    exact need_fail (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump) (by decide) (by simp [hst])
  | a :: b :: r =>
    simp only [eqRes, hst]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    have ha : a.length ≤ 80 := hc.elems a (by rw [hst]; simp)
    have hb : b.length ≤ 80 := hc.elems b (by rw [hst]; simp)
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (EQ + 3) (by decide)
      (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (EQ + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp (EQ + 5) (by decide)
      (by rw [m3, m2, m1]; exact code) p3 rfl rfl
    have k4 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → s4.reg x = s.reg x :=
      fun x h6 h7 h13 h14 h29 => by
        rw [r4 x]; simp only [h29, false_and, ↓reduceIte]; rw [r3 x]; simp only [h14, false_and, ↓reduceIte]
        rw [r2 x]; simp only [h13, false_and, ↓reduceIte]; exact r1 x h6 h7
    have a13 : s4.reg 13 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1)) := by
      rw [r4 13]; regsimp; rw [r3 13]; regsimp; rw [r2 13]; regsimp
      rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have a14 : s4.reg 14 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r4 14]; regsimp; rw [r3 14]; regsimp; rw [r2 20]; regsimp
      rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have z4 : s4.reg 29 = 0 := by rw [r4 29]; regsimp; simp only [aluI, reg_zero]; rfl
    have mm4 : s4.mem = s.mem := by rw [m4, m3, m2, m1]
    -- the 21 words compared
    obtain ⟨s5, e5, p5, m5, z5, k5⟩ := compare_n (prog := kernel) (n := 21) (k0 := EQ + 6) (ra := 13) (rb := 14)
      (acc := 29) (t := 6) (u := 7) (oa := 0) (ob := 0) (a := STACK + 84 * (r.length + 1)) (b := STACK + 84 * r.length)
      hp (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; omega)
      (by simp only [STACK]; omega) p4 (by rw [mm4]; exact code) a13 a14 (by decide) 21 (Nat.le_refl _)
    have zz : s5.reg 29 = 0 ↔ a = b := by
      rw [z5, mm4]; simp only [z4, true_and]
      exact slots_equal hfit st.top st.second (by simp only [STACK]; omega) (by simp only [STACK]; omega) ha hb
    have mm5 : s5.mem = s.mem := by rw [m5, mm4]
    -- addi s4, s4, -168
    obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (EQ + 90) (by decide)
      (by rw [mm5]; exact code) p5 rfl rfl
    have a20 : s6.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r6 20]; regsimp
      rw [k5 20 (by decide) (by decide) (by decide), k4 20 (by decide) (by decide) (by decide) (by decide) (by decide),
        hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have k6 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → x ≠ 20 → s6.reg x = s.reg x :=
      fun x h6 h7 h13 h14 h29 h20 => by
        rw [r6 x]; simp only [h20, false_and, ↓reduceIte]; rw [k5 x h29 h6 h7, k4 x h6 h7 h13 h14 h29]
    have z6 : s6.reg 29 = 0 ↔ a = b := by
      rw [r6 29]; regsimp; exact zz
    -- bne t6, zero, EQV_TAIL
    obtain ⟨s7, e7, p7, m7, r7⟩ := brStep (prog := kernel) hp (EQ + 91) (by decide)
      (by rw [m6, mm5]; exact code) p6 rfl (k' := EQV_TAIL) (by jump)
    have tk : taken .bne (s6.reg 31) (s6.reg 0) = v := by
      rw [k6 31 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h31, reg_zero]
      cases v <;> rfl
    rw [tk] at p7
    have e7' : run env (3 + 1 + 1 + 1 + 4 * 21 + 1 + 1) s = .running s7 := by
      rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running
        ((run_add_running e1).trans e2)).trans e3)).trans e4)).trans e5)).trans e6), e7]
    have mm7 : s7.mem = s.mem := by rw [m7, m6, mm5]
    have c7 : CodeAt s7.mem base kernel := by rw [mm7]; exact code
    have k7 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → x ≠ 20 → s7.reg x = s.reg x :=
      fun x h6 h7 h13 h14 h29 h20 => by rw [r7, k6 x h6 h7 h13 h14 h29 h20]
    cases v
    · -- OP_EQUAL: a zeroed slot where b was, and 1 in it if they matched
      simp only [Bool.false_eq_true, ↓reduceIte] at p7 ⊢
      have hS : STACK + 84 * r.length + 84 < 0x10000 := by simp only [STACK]; omega
      obtain ⟨s8, e8, p8, m8, r8⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0)
        (a := STACK + 84 * r.length) (k0 := EQ + 92) hp (by decide) (by decide) (by decide)
        (by omega) (by simp only [STACK]; omega) (by simp only [STACK]; rw [kernel_length]; omega)
        (by rw [p7]) c7 (by rw [r7, a20]) (by decide) 21 (Nat.le_refl _)
      have c8 : CodeAt s8.mem base kernel := by
        rw [m8]; exact code_of_overlay hfit c7 (by simp only [STACK]; rw [kernel_length]; omega) (by omega) _
      obtain ⟨s9, e9, p9, m9, r9⟩ := brStep (prog := kernel) hp (EQ + 113) (by decide) c8 (by rw [p8]) rfl
        (k' := EQ_PUSH) (by jump)
      have tk9 : taken .bne (s8.reg 29) (s8.reg 0) = !decide (a = b) := by
        rw [r8, r7 29, reg_zero]; simp only [taken, bne]
        by_cases hab : a = b
        · rw [z6.mpr hab]; simp [hab]
        · rw [beq_false_of_ne (fun h => hab (z6.mp h))]; simp [hab]
      rw [tk9] at p9
      have r20_8 : s8.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by rw [r8, r7, a20]
      have fixed : Fixed base scr s := hc.fixed
      have k8 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → x ≠ 20 → s8.reg x = s.reg x :=
        fun x h6 h7 h13 h14 h29 h20 => by rw [r8, k7 x h6 h7 h13 h14 h29 h20]
      -- the pushed element, and where the machine is when it is in place
      have fin : ∀ (e : Elem) (sF : Machine) (n : Nat), run env n s8 = .running sF →
          sF.pc = base + BitVec.ofNat 32 (4 * EQ_PUSH) → SlotAt sF.mem base (STACK + 84 * r.length) e →
          Agree s.mem sF.mem base (STACK + 84 * r.length) LIMIT → e.length ≤ EMAX →
          (∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → x ≠ 20 → sF.reg x = s.reg x) →
          sF.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * r.length) →
          Goes env base m0 scr s (.next ⟨c.pc + 1, e :: r, c.sigs⟩) := by
        intro e sF n eF pF slot ag hel kF h20F
        have eF' : run env (3 + 1 + 1 + 1 + 4 * 21 + 1 + 1 + 21 + n) s = .running sF := by
          rw [run_add_running ((run_add_running e7').trans e8), eF]
        refine Goes.prepend eF' (tail hp hin (k := r.length) (fixed.keep fun x hx => kF x ?_ ?_ ?_ ?_ ?_ ?_) h20F
          pF (by decide) rfl rfl (by jump) ?_ ?_ ?_
          (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
          (st.pop.pop.push (by simp only [DMAX]; omega) slot ag) (by simp only [DMAX, List.length_cons]; omega)
          ?_ hc.sigs (by simp only; omega))
        all_goals first
          | (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
          | skip
        · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
          simp only [List.length_cons]
          rw [show STACK + 84 * r.length + 84 = STACK + 84 * (r.length + 1) by omega]
        · rw [kF 18 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h18, Nat.add_assoc]
        · rw [kF 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21]
        · intro x hx; simp only [List.mem_cons] at hx
          rcases hx with rfl | hx
          · exact hel
          · exact hc.elems x (by rw [hst]; simp [hx])
      have ag8 : Agree s.mem s8.mem base (STACK + 84 * r.length) LIMIT := by
        rw [m8, mm7, Nat.add_zero]
        exact (agree_overlay hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)
      by_cases hab : a = b
      · simp only [hab, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p9 ⊢
        obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp (EQ + 114) (by decide)
          (by rw [m9]; exact c8) p9 rfl rfl
        have a6 : s10.reg 6 = 1#32 := by
          rw [r10 6]; regsimp; simp only [reg_zero, aluI]
          rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]
          exact BitVec.zero_add _
        obtain ⟨s11, e11, p11, m11, r11⟩ := storeStep (prog := kernel) hp (EQ + 115) (by decide)
          (by rw [m10, m9]; exact c8) p10 rfl (STACK + 84 * r.length)
          (by rw [r10 20]; regsimp; rw [r9, r20_8]; simp) (by omega) (by simp only [STACK]; omega)
        have c11 : CodeAt s11.mem base kernel := by
          rw [m11]
          have c10 : CodeAt s10.mem base kernel := by rw [m10, m9]; exact c8
          exact code_keep hfit c10 ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _))
            (by simp only [STACK]; omega)
        obtain ⟨s12, e12, p12, m12, r12⟩ := sbStep (prog := kernel) hp (EQ + 116) (by decide)
          c11 p11 rfl (STACK + 84 * r.length + 4)
          (by rw [r11, r10 20]; regsimp; rw [r9, r20_8]
              exact addi_pos hfit _ (v := 4) (by decide) (by decide) (by omega)) (by omega)
        have slot : SlotAt s12.mem base (STACK + 84 * r.length) [1] := by
          rw [m12, r11, a6, m11, a6, m10, m9, m8, Nat.add_zero]
          exact slot_one hfit _ _ _ (by omega)
        have ag : Agree s.mem s12.mem base (STACK + 84 * r.length) LIMIT := by
          rw [m12, m11, m10, m9]
          exact (ag8.trans ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _)
            (by simp only [STACK, LIMIT]; omega))).trans
            ((agree_writeByte hfit _ _ (by omega)).widen (by omega) (by simp only [STACK, LIMIT]; omega))
        exact fin [1] s12 (1 + 1 + 1 + 1) (by rw [run_add_running ((run_add_running ((run_add_running e9).trans e10)).trans e11), e12])
          (by rw [p12]; rfl) slot ag (by simp [EMAX])
          (fun x h6 h7 h13 h14 h29 h20 => by
            rw [r12, r11, r10 x]; simp only [h6, false_and, ↓reduceIte]; rw [r9, k8 x h6 h7 h13 h14 h29 h20])
          (by rw [r12, r11, r10 20]; regsimp; rw [r9, r20_8])
      · simp only [hab, decide_false, Bool.not_false, ↓reduceIte] at p9 ⊢
        have slot : SlotAt s9.mem base (STACK + 84 * r.length) [] := by
          rw [m9, m8, mm7, Nat.add_zero]; exact slot_zero hfit _ _ (by omega)
        exact fin [] s9 1 e9 p9 slot (by rw [m9]; exact ag8) (by simp [EMAX])
          (fun x h6 h7 h13 h14 h29 h20 => by rw [r9, k8 x h6 h7 h13 h14 h29 h20]) (by rw [r9, r20_8])
    · -- OP_EQUALVERIFY: both popped, and fail unless they matched
      simp only [↓reduceIte] at p7 ⊢
      obtain ⟨s8, e8, p8, m8, r8⟩ := brStep (prog := kernel) hp EQV_TAIL (by decide) c7 p7 rfl
        (k' := F_EQV) (by jump)
      have tk8 : taken .bne (s7.reg 29) (s7.reg 0) = !decide (a = b) := by
        rw [r7 29, reg_zero]; simp only [taken, bne]
        by_cases hab : a = b
        · rw [z6.mpr hab]; simp [hab]
        · rw [beq_false_of_ne (fun h => hab (z6.mp h))]; simp [hab]
      rw [tk8] at p8
      have e8' : run env (3 + 1 + 1 + 1 + 4 * 21 + 1 + 1 + 1) s = .running s8 := by
        rw [run_add_running e7', e8]
      by_cases hab : a = b
      · simp only [hab, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p8 ⊢
        have k8 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 29 → x ≠ 20 → s8.reg x = s.reg x :=
          fun x h6 h7 h13 h14 h29 h20 => by rw [r8, k7 x h6 h7 h13 h14 h29 h20]
        have hcore : Core base m0 scr ⟨c.pc + 1, r, c.sigs⟩ s8 := by
          refine hc.next (fun x hx => k8 x ?_ ?_ ?_ ?_ ?_ ?_) (by rw [r8, r7, a20])
            (by rw [k8 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21])
            (by rw [m8, mm7]; exact hc.agree) (by rw [m8, mm7]; exact st.pop.pop) (by simp only [DMAX]; omega)
            (fun x hx => hc.elems x (by rw [hst]; simp [hx])) hc.sigs (by simp only; omega)
          all_goals (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
        exact Goes.prepend e8' (back hp hin hcore (by rw [k8 18 (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide), h18, Nat.add_assoc]) (by rw [p8]) (by decide) rfl (by jump))
      · simp only [hab, decide_false, Bool.not_false, ↓reduceIte] at p8 ⊢
        exact Goes.prepend e8' (f_eqv hp (by rw [m8]; exact c7) p8)

/-- **OP_EQUAL**: `t6` cleared, on to EQ. -/
theorem h_equal (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_EQUAL s) (hop : (scr.getD c.pc 0).toNat = 0x87) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = eqRes false c := by
    simp only [stepOp]; rw [hop]; simp only [eqRes]
    rcases c.st with _ | ⟨a, _ | ⟨b, r⟩⟩ <;> simp
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_EQUAL (by decide) (hc.code hp hin) hE.pc rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := jStep (prog := kernel) hp (H_EQUAL + 1) (by decide)
    (by rw [m1]; exact hc.code hp hin) p1 rfl (k' := EQ) (by jump)
  refine Goes.prepend (n := 1 + 1) (by rw [run_add_running e1, e2])
    (eq_core hp hin false (hc.regs (by rw [m2, m1]) fun x hx => ?_) p2 ?_ ?_ hE.lt)
  · rw [r2, r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r2, r1 18]; regsimp; exact hE.r18
  · rw [r2, r1 31]; regsimp; simp only [aluI, reg_zero]; rfl

/-- **OP_EQUALVERIFY**: `t6` set, into EQ. -/
theorem h_eqv (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_EQV s) (hop : (scr.getD c.pc 0).toNat = 0x88) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = eqRes true c := by
    simp only [stepOp]; rw [hop]; simp only [eqRes]
    rcases c.st with _ | ⟨a, _ | ⟨b, r⟩⟩ <;> simp
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_EQV (by decide) (hc.code hp hin) hE.pc rfl rfl
  refine Goes.prepend e1 (eq_core hp hin true (hc.regs m1 fun x hx => ?_) (by rw [p1]; rfl) ?_ ?_ hE.lt)
  · rw [r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r1 18]; regsimp; exact hE.r18
  · rw [r1 31]; regsimp; simp only [aluI, reg_zero]
    rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]
    exact BitVec.zero_add _

end Exp228
