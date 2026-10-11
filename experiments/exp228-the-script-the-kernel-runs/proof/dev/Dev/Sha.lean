import Dev.Arith2

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- An element read back from its slot. -/
theorem readBytes_slot (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {A : Nat} {e : Elem}
    (h : SlotAt m base A e) (hA : A + 84 < 0x10000) (hl : e.length ≤ 80) :
    readBytes m (base + BitVec.ofNat 32 (A + 4)) e.length = e := by
  apply List.ext_getElem (by rw [readBytes_length])
  intro d h1 h2
  rw [readBytes_getElem _ _ _ _ h2, off_add hfit _ _ (by omega), show A + 4 + d = A + (4 + d) by omega,
    h _ (by omega)]
  unfold slotBytes
  simp only [show ¬ 4 + d < 4 by omega, ↓reduceIte, show 4 + d - 4 = d by omega, List.getD_eq_getElem?_getD,
    List.getElem?_eq_getElem h2, Option.getD_some]

theorem ev_writeBytes (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c : Nat) (f : Fin 32 → Byte) (x : Nat)
    (hc : c + 32 < 0x10000) (hx : x < 0x10000) :
    writeBytes m (base + BitVec.ofNat 32 c) f (base + BitVec.ofNat 32 x)
      = if h : c ≤ x ∧ x < c + 32 then f ⟨x - c, by omega⟩ else m (base + BitVec.ofNat 32 x) := by
  rw [writeBytes_apply, dist_of hfit c x (by omega) hx]
  by_cases h : c ≤ x ∧ x < c + 32
  · simp only [h.1, ↓reduceIte, show x - c < 32 by omega, ↓reduceDIte, h, and_self]
  · rw [dite_cond_eq_false (eq_false h)]
    by_cases h1 : c ≤ x
    · simp only [h1, ↓reduceIte, show ¬ x - c < 32 by omega, ↓reduceDIte]
    · simp only [h1, ↓reduceIte, show ¬ 2 ^ 32 - c + x < 32 by omega, ↓reduceDIte]


/-- **OP_SHA256**: the shell's hash of the top into TMP, the top's slot
zeroed, the 32 bytes copied back with their length. -/
theorem h_sha (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_SHA s) (hop : (scr.getD c.pc 0).toNat = 0xa8) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact need_fail (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump) (by decide) (by rw [hst]; decide)
  | a :: r =>
    rw [show stepOp env scr c = .next ⟨c.pc + 1, List.ofFn (env.hash a) :: r, c.sigs⟩ by
      simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 1 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    have ha : a.length ≤ 80 := hc.elems a (by rw [hst]; simp)
    generalize hA : STACK + 84 * r.length = A
    have hA1 : STACK ≤ A := by omega
    have hA2 : A + 84 ≤ TMP := by simp only [STACK, TMP] at *; omega
    have hT : TMP + 84 = LIMIT := rfl
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_SHA + 3) (by decide) (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_SHA + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have a13 : s2.reg 13 = base + BitVec.ofNat 32 A := by
      rw [r2 13]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK] at *; omega),
        ← hA]
      congr 2
    have mm3 : s3.mem = s.mem := by rw [m3, m2, m1]
    obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp (H_SHA + 5) (by decide) (by rw [mm3]; exact code)
      p3 rfl A (by rw [r3 13]; regsimp; rw [a13]; simp) (by simp only [TMP] at hA2; omega)
      (by rw [← hA]; simp only [STACK]; omega)
    obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (H_SHA + 6) (by decide)
      (by rw [m4, mm3]; exact code) p4 rfl rfl
    obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (H_SHA + 7) (by decide)
      (by rw [m5, m4, mm3]; exact code) p5 rfl rfl
    have mm6 : s6.mem = s.mem := by rw [m6, m5, m4, mm3]
    have slotA : SlotAt s6.mem base A a := by rw [mm6, ← hA]; exact st.top
    have k6 : ∀ x : Reg, x ≠ 5 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 12 → x ≠ 13 → s6.reg x = s.reg x :=
      fun x h5 h6 h7 h10 h11 h12 h13 => by
        rw [r6 x]; simp only [h5, false_and, ↓reduceIte]; rw [r5 x]; simp only [h12, false_and, ↓reduceIte]
        rw [r4 x]; simp only [h11, false_and, ↓reduceIte]; rw [r3 x]; simp only [h10, false_and, ↓reduceIte]
        rw [r2 x]; simp only [h13, false_and, ↓reduceIte]; exact r1 x h6 h7
    have b10 : s6.reg 10 = base + BitVec.ofNat 32 (A + 4) := by
      rw [r6 10]; regsimp; rw [r5 10]; regsimp; rw [r4 10]; regsimp; rw [r3 10]; regsimp; simp only [aluI]
      rw [a13]; exact addi_pos hfit _ (by decide) (by decide) (by simp only [TMP] at hA2; omega)
    have b11 : s6.reg 11 = BitVec.ofNat 32 a.length := by
      rw [r6 11]; regsimp; rw [r5 11]; regsimp; rw [r4 11]; regsimp; rw [mm3]
      rw [← hA, slot_len hfit st.top (by simp only [STACK]; omega) (by omega)]
    have b12 : s6.reg 12 = base + BitVec.ofNat 32 (TMP + 4) := by
      rw [r6 12]; regsimp; rw [r5 12]; regsimp; simp only [aluI]
      rw [r4 25]; regsimp; rw [r3 25]; regsimp; rw [r2 25]; regsimp; rw [r1 25 (by decide) (by decide), hc.r25]
      exact addi_pos hfit _ (by decide) (by decide) (by decide)
    have b13 : s6.reg 13 = base + BitVec.ofNat 32 A := by
      rw [r6 13]; regsimp; rw [r5 13]; regsimp; rw [r4 13]; regsimp; rw [r3 13]; regsimp; exact a13
    have b5 : s6.reg T0 = 2 := by
      rw [T0, r6 5]; regsimp; simp only [aluI, reg_zero]
      rw [show (2 : BitVec 12) = BitVec.ofNat 12 2 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _
    -- ecall: HASHB
    have hex := exec_hashb (env := env) (s := s6) b5
      (by rw [A0, A1, b10, b11, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show a.length < 2 ^ 32 by omega)]; exact ok_off hp _ _ (by simp only [TMP] at hA2; omega) (by simp only [TMP] at hA2; omega))
      (by rw [A2, b12]; exact ok_off hp _ _ (by decide) (by decide))
    rw [A0, A1, A2, b10, b11, b12, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show a.length < 2 ^ 32 by omega), readBytes_slot hfit slotA (by simp only [TMP] at hA2; omega) ha] at hex
    have e7 := stepK (prog := kernel) hp (H_SHA + 8) (by decide) (by rw [mm6]; exact code) p6 rfl hex 0
    generalize hs7 : ({ s6 with mem := writeBytes s6.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a) } : Machine).next
      = s7 at e7
    rw [run_zero] at e7
    have p7 : s7.pc = base + BitVec.ofNat 32 (4 * (H_SHA + 9)) := by
      rw [← hs7, next_pc]; simp only; rw [p6]; exact pc_next hfit _ (by decide)
    have m7 : s7.mem = writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a) := by
      rw [← hs7, mm6]; rfl
    have r7 : ∀ x, s7.reg x = s6.reg x := fun x => by rw [← hs7]; rfl
    have ag7 : Agree s.mem s7.mem base TMP LIMIT := by
      rw [m7]; exact (agree_writeBytes hfit _ _ (by decide)).widen (by omega) (by decide)
    have c7 : CodeAt s7.mem base kernel := code_keep hfit code ag7 (by decide)
    -- zero the top's slot
    obtain ⟨s8, e8, p8, m8, r8⟩ := zero_n (prog := kernel) (n := 21) (rd := 13) (o := 0) (a := A)
      (k0 := H_SHA + 9) hp (by decide) (by decide) (by decide) (by simp only [TMP] at hA2; omega)
      (by rw [← hA]; simp only [STACK]; omega) (by rw [kernel_length]; simp only [STACK] at hA1; omega)
      p7 c7 (by rw [r7, b13]) (by decide) 21 (Nat.le_refl _)
    have mm8 : s8.mem = overlay s7.mem (base + BitVec.ofNat 32 A) 84 (fun _ => 0) := by rw [m8, Nat.add_zero]
    have c8 : CodeAt s8.mem base kernel := by
      rw [mm8]; exact code_of_overlay hfit c7 (by rw [kernel_length]; simp only [STACK] at hA1; omega)
        (by simp only [TMP] at hA2; omega) _
    -- copy the 32 bytes back
    obtain ⟨s9, e9, p9, m9, r9⟩ := copy_n (prog := kernel) (n := 8) (rs := 25) (rd := 13) (t := 6) (so := 4) (dof := 4)
      (src := TMP) (dst := A) (k0 := H_SHA + 30) hp (by decide) (by rw [kernel_length]; decide) (by decide) (by decide)
      (by decide) (by decide) (by decide) (by decide) (by simp only [TMP] at hA2; omega) (by decide)
      (by rw [← hA]; simp only [STACK]; omega) (by rw [kernel_length]; simp only [STACK] at hA1; omega)
      (by right; simp only [TMP] at hA2 ⊢; omega) (by rw [p8]) c8
      (by rw [r8, r7, k6 25 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r25])
      (by rw [r8, r7, b13]) (by decide) 8 (Nat.le_refl _)
    have c9 : CodeAt s9.mem base kernel := by
      rw [m9]; exact code_of_overlay hfit c8 (by rw [kernel_length]; simp only [STACK] at hA1; omega)
        (by simp only [TMP] at hA2; omega) _
    obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp (H_SHA + 46) (by decide) c9 p9 rfl rfl
    obtain ⟨s11, e11, p11, m11, r11⟩ := storeStep (prog := kernel) hp (H_SHA + 47) (by decide) (by rw [m10]; exact c9)
      p10 rfl A (by rw [r10 13]; regsimp; rw [r9 13 (by decide), r8, r7, b13]; simp)
      (by simp only [TMP] at hA2; omega) (by rw [← hA]; simp only [STACK]; omega)
    have v11 : (s10.reg 6).toNat = 32 := by
      rw [r10 6]; regsimp; simp only [aluI, reg_zero]
      rw [show (0x20 : BitVec 12) = BitVec.ofNat 12 32 from rfl, se_small _ (by decide)]; rfl
    have hA84 : A + 84 < 0x10000 := by simp only [TMP] at hA2; omega
    have mem11 : s11.mem = writeLE (overlay (overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a))
        (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) (base + BitVec.ofNat 32 (A + 4)) 32
        (fun d => overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a))
          (base + BitVec.ofNat 32 A) 84 (fun _ => 0) (base + BitVec.ofNat 32 (TMP + 4 + d))))
        (base + BitVec.ofNat 32 A) 32 4 := by
      rw [m11, v11, m10, m9, mm8, m7]
    have slot : SlotAt s11.mem base A (List.ofFn (env.hash a)) := by
      rw [mem11]; intro d hd
      rw [ev_writeLE hfit _ _ _ _ (by omega) (by omega), ev_overlay hfit _ _ _ _ _ (by omega) (by omega)]
      unfold slotBytes
      rcases (by omega : d < 4 ∨ (4 ≤ d ∧ d < 36) ∨ 36 ≤ d) with h | h | h
      · simp only [show A ≤ A + d ∧ A + d < A + 4 by omega, and_self, ↓reduceIte, h, show A + d - A = d by omega,
          List.length_ofFn]
      · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show A + 4 ≤ A + d ∧ A + d < A + 4 + 32 by omega,
          and_self, ↓reduceIte, show ¬ d < 4 by omega, show A + d - (A + 4) = d - 4 by omega]
        rw [ev_overlay hfit _ _ _ _ _ (by omega) (by simp only [TMP]; omega),
          ite_eq_right_of_eq_false _ _ (eq_false (by simp only [TMP] at hA2 ⊢; omega)),
          ev_writeBytes hfit _ _ _ _ (by decide) (by simp only [TMP]; omega),
          dite_cond_eq_true (eq_true ⟨by omega, by omega⟩)]
        rw [List.getD_eq_getElem?_getD, List.getElem?_ofFn]
        simp [show d - 4 < 32 by omega, show TMP + 4 + (d - 4) - (TMP + 4) = d - 4 by omega]
      · simp only [show ¬ (A ≤ A + d ∧ A + d < A + 4) by omega, show ¬ (A + 4 ≤ A + d ∧ A + d < A + 4 + 32) by omega,
          and_self, ↓reduceIte, show ¬ d < 4 by omega, false_and, show ¬ A + d < A + 4 by omega, and_false]
        rw [ev_overlay hfit _ _ _ _ _ (by omega) (by omega),
          ite_eq_left_of_eq_true _ _ (eq_true ⟨by omega, by omega⟩)]
        rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by simp; omega)]; rfl
    have ag : Agree s.mem s11.mem base A LIMIT := by
      rw [mem11]
      have a1 : Agree s.mem (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a)) base A LIMIT :=
        (agree_writeBytes hfit _ _ (by decide)).widen (by simp only [TMP] at hA2 ⊢; omega) (by decide)
      have a2 := (agree_overlay hfit (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a)) (fun _ => 0)
        (c := A) (n := 84) (by omega)).widen (lo' := A) (hi' := LIMIT) (Nat.le_refl _) (by simp only [TMP, LIMIT] at hA2 ⊢; omega)
      have a3 := (agree_overlay hfit (overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a))
        (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) (fun d => overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4))
          (env.hash a)) (base + BitVec.ofNat 32 A) 84 (fun _ => 0) (base + BitVec.ofNat 32 (TMP + 4 + d)))
        (c := A + 4) (n := 32) (by omega)).widen (lo' := A) (hi' := LIMIT) (by omega)
        (by simp only [TMP, LIMIT] at hA2 ⊢; omega)
      have a4 := (agree_writeLE hfit (overlay (overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a))
        (base + BitVec.ofNat 32 A) 84 (fun _ => 0)) (base + BitVec.ofNat 32 (A + 4)) 32
        (fun d => overlay (writeBytes s.mem (base + BitVec.ofNat 32 (TMP + 4)) (env.hash a))
          (base + BitVec.ofNat 32 A) 84 (fun _ => 0) (base + BitVec.ofNat 32 (TMP + 4 + d)))) 32 (c := A) (by omega)).widen
        (lo' := A) (hi' := LIMIT) (Nat.le_refl _) (by simp only [TMP, LIMIT] at hA2 ⊢; omega)
      exact a1.trans (a2.trans (a3.trans a4))
    have k11 : ∀ x : Reg, x ≠ 5 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 12 → x ≠ 13 → s11.reg x = s.reg x :=
      fun x h5 h6 h7 h10 h11 h12 h13 => by
        rw [r11, r10 x]; simp only [h6, false_and, ↓reduceIte]; rw [r9 x h6, r8, r7, k6 x h5 h6 h7 h10 h11 h12 h13]
    have e11 : run env (3 + 1 + 1 + 1 + 1 + 1 + 1 + 21 + 2 * 8 + 1 + 1) s = .running s11 :=
      run_trans (run_trans (run_trans (run_trans (run_trans (run_trans (run_trans (run_trans (run_trans (run_trans
        e1 e2) e3) e4) e5) e6) e7) e8) e9) e10) e11
    have hcore : Core base m0 scr ⟨c.pc + 1, List.ofFn (env.hash a) :: r, c.sigs⟩ s11 := by
      refine hc.next (fun x hx => k11 x ?_ ?_ ?_ ?_ ?_ ?_ ?_)
        (by rw [k11 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r20, hst]; simp)
        (by rw [k11 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21])
        (hc.agree.trans (ag.widen hA1 (Nat.le_refl _))) ?_ (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs
        (by have := hE.lt; simp only; omega)
      all_goals first
        | (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
        | skip
      · show Holds s11.mem base (List.ofFn (env.hash a) :: r)
        exact st.pop.push (by simp only [DMAX]; omega) (hA ▸ slot) (hA ▸ ag)
      · intro x hx; simp only [List.mem_cons] at hx
        rcases hx with rfl | hx
        · simp [EMAX]
        · exact hc.elems x (by rw [hst]; simp [hx])
    exact Goes.prepend e11 (back hp hin hcore (by rw [k11 18 (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide), hE.r18, Nat.add_assoc]) (by rw [p11]) (by decide) rfl (by jump))

end Exp228
