import Dev.Slots

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- **OP_DROP**. -/
theorem h_drop (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_DROP s) (hop : (scr.getD c.pc 0).toNat = 0x75) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact need_fail (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump) (by decide) (by rw [hst]; decide)
  | e :: r =>
    rw [show stepOp env scr c = .next ⟨c.pc + 1, r, c.sigs⟩ by simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 1 := by rw [hst]; rfl
    have hd := hc.depth
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_DROP + 3) (by decide)
      (by rw [m1]; exact code) p1 rfl rfl
    refine Goes.prepend (n := 3 + 1) (by rw [run_add_running e1, e2]) (back hp hin ?_ ?_ p2 (by decide) rfl (by jump))
    · refine hc.next (fun r h => ?_) ?_ ?_ (by rw [m2, m1]; exact hc.agree) ?_ ?_ ?_ hc.sigs ?_
      · rw [r2 r, r1 r (by rcases h with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
          (by rcases h with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)]
        rcases h with rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
      · rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
        rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega)
          (by simp only [STACK, DMAX] at *; omega)]
        rw [show STACK + 84 * (r.length + 1) - 84 = STACK + 84 * r.length by omega]
      · rw [r2 21]; regsimp; rw [r1 21 (by decide) (by decide), hc.r21]
      · rw [m2, m1]; have := hc.stack; rw [hst] at this; exact this.pop
      · show r.length ≤ DMAX; simp only [DMAX] at *; omega
      · intro x hx; exact hc.elems x (by rw [hst]; exact List.mem_cons_of_mem _ hx)
      · show c.pc + 1 ≤ scr.length; have := hE.lt; omega
    · show s2.reg 18 = base + BitVec.ofNat 32 (SCRIPT + (c.pc + 1))
      rw [r2 18]; regsimp; rw [r1 18 (by decide) (by decide), hE.r18, Nat.add_assoc]

/-- The 21 stores of a zeroed slot at `rd`, from instruction `k`. -/
theorem zeroes_at (k : Nat) (rd : Reg) (h : ∀ j < 21, kernel.getD (k + j) .ecall = .st .sw rd 0 (BitVec.ofNat 12 (0 + 4 * j))) :
    ∀ j < 21, kernel.getD (k + j) .ecall = .st .sw rd 0 (BitVec.ofNat 12 (0 + 4 * j)) := h

/-- **OP_0**: room for one more, a zeroed slot, pushed. -/
theorem h_op0 (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_OP0 s) (hop : (scr.getD c.pc 0).toNat = 0) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  have hd := hc.depth
  rw [show stepOp env scr c = pushE c (c.pc + 1) [] by simp only [stepOp]; rw [hop]; simp]
  unfold pushE
  by_cases hfull : DMAX ≤ c.st.length
  · simp only [hfull, ↓reduceIte]; exact room_fail hp hin hc hE.pc (by decide) rfl (by jump) hfull
  · simp only [hfull, ↓reduceIte]
    simp only [DMAX] at hd hfull
    obtain ⟨s1, e1, p1, m1, r1⟩ := room_pass hp hin hc hE.pc (by decide) rfl (by jump) (by simp only [DMAX]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0)
      (a := STACK + 84 * c.st.length) (k0 := H_OP0 + 1) hp (by decide) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; rw [kernel_length]; omega)
      p1 (by rw [m1]; exact code) (by rw [r1, hc.r20]) (by decide) 21 (Nat.le_refl _)
    have slot : SlotAt s2.mem base (STACK + 84 * c.st.length) [] := by
      rw [m2, Nat.add_zero]; exact slot_zero hfit _ _ (by simp only [STACK]; omega)
    have ag : Agree s.mem s2.mem base (STACK + 84 * c.st.length) LIMIT := by
      rw [m2, m1, Nat.add_zero]
      exact (agree_overlay hfit _ _ (by simp only [STACK]; omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)
    refine Goes.prepend (n := 1 + 21) (by rw [run_add_running e1, e2]) (tail hp hin (k := c.st.length)
      (hc.fixed.keep (keeps6_all fun r => by rw [r2, r1])) (by rw [r2, r1, hc.r20]) p2 (by decide) rfl rfl (by jump)
      ?_ (by rw [r2, r1, hE.r18, Nat.add_assoc]) (by rw [r2, r1, hc.r21])
      (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _))) (hc.stack.push (by simp only [DMAX]; omega) slot ag)
      (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by have := hE.lt; simp only; omega))
    · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
      simp only [List.length_cons]; congr 2
    · intro x hx; simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · simp [EMAX]
      · exact hc.elems x hx

