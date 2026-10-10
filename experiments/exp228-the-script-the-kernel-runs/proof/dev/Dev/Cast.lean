import Dev.Push

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- Byte `i` of an element with its last byte's sign bit cleared. -/
def masked (e : Elem) (i : Nat) : Byte :=
  if i + 1 = e.length then e.getD i 0 &&& 0x7f else e.getD i 0

theorem cast_one (b : Byte) : (b != 0 && b != 0x80) = decide (b &&& 0x7f ≠ 0) := by
  revert b; decide

/-- **CastToBool, as the kernel computes it**: false exactly when every byte is
zero once the last one's sign bit is cleared. -/
theorem cast_false_iff : ∀ e : Elem, cast e = false ↔ ∀ i < e.length, masked e i = 0
  | [] => by simp [cast]
  | [b] => by
    have := cast_one b
    simp only [cast, masked, List.length_singleton]
    constructor
    · intro h i hi
      have : i = 0 := by omega
      subst this; simp only [Nat.zero_add, ↓reduceIte, List.getD_cons_zero]
      rw [h] at this; simpa using this
    · intro h
      have h0 := h 0 (by decide)
      simp only [Nat.zero_add, ↓reduceIte, List.getD_cons_zero] at h0
      rw [this]; simpa using h0
  | b :: c :: rest => by
    have ih := cast_false_iff (c :: rest)
    simp only [cast, Bool.or_eq_false_iff, ih]
    constructor
    · rintro ⟨hb, hr⟩ i hi
      rcases i with _ | i
      · simp only [masked, List.length_cons]
        rw [ite_eq_right_of_eq_false _ _ (eq_false (by omega))]
        simpa using hb
      · have := hr i (by simp only [List.length_cons] at hi ⊢; omega)
        simp only [masked, List.length_cons] at this ⊢
        simp only [Nat.add_right_cancel_iff, List.getD_cons_succ] at this ⊢
        exact this
    · intro h
      constructor
      · have := h 0 (by simp)
        simp only [masked, List.length_cons] at this
        rw [ite_eq_right_of_eq_false _ _ (eq_false (by omega))] at this
        simpa using this
      · intro i hi
        have := h (i + 1) (by simp only [List.length_cons] at hi ⊢; omega)
        simp only [masked, List.length_cons] at this ⊢
        simp only [Nat.add_right_cancel_iff, List.getD_cons_succ] at this ⊢
        exact this

