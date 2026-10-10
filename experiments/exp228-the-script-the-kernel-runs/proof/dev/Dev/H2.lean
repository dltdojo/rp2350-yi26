import Dev.H1
import Dev.Copy

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- **OP_DUP**. -/
theorem h_dup (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_DUP s) (hop : (scr.getD c.pc 0).toNat = 0x76) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact need_fail (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump) (by decide) (by rw [hst]; decide)
  | e :: r =>
    rw [show stepOp env scr c = pushE c (c.pc + 1) e by simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 1 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    have hc1 : Core base m0 scr c s1 := hc.regs m1 fun x hx => r1 x
      (by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
      (by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
    unfold pushE
    by_cases hfull : DMAX ≤ c.st.length
    · simp only [hfull, ↓reduceIte]
      exact Goes.prepend e1 (room_fail hp hin hc1 p1 (by decide) rfl (by jump) hfull)
    simp only [hfull, ↓reduceIte]
    simp only [DMAX] at hfull
    obtain ⟨s2, e2, p2, m2, r2⟩ := room_pass hp hin hc1 p1 (by decide) rfl (by jump) (by simp only [DMAX]; omega)
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_DUP + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have a13 : s3.reg 13 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r3 13]; regsimp; rw [r2, hc1.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have a20 : s3.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1)) := by
      rw [r3 20]; regsimp; rw [r2, hc1.r20, hlen]
    have st := hc.stack
    rw [hst] at st
    obtain ⟨s4, e4, p4, m4, r4⟩ := copy_slot (k0 := H_DUP + 5) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega)
      (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by omega)
      p3 (by rw [m3, m2, m1]; exact code) a13 a20
    have slot : SlotAt s4.mem base (STACK + 84 * (e :: r).length) e := by
      rw [m4, m3, m2, m1]; exact copied hfit st.top (by simp only [STACK]; omega)
    have ag : Agree s.mem s4.mem base (STACK + 84 * (e :: r).length) LIMIT := by
      rw [m4, m3, m2, m1]; exact agree_copy hfit _ _ (by simp only [STACK, LIMIT]; omega)
    have k6 : Keeps6 s s4 := fun x hx => by
      rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;>
      · rw [r4 _ (by decide), r3]; regsimp; rw [r2, r1 _ (by decide) (by decide)]
    have e4' : run env (3 + 1 + 1 + 42) s = .running s4 := by
      rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4]
    refine Goes.prepend e4' (tail hp hin (k := r.length + 1) (hc.fixed.keep k6)
      (by rw [r4 20 (by decide), a20]) p4 (by decide) rfl rfl (by jump) ?_
      ?_ ?_ (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
      (by show Holds s4.mem base (e :: c.st); rw [hst]; exact st.push (by simp only [DMAX, List.length_cons]; omega) slot ag)
      (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by have := hE.lt; simp only; omega))
    · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
      simp only [List.length_cons, hst]
      rw [show STACK + 84 * (r.length + 1) + 84 = STACK + 84 * (r.length + 1 + 1) by omega]
    · rw [r4 18 (by decide), r3 18]; regsimp; rw [r2, r1 18 (by decide) (by decide), hE.r18, Nat.add_assoc]
    · rw [r4 21 (by decide), r3 21]; regsimp; rw [r2, r1 21 (by decide) (by decide), hc.r21]
    · intro x hx; simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · exact hc.elems _ (by rw [hst]; simp)
      · exact hc.elems x hx

/-- Fewer than two: the spec's underflow, and the kernel's `need(2)` failing. -/
theorem under2 (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op k : Nat} {s : Machine}
    (hE : Entry base m0 scr c op k s) (hk : k + 2 < 881)
    (h1 : kernel.getD k .ecall = .op .sub 6 20 23)
    (h2 : kernel.getD (k + 1) .ecall = .opi .addi 7 0 (BitVec.ofNat 12 (84 * 2)))
    {off : BitVec 12} (h3 : kernel.getD (k + 2) .ecall = .br .bltu 6 7 off)
    (hoff : BitVec.ofNat 32 (4 * (k + 2)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * F_UNDER))
    (hl : c.st.length < 2) : Goes env base m0 scr s (.done C_UNDER) :=
  need_fail (k := 2) hp hin hE.core hE.pc hk h1 h2 h3 hoff (by decide) hl

