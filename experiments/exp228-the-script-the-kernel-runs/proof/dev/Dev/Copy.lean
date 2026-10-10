import Dev.Slots

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- A slot's 84 bytes laid over another, from a slot holding `e`. -/
theorem copied (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {src dst : Nat} {e : Elem}
    (h : SlotAt m base src e) (hd : dst + 84 < 0x10000) :
    SlotAt (overlay m (base + BitVec.ofNat 32 dst) 84 (fun d => m (base + BitVec.ofNat 32 (src + d))))
      base dst e := by
  intro d hd'
  rw [ev_overlay hfit _ _ _ _ _ hd (by omega)]
  simp only [show dst ≤ dst + d ∧ dst + d < dst + 84 by omega, and_self, ↓reduceIte,
    show dst + d - dst = d by omega]
  exact h d hd'

/-- **A slot copied**: 21 `lw t1; sw t1` pairs, from the slot at `rs` to the
one at `rd`, both in the stack's window and apart. -/
theorem copy_slot (hp : Placed env base) {k0 : Nat} {rs rd : Reg} {src dst : Nat}
    (hat : ∀ j < 21, kernel.getD (k0 + 2 * j) .ecall = .ld .lw 6 rs (BitVec.ofNat 12 (0 + 4 * j))
      ∧ kernel.getD (k0 + 2 * j + 1) .ecall = .st .sw rd 6 (BitVec.ofNat 12 (0 + 4 * j)))
    (hk : k0 + 42 ≤ 881) (hst : rs ≠ 6) (hdt : rd ≠ 6)
    (hs1 : STACK ≤ src) (hs2 : src + 84 ≤ LIMIT) (hd1 : STACK ≤ dst) (hd2 : dst + 84 ≤ LIMIT)
    (hs4 : src % 4 = 0) (hd4 : dst % 4 = 0) (hsep : src + 84 ≤ dst ∨ dst + 84 ≤ src)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base kernel)
    (h1 : s.reg rs = base + BitVec.ofNat 32 src) (h2 : s.reg rd = base + BitVec.ofNat 32 dst) :
    ∃ s', run env 42 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 42))
      ∧ s'.mem = overlay s.mem (base + BitVec.ofNat 32 dst) 84
          (fun d => s.mem (base + BitVec.ofNat 32 (src + d)))
      ∧ ∀ r, r ≠ 6 → s'.reg r = s.reg r := by
  simp only [STACK, LIMIT] at *
  obtain ⟨s', e, p, m, r⟩ := copy_n (prog := kernel) (n := 21) (so := 0) (dof := 0) hp hat
    (by rw [kernel_length]; omega) (by decide) hst hdt (by decide) (by decide) (by omega) (by omega)
    (by omega) (by omega) (by rw [kernel_length]; omega) (by omega) hpc hcode h1 h2 (by decide) 21 (Nat.le_refl _)
  exact ⟨s', e, p, by rw [m]; rfl, r⟩

theorem agree_copy (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {dst : Nat} (f : Nat → Byte)
    (hd2 : dst + 84 ≤ LIMIT) :
    Agree m (overlay m (base + BitVec.ofNat 32 dst) 84 f) base dst LIMIT :=
  (agree_overlay hfit m f (by simp only [LIMIT] at hd2; omega)).widen (Nat.le_refl _) hd2

end Exp228
