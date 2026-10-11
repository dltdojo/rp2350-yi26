import Dev.Sha

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

theorem f_size (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_SIZE)) : Goes env base m0 scr s (.done C_SIZE) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem f_count (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_COUNT)) : Goes env base m0 scr s (.done C_COUNT) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem f_invalid (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_INVALID)) : Goes env base m0 scr s (.done C_INVALID) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-- What OP_CHECKSIG does, for a key over a signature. -/
def csRes (env : Env) (c : Cfg) (pk sg : Elem) (r : List Elem) : Res :=
  if pk.length ≠ 32 then .done C_SIZE
  else if sg.length = 0 then .next ⟨c.pc + 1, [] :: r, c.sigs⟩
  else if sg.length ≠ 64 then .done C_SIZE
  else if c.sigs ≠ 0 then .done C_COUNT
  else if env.sig pk sg then .next ⟨c.pc + 1, [1] :: r, 1⟩
  else .done C_INVALID

/-- **OP_CHECKSIG**. -/
theorem h_checksig (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_CHECKSIG s) (hop : (scr.getD c.pc 0).toNat = 0xac) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by simp [hst])
  | [_] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by simp [hst])
  | pk :: sg :: r =>
    rw [show stepOp env scr c = csRes env c pk sg r by simp only [stepOp]; rw [hop]; simp [hst, csRes]]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    have hpk : pk.length ≤ 80 := hc.elems pk (by rw [hst]; simp)
    have hsg : sg.length ≤ 80 := hc.elems sg (by rw [hst]; simp)
    generalize hA : STACK + 84 * r.length = A
    have hA1 : STACK ≤ A := by omega
    have hA2 : A + 168 ≤ TMP := by simp only [STACK, TMP] at *; omega
    have hAT : A + 84 + 84 < 0x10000 := by simp only [TMP] at hA2; omega
    have slotP : SlotAt s.mem base (A + 84) pk := by
      rw [← hA, show STACK + 84 * r.length + 84 = STACK + 84 * (sg :: r).length by simp; omega]; exact st.top
    have slotS : SlotAt s.mem base A sg := by rw [← hA]; exact st.second
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_CHECKSIG + 3) (by decide) (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_CHECKSIG + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have mm3 : s3.mem = s.mem := by rw [m3, m2, m1]
    have a13 : s3.reg 13 = base + BitVec.ofNat 32 (A + 84) := by
      rw [r3 13]; regsimp; rw [r2 13]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK] at *; omega),
        ← hA]
      congr 2
    have a14 : s3.reg 14 = base + BitVec.ofNat 32 A := by
      rw [r3 14]; regsimp; rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK] at *; omega),
        ← hA]
      congr 2
    have k3 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → s3.reg x = s.reg x := fun x h6 h7 h13 h14 => by
      rw [r3 x]; simp only [h14, false_and, ↓reduceIte]; rw [r2 x]; simp only [h13, false_and, ↓reduceIte]
      exact r1 x h6 h7
    -- lw t1, 0(a3); li t2, 32; bne t1, t2, F_SIZE
    obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp (H_CHECKSIG + 5) (by decide) (by rw [mm3]; exact code)
      p3 rfl (A + 84) (by rw [a13]; simp) (by omega) (by rw [← hA]; simp only [STACK]; omega)
    obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (H_CHECKSIG + 6) (by decide)
      (by rw [m4, mm3]; exact code) p4 rfl rfl
    obtain ⟨s6, e6, p6, m6, r6⟩ := brStep (prog := kernel) hp (H_CHECKSIG + 7) (by decide)
      (by rw [m5, m4, mm3]; exact code) p5 rfl (k' := F_SIZE) (by jump)
    rw [show taken .bne (s5.reg 6) (s5.reg 7) = !decide (pk.length = 32) by
      simp only [taken, bne]; rw [r5 6]; regsimp; rw [r4 6]; regsimp; rw [r5 7]; regsimp; simp only [aluI, reg_zero]
      rw [mm3, slot_len hfit slotP (by omega) (by omega),
        show (0 : Word) + (0x20 : BitVec 12).signExtend 32 = BitVec.ofNat 32 32 by decide,
        beq_ofNat _ _ (by omega) (by decide)]] at p6
    have mm6 : s6.mem = s.mem := by rw [m6, m5, m4, mm3]
    have e6' : run env (3 + 1 + 1 + 1 + 1 + 1) s = .running s6 :=
      run_trans (run_trans (run_trans (run_trans (run_trans e1 e2) e3) e4) e5) e6
    unfold csRes
    by_cases h32 : ¬ pk.length = 32
    · simp only [h32, decide_false, Bool.not_false, ↓reduceIte, ne_eq, not_false_eq_true] at p6 ⊢
      exact Goes.prepend e6' (f_size hp (by rw [mm6]; exact code) p6)
    replace h32 : pk.length = 32 := Classical.not_not.mp h32
    simp only [h32, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte, ne_eq, not_true_eq_false] at p6 ⊢
    -- lw t3, 0(a4); addi s4, s4, -168; bne t3, zero, CS_SIG
    obtain ⟨s7, e7, p7, m7, r7⟩ := loadStep (prog := kernel) hp (H_CHECKSIG + 8) (by decide) (by rw [mm6]; exact code)
      p6 rfl A (by rw [r6, r5 14]; regsimp; rw [r4 14]; regsimp; rw [a14]; simp) (by omega)
      (by rw [← hA]; simp only [STACK]; omega)
    obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp (H_CHECKSIG + 9) (by decide)
      (by rw [m7, mm6]; exact code) p7 rfl rfl
    obtain ⟨s9, e9, p9, m9, r9⟩ := brStep (prog := kernel) hp (H_CHECKSIG + 10) (by decide)
      (by rw [m8, m7, mm6]; exact code) p8 rfl (k' := CS_SIG) (by jump)
    have t28 : s8.reg 28 = BitVec.ofNat 32 sg.length := by
      rw [r8 28]; regsimp; rw [r7 28]; regsimp; rw [mm6, slot_len hfit slotS (by omega) (by omega)]
    rw [show taken .bne (s8.reg 28) (s8.reg 0) = !decide (sg.length = 0) by
      simp only [taken, bne]; rw [t28, reg_zero, show (0 : Word) = BitVec.ofNat 32 0 from rfl,
        beq_ofNat _ _ (by omega) (by decide)]] at p9
    have mm9 : s9.mem = s.mem := by rw [m9, m8, m7, mm6]
    have c9 : CodeAt s9.mem base kernel := by rw [mm9]; exact code
    have e9' : run env (3 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1) s = .running s9 := run_trans (run_trans (run_trans e6' e7) e8) e9
    have a20 : s9.reg 20 = base + BitVec.ofNat 32 A := by
      rw [r9, r8 20]; regsimp; simp only [aluI]; rw [r7 20]; regsimp; rw [r6, r5 20]; regsimp; rw [r4 20]; regsimp
      rw [k3 20 (by decide) (by decide) (by decide) (by decide), hc.r20, hlen]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK] at *; omega),
        ← hA]
      congr 2
    have k9 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → x ≠ 20 → x ≠ 28 → s9.reg x = s.reg x :=
      fun x h6 h7 h13 h14 h20 h28 => by
        rw [r9, r8 x]; simp only [h20, false_and, ↓reduceIte]; rw [r7 x]; simp only [h28, false_and, ↓reduceIte]
        rw [r6, r5 x]; simp only [h7, false_and, ↓reduceIte]; rw [r4 x]; simp only [h6, false_and, ↓reduceIte]
        exact k3 x h6 h7 h13 h14
    -- where the pushed element ends up, either way
    have fin : ∀ (e : Elem) (sigs' : Nat) (sF : Machine) (n : Nat), run env n s = .running sF →
        sF.pc = base + BitVec.ofNat 32 (4 * (H_CHECKSIG + 32)) ∨ sF.pc = base + BitVec.ofNat 32 (4 * (H_CHECKSIG + 67)) →
        SlotAt sF.mem base A e → Agree s.mem sF.mem base A LIMIT → e.length ≤ EMAX → sigs' ≤ 1 →
        sF.reg 20 = base + BitVec.ofNat 32 A → sF.reg 21 = BitVec.ofNat 32 sigs' →
        (∀ x : Reg, x = 9 ∨ x = 24 ∨ x = 19 ∨ x = 23 ∨ x = 22 ∨ x = 25 ∨ x = 18 → sF.reg x = s.reg x) →
        Goes env base m0 scr s (.next ⟨c.pc + 1, e :: r, sigs'⟩) := by
      intro e sigs' sF n eF pF slot ag hel hs' h20 h21 kF
      have tl := fun (i : Nat) (hpcF : sF.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i + 1 < 881)
          (h1 : kernel.getD i .ecall = .opi .addi 20 20 (84 : BitVec 12))
          (h2 : ∃ off, kernel.getD (i + 1) .ecall = .jal 0 off ∧
            BitVec.ofNat 32 (4 * (i + 1)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * LOOP)) =>
        Goes.prepend eF (tail hp hin (c' := ⟨c.pc + 1, e :: r, sigs'⟩) (k := r.length)
          (hc.fixed.keep fun x hx => kF x (by rcases hx with h | h | h | h | h | h <;> simp [h]))
          (by rw [h20, hA]) hpcF hi h1 h2.choose_spec.1 h2.choose_spec.2
          (by rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
              simp only [List.length_cons]; rw [show STACK + 84 * r.length + 84 = STACK + 84 * (r.length + 1) by omega])
          (by rw [kF 18 (by simp), hE.r18, Nat.add_assoc]) h21
          (hc.agree.trans (ag.widen hA1 (Nat.le_refl _)))
          (st.pop.pop.push (by simp only [DMAX]; omega) (hA ▸ slot) (hA ▸ ag))
          (by simp only [DMAX, List.length_cons]; omega)
          (fun x hx => by
            simp only [List.mem_cons] at hx
            rcases hx with rfl | hx
            · exact hel
            · exact hc.elems x (by rw [hst]; simp [hx])) hs' (by have := hE.lt; simp only; omega))
      rcases pF with pF | pF
      · exact tl _ pF (by decide) rfl ⟨_, rfl, by jump⟩
      · exact tl _ pF (by decide) rfl ⟨_, rfl, by jump⟩
    have hz8 : ∀ k0 : Nat, (∀ j < 21, kernel.getD (k0 + j) .ecall = .st .sw 20 0 (BitVec.ofNat 12 (0 + 4 * j))) →
        k0 + 21 ≤ 881 → ∀ t : Machine, t.pc = base + BitVec.ofNat 32 (4 * k0) → CodeAt t.mem base kernel →
        t.reg 20 = base + BitVec.ofNat 32 A →
        ∃ t', run env 21 t = .running t' ∧ t'.pc = base + BitVec.ofNat 32 (4 * (k0 + 21))
          ∧ t'.mem = overlay t.mem (base + BitVec.ofNat 32 A) 84 (fun _ => 0) ∧ ∀ x, t'.reg x = t.reg x := by
      intro k0 hat hk t hpc' hc' h20'
      obtain ⟨t', e', p', m', r'⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0) (a := A) (k0 := k0)
        hp hat (by rw [kernel_length]; omega) (by decide) (by omega) (by rw [← hA]; simp only [STACK]; omega)
        (by rw [kernel_length]; simp only [STACK] at hA1; omega) hpc' hc' h20' (by decide) 21 (Nat.le_refl _)
      exact ⟨t', e', p', by rw [m', Nat.add_zero], r'⟩
    by_cases hz : sg.length = 0
    · -- an empty signature: false pushed, nothing checked
      simp only [hz, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p9 ⊢
      have he : sg = [] := List.eq_nil_of_length_eq_zero hz
      obtain ⟨s10, e10, p10, m10, r10⟩ := hz8 (H_CHECKSIG + 11) (by decide) (by decide) s9 p9 c9 a20
      have ag10 : Agree s.mem s10.mem base A LIMIT := by
        rw [m10, mm9]
        exact (agree_overlay hfit s.mem (fun _ => 0) (c := A) (n := 84) (by omega)).widen (Nat.le_refl _)
          (by simp only [TMP, LIMIT] at hA2 ⊢; omega)
      exact fin [] c.sigs s10 _ (run_trans e9' e10) (Or.inl p10)
        (by rw [m10]; exact slot_zero hfit _ _ (by omega)) ag10
        (by simp [EMAX]) hc.sigs (by rw [r10, a20])
        (by rw [r10, k9 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21])
        (fun x hx => by rw [r10]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> (apply k9 <;> decide))
    simp only [hz, decide_false, Bool.not_false, ↓reduceIte] at p9 ⊢
    -- li t2, 64; bne t3, t2, F_SIZE
    obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp CS_SIG (by decide) c9 p9 rfl rfl
    obtain ⟨s11, e11, p11, m11, r11⟩ := brStep (prog := kernel) hp (CS_SIG + 1) (by decide)
      (by rw [m10]; exact c9) p10 rfl (k' := F_SIZE) (by jump)
    rw [show taken .bne (s10.reg 28) (s10.reg 7) = !decide (sg.length = 64) by
      simp only [taken, bne]; rw [r10 28]; regsimp; rw [r10 7]; regsimp; simp only [aluI, reg_zero]
      rw [r9, t28, show (0 : Word) + (0x40 : BitVec 12).signExtend 32 = BitVec.ofNat 32 64 by decide,
        beq_ofNat _ _ (by omega) (by decide)]] at p11
    have e11' := run_trans (run_trans e9' e10) e11
    have mm11 : s11.mem = s.mem := by rw [m11, m10, mm9]
    by_cases h64 : ¬ sg.length = 64
    · simp only [h64, decide_false, Bool.not_false, ↓reduceIte, ne_eq, not_false_eq_true] at p11 ⊢
      exact Goes.prepend e11' (f_size hp (by rw [mm11]; exact code) p11)
    replace h64 : sg.length = 64 := Classical.not_not.mp h64
    simp only [h64, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte, ne_eq, not_true_eq_false] at p11 ⊢
    -- bne s5, zero, F_COUNT
    obtain ⟨s12, e12, p12, m12, r12⟩ := brStep (prog := kernel) hp (CS_SIG + 2) (by decide)
      (by rw [mm11]; exact code) p11 rfl (k' := F_COUNT) (by jump)
    have hsig := hc.sigs
    rw [show taken .bne (s11.reg 21) (s11.reg 0) = !decide (c.sigs = 0) by
      simp only [taken, bne]; rw [r11, r10 21]; regsimp
      rw [k9 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21, reg_zero,
        show (0 : Word) = BitVec.ofNat 32 0 from rfl, beq_ofNat _ _ (by omega) (by decide)]] at p12
    have e12' := run_trans e11' e12
    have mm12 : s12.mem = s.mem := by rw [m12, mm11]
    by_cases h0 : ¬ c.sigs = 0
    · simp only [h0, decide_false, Bool.not_false, ↓reduceIte, ne_eq, not_false_eq_true] at p12 ⊢
      exact Goes.prepend e12' (f_count hp (by rw [mm12]; exact code) p12)
    replace h0 : c.sigs = 0 := Classical.not_not.mp h0
    simp only [h0, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte, ne_eq, not_true_eq_false] at p12 ⊢
    -- addi a0, a3, 4; addi a1, a4, 4; li t0, 3; ecall
    obtain ⟨s13, e13, p13, m13, r13⟩ := regStep (prog := kernel) hp (CS_SIG + 3) (by decide)
      (by rw [mm12]; exact code) p12 rfl rfl
    obtain ⟨s14, e14, p14, m14, r14⟩ := regStep (prog := kernel) hp (CS_SIG + 4) (by decide)
      (by rw [m13, mm12]; exact code) p13 rfl rfl
    obtain ⟨s15, e15, p15, m15, r15⟩ := regStep (prog := kernel) hp (CS_SIG + 5) (by decide)
      (by rw [m14, m13, mm12]; exact code) p14 rfl rfl
    have mm15 : s15.mem = s.mem := by rw [m15, m14, m13, mm12]
    have k12 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 20 → x ≠ 28 → s12.reg x = s3.reg x := fun x h6 h7 h20 h28 => by
      rw [r12, r11, r10 x]; simp only [h7, false_and, ↓reduceIte]; rw [r9, r8 x]; simp only [h20, false_and, ↓reduceIte]
      rw [r7 x]; simp only [h28, false_and, ↓reduceIte]; rw [r6, r5 x]; simp only [h7, false_and, ↓reduceIte]
      rw [r4 x]; simp only [h6, false_and, ↓reduceIte]
    have b10 : s15.reg A0 = base + BitVec.ofNat 32 (A + 84 + 4) := by
      rw [A0, r15 10]; regsimp; rw [r14 10]; regsimp; rw [r13 10]; regsimp; simp only [aluI]
      rw [k12 13 (by decide) (by decide) (by decide) (by decide), a13]
      exact addi_pos hfit _ (by decide) (by decide) (by omega)
    have b11 : s15.reg A1 = base + BitVec.ofNat 32 (A + 4) := by
      rw [A1, r15 11]; regsimp; rw [r14 11]; regsimp; simp only [aluI]; rw [r13 14]; regsimp
      rw [k12 14 (by decide) (by decide) (by decide) (by decide), a14]
      exact addi_pos hfit _ (by decide) (by decide) (by omega)
    have b5 : s15.reg T0 = 3 := by
      rw [T0, r15 5]; regsimp; simp only [aluI, reg_zero]
      rw [show (3 : BitVec 12) = BitVec.ofNat 12 3 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _
    have hex := exec_checksig (env := env) (s := s15) b5
      (by rw [b10]; exact ok_off hp _ _ (by omega) (by omega)) (by rw [b11]; exact ok_off hp _ _ (by omega) (by omega))
    have rp : readBytes s.mem (base + BitVec.ofNat 32 (A + 84 + 4)) 32 = pk := by
      have := readBytes_slot hfit slotP (by omega) hpk; rwa [h32] at this
    have rs : readBytes s.mem (base + BitVec.ofNat 32 (A + 4)) 64 = sg := by
      have := readBytes_slot hfit slotS (by omega) hsg; rwa [h64] at this
    rw [b10, b11, mm15, rp, rs] at hex
    have e16 := stepK (prog := kernel) hp (CS_SIG + 6) (by decide) (by rw [mm15]; exact code) p15 rfl hex 0
    generalize hs16 : (s15.setReg A0 (if env.sig pk sg = true then 1 else 0)).next = s16 at e16
    rw [run_zero] at e16
    have p16 : s16.pc = base + BitVec.ofNat 32 (4 * (CS_SIG + 7)) := by
      rw [← hs16, next_pc, setReg_pc, p15]; exact pc_next hfit _ (by decide)
    have m16 : s16.mem = s.mem := by rw [← hs16, ← mm15]; rfl
    have r16 : ∀ x, s16.reg x = if x = A0 ∧ A0 ≠ 0 then (if env.sig pk sg = true then 1 else 0) else s15.reg x :=
      fun x => by rw [← hs16, next_reg, reg_setReg]
    -- beq a0, zero, F_INVALID
    obtain ⟨s17, e17, p17, m17, r17⟩ := brStep (prog := kernel) hp (CS_SIG + 7) (by decide)
      (by rw [m16]; exact code) p16 rfl (k' := F_INVALID) (by jump)
    rw [show taken .beq (s16.reg 10) (s16.reg 0) = !env.sig pk sg by
      simp only [taken]; rw [r16 10]; simp only [A0, show (10 : Reg) ≠ 0 by decide, and_self, ↓reduceIte, reg_zero]
      cases env.sig pk sg <;> rfl] at p17
    have e17' := run_trans (run_trans (run_trans (run_trans (run_trans e12' e13) e14) e15) e16) e17
    by_cases hv : env.sig pk sg = false
    · simp only [hv, Bool.not_false, ↓reduceIte, Bool.false_eq_true] at p17 ⊢
      exact Goes.prepend e17' (f_invalid hp (by rw [m17, m16]; exact code) p17)
    replace hv : env.sig pk sg = true := by simpa using hv
    simp only [hv, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p17 ⊢
    -- li s5, 1; the slot zeroed; 1 stored as length and byte
    obtain ⟨s18, e18, p18, m18, r18⟩ := regStep (prog := kernel) hp (CS_SIG + 8) (by decide)
      (by rw [m17, m16]; exact code) p17 rfl rfl
    have k18 : ∀ x : Reg, x ≠ 5 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 13 → x ≠ 14 → x ≠ 20 → x ≠ 21 → x ≠ 28 →
        s18.reg x = s.reg x := fun x h5 h6 h7 h10 h11 h13 h14 h20 h21 h28 => by
      rw [r18 x]; simp only [h21, false_and, ↓reduceIte]; rw [r17, r16 x]
      simp only [A0, h10, false_and, ↓reduceIte]; rw [r15 x]; simp only [h5, false_and, ↓reduceIte]
      rw [r14 x]; simp only [h11, false_and, ↓reduceIte]; rw [r13 x]; simp only [h10, false_and, ↓reduceIte]
      rw [k12 x h6 h7 h20 h28, k3 x h6 h7 h13 h14]
    have a20' : s18.reg 20 = base + BitVec.ofNat 32 A := by
      rw [r18 20]; regsimp; rw [r17, r16 20]; simp only [A0, show ¬ ((20 : Reg) = 10 ∧ (10 : Reg) ≠ 0) by decide,
        ↓reduceIte]
      rw [r15 20]; regsimp; rw [r14 20]; regsimp; rw [r13 20]; regsimp; rw [r12, r11, r10 20]; regsimp; exact a20
    obtain ⟨s19, e19, p19, m19, r19⟩ := hz8 (CS_SIG + 9) (by decide) (by decide) s18 p18
      (by rw [m18, m17, m16]; exact code) a20'
    have c19 : CodeAt s19.mem base kernel := by
      rw [m19, m18, m17, m16]
      exact code_of_overlay hfit code (by rw [kernel_length]; simp only [STACK] at hA1; omega) (by omega) _
    obtain ⟨s20, e20, p20, m20, r20⟩ := regStep (prog := kernel) hp (CS_SIG + 30) (by decide) c19 p19 rfl rfl
    have a6 : s20.reg 6 = 1#32 := by
      rw [r20 6]; regsimp; simp only [aluI, reg_zero]
      rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _
    obtain ⟨s21, e21, p21, m21, r21⟩ := storeStep (prog := kernel) hp (CS_SIG + 31) (by decide) (by rw [m20]; exact c19)
      p20 rfl A (by rw [r20 20]; regsimp; rw [r19, a20']; simp) (by omega) (by rw [← hA]; simp only [STACK]; omega)
    have c21 : CodeAt s21.mem base kernel := by
      rw [m21]; exact code_keep hfit (by rw [m20]; exact c19)
        ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (Nat.le_refl _)) (by simp only [STACK] at hA1; omega)
    obtain ⟨s22, e22, p22, m22, r22⟩ := sbStep (prog := kernel) hp (CS_SIG + 32) (by decide) c21 p21 rfl (A + 4)
      (by rw [r21, r20 20]; regsimp; rw [r19, a20']; exact addi_pos hfit _ (v := 4) (by decide) (by decide) (by omega))
      (by omega)
    have slot : SlotAt s22.mem base A [1] := by
      rw [m22, r21, a6, m21, a6, m20, m19, m18, m17, m16]
      exact slot_one hfit _ _ _ (by omega)
    have ag : Agree s.mem s22.mem base A LIMIT := by
      rw [m22, m21, m20, m19, m18, m17, m16]
      exact (((agree_overlay hfit _ (fun _ => 0) (c := A) (n := 84) (by omega)).widen (Nat.le_refl _) (by simp only [TMP, LIMIT] at hA2 ⊢; omega)).trans
        ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [TMP, LIMIT] at hA2 ⊢; omega))).trans
        ((agree_writeByte hfit _ _ (by omega)).widen (by omega) (by simp only [TMP, LIMIT] at hA2 ⊢; omega))
    have kk : ∀ x : Reg, x ≠ 5 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 13 → x ≠ 14 → x ≠ 20 → x ≠ 21 → x ≠ 28 →
        s22.reg x = s.reg x := fun x h5 h6 h7 h10 h11 h13 h14 h20 h21 h28 => by
      rw [r22, r21, r20 x]; simp only [h6, false_and, ↓reduceIte]; rw [r19, k18 x h5 h6 h7 h10 h11 h13 h14 h20 h21 h28]
    exact fin [1] 1 s22 _ (run_trans (run_trans (run_trans (run_trans (run_trans e17' e18) e19) e20) e21) e22)
      (Or.inr (by rw [p22]; rfl)) slot ag (by simp [EMAX]) (by decide)
      (by rw [r22, r21, r20 20]; regsimp; rw [r19, a20'])
      (by rw [r22, r21, r20 21]; regsimp; rw [r19, r18 21]; regsimp; simp only [aluI, reg_zero]
          rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _)
      (fun x hx => by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> (apply kk <;> decide))

end Exp228