/-- **OP_NIP**. -/
theorem h_nip (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_NIP s) (hop : (scr.getD c.pc 0).toNat = 0x77) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by rw [hst]; decide)
  | [_] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by rw [hst]; simp)
  | a :: b :: r =>
    rw [show stepOp env scr c = .next ⟨c.pc + 1, a :: r, c.sigs⟩ by simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_NIP + 3) (by decide)
      (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_NIP + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have a20 : s3.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 2)) := by
      rw [r3 20]; regsimp; rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]
    have a13 : s3.reg 13 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1)) := by
      rw [r3 13]; regsimp; rw [r2 13]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have a14 : s3.reg 14 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r3 14]; regsimp; rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have st := hc.stack
    rw [hst] at st
    obtain ⟨s4, e4, p4, m4, r4⟩ := copy_slot (k0 := H_NIP + 5) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega)
      (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by omega)
      p3 (by rw [m3, m2, m1]; exact code) a13 a14
    have slot : SlotAt s4.mem base (STACK + 84 * r.length) a := by
      rw [m4, m3, m2, m1]; exact copied hfit st.top (by simp only [STACK]; omega)
    have ag : Agree s.mem s4.mem base (STACK + 84 * r.length) LIMIT := by
      rw [m4, m3, m2, m1]; exact agree_copy hfit _ _ (by simp only [STACK, LIMIT]; omega)
    have k6 : Keeps6 s s4 := fun x hx => by
      rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;>
      · rw [r4 _ (by decide), r3]; regsimp; rw [r2]; regsimp; rw [r1 _ (by decide) (by decide)]
    have e4' : run env (3 + 1 + 1 + 42) s = .running s4 := by
      rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4]
    refine Goes.prepend e4' (tail hp hin (k := r.length + 2) (hc.fixed.keep k6)
      (by rw [r4 20 (by decide), a20]) p4 (by decide) rfl rfl (by jump) ?_
      ?_ ?_ (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
      (by show Holds s4.mem base (a :: r); exact st.pop.pop.push (by simp only [DMAX]; omega) slot ag)
      (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by have := hE.lt; simp only; omega))
    · rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      simp only [List.length_cons]
      rw [show STACK + 84 * (r.length + 2) - 84 = STACK + 84 * (r.length + 1) by omega]
    · rw [r4 18 (by decide), r3 18]; regsimp; rw [r2 18]; regsimp
      rw [r1 18 (by decide) (by decide), hE.r18, Nat.add_assoc]
    · rw [r4 21 (by decide), r3 21]; regsimp; rw [r2 21]; regsimp; rw [r1 21 (by decide) (by decide), hc.r21]
    · intro x hx; simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · exact hc.elems _ (by rw [hst]; simp)
      · exact hc.elems x (by rw [hst]; simp [hx])

