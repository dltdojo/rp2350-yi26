import Dev.Steps

set_option maxRecDepth 100000

/-! # Slots: what the kernel writes, read back -/

namespace Exp228
open Rv32

variable {base : Word}

/-! ## A byte of the region after each kind of write -/

theorem ev_overlay (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c n : Nat) (f : Nat → Byte)
    (x : Nat) (hc : c + n < 0x10000) (hx : x < 0x10000) :
    overlay m (base + BitVec.ofNat 32 c) n f (base + BitVec.ofNat 32 x)
      = if c ≤ x ∧ x < c + n then f (x - c) else m (base + BitVec.ofNat 32 x) := by
  split
  · rename_i h; exact overlay_off_in hfit m f hx h.1 h.2
  · rename_i h; exact overlay_off_out hfit m f hc hx (by omega)

theorem dist_of (hfit : base.toNat + 0x10000 ≤ 2^32) (c x : Nat) (hc : c < 0x10000) (hx : x < 0x10000) :
    (base + BitVec.ofNat 32 x - (base + BitVec.ofNat 32 c)).toNat
      = if c ≤ x then x - c else 2 ^ 32 - c + x := by
  rw [toNat_sub_off hfit _ c hc, toNat_off hfit x hx]
  have := base.isLt
  rw [wrapdist _ _ (by omega) (by omega)]
  by_cases h : c ≤ x
  · simp only [show base.toNat + c ≤ base.toNat + x by omega, h, ↓reduceIte]; omega
  · simp only [show ¬ base.toNat + c ≤ base.toNat + x by omega, h, ↓reduceIte]; omega

theorem ev_writeLE (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c v x : Nat)
    (hc : c + 4 < 0x10000) (hx : x < 0x10000) :
    writeLE m (base + BitVec.ofNat 32 c) v 4 (base + BitVec.ofNat 32 x)
      = if c ≤ x ∧ x < c + 4 then BitVec.ofNat 8 (v / 256 ^ (x - c)) else m (base + BitVec.ofNat 32 x) := by
  rw [writeLE_apply _ _ _ _ (by decide), dist_of hfit c x (by omega) hx]
  by_cases h : c ≤ x ∧ x < c + 4
  · simp only [h.1, ↓reduceIte, show x - c < 4 by omega, h, and_self]
  · rw [ite_eq_right_of_eq_false _ _ (eq_false h)]
    by_cases h1 : c ≤ x
    · simp only [h1, ↓reduceIte, show ¬ x - c < 4 by omega]
    · simp only [h1, ↓reduceIte, show ¬ 2 ^ 32 - c + x < 4 by omega]

theorem ev_writeByte (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c : Nat) (v : Byte) (x : Nat)
    (hc : c < 0x10000) (hx : x < 0x10000) :
    writeByte m (base + BitVec.ofNat 32 c) v (base + BitVec.ofNat 32 x)
      = if x = c then v else m (base + BitVec.ofNat 32 x) := by
  unfold writeByte
  by_cases h : x = c
  · subst h; simp
  · have : base + BitVec.ofNat 32 x ≠ base + BitVec.ofNat 32 c := by
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off hfit x hx, toNat_off hfit c hc] at this; omega
    simp [this, h]

/-! ## Slots -/

theorem slotBytes_nil (d : Nat) : slotBytes [] d = 0 := by
  unfold slotBytes; split <;> simp

/-- A zeroed slot holds the empty element. -/
theorem slot_zero (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c : Nat) (hc : c + 84 < 0x10000) :
    SlotAt (overlay m (base + BitVec.ofNat 32 c) 84 (fun _ => 0)) base c [] := by
  intro d hd
  rw [ev_overlay hfit _ _ _ _ _ (by omega) (by omega), slotBytes_nil]
  simp only [show c ≤ c + d ∧ c + d < c + 84 by omega, and_self, ↓reduceIte]