/-- OP_N's body, for `t0 = v`: room, a zeroed slot, length one, the byte `v - 0x50`. -/
theorem opn_core (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) (hpc : s.pc = base + BitVec.ofNat 32 (4 * H_OPN))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1)) {v : Nat} (h5 : s.reg 5 = BitVec.ofNat 32 v)
    (hv1 : 0x50 ≤ v) (hv2 : v < 2048) (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (pushE c (c.pc + 1) [BitVec.ofNat 8 (v - 0x50)]) := by
  have code := hc.code hp hin
  have hfit := hp.fit
  have hd := hc.depth
  unfold pushE
  by_cases hfull : DMAX ≤ c.st.length
  · simp only [hfull, ↓reduceIte]; exact room_fail hp hin hc hpc (by decide) rfl (by jump) hfull
  · simp only [hfull, ↓reduceIte]
    simp only [DMAX] at hd hfull
    have hS : STACK + 84 * c.st.length + 84 < 0x10000 := by simp only [STACK]; omega
    obtain ⟨s1, e1, p1, m1, r1⟩ := room_pass hp hin hc hpc (by decide) rfl (by jump) (by simp only [DMAX]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0)
      (a := STACK + 84 * c.st.length) (k0 := H_OPN + 1) hp (by decide) (by decide) (by decide)
      (by omega) (by simp only [STACK]; omega) (by simp only [STACK]; rw [kernel_length]; omega)
      p1 (by rw [m1]; exact code) (by rw [r1, hc.r20]) (by decide) 21 (Nat.le_refl _)
    have c2 : CodeAt s2.mem base kernel := by
      rw [m2, m1]; exact code_of_overlay hfit code (by simp only [STACK]; rw [kernel_length]; omega) (by omega) _
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_OPN + 22) (by decide) c2 p2 rfl rfl
    have a3 : s3.reg 6 = 1#32 := by
      rw [r3 6]; regsimp
      simp only [reg_zero, aluI]
      rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]
      exact BitVec.zero_add _
    obtain ⟨s4, e4, p4, m4, r4⟩ := storeStep (prog := kernel) hp (H_OPN + 23) (by decide) (by rw [m3]; exact c2)
      p3 rfl (STACK + 84 * c.st.length) (by rw [r3 20]; regsimp; rw [r2, r1, hc.r20]; simp)
      (by omega) (by simp only [STACK]; omega)
    -- what the slot's window looks like after the length word
    have ag4 : Agree s.mem s4.mem base (STACK + 84 * c.st.length) LIMIT := by
      rw [m4, m3, m2, m1, Nat.add_zero]
      exact ((agree_overlay hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)).trans
        ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega))
    have c4 : CodeAt s4.mem base kernel :=
      code_of_agree hfit hin.code (hc.agree.trans (ag4.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
    obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (H_OPN + 24) (by decide) c4 p4 rfl rfl
    have a5 : s5.reg 6 = BitVec.ofNat 32 (v - 0x50) := by
      rw [r5 6]; regsimp; rw [r4 5, r3 5]; regsimp; rw [r2 5, r1 5, h5]
      rw [show (4016 : BitVec 12) = BitVec.ofNat 12 4016 from rfl, se_neg _ (by decide) (by decide)]
      simp only [aluI]
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat]
      omega
    have hS4 : STACK + 84 * c.st.length + 4 < 0x10000 := by omega
    obtain ⟨s6, e6, p6, m6, r6⟩ := sbStep (prog := kernel) hp (H_OPN + 25) (by decide) (by rw [m5]; exact c4)
      p5 rfl (STACK + 84 * c.st.length + 4)
      (by rw [r5 20]; regsimp; rw [r4 20, r3 20]; regsimp; rw [r2, r1, hc.r20]
          exact addi_pos hfit _ (v := 4) (by decide) (by decide) (by omega)) (by omega)
    have hb : BitVec.ofNat 8 (s5.reg 6).toNat = BitVec.ofNat 8 (v - 0x50) := by
      rw [a5, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
    have slot : SlotAt s6.mem base (STACK + 84 * c.st.length) [BitVec.ofNat 8 (v - 0x50)] := by
      rw [m6, m5, m4, a3, m3, m2, m1, hb, Nat.add_zero]
      exact slot_one hfit _ _ _ (by omega)
    have ag : Agree s.mem s6.mem base (STACK + 84 * c.st.length) LIMIT := by
      rw [m6, m5]
      exact ag4.trans ((agree_writeByte hfit _ _ (by omega)).widen (by omega) (by simp only [STACK, LIMIT]; omega))
    have e : run env (1 + 21 + 1 + 1 + 1 + 1) s = .running s6 := by
      rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3)).trans e4)).trans e5), e6]
    refine Goes.prepend e (tail hp hin (k := c.st.length)
      (hc.fixed.keep ?_) (by rw [r6, r5 20]; regsimp; rw [r4 20, r3 20]; regsimp; rw [r2, r1, hc.r20]) p6 (by decide) rfl rfl (by jump)
      ?_ (by rw [r6, r5 18]; regsimp; rw [r4 18, r3 18]; regsimp; rw [r2, r1, h18, Nat.add_assoc])
      (by rw [r6, r5 21]; regsimp; rw [r4 21, r3 21]; regsimp; rw [r2, r1, hc.r21])
      (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _))) (hc.stack.push (by simp only [DMAX]; omega) slot ag)
      (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by simp only; omega))
    · exact (((((keeps6_all fun r => r1 r).trans (keeps6_all fun r => r2 r)).trans (keeps6_of r3 (by decide))).trans
        (keeps6_all fun r => r4 r)).trans (keeps6_of r5 (by decide))).trans (keeps6_all fun r => r6 r)
    · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
      simp only [List.length_cons]; congr 2
    · intro x hx; simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · simp [EMAX]
      · exact hc.elems x hx

