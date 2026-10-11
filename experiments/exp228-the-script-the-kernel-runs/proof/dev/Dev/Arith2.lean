import Dev.Arith

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- **From CORE to the top of the loop**: the sum encoded, in the slot at `s4`,
pushed on `r`. -/
theorem arith_finish (hp : Placed env base) (hin : Input m0 base scr st0) {r : List Elem} {pc' sigs : Nat}
    {s : Machine} (hf : Fixed base scr s) (hpc : s.pc = base + BitVec.ofNat 32 (4 * CORE))
    (h20 : s.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * r.length))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + pc')) (h21 : s.reg 21 = BitVec.ofNat 32 sigs)
    (hag : Agree m0 s.mem base STACK LIMIT) (hst : Holds s.mem base r) (hd : r.length < DMAX)
    (he : ∀ e ∈ r, e.length ≤ EMAX) (hs : sigs ≤ 1) (hpc' : pc' ≤ scr.length)
    {s1 m1 s2 m2 : Nat} (hs1 : s1 ≤ 1) (hs2 : s2 ≤ 1) (hm1 : m1 < 2 ^ 31) (hm2 : m2 < 2 ^ 31)
    (h13 : s.reg 13 = BitVec.ofNat 32 s1) (h14 : s.reg 14 = BitVec.ofNat 32 m1)
    (h15 : s.reg 15 = BitVec.ofNat 32 s2) (h16 : s.reg 16 = BitVec.ofNat 32 m2) :
    Goes env base m0 scr s (.next ⟨pc', encode (val s1 m1 + val s2 m2) :: r, sigs⟩) := by
  have hfit := hp.fit
  simp only [DMAX] at hd
  have code := code_of_agree hfit hin.code hag
  obtain ⟨k1, t1, e1, p1, n1, a11, a12, q1⟩ := core_block hp code hpc hs1 hs2 hm1 hm2 h13 h14 h15 h16
  obtain ⟨k2, t2, e2, p2, slot, ag, q2⟩ := enc_block hp (by rw [n1]; exact code) p1 (A := STACK + 84 * r.length)
    (by omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) (kcore_le _ _ _ _ hs1 hs2)
    (kcore_lt _ _ _ _ hm1 hm2) a11 a12 (by rw [q1 20 (by decide) (by decide), h20])
  rw [n1] at ag
  have hk : encode (val s1 m1 + val s2 m2) = kenc (kcore s1 m1 s2 m2).1 (kcore s1 m1 s2 m2).2 := by
    rw [← kcore_val _ _ _ _ hs1 hs2, encode_k _ _ (kcore_le _ _ _ _ hs1 hs2) (kcore_lt _ _ _ _ hm1 hm2)]
  rw [hk]
  have agw : Agree s.mem t2.mem base (STACK + 84 * r.length) LIMIT :=
    ag.widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)
  have kt : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 11 → x ≠ 12 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 → t2.reg x = s.reg x :=
    fun x h6 h7 h11 h12 h28 h29 h30 h31 => by rw [q2 x h6 h7 h12 h28 h29 h30 h31, q1 x h11 h12]
  refine Goes.prepend (n := k1 + k2) (by rw [run_add_running e1, e2]) (tail hp hin (k := r.length)
    (hf.keep fun x hx => by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> (apply kt <;> decide))
    (by rw [kt 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h20])
    p2 (by decide) rfl rfl (by jump) ?_
    (by rw [kt 18 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h18])
    (by rw [kt 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h21])
    (hag.trans (agw.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
    (hst.push (by simp only [DMAX]; omega) slot agw) (by simp only [DMAX, List.length_cons]; omega) ?_ hs hpc')
  · rw [addi_pos hfit _ (v := 84) (by decide) (by decide) (by simp only [STACK]; omega)]
    simp only [List.length_cons]
    rw [show STACK + 84 * r.length + 84 = STACK + 84 * (r.length + 1) by omega]
  · intro x hx; simp only [List.mem_cons] at hx
    rcases hx with rfl | hx
    · have := kenc_length (kcore s1 m1 s2 m2).1 (kcore s1 m1 s2 m2).2 (kcore_lt _ _ _ _ hm1 hm2)
      simp only [EMAX]; omega
    · exact he x hx

theorem run_trans {s s1 s2 : Machine} {a b : Nat} (h1 : run env a s = .running s1) (h2 : run env b s1 = .running s2) :
    run env (a + b) s = .running s2 := (run_add_running h1).trans h2

theorem add0w (x : Word) : x + (0 : BitVec 12).signExtend 32 = x := by
  rw [show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]

/-- What OP_1ADD (`v = 0`) and OP_1SUB (`v = 1`) do. -/
def unRes (v : Nat) (c : Cfg) : Res :=
  match c.st with
  | a :: r =>
    match decode a with
    | some x => .next ⟨c.pc + 1, encode (x + val v 1) :: r, c.sigs⟩
    | none => .done C_NUM
  | [] => .done C_UNDER

/-- **UNARY**: the top decoded, `±1` added in CORE. -/
theorem unary_core (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine} (v : Nat)
    (hv : v ≤ 1) (hc : Core base m0 scr c s) (hpc : s.pc = base + BitVec.ofNat 32 (4 * UNARY))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1)) (h15 : s.reg 15 = BitVec.ofNat 32 v)
    (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (unRes v c) := by
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    simp only [unRes, hst]
    exact need_fail (k := 1) hp hin hc hpc (by decide) rfl rfl rfl (by jump) (by decide) (by simp [hst])
  | a :: r =>
    simp only [unRes, hst]
    have hlen : c.st.length = r.length + 1 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    have ha : a.length ≤ 80 := hc.elems a (by rw [hst]; simp)
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 1) hp hin hc hpc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (UNARY + 3) (by decide) (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := callStep (prog := kernel) hp (UNARY + 4) (by decide) (by rw [m2, m1]; exact code) p2
      rfl (k' := DECODE) (by jump)
    have mm3 : s3.mem = s.mem := by rw [m3, m2, m1]
    have a10 : s3.reg 10 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r3 10]; simp only [show (10 : Reg) ≠ 1 by decide, ↓reduceIte]; rw [r2 10]; regsimp
      rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have a1 : s3.reg 1 = base + BitVec.ofNat 32 (4 * (UNARY + 5)) := by rw [r3 1]; simp
    have k3 : ∀ x : Reg, x ≠ 1 → x ≠ 6 → x ≠ 7 → x ≠ 10 → s3.reg x = s.reg x := fun x h1 h6 h7 h10 => by
      rw [r3 x]; simp only [h1, ↓reduceIte]; rw [r2 x]; simp only [h10, false_and, ↓reduceIte]; exact r1 x h6 h7
    have slot : SlotAt s3.mem base (STACK + 84 * r.length) a := by rw [mm3]; exact st.top
    have hw := word_of_slot hfit slot (by simp only [STACK]; omega)
    obtain ⟨dn, ds⟩ := dec_block (m0 := m0) (scr := scr) hp (by rw [mm3]; exact code) p3
      (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) a10 slot ha
      a1 (by decide)
    have e3' : run env (3 + 1 + 1) s = .running s3 := by
      rw [run_add_running ((run_add_running e1).trans e2), e3]
    have hdec := decode_k a (readLE s3.mem (base + BitVec.ofNat 32 (STACK + 84 * r.length + 4)) 4)
      (fun h => (hw h).1)
    cases hk : kdec a.length (readLE s3.mem (base + BitVec.ofNat 32 (STACK + 84 * r.length + 4)) 4) with
    | none =>
      rw [hk] at hdec; simp only [Option.map_none] at hdec; rw [hdec]
      exact Goes.prepend e3' (dn hk)
    | some p =>
      obtain ⟨sg, mg⟩ := p
      rw [hk] at hdec; simp only [Option.map_some] at hdec; rw [hdec]; dsimp only
      obtain ⟨hs1, hm1⟩ := kdec_bounds hk (fun h => by rw [← (hw h).1] at *; exact (hw h).2)
      obtain ⟨n4, s4, e4, p4, m4, a11, a12, k4⟩ := ds sg mg hk
      obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (UNARY + 5) (by decide)
        (by rw [m4, mm3]; exact code) p4 rfl rfl
      obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (UNARY + 6) (by decide)
        (by rw [m5, m4, mm3]; exact code) p5 rfl rfl
      obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (UNARY + 7) (by decide)
        (by rw [m6, m5, m4, mm3]; exact code) p6 rfl rfl
      obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp (UNARY + 8) (by decide)
        (by rw [m7, m6, m5, m4, mm3]; exact code) p7 rfl rfl
      obtain ⟨s9, e9, p9, m9, r9⟩ := jStep (prog := kernel) hp (UNARY + 9) (by decide)
        (by rw [m8, m7, m6, m5, m4, mm3]; exact code) p8 rfl (k' := CORE) (by jump)
      have mm9 : s9.mem = s.mem := by rw [m9, m8, m7, m6, m5, m4, mm3]
      have k9 : ∀ x : Reg, x ≠ 1 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 12 → x ≠ 13 → x ≠ 14 → x ≠ 16 → x ≠ 20 →
          x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 → s9.reg x = s.reg x := by
        intro x h1 h6 h7 h10 h11 h12 h13 h14 h16 h20 h28 h29 h30 h31
        rw [r9, r8 x]; simp only [h20, false_and, ↓reduceIte]; rw [r7 x]; simp only [h16, false_and, ↓reduceIte]
        rw [r6 x]; simp only [h14, false_and, ↓reduceIte]; rw [r5 x]; simp only [h13, false_and, ↓reduceIte]
        rw [k4 x h6 h7 h11 h12 h28 h29 h30 h31, k3 x h1 h6 h7 h10]
      have e9' : run env (3 + 1 + 1 + n4 + 1 + 1 + 1 + 1 + 1) s = .running s9 := by
        exact run_trans (run_trans (run_trans (run_trans (run_trans (run_trans e3' e4) e5) e6) e7) e8) e9
      refine Goes.prepend e9' (arith_finish hp hin (r := r) (pc' := c.pc + 1) (sigs := c.sigs)
        (hc.fixed.keep fun x hx => by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> (apply k9 <;> decide))
        p9 ?_ ?_ ?_ (by rw [mm9]; exact hc.agree) (by rw [mm9]; exact st.pop) (by simp only [DMAX]; omega)
        (fun x hx => hc.elems x (by rw [hst]; simp [hx])) hc.sigs (by omega) hs1 hv hm1 (by decide) ?_ ?_ ?_ ?_)
      · rw [r9, r8 20]; regsimp; simp only [aluI]
        rw [r7 20]; regsimp; rw [r6 20]; regsimp; rw [r5 20]; regsimp
        rw [k4 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
          k3 20 (by decide) (by decide) (by decide) (by decide), hc.r20, hlen]
        rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
        congr 2
      · rw [k9 18 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h18, Nat.add_assoc]
      · rw [k9 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21]
      · rw [r9, r8 13]; regsimp; rw [r7 13]; regsimp; rw [r6 13]; regsimp; rw [r5 13]; regsimp; simp only [aluI]
        rw [a11, add0w]
      · rw [r9, r8 14]; regsimp; rw [r7 14]; regsimp; rw [r6 14]; regsimp; simp only [aluI]; rw [r5 12]; regsimp
        rw [a12, add0w]
      · rw [r9, r8 15]; regsimp; rw [r7 15]; regsimp; rw [r6 15]; regsimp; rw [r5 15]; regsimp
        rw [k4 15 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
          k3 15 (by decide) (by decide) (by decide) (by decide), h15]
      · rw [r9, r8 16]; regsimp; rw [r7 16]; regsimp; simp only [aluI, reg_zero]
        rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _

/-- What OP_ADD (`w = 0`) and OP_SUB (`w = 1`) do. -/
def binRes (w : Nat) (c : Cfg) : Res :=
  match c.st with
  | b :: a :: r =>
    match decode b, decode a with
    | some y, some x => .next ⟨c.pc + 1, encode (x + (if w = 1 then -y else y)) :: r, c.sigs⟩
    | _, _ => .done C_NUM
  | _ => .done C_UNDER

theorem flip_val (sb mb w : Nat) (hs : sb ≤ 1) (hw : w ≤ 1) :
    val (sb ^^^ w) mb = (if w = 1 then -val sb mb else val sb mb) ∧ sb ^^^ w ≤ 1 := by
  rcases (by omega : sb = 0 ∨ sb = 1) with rfl | rfl <;> rcases (by omega : w = 0 ∨ w = 1) with rfl | rfl <;>
    simp [val]

theorem w_xor (a b : Nat) (ha : a < 2 ^ 32) (hb : b < 2 ^ 32) :
    BitVec.ofNat 32 a ^^^ BitVec.ofNat 32 b = BitVec.ofNat 32 (a ^^^ b) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_xor, BitVec.toNat_ofNat, Nat.mod_eq_of_lt ha, Nat.mod_eq_of_lt hb]
  exact (Nat.mod_eq_of_lt (Nat.xor_lt_two_pow ha hb)).symm

/-- **BINARY**: the top decoded, its sign flipped for SUB, the one under it
decoded, the two added in CORE. -/
theorem binary_core (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine} (w : Nat)
    (hw : w ≤ 1) (hc : Core base m0 scr c s) (hpc : s.pc = base + BitVec.ofNat 32 (4 * BINARY))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1)) (h17 : s.reg 17 = BitVec.ofNat 32 w)
    (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (binRes w c) := by
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    simp only [binRes, hst]
    exact need_fail (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump) (by decide) (by simp [hst])
  | [_] =>
    simp only [binRes, hst]
    exact need_fail (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump) (by decide) (by simp [hst])
  | b :: a :: r =>
    simp only [binRes, hst]
    have hlen : c.st.length = r.length + 2 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    have hb : b.length ≤ 80 := hc.elems b (by rw [hst]; simp)
    have ha : a.length ≤ 80 := hc.elems a (by rw [hst]; simp)
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 2) hp hin hc hpc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (BINARY + 3) (by decide) (by rw [m1]; exact code) p1 rfl rfl
    obtain ⟨s3, e3, p3, m3, r3⟩ := callStep (prog := kernel) hp (BINARY + 4) (by decide) (by rw [m2, m1]; exact code) p2
      rfl (k' := DECODE) (by jump)
    have mm3 : s3.mem = s.mem := by rw [m3, m2, m1]
    have a10 : s3.reg 10 = base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1)) := by
      rw [r3 10]; simp only [show (10 : Reg) ≠ 1 by decide, ↓reduceIte]; rw [r2 10]; regsimp
      rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have k3 : ∀ x : Reg, x ≠ 1 → x ≠ 6 → x ≠ 7 → x ≠ 10 → s3.reg x = s.reg x := fun x h1 h6 h7 h10 => by
      rw [r3 x]; simp only [h1, ↓reduceIte]; rw [r2 x]; simp only [h10, false_and, ↓reduceIte]; exact r1 x h6 h7
    have slotB : SlotAt s3.mem base (STACK + 84 * (r.length + 1)) b := by rw [mm3]; exact st.top
    have hwB := word_of_slot hfit slotB (by simp only [STACK]; omega)
    obtain ⟨dnB, dsB⟩ := dec_block (m0 := m0) (scr := scr) (R := BINARY + 5) hp (by rw [mm3]; exact code) p3
      (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) a10 slotB hb
      (by rw [r3 1]; simp) (by decide)
    have e3' : run env (3 + 1 + 1) s = .running s3 := run_trans (run_trans e1 e2) e3
    have hdecB := decode_k b (readLE s3.mem (base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1) + 4)) 4)
      (fun h => (hwB h).1)
    cases hkB : kdec b.length (readLE s3.mem (base + BitVec.ofNat 32 (STACK + 84 * (r.length + 1) + 4)) 4) with
    | none =>
      rw [hkB] at hdecB; simp only [Option.map_none] at hdecB; rw [hdecB]
      exact Goes.prepend e3' (dnB hkB)
    | some pB =>
      obtain ⟨sb, mb⟩ := pB
      rw [hkB] at hdecB; simp only [Option.map_some] at hdecB; rw [hdecB]
      obtain ⟨hsb, hmb⟩ := kdec_bounds hkB (fun h => by rw [← (hwB h).1] at *; exact (hwB h).2)
      obtain ⟨n4, s4, e4, p4, m4, a11, a12, k4⟩ := dsB sb mb hkB
      have mm4 : s4.mem = s.mem := by rw [m4, mm3]
      -- xor a5, a1, a7; addi a6, a2, 0; addi a0, s4, -168; jal ra, DECODE
      obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (BINARY + 5) (by decide)
        (by rw [mm4]; exact code) p4 rfl rfl
      obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (BINARY + 6) (by decide)
        (by rw [m5, mm4]; exact code) p5 rfl rfl
      obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (BINARY + 7) (by decide)
        (by rw [m6, m5, mm4]; exact code) p6 rfl rfl
      obtain ⟨s8, e8, p8, m8, r8⟩ := callStep (prog := kernel) hp (BINARY + 8) (by decide)
        (by rw [m7, m6, m5, mm4]; exact code) p7 rfl (k' := DECODE) (by jump)
      have mm8 : s8.mem = s.mem := by rw [m8, m7, m6, m5, mm4]
      have k8 : ∀ x : Reg, x ≠ 1 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 12 → x ≠ 15 → x ≠ 16 → x ≠ 28 → x ≠ 29 →
          x ≠ 30 → x ≠ 31 → s8.reg x = s.reg x := by
        intro x h1 h6 h7 h10 h11 h12 h15 h16 h28 h29 h30 h31
        rw [r8 x]; simp only [h1, ↓reduceIte]; rw [r7 x]; simp only [h10, false_and, ↓reduceIte]
        rw [r6 x]; simp only [h16, false_and, ↓reduceIte]; rw [r5 x]; simp only [h15, false_and, ↓reduceIte]
        rw [k4 x h6 h7 h11 h12 h28 h29 h30 h31, k3 x h1 h6 h7 h10]
      have a10' : s8.reg 10 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
        rw [r8 10]; simp only [show (10 : Reg) ≠ 1 by decide, ↓reduceIte]; rw [r7 10]; regsimp; simp only [aluI]
        rw [r6 20]; regsimp; rw [r5 20]; regsimp
        rw [k4 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
          k3 20 (by decide) (by decide) (by decide) (by decide), hc.r20, hlen]
        rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
        congr 2
      have slotA : SlotAt s8.mem base (STACK + 84 * r.length) a := by rw [mm8]; exact st.second
      have hwA := word_of_slot hfit slotA (by simp only [STACK]; omega)
      obtain ⟨dnA, dsA⟩ := dec_block (m0 := m0) (scr := scr) (R := BINARY + 9) hp (by rw [mm8]; exact code) p8
        (by simp only [STACK]; omega) (by simp only [STACK, LIMIT]; omega) (by simp only [STACK]; omega) a10' slotA ha
        (by rw [r8 1]; simp) (by decide)
      have e8' : run env (3 + 1 + 1 + n4 + 1 + 1 + 1 + 1) s = .running s8 :=
        run_trans (run_trans (run_trans (run_trans (run_trans e3' e4) e5) e6) e7) e8
      have hdecA := decode_k a (readLE s8.mem (base + BitVec.ofNat 32 (STACK + 84 * r.length + 4)) 4)
        (fun h => (hwA h).1)
      cases hkA : kdec a.length (readLE s8.mem (base + BitVec.ofNat 32 (STACK + 84 * r.length + 4)) 4) with
      | none =>
        rw [hkA] at hdecA; simp only [Option.map_none] at hdecA; rw [hdecA]
        exact Goes.prepend e8' (dnA hkA)
      | some pA =>
        obtain ⟨sa, ma⟩ := pA
        rw [hkA] at hdecA; simp only [Option.map_some] at hdecA; rw [hdecA]; dsimp only
        obtain ⟨hsa, hma⟩ := kdec_bounds hkA (fun h => by rw [← (hwA h).1] at *; exact (hwA h).2)
        obtain ⟨n9, s9, e9, p9, m9, b11, b12, k9⟩ := dsA sa ma hkA
        obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp (BINARY + 9) (by decide)
          (by rw [m9, mm8]; exact code) p9 rfl rfl
        obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp (BINARY + 10) (by decide)
          (by rw [m10, m9, mm8]; exact code) p10 rfl rfl
        obtain ⟨s12, e12, p12, m12, r12⟩ := regStep (prog := kernel) hp (BINARY + 11) (by decide)
          (by rw [m11, m10, m9, mm8]; exact code) p11 rfl rfl
        have mm12 : s12.mem = s.mem := by rw [m12, m11, m10, m9, mm8]
        have k12 : ∀ x : Reg, x ≠ 1 → x ≠ 6 → x ≠ 7 → x ≠ 10 → x ≠ 11 → x ≠ 12 → x ≠ 13 → x ≠ 14 → x ≠ 15 →
            x ≠ 16 → x ≠ 20 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 31 → s12.reg x = s.reg x := by
          intro x h1 h6 h7 h10 h11 h12 h13 h14 h15 h16 h20 h28 h29 h30 h31
          rw [r12 x]; simp only [h20, false_and, ↓reduceIte]; rw [r11 x]; simp only [h14, false_and, ↓reduceIte]
          rw [r10 x]; simp only [h13, false_and, ↓reduceIte]
          rw [k9 x h6 h7 h11 h12 h28 h29 h30 h31, k8 x h1 h6 h7 h10 h11 h12 h15 h16 h28 h29 h30 h31]
        have e12' : run env (3 + 1 + 1 + n4 + 1 + 1 + 1 + 1 + n9 + 1 + 1 + 1) s = .running s12 :=
          run_trans (run_trans (run_trans (run_trans e8' e9) e10) e11) e12
        obtain ⟨hflip, hle⟩ := flip_val sb mb w hsb hw
        rw [← hflip]
        refine Goes.prepend e12' (arith_finish hp hin (r := r) (pc' := c.pc + 1) (sigs := c.sigs)
          (hc.fixed.keep fun x hx => by rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> (apply k12 <;> decide))
          (by rw [p12]; rfl) ?_ ?_ ?_ (by rw [mm12]; exact hc.agree) (by rw [mm12]; exact st.pop.pop)
          (by simp only [DMAX]; omega) (fun x hx => hc.elems x (by rw [hst]; simp [hx])) hc.sigs (by omega)
          hsa hle hma hmb ?_ ?_ ?_ ?_)
        · rw [r12 20]; regsimp; simp only [aluI]; rw [r11 20]; regsimp; rw [r10 20]; regsimp
          rw [k9 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
            k8 20 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
              (by decide) (by decide) (by decide) (by decide), hc.r20, hlen]
          rw [addi_neg hfit _ (v := 168) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
          congr 2
        · rw [k12 18 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
            (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h18, Nat.add_assoc]
        · rw [k12 21 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
            (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hc.r21]
        · rw [r12 13]; regsimp; rw [r11 13]; regsimp; rw [r10 13]; regsimp; simp only [aluI]; rw [b11, add0w]
        · rw [r12 14]; regsimp; rw [r11 14]; regsimp; simp only [aluI]; rw [r10 12]; regsimp; rw [b12, add0w]
        · rw [r12 15]; regsimp; rw [r11 15]; regsimp; rw [r10 15]; regsimp
          rw [k9 15 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)]
          rw [r8 15]; simp only [show (15 : Reg) ≠ 1 by decide, ↓reduceIte]; rw [r7 15]; regsimp; rw [r6 15]; regsimp
          rw [r5 15]; regsimp; simp only [aluR]; rw [a11]
          rw [k4 17 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
            k3 17 (by decide) (by decide) (by decide) (by decide), h17, w_xor _ _ (by omega) (by omega)]
        · rw [r12 16]; regsimp; rw [r11 16]; regsimp; rw [r10 16]; regsimp
          rw [k9 16 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)]
          rw [r8 16]; simp only [show (16 : Reg) ≠ 1 by decide, ↓reduceIte]; rw [r7 16]; regsimp; rw [r6 16]; regsimp
          simp only [aluI]; rw [r5 12]; regsimp; rw [a12, add0w]

/-- **OP_1ADD**. -/
theorem h_1add (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_1ADD s) (hop : (scr.getD c.pc 0).toNat = 0x8b) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = unRes 0 c := by
    simp only [stepOp]; rw [hop]; simp only [unRes]
    rcases c.st with _ | ⟨a, r⟩ <;> simp
    cases decode a <;> simp [val]
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_1ADD (by decide) (hc.code hp hin) hE.pc rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := jStep (prog := kernel) hp (H_1ADD + 1) (by decide)
    (by rw [m1]; exact hc.code hp hin) p1 rfl (k' := UNARY) (by jump)
  refine Goes.prepend (n := 1 + 1) (by rw [run_add_running e1, e2])
    (unary_core hp hin 0 (by decide) (hc.regs (by rw [m2, m1]) fun x hx => ?_) p2 ?_ ?_ hE.lt)
  · rw [r2, r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r2, r1 18]; regsimp; exact hE.r18
  · rw [r2, r1 15]; regsimp; simp only [aluI, reg_zero]; rfl

/-- **OP_1SUB**. -/
theorem h_1sub (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_1SUB s) (hop : (scr.getD c.pc 0).toNat = 0x8c) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = unRes 1 c := by
    simp only [stepOp]; rw [hop]; simp only [unRes]
    rcases c.st with _ | ⟨a, r⟩ <;> simp
    cases decode a <;> simp [val, Int.sub_eq_add_neg]
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_1SUB (by decide) (hc.code hp hin) hE.pc rfl rfl
  refine Goes.prepend e1 (unary_core hp hin 1 (by decide) (hc.regs m1 fun x hx => ?_) (by rw [p1]; rfl) ?_ ?_ hE.lt)
  · rw [r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r1 18]; regsimp; exact hE.r18
  · rw [r1 15]; regsimp; simp only [aluI, reg_zero]
    rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _

/-- **OP_ADD**. -/
theorem h_add (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_ADD s) (hop : (scr.getD c.pc 0).toNat = 0x93) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = binRes 0 c := by
    simp only [stepOp]; rw [hop]; simp only [binRes]
    rcases c.st with _ | ⟨b, _ | ⟨a, r⟩⟩ <;> simp
    cases decode b <;> cases decode a <;> rfl
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_ADD (by decide) (hc.code hp hin) hE.pc rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := jStep (prog := kernel) hp (H_ADD + 1) (by decide)
    (by rw [m1]; exact hc.code hp hin) p1 rfl (k' := BINARY) (by jump)
  refine Goes.prepend (n := 1 + 1) (by rw [run_add_running e1, e2])
    (binary_core hp hin 0 (by decide) (hc.regs (by rw [m2, m1]) fun x hx => ?_) p2 ?_ ?_ hE.lt)
  · rw [r2, r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r2, r1 18]; regsimp; exact hE.r18
  · rw [r2, r1 17]; regsimp; simp only [aluI, reg_zero]; rfl

/-- **OP_SUB**. -/
theorem h_sub (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_SUB s) (hop : (scr.getD c.pc 0).toNat = 0x94) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have e : stepOp env scr c = binRes 1 c := by
    simp only [stepOp]; rw [hop]; simp only [binRes]
    rcases c.st with _ | ⟨b, _ | ⟨a, r⟩⟩ <;> simp
    cases decode b <;> cases decode a <;> simp [Int.sub_eq_add_neg]
  rw [e]
  have hc := hE.core
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp H_SUB (by decide) (hc.code hp hin) hE.pc rfl rfl
  refine Goes.prepend e1 (binary_core hp hin 1 (by decide) (hc.regs m1 fun x hx => ?_) (by rw [p1]; rfl) ?_ ?_ hE.lt)
  · rw [r1 x]; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r1 18]; regsimp; exact hE.r18
  · rw [r1 17]; regsimp; simp only [aluI, reg_zero]
    rw [show (1 : BitVec 12) = BitVec.ofNat 12 1 from rfl, se_small _ (by decide)]; exact BitVec.zero_add _

end Exp228
