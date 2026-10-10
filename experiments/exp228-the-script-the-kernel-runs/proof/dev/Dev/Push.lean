import Dev.H2

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- A byte stored right after what has been overlaid extends the overlay by one. -/
theorem overlay_byte_step {m : Word → Byte} {a : Word} {j : Nat} {f : Nat → Byte} (hj : j < 2^32) :
    writeByte (overlay m a j f) (a + BitVec.ofNat 32 j) (f j) = overlay m a (j + 1) f := by
  funext x
  unfold writeByte overlay
  by_cases hx : x = a + BitVec.ofNat 32 j
  · subst hx
    have : (a + BitVec.ofNat 32 j - a).toNat = j := by
      rw [BitVec.add_comm, BitVec.add_sub_cancel, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hj]
    simp [this]
  · have hne : (x - a).toNat ≠ j := by
      intro h; apply hx
      have e : x - a = BitVec.ofNat 32 j := BitVec.eq_of_toNat_eq (by rw [h, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hj])
      rw [← e, BitVec.add_comm, BitVec.sub_add_cancel]
    simp only [hx, ↓reduceIte]
    by_cases h : (x - a).toNat < j
    · simp only [h, show (x - a).toNat < j + 1 by omega, ↓reduceIte]
    · simp only [h, show ¬ (x - a).toNat < j + 1 by omega, ↓reduceIte]

theorem ne_off (hfit : base.toNat + 0x10000 ≤ 2^32) (a b : Nat) (ha : a < 0x10000) (hb : b < 0x10000) :
    (base + BitVec.ofNat 32 a != base + BitVec.ofNat 32 b) = decide (a ≠ b) := by
  by_cases h : a = b
  · subst h; simp
  · have : base + BitVec.ofNat 32 a ≠ base + BitVec.ofNat 32 b := by
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off hfit a ha, toNat_off hfit b hb] at this; omega
    simp [this, h]