/-- A slot copied byte for byte holds what the other held. -/
theorem slot_copy {m m' : Word → Byte} {src dst : Nat} {e : Elem} (h : SlotAt m base src e)
    (hc : ∀ d < 84, m' (base + BitVec.ofNat 32 (dst + d)) = m (base + BitVec.ofNat 32 (src + d))) :
    SlotAt m' base dst e := fun d hd => by rw [hc d hd, h d hd]

/-- A slot zeroed, then a length of one stored, then the byte: `[b]`. -/
theorem slot_one (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c : Nat) (b : Byte)
    (hc : c + 84 < 0x10000) :
    SlotAt (writeByte (writeLE (overlay m (base + BitVec.ofNat 32 c) 84 (fun _ => 0))
      (base + BitVec.ofNat 32 c) 1 4) (base + BitVec.ofNat 32 (c + 4)) b) base c [b] := by
  intro d hd
  rw [ev_writeByte hfit _ _ _ _ (by omega) (by omega), ev_writeLE hfit _ _ _ _ (by omega) (by omega),
    ev_overlay hfit _ _ _ _ _ (by omega) (by omega)]
  unfold slotBytes
  rcases (by omega : d < 4 ∨ d = 4 ∨ 4 < d) with h | h | h
  · have h1 : ¬ c + d = c + 4 := by omega
    have h2 : c ≤ c + d ∧ c + d < c + 4 := by omega
    rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_left_of_eq_true _ _ (eq_true h2),
      ite_eq_left_of_eq_true _ _ (eq_true h)]
    simp [show c + d - c = d by omega]
  · subst h; simp
  · have h1 : ¬ c + d = c + 4 := by omega
    have h2 : ¬ (c ≤ c + d ∧ c + d < c + 4) := by omega
    have h3 : c ≤ c + d ∧ c + d < c + 84 := by omega
    rw [ite_eq_right_of_eq_false _ _ (eq_false h1), ite_eq_right_of_eq_false _ _ (eq_false h2),
      ite_eq_left_of_eq_true _ _ (eq_true h3), ite_eq_right_of_eq_false _ _ (eq_false (show ¬ d < 4 by omega))]
    obtain ⟨k, rfl⟩ : ∃ k, d = 5 + k := ⟨d - 5, by omega⟩
    simp [show 5 + k - 4 = k + 1 by omega]

/-- Four bytes from `base + c`, as a number, from the bytes one by one. -/
theorem readLE_off (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (c : Nat) (hc : c + 4 < 0x10000) :
    readLE m (base + BitVec.ofNat 32 c) 4 = (m (base + BitVec.ofNat 32 c)).toNat
      + 256 * (m (base + BitVec.ofNat 32 (c + 1))).toNat + 65536 * (m (base + BitVec.ofNat 32 (c + 2))).toNat
      + 16777216 * (m (base + BitVec.ofNat 32 (c + 3))).toNat := by
  rw [readLE_four, show (1 : Word) = BitVec.ofNat 32 1 from rfl, show (2 : Word) = BitVec.ofNat 32 2 from rfl,
    show (3 : Word) = BitVec.ofNat 32 3 from rfl, off_add hfit _ _ (by omega), off_add hfit _ _ (by omega),
    off_add hfit _ _ (by omega)]

/-- The length word of a slot. -/
theorem slot_len (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {c : Nat} {e : Elem}
    (h : SlotAt m base c e) (hc : c + 84 < 0x10000) (he : e.length < 2 ^ 32) :
    readLE m (base + BitVec.ofNat 32 c) 4 = e.length := by
  rw [readLE_off hfit _ _ (by omega)]
  have h0 := h 0 (by decide); have h1 := h 1 (by decide); have h2 := h 2 (by decide); have h3 := h 3 (by decide)
  rw [Nat.add_zero] at h0
  rw [h0, h1, h2, h3]
  simp only [slotBytes, show (0 : Nat) < 4 by decide, show (1 : Nat) < 4 by decide, show (2 : Nat) < 4 by decide,
    show (3 : Nat) < 4 by decide, ↓reduceIte, BitVec.toNat_ofNat]
  omega

end Exp228

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-! ## Writes inside the stack's window -/

theorem agw_writeLE (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} (ha : Agree m0 m base STACK LIMIT)
    (he : m' = writeLE m (base + BitVec.ofNat 32 c) v 4) (h1 : STACK ≤ c) (h2 : c + 4 ≤ LIMIT) :
    Agree m0 m' base STACK LIMIT :=
  he ▸ ha.trans ((agree_writeLE hfit m v (by simp only [LIMIT] at h2; omega)).widen h1 h2)

theorem agw_writeByte (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} (ha : Agree m0 m base STACK LIMIT)
    (he : m' = writeByte m (base + BitVec.ofNat 32 c) v) (h1 : STACK ≤ c) (h2 : c + 1 ≤ LIMIT) :
    Agree m0 m' base STACK LIMIT :=
  he ▸ ha.trans ((agree_writeByte hfit m v (by simp only [LIMIT] at h2; omega)).widen h1 h2)

theorem agw_overlay (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} (ha : Agree m0 m base STACK LIMIT)
    {f : Nat → Byte} (he : m' = overlay m (base + BitVec.ofNat 32 c) n f) (h1 : STACK ≤ c) (h2 : c + n ≤ LIMIT) :
    Agree m0 m' base STACK LIMIT :=
  he ▸ ha.trans ((agree_overlay hfit m f (by simp only [LIMIT] at h2; omega)).widen h1 h2)

theorem agw_writeBytes (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} (ha : Agree m0 m base STACK LIMIT)
    {f : Fin 32 → Byte} (he : m' = writeBytes m (base + BitVec.ofNat 32 c) f) (h1 : STACK ≤ c) (h2 : c + 32 ≤ LIMIT) :
    Agree m0 m' base STACK LIMIT :=
  he ▸ ha.trans ((agree_writeBytes hfit m f (by simp only [LIMIT] at h2; omega)).widen h1 h2)

/-- The six registers that never change after the start. -/
structure Fixed (base : Word) (scr : List Byte) (s : Machine) : Prop where
  r9 : s.reg 9 = base
  r24 : s.reg 24 = base + BitVec.ofNat 32 TABLE
  r19 : s.reg 19 = base + BitVec.ofNat 32 (SCRIPT + scr.length)
  r23 : s.reg 23 = base + BitVec.ofNat 32 STACK
  r22 : s.reg 22 = base + BitVec.ofNat 32 TMP
  r25 : s.reg 25 = base + BitVec.ofNat 32 TMP

theorem Core.fixed {c : Cfg} {s : Machine} (h : Core base m0 scr c s) : Fixed base scr s :=
  ⟨h.r9, h.r24, h.r19, h.r23, h.r22, h.r25⟩

/-- A step that writes a register outside the six, and nothing else of them. -/
def Keeps6 (s s' : Machine) : Prop :=
  ∀ r : Reg, r = 9 ∨ r = 24 ∨ r = 19 ∨ r = 23 ∨ r = 22 ∨ r = 25 → s'.reg r = s.reg r

theorem Keeps6.trans {s1 s2 s3 : Machine} (h1 : Keeps6 s1 s2) (h2 : Keeps6 s2 s3) : Keeps6 s1 s3 :=
  fun r hr => (h2 r hr).trans (h1 r hr)

theorem Keeps6.refl (s : Machine) : Keeps6 s s := fun _ _ => rfl

theorem Fixed.keep {s s' : Machine} (h : Fixed base scr s) (k : Keeps6 s s') : Fixed base scr s' :=
  ⟨by rw [k 9 (by decide), h.r9], by rw [k 24 (by decide), h.r24], by rw [k 19 (by decide), h.r19],
   by rw [k 23 (by decide), h.r23], by rw [k 22 (by decide), h.r22], by rw [k 25 (by decide), h.r25]⟩

/-- `Keeps6` from a step's register equation, when what it wrote is not one of the six. -/
theorem keeps6_of {s s' : Machine} {rd : Reg} {v : Word}
    (h : ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0 then v else s.reg r)
    (hrd : rd ≠ 9 ∧ rd ≠ 24 ∧ rd ≠ 19 ∧ rd ≠ 23 ∧ rd ≠ 22 ∧ rd ≠ 25) : Keeps6 s s' := by
  intro r hr
  rw [h r]
  have : ¬ (r = rd ∧ rd ≠ 0) := by
    rintro ⟨rfl, _⟩
    rcases hr with rfl | rfl | rfl | rfl | rfl | rfl <;> simp_all
  simp only [this, ↓reduceIte]

theorem keeps6_all {s s' : Machine} (h : ∀ r, s'.reg r = s.reg r) : Keeps6 s s' := fun r _ => h r

/-- **The tail of a handler**: `addi s4, s4, imm; j LOOP`, from a machine that
holds the next configuration but for `s4`. -/
theorem tail (hp : Placed env base) (hin : Input m0 base scr st0) {c' : Cfg} {s : Machine}
    (hf : Fixed base scr s) {k : Nat} (h20 : s.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * k))
    {i : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i + 1 < 881)
    {imm : BitVec 12} (h1 : kernel.getD i .ecall = .opi .addi 20 20 imm)
    {off : BitVec 20} (h2 : kernel.getD (i + 1) .ecall = .jal 0 off)
    (hoff : BitVec.ofNat 32 (4 * (i + 1)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * LOOP))
    (himm : base + BitVec.ofNat 32 (STACK + 84 * k) + imm.signExtend 32
      = base + BitVec.ofNat 32 (STACK + 84 * c'.st.length))
    (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c'.pc)) (h21 : s.reg 21 = BitVec.ofNat 32 c'.sigs)
    (hag : Agree m0 s.mem base STACK LIMIT) (hst : Holds s.mem base c'.st) (hd : c'.st.length ≤ DMAX)
    (he : ∀ e ∈ c'.st, e.length ≤ EMAX) (hs : c'.sigs ≤ 1) (hpc' : c'.pc ≤ scr.length) :
    Goes env base m0 scr s (.next c') := by
  have code := code_of_agree hp.fit hin.code hag
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp i (by rw [kernel_length]; omega) code hpc h1 rfl
  have hc1 : Core base m0 scr c' s1 :=
    { r9 := by rw [r1 9]; regsimp; exact hf.r9
      r24 := by rw [r1 24]; regsimp; exact hf.r24
      r19 := by rw [r1 19]; regsimp; exact hf.r19
      r23 := by rw [r1 23]; regsimp; exact hf.r23
      r22 := by rw [r1 22]; regsimp; exact hf.r22
      r25 := by rw [r1 25]; regsimp; exact hf.r25
      r20 := by rw [r1 20]; regsimp; simp only [aluI]; rw [h20, himm]
      r21 := by rw [r1 21]; regsimp; exact h21
      agree := by rw [m1]; exact hag
      stack := by rw [m1]; exact hst
      depth := hd
      elems := he
      sigs := hs
      pcle := hpc' }
  exact Goes.prepend e1 (back hp hin hc1 (by rw [r1 18]; regsimp; exact h18) p1 (by omega) h2 hoff)

end Exp228