/-- Twenty words from `a + 4` all zero, as bytes. -/
theorem words_zero_iff (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {a : Nat} (ha : a + 84 < 0x10000) :
    (∀ j < 20, readLE m (base + BitVec.ofNat 32 (a + 4 + 4 * j)) 4 = 0)
      ↔ ∀ d, 4 ≤ d → d < 84 → m (base + BitVec.ofNat 32 (a + d)) = 0 := by
  constructor
  · intro h d h1 h2
    have := readLE_four_byte m (base + BitVec.ofNat 32 (a + 4 + 4 * ((d - 4) / 4))) ((d - 4) % 4) (by omega)
    rw [h _ (by omega), off_add hfit _ _ (by omega),
      show a + 4 + 4 * ((d - 4) / 4) + (d - 4) % 4 = a + d by omega] at this
    rw [← this]; simp
  · intro h j hj
    rw [readLE_four_eq (m' := fun _ => 0) (a' := base + BitVec.ofNat 32 (a + 4 + 4 * j)) (fun d hd => by
      rw [off_add hfit _ _ (by omega), show a + 4 + 4 * j + d = a + (4 + 4 * j + d) by omega, h _ (by omega) (by omega)])]
    rw [readLE_four]; rfl

/-- What the kernel's cast looks at: the slot's bytes from 4 on, its last
element byte's sign bit cleared. All zero exactly when the element is false. -/
theorem cast_bytes (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {a : Nat} {e : Elem}
    (h : SlotAt m base a e) (ha : a + 84 < 0x10000) (h1 : 1 ≤ e.length) (h2 : e.length ≤ 80) :
    (∀ d, 4 ≤ d → d < 84 → writeByte m (base + BitVec.ofNat 32 (a + e.length + 3))
        (e.getD (e.length - 1) 0 &&& 0x7f) (base + BitVec.ofNat 32 (a + d)) = 0) ↔ cast e = false := by
  rw [cast_false_iff]
  have ev : ∀ d, 4 ≤ d → d < 84 → writeByte m (base + BitVec.ofNat 32 (a + e.length + 3))
      (e.getD (e.length - 1) 0 &&& 0x7f) (base + BitVec.ofNat 32 (a + d))
      = if d - 4 < e.length then masked e (d - 4) else 0 := by
    intro d hd1 hd2
    rw [ev_writeByte hfit _ _ _ _ (by omega) (by omega)]
    by_cases hl : a + d = a + e.length + 3
    · simp only [hl, ↓reduceIte, show d - 4 < e.length by omega, masked, show d - 4 + 1 = e.length by omega,
        show e.length - 1 = d - 4 by omega]
    · simp only [hl, ↓reduceIte]
      rw [h d hd2]; unfold slotBytes
      simp only [show ¬ d < 4 by omega, ↓reduceIte]
      by_cases hin : d - 4 < e.length
      · simp only [hin, ↓reduceIte, masked, show ¬ d - 4 + 1 = e.length by omega]
      · simp only [hin, ↓reduceIte]
        rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]; rfl
  constructor
  · intro H i hi
    have := H (i + 4) (by omega) (by omega)
    rw [ev _ (by omega) (by omega)] at this
    simpa [show i + 4 - 4 = i by omega, hi] using this
  · intro H d hd1 hd2
    rw [ev d hd1 hd2]
    split
    · exact H _ (by assumption)
    · rfl

/-- The kernel stays loaded under writes above it. -/
theorem code_keep (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} (hc : CodeAt m base kernel)
    {lo hi : Nat} (ha : Agree m m' base lo hi) (hlo : 4 * 881 ≤ lo) : CodeAt m' base kernel := by
  refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => ?_) hc
  rw [kernel_length] at h2
  have hx : x = base + BitVec.ofNat 32 (x.toNat - base.toNat) := by
    apply BitVec.eq_of_toNat_eq; rw [toNat_off hfit _ (by omega)]; omega
  rw [hx, ha _ (by omega) (by left; omega)]

theorem and7f (b : Byte) :
    BitVec.ofNat 8 ((BitVec.ofNat 32 b.toNat &&& (0x7f : BitVec 12).signExtend 32).toNat) = b &&& 0x7f := by
  rw [show (0x7f : BitVec 12) = BitVec.ofNat 12 0x7f from rfl, se_small _ (by decide)]
  apply BitVec.eq_of_toNat_eq
  have := b.isLt
  simp only [BitVec.toNat_ofNat, BitVec.toNat_and, Nat.mod_eq_of_lt (show b.toNat < 2 ^ 32 by omega)]
  rw [Nat.mod_eq_of_lt (show b.toNat &&& 127 % 2 ^ 32 < 2 ^ 8 from
    Nat.lt_of_le_of_lt Nat.and_le_left this)]
  rw [show (0x7f : BitVec 8).toNat = 127 from rfl]

/-- **The kernel's CastToBool** of the slot at `r`: on to `k0 + 48` when the
element is true, to `tgt` when false; only the slot and five scratch registers
touched. -/
theorem cast_block (hp : Placed env base) {k0 tgt : Nat} {r : Reg} {off1 off2 : BitVec 12}
    (i0 : kernel.getD k0 .ecall = .ld .lw 6 r 0)
    (i1 : kernel.getD (k0 + 1) .ecall = .br .beq 6 0 off1)
    (o1 : BitVec.ofNat 32 (4 * (k0 + 1)) + (off1 ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * tgt))
    (i2 : kernel.getD (k0 + 2) .ecall = .op .add 7 r 6)
    (i3 : kernel.getD (k0 + 3) .ecall = .ld .lbu 28 7 3)
    (i4 : kernel.getD (k0 + 4) .ecall = .opi .andi 28 28 0x7f)
    (i5 : kernel.getD (k0 + 5) .ecall = .st .sb 7 28 3)
    (i6 : kernel.getD (k0 + 6) .ecall = .opi .addi 29 0 0)
    (i7 : ∀ j < 20, kernel.getD (k0 + 7 + 2 * j) .ecall = .ld .lw 30 r (BitVec.ofNat 12 (4 + 4 * j))
      ∧ kernel.getD (k0 + 7 + 2 * j + 1) .ecall = .op .or 29 29 30)
    (i47 : kernel.getD (k0 + 47) .ecall = .br .beq 29 0 off2)
    (o2 : BitVec.ofNat 32 (4 * (k0 + 47)) + (off2 ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * tgt))
    (hk : k0 + 48 < 881) (hr : r ≠ 6 ∧ r ≠ 7 ∧ r ≠ 28 ∧ r ≠ 29 ∧ r ≠ 30 ∧ r ≠ 0)
    {a : Nat} (ha1 : 4 * 881 ≤ a) (ha2 : a + 84 < 0x10000) (ha4 : a % 4 = 0) {e : Elem} (hle : e.length ≤ 80)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base kernel)
    (hreg : s.reg r = base + BitVec.ofNat 32 a) (hslot : SlotAt s.mem base a e) :
    ∃ n s', run env n s = .running s'
      ∧ s'.pc = base + BitVec.ofNat 32 (4 * (if cast e then k0 + 48 else tgt))
      ∧ Agree s.mem s'.mem base a (a + 84)
      ∧ ∀ x, x ≠ 6 → x ≠ 7 → x ≠ 28 → x ≠ 29 → x ≠ 30 → s'.reg x = s.reg x := by
  have hfit := hp.fit
  obtain ⟨hr6, hr7, hr28, hr29, hr30, hr0⟩ := hr
  -- lw t1, 0(r)
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp k0 (by rw [kernel_length]; omega) hcode hpc i0 a
    (by rw [hreg]; simp) (by omega) ha4
  have a6 : s1.reg 6 = BitVec.ofNat 32 e.length := by
    rw [r1 6]; regsimp; rw [slot_len hfit hslot (by omega) (by omega)]
  have k1 : ∀ x, x ≠ 6 → s1.reg x = s.reg x := fun x h => by rw [r1 x]; simp only [h, false_and, ↓reduceIte]
  -- beq t1, zero, false
  obtain ⟨s2, e2, p2, m2, r2⟩ := brStep (prog := kernel) hp (k0 + 1) (by rw [kernel_length]; omega)
    (by rw [m1]; exact hcode) p1 i1 o1
  have tk : taken .beq (s1.reg 6) (s1.reg 0) = decide (e.length = 0) := by
    rw [a6, reg_zero]; simp only [taken]
    by_cases h : e.length = 0
    · rw [h]; rfl
    · rw [decide_eq_false h]; apply beq_false_of_ne
      intro h'; have := congrArg BitVec.toNat h'; simp at this; omega
  rw [tk] at p2
  by_cases hz : e.length = 0
  · have he : e = [] := List.eq_nil_of_length_eq_zero hz
    subst he
    simp only [hz, decide_true, ↓reduceIte] at p2
    refine ⟨1 + 1, s2, by rw [run_add_running e1, e2], by rw [p2]; rfl, by rw [m2, m1]; exact Agree.refl _ _ _ _,
      fun x h6 _ _ _ _ => by rw [r2, k1 x h6]⟩
  simp only [hz, decide_false, Bool.false_eq_true, ↓reduceIte] at p2
  -- add t2, r, t1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (k0 + 2) (by rw [kernel_length]; omega)
    (by rw [m2, m1]; exact hcode) p2 i2 rfl
  have a7 : s3.reg 7 = base + BitVec.ofNat 32 (a + e.length) := by
    rw [r3 7]; regsimp; simp only [aluR]; rw [r2, r2, k1 r hr6, hreg, a6, off_add hfit _ _ (by omega)]
  -- lbu t3, 3(t2)
  obtain ⟨s4, e4, p4, m4, r4⟩ := lbuStep (prog := kernel) hp (k0 + 3) (by rw [kernel_length]; omega)
    (by rw [m3, m2, m1]; exact hcode) p3 i3 (a + e.length + 3)
    (by rw [a7]; exact addi_pos hfit _ (by decide) (by decide) (by omega)) (by omega)
  have hb : s3.mem (base + BitVec.ofNat 32 (a + e.length + 3)) = e.getD (e.length - 1) 0 := by
    rw [m3, m2, m1, show a + e.length + 3 = a + (e.length + 3) by omega, hslot _ (by omega)]
    unfold slotBytes; simp only [show ¬ e.length + 3 < 4 by omega, ↓reduceIte, show e.length + 3 - 4 = e.length - 1 by omega]
  -- andi t3, t3, 0x7f
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (k0 + 4) (by rw [kernel_length]; omega)
    (by rw [m4, m3, m2, m1]; exact hcode) p4 i4 rfl
  have a28 : s5.reg 28 = BitVec.ofNat 32 (e.getD (e.length - 1) 0).toNat &&& (0x7f : BitVec 12).signExtend 32 := by
    rw [r5 28]; regsimp; simp only [aluI]; rw [r4 28]; regsimp; rw [hb]
  -- sb t3, 3(t2)
  obtain ⟨s6, e6, p6, m6, r6⟩ := sbStep (prog := kernel) hp (k0 + 5) (by rw [kernel_length]; omega)
    (by rw [m5, m4, m3, m2, m1]; exact hcode) p5 i5 (a + e.length + 3)
    (by rw [r5 7]; regsimp; rw [r4 7]; regsimp; rw [a7]; exact addi_pos hfit _ (by decide) (by decide) (by omega))
    (by omega)
  have mm6 : s6.mem = writeByte s.mem (base + BitVec.ofNat 32 (a + e.length + 3)) (e.getD (e.length - 1) 0 &&& 0x7f) := by
    rw [m6, a28, and7f, m5, m4, m3, m2, m1]
  have ag6 : Agree s.mem s6.mem base a (a + 84) := by
    rw [mm6]; exact (agree_writeByte hfit _ _ (by omega)).widen (by omega) (by omega)
  have c6 : CodeAt s6.mem base kernel := code_keep hfit hcode ag6 ha1
  -- li t4, 0
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (k0 + 6) (by rw [kernel_length]; omega)
    c6 p6 i6 rfl
  have z7 : s7.reg 29 = 0 := by rw [r7 29]; regsimp; simp only [aluI, reg_zero]; rfl
  have k7 : ∀ x, x ≠ 6 → x ≠ 7 → x ≠ 28 → x ≠ 29 → s7.reg x = s.reg x := fun x h6 h7 h28 h29 => by
    rw [r7 x]; simp only [h29, false_and, ↓reduceIte]; rw [r6, r5 x]; simp only [h28, false_and, ↓reduceIte]
    rw [r4 x]; simp only [h28, false_and, ↓reduceIte]; rw [r3 x]; simp only [h7, false_and, ↓reduceIte]
    rw [r2, k1 x h6]
  -- or of the twenty words after the length
  obtain ⟨s8, e8, p8, m8, z8, k8⟩ := or_n (prog := kernel) (n := 20) (o := 4) (a := a) (acc := 29) (t := 30)
    hp i7 (by rw [kernel_length]; omega) (by decide) (by decide) (by decide) hr30 hr29 (by decide) (by omega)
    (by omega) (by rw [p7]) (by rw [m7]; exact c6) (by rw [k7 r hr6 hr7 hr28 hr29, hreg]) (by decide) 20 (Nat.le_refl _)
  have zz : s8.reg 29 = 0 ↔ cast e = false := by
    rw [z8, m7, mm6]
    simp only [z7, true_and]
    rw [words_zero_iff hfit (by omega)]
    exact cast_bytes hfit hslot (by omega) (by omega) hle
  -- beq t4, zero, false
  obtain ⟨s9, e9, p9, m9, r9⟩ := brStep (prog := kernel) hp (k0 + 47) (by rw [kernel_length]; omega)
    (by rw [m8, m7]; exact c6) (by rw [p8]) i47 o2
  have tk9 : taken .beq (s8.reg 29) (s8.reg 0) = !cast e := by
    rw [reg_zero]; simp only [taken]
    by_cases hc : cast e
    · have : s8.reg 29 ≠ 0 := fun h => by rw [zz.mp h] at hc; exact Bool.false_ne_true hc
      rw [beq_false_of_ne this, hc]; rfl
    · have : s8.reg 29 = 0 := zz.mpr (by simpa using hc)
      rw [this, show cast e = false by simpa using hc]; rfl
  rw [tk9] at p9
  refine ⟨1 + 1 + 1 + 1 + 1 + 1 + 1 + 2 * 20 + 1, s9, ?_, ?_, by rw [m9, m8, m7]; exact ag6, ?_⟩
  · rw [run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running ((run_add_running
      ((run_add_running ((run_add_running e1).trans e2)).trans e3)).trans e4)).trans e5)).trans e6)).trans e7)).trans
      e8), e9]
  · rw [p9]; by_cases hc : cast e <;> simp [hc]
  · intro x h6 h7 h28 h29 h30
    rw [r9, k8 x h29 h30, k7 x h6 h7 h28 h29]

