import Dev.Gen

/-! # The region's layout, slots, and the stack in memory -/

namespace Exp228
open Rv32

def TABLE : Nat := 0x1000
def SLEN : Nat := 0x1400
def SCRIPT : Nat := 0x1404
def DEPTH : Nat := 0x1800
def STACK : Nat := 0x1804
def TMP : Nat := 0x2284
/-- Everything the kernel writes is in `[STACK, LIMIT)`. -/
def LIMIT : Nat := 0x22d8

/-- Byte `d` of the slot holding `e`: the length, little-endian, in the first
four; the element; zeros to the end. -/
def slotBytes (e : Elem) (d : Nat) : Byte :=
  if d < 4 then BitVec.ofNat 8 (e.length / 256 ^ d) else e.getD (d - 4) 0

/-- The 84 bytes from `base + c` are the slot holding `e`. -/
def SlotAt (m : Word → Byte) (base : Word) (c : Nat) (e : Elem) : Prop :=
  ∀ d < 84, m (base + BitVec.ofNat 32 (c + d)) = slotBytes e d

/-- `m'` is `m` everywhere in the region but `[lo, hi)`. -/
def Agree (m m' : Word → Byte) (base : Word) (lo hi : Nat) : Prop :=
  ∀ x < 0x10000, (x < lo ∨ hi ≤ x) → m' (base + BitVec.ofNat 32 x) = m (base + BitVec.ofNat 32 x)

/-- The stack, top first, in its slots from STACK, bottom first. -/
def Holds (m : Word → Byte) (base : Word) (st : List Elem) : Prop :=
  ∀ i < st.length, SlotAt m base (STACK + 84 * i) (st.reverse.getD i [])

variable {base : Word}

/-! ## Agreeing outside a window -/

theorem Agree.refl (m : Word → Byte) (base : Word) (lo hi : Nat) : Agree m m base lo hi := fun _ _ _ => rfl

theorem Agree.trans {m1 m2 m3 : Word → Byte} {lo hi : Nat} (h1 : Agree m1 m2 base lo hi)
    (h2 : Agree m2 m3 base lo hi) : Agree m1 m3 base lo hi :=
  fun x hx o => (h2 x hx o).trans (h1 x hx o)

theorem Agree.widen {m m' : Word → Byte} {lo hi lo' hi' : Nat} (h : Agree m m' base lo hi)
    (h1 : lo' ≤ lo) (h2 : hi ≤ hi') : Agree m m' base lo' hi' :=
  fun x hx o => h x hx (by omega)

theorem agree_overlay (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c n : Nat} (f : Nat → Byte)
    (hc : c + n < 0x10000) : Agree m (overlay m (base + BitVec.ofNat 32 c) n f) base c (c + n) :=
  fun x hx o => overlay_off_out hfit m f hc hx (by omega)

theorem agree_writeLE (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c : Nat} (v : Nat)
    (hc : c + 4 < 0x10000) : Agree m (writeLE m (base + BitVec.ofNat 32 c) v 4) base c (c + 4) := by
  intro x hx o
  rw [writeLE_apply _ _ _ _ (by decide), toNat_sub_off hfit _ c (by omega), toNat_off hfit x hx]
  have := base.isLt
  rw [wrapdist _ _ (by omega) (by omega)]
  have : ¬ (if base.toNat + c ≤ base.toNat + x then base.toNat + x - (base.toNat + c)
      else 2 ^ 32 - (base.toNat + c) + (base.toNat + x)) < 4 := by split <;> omega
  simp only [this, ↓reduceIte]

theorem agree_writeByte (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c : Nat} (v : Byte)
    (hc : c + 1 < 0x10000) : Agree m (writeByte m (base + BitVec.ofNat 32 c) v) base c (c + 1) := by
  intro x hx o
  unfold writeByte
  have : base + BitVec.ofNat 32 x ≠ base + BitVec.ofNat 32 c := by
    intro e; have := congrArg BitVec.toNat e
    rw [toNat_off hfit x hx, toNat_off hfit c (by omega)] at this; omega
  simp [this]

theorem agree_writeBytes (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c : Nat}
    (f : Fin 32 → Byte) (hc : c + 32 < 0x10000) :
    Agree m (writeBytes m (base + BitVec.ofNat 32 c) f) base c (c + 32) := by
  intro x hx o
  rw [writeBytes_apply]
  have : ¬ (base + BitVec.ofNat 32 x - (base + BitVec.ofNat 32 c)).toNat < 32 := by
    rw [toNat_sub_off hfit _ c (by omega), toNat_off hfit x hx]
    have := base.isLt
    rw [wrapdist _ _ (by omega) (by omega)]
    split <;> omega
  simp only [this, ↓reduceDIte]

/-! ## Slots -/

theorem SlotAt.agree {m m' : Word → Byte} {c lo hi : Nat} {e : Elem} (h : SlotAt m base c e)
    (ha : Agree m m' base lo hi) (hc : c + 84 < 0x10000) (hd : c + 84 ≤ lo ∨ hi ≤ c) :
    SlotAt m' base c e := fun d hd' => by rw [ha _ (by omega) (by omega)]; exact h d hd'

theorem Holds.agree {m m' : Word → Byte} {st : List Elem} {lo hi : Nat} (h : Holds m base st)
    (ha : Agree m m' base lo hi) (hlen : st.length ≤ DMAX)
    (hd : STACK + 84 * st.length ≤ lo ∨ hi ≤ STACK) : Holds m' base st := fun i hi' =>
  (h i hi').agree ha (by simp only [STACK, DMAX] at *; omega)
    (by rcases hd with hd | hd <;> omega)

theorem holds_nil (m : Word → Byte) (base : Word) : Holds m base [] := fun _ h => by simp at h

/-- The top of the stack, in slot `r.length`. -/
theorem Holds.top {m : Word → Byte} {e : Elem} {r : List Elem} (h : Holds m base (e :: r)) :
    SlotAt m base (STACK + 84 * r.length) e := by
  have := h r.length (by simp)
  simpa [List.reverse_cons, List.getD_eq_getElem?_getD] using this

/-- The one under it, in slot `r.length`. -/
theorem Holds.second {m : Word → Byte} {a b : Elem} {r : List Elem} (h : Holds m base (a :: b :: r)) :
    SlotAt m base (STACK + 84 * r.length) b := by
  have := h r.length (by simp; omega)
  simpa [List.reverse_cons, List.getD_eq_getElem?_getD, List.getElem?_append_left] using this

theorem Holds.pop {m : Word → Byte} {e : Elem} {r : List Elem} (h : Holds m base (e :: r)) :
    Holds m base r := by
  intro i hi
  have := h i (by simp; omega)
  rw [List.reverse_cons, List.getD_eq_getElem?_getD, List.getElem?_append_left (by simp; omega)] at this
  rw [List.getD_eq_getElem?_getD]; exact this

/-- Pushing `e`: its slot written, nothing below it touched. -/
theorem Holds.push {m m' : Word → Byte} {st : List Elem} {e : Elem} (h : Holds m base st)
    (hlen : st.length < DMAX) (hs : SlotAt m' base (STACK + 84 * st.length) e)
    (ha : Agree m m' base (STACK + 84 * st.length) LIMIT) : Holds m' base (e :: st) := by
  intro i hi
  simp only [List.length_cons] at hi
  rcases (by omega : i < st.length ∨ i = st.length) with hl | rfl
  · have := (h i hl).agree ha (by simp only [STACK, DMAX] at *; omega) (by left; omega)
    rw [List.reverse_cons, List.getD_eq_getElem?_getD, List.getElem?_append_left (by simp; omega)]
    rw [List.getD_eq_getElem?_getD] at this; exact this
  · simpa [List.reverse_cons, List.getD_eq_getElem?_getD] using hs

end Exp228
