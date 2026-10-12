/-
SPDX-License-Identifier: Apache-2.0

# A ring of tissue with a tumour in it, and a dose

exp232's model: each cell empty, tissue or tumour, two words. Each
generation a dose may come, by the schedule's low bit, and kill every cell at
the edge of its own kind; then the tumour invades the cell above each of its
cells and the tissue fills the gaps beside it. Moving the ring changes
nothing (`gen_up1`), so a patient anywhere on it is the patient at cell 0
moved. exp232 wrote this; exp234, whose world adds resistance to it, needed
it second.
-/
import Rv32.Ring

namespace Tissue
open Rv32


/-- Each cell's two neighbours, together: lit where either is. -/
def spread (x : Word) : Word := up1 x ||| dn1 x

/-- A dose this generation: all ones if the schedule's low bit is set, else none. -/
def dose (s : Word) : Word := 0 - (s &&& 1)
/-- The cells a dose kills: each at the edge of its own kind. -/
def edge (t h : Word) : Word := (spread (~~~t) &&& t) ||| (spread (~~~h) &&& h)

structure Body where
  t : Word
  h : Word
  s : Word

def next (b : Body) : Body :=
  let k := edge b.t b.h &&& dose b.s
  let t1 := b.t &&& ~~~k
  let h1 := b.h &&& ~~~k
  let e := ~~~(t1 ||| h1)
  let t2 := t1 ||| up1 t1
  { t := t2, h := (h1 ||| (spread h1 &&& e)) &&& ~~~t2, s := b.s >>> 1 }

/-- Generation `n` from `b`. -/
def gen (b : Body) : Nat → Body
  | 0 => b
  | n + 1 => next (gen b n)

/-! ## Moving the patient round the ring changes nothing -/

theorem spread_up1 (x : Word) : spread (up1 x) = up1 (spread x) := by
  simp only [spread, up1_or, up1_dn1]

theorem dose_up1 (s : Word) : up1 (dose s) = dose s := by
  have lt : (s &&& (1 : Word)).toNat < 2 := by
    rw [BitVec.toNat_and]; exact Nat.lt_of_le_of_lt Nat.and_le_right (by decide)
  have h01 : s &&& (1 : Word) = 0 ∨ s &&& (1 : Word) = 1 := by
    rcases (by omega : (s &&& (1 : Word)).toNat = 0 ∨ (s &&& (1 : Word)).toNat = 1) with h | h
    · left; exact BitVec.eq_of_toNat_eq (by rw [h]; rfl)
    · right; exact BitVec.eq_of_toNat_eq (by rw [h]; rfl)
  rcases h01 with h | h <;> simp only [dose, h] <;> decide

theorem next_up1 (b : Body) : next ⟨up1 b.t, up1 b.h, b.s⟩ = ⟨up1 (next b).t, up1 (next b).h, (next b).s⟩ := by
  simp only [next, edge, up1_and, up1_or, up1_not, ← spread_up1, dose_up1]

theorem gen_up1 (b : Body) : ∀ n, gen ⟨up1 b.t, up1 b.h, b.s⟩ n = ⟨up1 (gen b n).t, up1 (gen b n).h, (gen b n).s⟩
  | 0 => rfl
  | n + 1 => by
    show next (gen _ n) = _
    rw [gen_up1 b n]
    exact next_up1 (gen b n)

/-! ## The trial's endpoint, and the patients it enrols -/

/-- The ring moved `p` cells up. -/
def rot : Nat → Word → Word
  | 0, x => x
  | p + 1, x => up1 (rot p x)

/-- A patient: a lump of `w` tumour cells, its lowest at cell `p`, tissue
everywhere else, and a schedule. -/
def patient (w p : Nat) (s : Word) : Body :=
  ⟨rot p (BitVec.ofNat 32 (2 ^ w - 1)), ~~~(rot p (BitVec.ofNat 32 (2 ^ w - 1))), s⟩

/-- **The stated endpoint** — the prompt. After generation 24 a scan sees no
tumour: two cells or fewer, which a scan cannot see. And at every generation
up to 24 the patient kept at least half the tissue. -/
def met (b : Body) : Prop :=
  pc (gen b 24).t 32 ≤ 2 ∧ ∀ g < 24, 16 ≤ pc (gen b (g + 1)).h 32

instance (b : Body) : Decidable (met b) := by unfold met; infer_instance

theorem gen_iter (w p : Nat) (s : Word) (n : Nat) :
    gen (patient w p s) n = ⟨rot p (gen (patient w 0 s) n).t, rot p (gen (patient w 0 s) n).h, (gen (patient w 0 s) n).s⟩ := by
  induction p with
  | zero => rfl
  | succ p ih =>
    have e : patient w (p + 1) s = ⟨up1 (patient w p s).t, up1 (patient w p s).h, (patient w p s).s⟩ := by
      simp only [patient, rot, up1_not]
    rw [e, gen_up1, ih]
    rfl

theorem pc_iter (x : Word) : ∀ p, pc (rot p x) 32 = pc x 32
  | 0 => rfl
  | p + 1 => by rw [rot, pc_up1, pc_iter x p]

theorem iter_zero (x : Word) : ∀ p, rot p x = 0 ↔ x = 0
  | 0 => Iff.rfl
  | p + 1 => by rw [rot, up1_eq_zero, iter_zero x p]

theorem met_iter (w p : Nat) (s : Word) : met (patient w p s) ↔ met (patient w 0 s) := by
  simp only [met, gen_iter w p s, pc_iter]

theorem gone_iter (w p n : Nat) (s : Word) : (gen (patient w p s) n).t = 0 ↔ (gen (patient w 0 s) n).t = 0 := by
  rw [gen_iter w p s n]; exact iter_zero _ p

end Tissue