/-- **PUSH's byte loop**: from byte `j` of `n`, the rest of the bytes from the
script at `p` to the slot's element at `q`, five instructions a byte. -/
theorem push_loop (hp : Placed env base) {p q n : Nat} {M : Word → Byte}
    (hn : n ≤ 80) (hpq : p + n ≤ q) (hq : q + n < 0x10000) (hlo : 4 * 881 ≤ q) (hM : CodeAt M base kernel) :
    ∀ k j (s : Machine), n - j = k → j < n →
      s.pc = base + BitVec.ofNat 32 (4 * PUSH_BYTE) → s.reg 18 = base + BitVec.ofNat 32 (p + j) →
      s.reg 28 = base + BitVec.ofNat 32 (q + j) → s.reg 7 = base + BitVec.ofNat 32 (p + n) →
      s.mem = overlay M (base + BitVec.ofNat 32 q) j (fun d => M (base + BitVec.ofNat 32 (p + d))) →
      ∃ s', run env (5 * k) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (PUSH_BYTE + 5))
        ∧ s'.mem = overlay M (base + BitVec.ofNat 32 q) n (fun d => M (base + BitVec.ofNat 32 (p + d)))
        ∧ s'.reg 18 = base + BitVec.ofNat 32 (p + n)
        ∧ ∀ r, r ≠ 18 → r ≠ 28 → r ≠ 29 → s'.reg r = s.reg r := by
  have hfit := hp.fit
  intro k
  induction k with
  | zero => intro j s hk hj; omega
  | succ k ih =>
    intro j s hk hj hpc h18 h28 h7 hm
    have code : CodeAt s.mem base kernel := by
      rw [hm]; exact code_of_overlay hfit hM (by rw [kernel_length]; omega) (by omega) _
    -- lbu t4, 0(s2)
    obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := kernel) hp PUSH_BYTE (by decide) code hpc rfl (p + j)
      (by rw [h18]; simp) (by omega)
    have a29 : s1.reg 29 = BitVec.ofNat 32 (M (base + BitVec.ofNat 32 (p + j))).toNat := by
      rw [r1 29]; regsimp
      rw [hm, overlay_off_out hfit _ _ (by omega) (by omega) (by omega)]
    -- sb t4, 0(t3)
    obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep (prog := kernel) hp (PUSH_BYTE + 1) (by decide) (by rw [m1]; exact code)
      p1 rfl (q + j) (by rw [r1 28]; regsimp; rw [h28]; simp) (by omega)
    have mm2 : s2.mem = overlay M (base + BitVec.ofNat 32 q) (j + 1) (fun d => M (base + BitVec.ofNat 32 (p + d))) := by
      rw [m2, m1, hm, a29, ← off_add hfit q j (by omega)]
      have : BitVec.ofNat 8 (BitVec.ofNat 32 (M (base + BitVec.ofNat 32 (p + j))).toNat).toNat
          = M (base + BitVec.ofNat 32 (p + j)) := by
        apply BitVec.eq_of_toNat_eq
        have := (M (base + BitVec.ofNat 32 (p + j))).isLt
        simp only [BitVec.toNat_ofNat]; omega
      rw [this]
      exact overlay_byte_step (f := fun d => M (base + BitVec.ofNat 32 (p + d))) (by omega)
    -- addi s2, s2, 1; addi t3, t3, 1
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (PUSH_BYTE + 2) (by decide)
      (by rw [mm2]; exact code_of_overlay hfit hM (by rw [kernel_length]; omega) (by omega) _) p2 rfl rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp (PUSH_BYTE + 3) (by decide)
      (by rw [m3, mm2]; exact code_of_overlay hfit hM (by rw [kernel_length]; omega) (by omega) _) p3 rfl rfl
    have b18 : s4.reg 18 = base + BitVec.ofNat 32 (p + (j + 1)) := by
      rw [r4 18]; regsimp; rw [r3 18]; regsimp; rw [r2, r1 18]; regsimp; rw [h18]; simp only [aluI]
      rw [addi_pos hfit _ (v := 1) (by decide) (by decide) (by omega), Nat.add_assoc]
    have b28 : s4.reg 28 = base + BitVec.ofNat 32 (q + (j + 1)) := by
      rw [r4 28]; regsimp; rw [r3 28]; regsimp; rw [r2, r1 28]; regsimp; rw [h28]; simp only [aluI]
      rw [addi_pos hfit _ (v := 1) (by decide) (by decide) (by omega), Nat.add_assoc]
    have b7 : s4.reg 7 = base + BitVec.ofNat 32 (p + n) := by
      rw [r4 7]; regsimp; rw [r3 7]; regsimp; rw [r2, r1 7]; regsimp; exact h7
    -- bne s2, t2, PUSH_BYTE
    obtain ⟨s5, e5, p5, m5, r5⟩ := brStep (prog := kernel) hp (PUSH_BYTE + 4) (by decide)
      (by rw [m4, m3, mm2]; exact code_of_overlay hfit hM (by rw [kernel_length]; omega) (by omega) _) p4 rfl
      (k' := PUSH_BYTE) (by jump)
    have tk : taken .bne (s4.reg 18) (s4.reg 7) = decide (j + 1 ≠ n) := by
      simp only [taken, b18, b7]; rw [ne_off hfit _ _ (by omega) (by omega)]; simp
    rw [tk] at p5
    have e5' : run env 5 s = .running s5 := by
      rw [show 5 = 1 + (1 + (1 + (1 + 1))) by rfl, run_add_running e1, run_add_running e2, run_add_running e3,
        run_add_running e4, e5]
    have keep : ∀ r, r ≠ 18 → r ≠ 28 → r ≠ 29 → s5.reg r = s.reg r := fun r h18 h28 h29 => by
      rw [r5, r4 r, r3 r]; simp only [h18, h28, false_and, ↓reduceIte]; rw [r2, r1 r]; simp only [h29, false_and, ↓reduceIte]
    by_cases hl : j + 1 = n
    · simp only [hl, ne_eq, not_true_eq_false, decide_false, Bool.false_eq_true, ↓reduceIte] at p5
      have hk0 : k = 0 := by omega
      subst hk0
      refine ⟨s5, by simpa using e5', by rw [p5], ?_, ?_, keep⟩
      · rw [m5, m4, m3, mm2, hl]
      · rw [r5, b18, hl]
    · simp only [show j + 1 ≠ n from hl, ne_eq, not_false_eq_true, decide_true, ↓reduceIte] at p5
      obtain ⟨s', e', p', m', r18', rk⟩ := ih (j + 1) s5 (by omega) (by omega) p5 (by rw [r5, b18])
        (by rw [r5, b28]) (by rw [r5, b7]) (by rw [m5, m4, m3, mm2])
      refine ⟨s', ?_, p', m', r18', fun r a b c => (rk r a b c).trans (keep r a b c)⟩
      rw [show 5 * (k + 1) = 5 + 5 * k by omega, run_add_running e5', e']

/-- A slot zeroed, its length `n` stored, then `n` bytes from `f`. -/
theorem slot_n (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c n : Nat) (f : Nat → Byte) (e : Elem)
    (hc : c + 84 < 0x10000) (hn : n ≤ 80) (hlen : e.length = n) (he : ∀ i < n, e.getD i 0 = f i) :
    SlotAt (overlay (writeLE (overlay m (base + BitVec.ofNat 32 c) 84 (fun _ => 0)) (base + BitVec.ofNat 32 c) n 4)
      (base + BitVec.ofNat 32 (c + 4)) n f) base c e := by
  intro d hd
  rw [ev_overlay hfit _ _ _ _ _ (by omega) (by omega), ev_writeLE hfit _ _ _ _ (by omega) (by omega),
    ev_overlay hfit _ _ _ _ _ (by omega) (by omega)]
  unfold slotBytes
  rcases (by omega : d < 4 ∨ (4 ≤ d ∧ d < 4 + n) ∨ 4 + n ≤ d) with h | h | h
  · simp only [show ¬ (c + 4 ≤ c + d ∧ c + d < c + 4 + n) by omega, show c ≤ c + d ∧ c + d < c + 4 by omega,
      h, and_self, ↓reduceIte, show c + d - c = d by omega, hlen, false_and]
  · simp only [show c + 4 ≤ c + d ∧ c + d < c + 4 + n by omega, show ¬ d < 4 by omega, and_self, ↓reduceIte,
      show c + d - (c + 4) = d - 4 by omega]
    exact (he _ (by omega)).symm
  · simp only [show ¬ (c + 4 ≤ c + d ∧ c + d < c + 4 + n) by omega, show ¬ (c ≤ c + d ∧ c + d < c + 4) by omega,
      show c ≤ c + d ∧ c + d < c + 84 by omega, show ¬ d < 4 by omega, and_self, ↓reduceIte,
      show ¬ c + d < c + 4 by omega, and_false]
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]; rfl