/-- **OP_OVER**. -/
theorem h_over (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_OVER s) (hop : (scr.getD c.pc 0).toNat = 0x78) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by rw [hst]; decide)
  | [_] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by rw [hst]; simp)
  | a :: b :: r =>
    rw [show stepOp env scr c = pushE c (c.pc + 1) b by simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    have hc1 : Core base m0 scr c s1 := hc.regs m1 fun x hx => r1 x
      (by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
      (by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
    unfold pushE
    by_cases hfull : DMAX ≤ c.st.length
    · simp only [hfull, ↓reduceIte]
      exact Goes.prepend e1 (room_fail hp hin hc1 p1 (by decide) rfl (by jump) hfull)
    simp only [hfull, ↓reduceIte]
    simp only [DMAX] at hfull
    obtain ⟨s2, e2, p2, m2, r2⟩ := room_pass hp hin hc1 p1 (by decide) rfl (by jump) (by simp only [DMAX]; omega)
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_OVER + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have a13 : s3.reg 13 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r3 13]; regsimp; rw [r2, hc1.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have a20 : s3.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 2)) := by
      rw [r3 20]; regsimp; rw [r2, hc1.r20, hlen]
    have st := hc.stack
    rw [hst] at st
    obtain ⟨s4, e4, p4, m4, r4⟩ := copy_slot (k0 := H_OVER + 5) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega)
      (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by omega)
      p3 (by rw [m3, m2, m1]; exact code) a13 a20
    have slot : SlotAt s4.mem base (STACK + 84 * (a :: b :: r).length) b := by
      rw [m4, m3, m2, m1]; exact copied hfit st.second (by simp only [STACK]; omega)
    have ag : Agree s.mem s4.mem base (STACK + 84 * (a :: b :: r).length) LIMIT := by
      rw [m4, m3, m2, m1]; exact agree_copy hfit _ _ (by simp only [STACK, LIMIT, List.length_cons]; omega)
    have k6 : Keeps6 s s4 := fun x hx => by
      rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;>
      · rw [r4 _ (by decide), r3]; regsimp; rw [r2, r1 _ (by decide) (by decide)]
    have e4' : run env (3 + 1 + 1 + 42) s = .running s4 := by
      rw [run_add_running ((run_add_running ((run_add_running e1).trans e2)).trans e3), e4]
    refine Goes.prepend e4' (tail hp hin (k := r.length + 2) (hc.fixed.keep k6)
      (by rw [r4 20 (by decide), a20]) p4 (by decide) rfl rfl (by jump) ?_
      ?_ ?_ (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
      (by show Holds s4.mem base (b :: c.st); rw [hst]
          exact st.push (by simp only [DMAX, List.length_cons]; omega) slot ag)
      (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs (by have := hE.lt; simp only; omega))
    · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
      simp only [List.length_cons, hst]
      congr 2; try omega
    · rw [r4 18 (by decide), r3 18]; regsimp; rw [r2, r1 18 (by decide) (by decide), hE.r18, Nat.add_assoc]
    · rw [r4 21 (by decide), r3 21]; regsimp; rw [r2, r1 21 (by decide) (by decide), hc.r21]
    · intro x hx; simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · exact hc.elems _ (by rw [hst]; simp)
      · exact hc.elems x hx

/-- **OP_SWAP**: the top to TMP, the second up, TMP down. -/
theorem h_swap (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_SWAP s) (hop : (scr.getD c.pc 0).toNat = 0x7c) :
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
    exact under2 hp hin hE (by decide) rfl rfl rfl (by jump) (by rw [hst]; simp)
  | a :: b :: r =>
    rw [show stepOp env scr c = .next ⟨c.pc + 1, b :: a :: r, c.sigs⟩ by simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have hA : STACK + 84 * (r.length + 1) + 84 ≤ TMP := by simp only [STACK, TMP, LIMIT]; omega
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_SWAP + 3) (by decide)
      (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (H_SWAP + 4) (by decide)
      (by rw [m2, m1]; exact code) p2 rfl rfl
    have a13 : s3.reg 13 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1)) := by
      rw [r3 13]; regsimp; rw [r2 13]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK, TMP, LIMIT]; omega)]
      congr 2
    have a14 : s3.reg 14 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r3 14]; regsimp; rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK, TMP, LIMIT]; omega)]
      congr 2
    have a25 : s3.reg 25 = base + BitVec.ofNat 32 TMP := by
      rw [r3 25]; regsimp; rw [r2 25]; regsimp; rw [r1 25 (by decide) (by decide), hc.r25]
    have st := hc.stack
    rw [hst] at st
    have c3 : CodeAt s3.mem base kernel := by rw [m3, m2, m1]; exact code
    -- the top to TMP
    obtain ⟨s4, e4, p4, m4, r4⟩ := copy_slot (k0 := H_SWAP + 5) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega)
      (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by decide) (by omega)
      p3 c3 a13 a25
    have T4 : SlotAt s4.mem base TMP a := by
      rw [m4, m3, m2, m1]; exact copied hfit st.top (by simp only [STACK, TMP, LIMIT]; omega)
    have ag4 : Agree s.mem s4.mem base TMP LIMIT := by
      rw [m4, m3, m2, m1]; exact agree_copy hfit _ _ (by simp only [STACK, TMP, LIMIT]; omega)
    have B4 : SlotAt s4.mem base (STACK + 84 * r.length) b :=
      st.second.agree ag4 (by simp only [STACK, TMP, LIMIT]; omega) (by left; omega)
    have c4 : CodeAt s4.mem base kernel :=
      code_of_agree hfit hin.code (hc.agree.trans (ag4.widen (by simp only [STACK, TMP, LIMIT]; omega) (Nat.le_refl _)))
    -- the second up
    obtain ⟨s5, e5, p5, m5, r5⟩ := copy_slot (k0 := H_SWAP + 47) (rs := 14) (rd := 13)
      (src := STACK + 84 * r.length) (dst := STACK + 84 * (r.length + 1)) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega)
      (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by omega)
      (by rw [p4]) c4 (by rw [r4 14 (by decide), a14]) (by rw [r4 13 (by decide), a13])
    have A5 : SlotAt s5.mem base (STACK + 84 * (r.length + 1)) b := by
      rw [m5]; exact copied hfit B4 (by simp only [STACK, TMP, LIMIT]; omega)
    have ag45 : Agree s4.mem s5.mem base (STACK + 84 * (r.length + 1)) (STACK + 84 * (r.length + 1) + 84) := by
      rw [m5]; exact agree_overlay hfit _ _ (by simp only [STACK, TMP, LIMIT]; omega)
    have T5 : SlotAt s5.mem base TMP a := T4.agree ag45 (by simp only [STACK, TMP, LIMIT]; omega) (by right; omega)
    have ag5 : Agree s.mem s5.mem base (STACK + 84 * (r.length + 1)) LIMIT :=
      (ag4.widen (by simp only [STACK, TMP, LIMIT]; omega) (Nat.le_refl _)).trans
        (ag45.widen (Nat.le_refl _) (by simp only [STACK, TMP, LIMIT]; omega))
    have c5 : CodeAt s5.mem base kernel :=
      code_of_agree hfit hin.code (hc.agree.trans (ag5.widen (by simp only [STACK, TMP, LIMIT]; omega) (Nat.le_refl _)))
    -- TMP down
    obtain ⟨s6, e6, p6, m6, r6⟩ := copy_slot (k0 := H_SWAP + 89) (rs := 25) (rd := 14)
      (src := TMP) (dst := STACK + 84 * r.length) hp (by decide) (by decide) (by decide) (by decide)
      (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega) (by simp only [STACK, TMP, LIMIT]; omega)
      (by simp only [STACK, TMP, LIMIT]; omega) (by decide) (by simp only [STACK, TMP, LIMIT]; omega) (by omega)
      (by rw [p5]) c5 (by rw [r5 25 (by decide), r4 25 (by decide), a25])
      (by rw [r5 14 (by decide), r4 14 (by decide), a14])
    have B6 : SlotAt s6.mem base (STACK + 84 * r.length) a := by
      rw [m6]; exact copied hfit T5 (by simp only [STACK, TMP, LIMIT]; omega)
    have ag56 : Agree s5.mem s6.mem base (STACK + 84 * r.length) (STACK + 84 * r.length + 84) := by
      rw [m6]; exact agree_overlay hfit _ _ (by simp only [STACK, TMP, LIMIT]; omega)
    have A6 : SlotAt s6.mem base (STACK + 84 * (r.length + 1)) b :=
      A5.agree ag56 (by simp only [STACK, TMP, LIMIT]; omega) (by right; omega)
    have ag6 : Agree s.mem s6.mem base (STACK + 84 * r.length) LIMIT :=
      (ag5.widen (by omega) (Nat.le_refl _)).trans (ag56.widen (Nat.le_refl _) (by simp only [STACK, TMP, LIMIT]; omega))
    have e6' : run env (3 + 1 + 1 + 42 + 42 + 42) s = .running s6 := by
      rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running e1).trans
        e2)).trans e3)).trans e4)).trans e5), e6]
    have k6 : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 13 → x ≠ 14 → s6.reg x = s.reg x := fun x h6 h7 h13 h14 => by
      rw [r6 x h6, r5 x h6, r4 x h6, r3 x, r2 x]
      simp only [h13, h14, false_and, ↓reduceIte]
      exact r1 x h6 h7
    have hcore : Core base m0 scr ⟨c.pc + 1, b :: a :: r, c.sigs⟩ s6 := by
      refine hc.next (fun x hx => k6 x ?_ ?_ ?_ ?_) ?_ ?_
        (hc.agree.trans (ag6.widen (by simp only [STACK, TMP, LIMIT]; omega) (Nat.le_refl _)))
        ((st.pop.pop.push (by simp only [DMAX]; omega) B6 ag6).push (by simp only [DMAX, List.length_cons]; omega)
          A6 (Agree.refl _ _ _ _)) (by simp only [DMAX, List.length_cons]; omega) ?_ hc.sigs
        (by have := hE.lt; simp only; omega)
      all_goals first
        | (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
        | skip
      · rw [k6 20 (by decide) (by decide) (by decide) (by decide), hc.r20, hlen]; rfl
      · rw [k6 21 (by decide) (by decide) (by decide) (by decide), hc.r21]
      · intro x hx; simp only [List.mem_cons] at hx
        rcases hx with rfl | rfl | hx
        · exact hc.elems _ (by rw [hst]; simp)
        · exact hc.elems _ (by rw [hst]; simp)
        · exact hc.elems x (by rw [hst]; simp [hx])
    exact Goes.prepend e6' (back hp hin hcore
      (by rw [k6 18 (by decide) (by decide) (by decide) (by decide), hE.r18, Nat.add_assoc]) p6 (by decide) rfl (by jump))

end Exp228