/-- **OP_1 … OP_16**. -/
theorem h_opn (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_OPN s) (hop : (scr.getD c.pc 0).toNat = op) (h1 : 0x51 ≤ op) (h2 : op ≤ 0x60) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = pushE c (c.pc + 1) [BitVec.ofNat 8 (op - 0x50)] := by
    simp only [stepOp]; rw [hop]
    simp only [show ¬ op = 0 by omega, show ¬ op ≤ 0x4b by omega, show ¬ op = 0x4f by omega,
      show 0x51 ≤ op ∧ op ≤ 0x60 from ⟨h1, h2⟩, and_self, ↓reduceIte]
  rw [e]
  exact opn_core hp hin hE.core hE.pc hE.r18 hE.r5 (by omega) (by omega) hE.lt

/-- **OP_1NEGATE**: `t0` set to what makes OP_N's byte 0x81, then OP_N. -/
theorem h_neg1 (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_NEG1 s) (hop : (scr.getD c.pc 0).toNat = 0x4f) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = pushE c (c.pc + 1) [BitVec.ofNat 8 (0xd1 - 0x50)] := by
    simp only [stepOp]; rw [hop]; rfl
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_NEG1 (by decide) (hc.code hp hin) hE.pc rfl rfl
  have a5 : s1.reg 5 = BitVec.ofNat 32 0xd1 := by
    rw [r1 5]; regsimp; simp only [reg_zero, aluI]
    rw [show (0xd1 : BitVec 12) = BitVec.ofNat 12 0xd1 from rfl, se_small _ (by decide)]
    exact BitVec.zero_add _
  refine Goes.prepend e1 (opn_core hp hin (hc.regs m1 fun r hr => ?_) (by rw [p1]; rfl) (by rw [r1 18]; regsimp; exact hE.r18)
    a5 (by decide) (by decide) hE.lt)
  rw [r1 r]; rcases hr with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp

end Exp228