theorem f_verify (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_VERIFY)) : Goes env base m0 scr s (.done C_VERIFY) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-- **OP_VERIFY**: pop, and fail unless what was popped is true. -/
theorem h_verify (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {op : Nat} {s : Machine}
    (hE : Entry base m0 scr c op H_VERIFY s) (hop : (scr.getD c.pc 0).toNat = 0x69) :
    Goes env base m0 scr s (stepOp env scr c) := by
  have hc := hE.core
  have code := hc.code hp hin
  have hfit := hp.fit
  match hst : c.st with
  | [] =>
    rw [show stepOp env scr c = .done C_UNDER by simp only [stepOp]; rw [hop]; simp [hst]]
    exact need_fail (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump) (by decide) (by rw [hst]; decide)
  | e :: r =>
    rw [show stepOp env scr c = if cast e then .next ⟨c.pc + 1, r, c.sigs⟩ else .done C_VERIFY by
      simp only [stepOp]; rw [hop]; simp [hst]]
    have hlen : c.st.length = r.length + 1 := by rw [hst]; rfl
    have hd := hc.depth
    simp only [DMAX] at hd
    have st := hc.stack
    rw [hst] at st
    obtain ⟨s1, e1, p1, m1, r1⟩ := need_pass (k := 1) hp hin hc hE.pc (by decide) rfl rfl rfl (by jump)
      (by decide) (by rw [hlen]; omega)
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (H_VERIFY + 3) (by decide)
      (by rw [m1]; exact code) p1 rfl rfl
    have a20 : s2.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * r.length) := by
      rw [r2 20]; regsimp; rw [r1 20 (by decide) (by decide), hc.r20, hlen]; simp only [aluI]
      rw [addi_neg hfit _ (v := 84) (by decide) (by decide) (by decide) (by omega) (by simp only [STACK]; omega)]
      congr 2
    have he : e.length ≤ 80 := hc.elems e (by rw [hst]; simp)
    obtain ⟨n3, s3, e3, p3, ag3, k3⟩ := cast_block (k0 := H_VERIFY + 4) (tgt := F_VERIFY) (r := 20) hp
      rfl rfl (by jump) rfl rfl rfl rfl rfl (by decide) rfl (by jump) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by simp only [STACK]; omega) he
      p2 (by rw [m2, m1]; exact code) a20 (by rw [m2, m1]; exact st.top)
    have ag : Agree s.mem s3.mem base (STACK + 84 * r.length) LIMIT := by
      rw [m2, m1] at ag3; exact ag3.widen (Nat.le_refl _) (by simp only [STACK, LIMIT]; omega)
    have c3 : CodeAt s3.mem base kernel :=
      code_of_agree hfit hin.code (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
    have e3' : run env (3 + 1 + n3) s = .running s3 := by
      rw [run_add_running ((run_add_running e1).trans e2), e3]
    by_cases hcast : cast e
    · simp only [hcast, ↓reduceIte] at p3 ⊢
      have k : ∀ x : Reg, x ≠ 6 → x ≠ 7 → x ≠ 28 → x ≠ 29 → x ≠ 30 → x ≠ 20 → s3.reg x = s.reg x :=
        fun x h6 h7 h28 h29 h30 h20 => by
          rw [k3 x h6 h7 h28 h29 h30, r2 x]; simp only [h20, false_and, ↓reduceIte]; exact r1 x h6 h7
      have hcore : Core base m0 scr ⟨c.pc + 1, r, c.sigs⟩ s3 := by
        refine hc.next (fun x hx => k x ?_ ?_ ?_ ?_ ?_ ?_) (by rw [k3 20 (by decide) (by decide) (by decide)
          (by decide) (by decide), a20]) (by rw [k 21 (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide), hc.r21]) (hc.agree.trans (ag.widen (by simp only [STACK]; omega) (Nat.le_refl _)))
          (st.pop.agree ag (by simp only [DMAX]; omega) (by left; omega)) (by simp only [DMAX]; omega)
          (fun x hx => hc.elems x (by rw [hst]; simp [hx])) hc.sigs (by have := hE.lt; simp only; omega)
        all_goals (rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide)
      exact Goes.prepend e3' (back hp hin hcore (by rw [k 18 (by decide) (by decide) (by decide) (by decide)
        (by decide) (by decide), hE.r18, Nat.add_assoc]) p3 (by decide) rfl (by jump))
    · simp only [hcast, Bool.false_eq_true, ↓reduceIte] at p3 ⊢
      exact Goes.prepend e3' (f_verify hp c3 p3)

end Exp228