theorem f_past (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_PAST)) : Goes env base m0 scr s (.done C_PAST) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-- **A push of 1 to 75 bytes**: past the script's end fails; otherwise room,
a zeroed slot, the length, the bytes. -/
theorem h_push (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_PUSH s) (hop : (scr.getD c.pc 0).toNat = op) (h1 : 1 ≤ op) (h2 : op ≤ 0x4b) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  have hsl := hin.len
  have hlt := hE.lt
  simp only [SMAX] at hsl
  have e : stepOp env scr c = if scr.length < c.pc + 1 + op then .done C_PAST
      else pushE c (c.pc + 1 + op) ((scr.drop (c.pc + 1)).take op) := by
    simp only [stepOp]; rw [hop]
    simp only [show ¬ op = 0 by omega, show op ≤ 0x4b from h2, ↓reduceIte]
  rw [e]
  -- add t2, s2, t0
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_PUSH (by decide) code hE.pc rfl rfl
  have a7 : s1.reg 7 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1 + op) := by
    rw [r1 7]; regsimp; simp only [aluR]; rw [hE.r18, hE.r5, off_add hfit _ _ (by simp only [SCRIPT]; omega)]
  -- bltu s3, t2, F_PAST
  obtain ⟨s2, e2, p2, m2, r2⟩ := brStep (prog := kernel) hp (H_PUSH + 1) (by decide) (by rw [m1]; exact code) p1 rfl
    (k' := F_PAST) (by jump)
  have tk : taken .bltu (s1.reg 19) (s1.reg 7) = decide (scr.length < c.pc + 1 + op) := by
    rw [r1 19]; regsimp; rw [hc.r19, a7]; simp only [taken]
    rw [ult_off hfit _ _ (by simp only [SCRIPT]; omega) (by simp only [SCRIPT]; omega)]
    simp only [decide_eq_decide]; omega
  rw [tk] at p2
  have hc2 : Core base m0 scr c s2 := hc.regs (by rw [m2, m1]) fun x hx => by
    rw [r2, r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  by_cases hpast : scr.length < c.pc + 1 + op
  · simp only [hpast, decide_true, ↓reduceIte] at p2 ⊢
    exact Goes.prepend (n := 1 + 1) (by rw [run_add_running e1, e2]) (f_past hp (hc2.code hp hin) p2)
  simp only [hpast, decide_false, Bool.false_eq_true, ↓reduceIte] at p2 ⊢
  have hd := hc.depth
  unfold pushE
  by_cases hfull : DMAX ≤ c.st.length
  · simp only [hfull, ↓reduceIte]
    exact Goes.prepend (n := 1 + 1) (by rw [run_add_running e1, e2])
      (room_fail hp hin hc2 p2 (by decide) rfl (by jump) hfull)
  simp only [hfull, ↓reduceIte]
  simp only [DMAX] at hd hfull
  have hS : STACK + 84 * c.st.length + 84 < 0x10000 := by simp only [STACK]; omega
  obtain ⟨s3, e3, p3, m3, r3⟩ := room_pass hp hin hc2 p2 (by decide) rfl (by jump) (by simp only [DMAX]; omega)
  obtain ⟨s4, e4, p4, m4, r4⟩ := zero_n (prog := kernel) (n := 21) (rd := 20) (o := 0)
    (a := STACK + 84 * c.st.length) (k0 := H_PUSH + 3) hp (by decide) (by decide) (by decide)
    (by omega) (by simp only [STACK]; omega) (by simp only [STACK]; rw [kernel_length]; omega)
    p3 (by rw [m3]; exact hc2.code hp hin) (by rw [r3, hc2.r20]) (by decide) 21 (Nat.le_refl _)
  have c4 : CodeAt s4.mem base kernel := by
    rw [m4, m3]; exact code_of_overlay hfit (hc2.code hp hin) (by simp only [STACK]; rw [kernel_length]; omega) (by omega) _
  -- sw t0, 0(s4)
  obtain ⟨s5, e5, p5, m5, r5⟩ := storeStep (prog := kernel) hp (H_PUSH + 24) (by decide) c4
    p4 rfl (STACK + 84 * c.st.length) (by rw [r4 20, r3, hc2.r20]; simp) (by omega) (by simp only [STACK]; omega)
  have v5 : (s4.reg 5).toNat = op := by
    rw [r4, r3, r2, r1 5]; regsimp; rw [hE.r5, BitVec.toNat_ofNat]; omega
  -- what the slot's window looks like now
  have mm5 : s5.mem = writeLE (overlay s.mem (base + BitVec.ofNat 32 (STACK + 84 * c.st.length)) 84 (fun _ => 0))
      (base + BitVec.ofNat 32 (STACK + 84 * c.st.length)) op 4 := by
    rw [m5, v5, m4, m3, m2, m1, Nat.add_zero]
  have ag5 : Agree s.mem s5.mem base (STACK + 84 * c.st.length) LIMIT := by
    rw [mm5]
    exact ((agree_overlay hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)).trans
      ((agree_writeLE hfit _ _ (by omega)).widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega))
  have cM : CodeAt s5.mem base kernel :=
    code_of_agree hfit hin.code (hc.agree.trans (ag5.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
  -- addi t3, s4, 4
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (H_PUSH + 25) (by decide) cM p5 rfl rfl
  have a20 : s5.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * c.st.length) := by
    rw [r5, r4, r3, hc2.r20]
  -- the loop
  obtain ⟨s7, e7, p7, m7, r18', keep⟩ := push_loop (p := SCRIPT + c.pc + 1) (q := STACK + 84 * c.st.length + 4)
    (n := op) (M := s5.mem) hp (by omega) (by simp only [SCRIPT, STACK]; omega) (by omega)
    (by simp only [STACK]; omega) cM op 0 s6 (by omega) (by omega) (by rw [p6]; rfl)
    (by rw [r6 18]; regsimp; rw [r5, r4, r3, r2, r1 18]; regsimp; rw [hE.r18])
    (by rw [r6 28]; regsimp; rw [a20]; simp only [aluI]
        rw [addi_pos hfit _ (v := 4) (by decide) (by decide) (by omega)])
    (by rw [r6 7]; regsimp; rw [r5, r4, r3, r2, a7])
    (by rw [m6, overlay_zero])
  -- the element in the slot
  have hel : ((scr.drop (c.pc + 1)).take op).length = op := by simp; omega
  have hscr : ∀ i < op, ((scr.drop (c.pc + 1)).take op).getD i 0
      = s5.mem (base + BitVec.ofNat 32 (SCRIPT + c.pc + 1 + i)) := by
    intro i hi
    rw [ag5 _ (by simp only [SCRIPT]; omega) (by left; simp only [SCRIPT, STACK]; omega),
      hc.agree _ (by simp only [SCRIPT]; omega) (by left; simp only [SCRIPT, STACK]; omega),
      show SCRIPT + c.pc + 1 + i = SCRIPT + (c.pc + 1 + i) by omega, hin.script _ (by omega)]
    simp [List.getD_eq_getElem?_getD, List.getElem?_take, List.getElem?_drop, hi]
  have slot : SlotAt s7.mem base (STACK + 84 * c.st.length) ((scr.drop (c.pc + 1)).take op) := by
    rw [m7, mm5]
    exact slot_n hfit _ _ _ _ _ (by omega) (by omega) hel (fun i hi => by rw [hscr i hi, mm5])
  have ag : Agree s.mem s7.mem base (STACK + 84 * c.st.length) LIMIT := by
    rw [m7]
    exact ag5.trans ((agree_overlay hfit _ _ (by omega)).widen (by omega) (by simp only [STACK, LIMIT]; omega))
  have k7 : ∀ x : Reg, x ≠ 18 → x ≠ 28 → x ≠ 29 → x ≠ 7 → x ≠ 5 → s7.reg x = s.reg x := fun x a b c' d e' => by
    rw [keep x a b c', r6 x]; simp only [b, false_and, ↓reduceIte]; rw [r5, r4, r3, r2, r1 x]
    simp only [d, false_and, ↓reduceIte]
  have e7' : run env (1 + 1 + 1 + 21 + 1 + 1 + 5 * op) s = .running s7 := by
    rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running
      ((run_add_running e1).trans e2)).trans e3)).trans e4)).trans e5)).trans e6), e7]
  refine Goes.prepend e7' (tail hp hin (k := c.st.length)
    (hc.fixed.keep fun x hx => k7 x ?_ ?_ ?_ ?_ ?_) (by rw [k7 20 (by decide) (by decide) (by decide) (by decide) (by decide), hc.r20])
    p7 (by decide) rfl rfl (by jump) ?_ (by rw [r18']; congr 2; simp only; omega) ?_
    (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
    (hc.stack.push (by simp only [DMAX]; omega) slot ag)
    (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by simp only; omega))
  all_goals first
    | (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
    | skip
  · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
    simp only [List.length_cons]; congr 2
  · rw [k7 21 (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21]
  · intro x hx; simp only [List.mem_cons] at hx
    rcases hx with rfl | hx
    · simp only [EMAX]; rw [hel]; omega
    · exact hc.elems x hx

end Exp228
