/-
SPDX-License-Identifier: Apache-2.0

# Constant time, checked

Two runs of the same program from states that agree on everything public —
the program, the registers, and a few named places in memory — and differ
anywhere else: the secret. **Constant time** here means the two runs are
indistinguishable to an observer of the core: at every step the same `pc`,
the same address loaded or stored, the same arguments to HASH, and the same
outcome. On a core with no caches and no data-dependent latency that is the
same time, which the RTL is held to separately.

The proof is not per kernel. `check` is an abstract interpretation a kernel
is run through by `decide`: every register is `sec` (may differ between the
runs), `pub` (equal in both), or public with what is known of its value — a
number in a range, an offset from `base` in a range, or an offset affine in
up to two counter registers, with a ranged constant part. Words of memory may be
declared constants (`Pub.consts`), which no store may meet and a load reads as
their number. It refuses a branch on a `sec` register, a load or store
whose address is `sec`, a store or a HASH whose place is not known to lie
above the code, and a secret value stored into a public place. `sound` is
proved once: whatever `check` accepts runs in lock step with itself.

Loops are given as heads: the abstract state at each branch target, which
the checker verifies every way in to it implies. Everything between heads is
computed.
-/
import Rv32.Frame

namespace Rv32.Ct
open Rv32

/-! ## What is known of a register -/

/-- The abstract value of one register, in two runs at once. -/
inductive AV where
  /-- may differ between the runs -/
  | sec
  /-- the same in both -/
  | pub
  /-- the same in both, a number in `[lo, hi]` -/
  | num (lo hi : Nat)
  /-- the same in both, `base` plus an offset in `[lo, hi]` -/
  | ptr (lo hi : Nat)
  /-- the same in both, `base + d + k₁ · x₁ + k₂ · x₂` for some `d` in
  `[lo, hi]`, where `xᵢ` is counter register `rᵢ`'s number, or its offset from
  `base`. `x0` reads as the counter 0, so a value in one counter has `r₂ = 0` -/
  | lin (r1 : Nat) (k1 : Int) (r2 : Nat) (k2 : Int) (lo hi : Int)
  deriving DecidableEq, Repr

/-- the same in both, `base + c + k · x`: affine in one counter, exactly. -/
@[match_pattern] abbrev AV.aff (r : Nat) (k c : Int) : AV := .lin r k 0 0 c c

/-- One per register, by number. -/
abbrev AState := List AV

/-- What `A` says of register `n`: `x0` is the number 0. -/
def get (A : AState) (n : Nat) : AV :=
  if n = 0 then .num 0 0 else if n < 32 then A.getD n .sec else .sec

/-- A counter's value, as `aff` reads it: the number, or the offset from `base`. -/
def idxOf (base : Word) (v : AV) (w : Word) : Option Nat :=
  match v with
  | .num _ _ => some w.toNat
  | .ptr _ _ => some (w - base).toNat
  | _ => none

/-- What abstract value `v` claims of two values `w1`, `w2` — one register in
the two runs — reading any counter from `s1`. -/
def valOK (base : Word) (A : AState) (s1 : Machine) (v : AV) (w1 w2 : Word) : Prop :=
  match v with
  | .sec => True
  | .pub => w1 = w2
  | .num lo hi => w1 = w2 ∧ lo ≤ w1.toNat ∧ w1.toNat ≤ hi
  | .ptr lo hi => w1 = w2 ∧ lo ≤ (w1 - base).toNat ∧ (w1 - base).toNat ≤ hi ∧ hi < 0x10000
  | .lin c1 k1 c2 k2 lo hi => w1 = w2 ∧
      match idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)), idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2)) with
      | some x1, some x2 => ∃ d : Int, lo ≤ d ∧ d ≤ hi ∧ w1 = base + BitVec.ofInt 32 (d + k1 * x1 + k2 * x2)
      | _, _ => True

/-- What the abstract value of register `r` claims of the two runs. -/
def regOK (base : Word) (A : AState) (s1 s2 : Machine) (r : Reg) : Prop :=
  valOK base A s1 (get A r.toNat) (s1.reg r) (s2.reg r)

/-- What is public, as offsets from `base`: places `[a, b)`, and constants --
words known to hold one value, which no store may touch. A list of places is
one with no constants. -/
structure Pub where
  places : List (Nat × Nat)
  consts : List (Nat × Nat) := []

instance : Coe (List (Nat × Nat)) Pub := ⟨fun l => { places := l }⟩

/-- An offset from `base` that is public: the program's own bytes, or one of
the places `P` names, `[a, b)` each. -/
def InP (len : Nat) (P : Pub) (o : Nat) : Prop :=
  o < 4 * len ∨ ∃ ab ∈ P.places, ab.1 ≤ o ∧ o < ab.2

/-- **Two runs, related by `A`.** Every register as `A` says; every public
byte the same; the program loaded in both. -/
structure Rel (base : Word) (prog : List Instr) (P : Pub) (A : AState) (s1 s2 : Machine) :
    Prop where
  regs : ∀ r : Reg, regOK base A s1 s2 r
  mem : ∀ o, o < 0x10000 → InP prog.length P o →
    s1.mem (base + BitVec.ofNat 32 o) = s2.mem (base + BitVec.ofNat 32 o)
  code1 : CodeAt s1.mem base prog
  code2 : CodeAt s2.mem base prog
  consts1 : ∀ c ∈ P.consts, readLE s1.mem (base + BitVec.ofNat 32 c.1) 4 = c.2
  consts2 : ∀ c ∈ P.consts, readLE s2.mem (base + BitVec.ofNat 32 c.1) 4 = c.2

/-! ## Reading registers back -/

theorem base_off (v base : Word) : base + BitVec.ofNat 32 (v - base).toNat = v := by
  rw [BitVec.ofNat_toNat, BitVec.setWidth_eq, BitVec.add_comm]; exact BitVec.sub_add_cancel v base

theorem toNat_lt_32 (r : Reg) : r.toNat < 32 := r.isLt

theorem ofNat_toNat5 (r : Reg) : BitVec.ofNat 5 r.toNat = r := by
  rw [BitVec.ofNat_toNat, BitVec.setWidth_eq]

/-- A public register is the same in both runs. -/
def isPub (v : AV) : Bool := v != .sec

theorem regOK_eq {base : Word} {A : AState} {s1 s2 : Machine} {r : Reg} (h : regOK base A s1 s2 r)
    (hp : isPub (get A r.toNat) = true) : s1.reg r = s2.reg r := by
  unfold regOK valOK at h
  unfold isPub at hp
  split at h
  · rename_i e; rw [e] at hp; exact absurd hp (by decide)
  · exact h
  · exact h.1
  · exact h.1
  · exact h.1

/-! ## One state implies another -/

/-- The same kind of counter: numbers both, or offsets both. -/
def sameKind (v w : AV) : Bool :=
  match v, w with
  | .num _ _, .num _ _ => true
  | .ptr _ _, .ptr _ _ => true
  | _, _ => false

/-- A counter that `idxOf` reads. -/
def isCounter (v : AV) : Bool :=
  match v with
  | .num _ _ => true
  | .ptr _ _ => true
  | _ => false

/-- A counter that names one value: that value. -/
def exactIdx (A : AState) (c : Nat) : Option Nat :=
  match get A c with
  | .num x y => if x = y then some x else none
  | .ptr x y => if x = y then some x else none
  | _ => none

/-- One term `k · x` of a value: the counter left and its coefficient, and the
shift folded into the offset -- all of it, and no counter (`x0`), when the
counter names one value. `none` when the register is not a counter. -/
def foldT (A : AState) (c : Nat) (k : Int) : Option (Nat × Int × Int) :=
  if isCounter (get A c) then
    match exactIdx A c with
    | some x => some (0, 0, k * x)
    | none => some (c, k, 0)
  else none

/-- A value as `base + d + k₁ · x₁ + k₂ · x₂` with `d` in `[a, b]`, every
counter that names one value folded into the range. -/
def fold (A : AState) (v : AV) : Option (Nat × Int × Nat × Int × Int × Int) :=
  match v with
  | .ptr a b => some (0, 0, 0, 0, a, b)
  | .lin c1 k1 c2 k2 lo hi =>
    match foldT A c1 k1, foldT A c2 k2 with
    | some (e1, j1, s1), some (e2, j2, s2) => some (e1, j1, e2, j2, lo + s1 + s2, hi + s1 + s2)
    | _, _ => none
  | _ => none

/-- What `w` claims of a register follows from what `v` claims, `A` and `B`
being the states they belong to. -/
def leAV (A B : AState) (v w : AV) : Bool :=
  match w with
  | .sec => true
  | .pub => isPub v
  | .num lo hi => match v with
    | .num a b => lo ≤ a && b ≤ hi
    | _ => false
  | .ptr lo hi => hi < 0x10000 && match v with
    | .ptr a b => lo ≤ a && b ≤ hi
    | _ => false
  | .lin c1 k1 c2 k2 lo hi => isPub v &&
    (!isCounter (get B c1) || !isCounter (get B c2) ||
      (sameKind (get A c1) (get B c1) && sameKind (get A c2) (get B c2) &&
        match fold A v, fold A (.lin c1 k1 c2 k2 lo hi) with
        | some (e1, j1, e2, j2, a, b), some (e1', j1', e2', j2', a', b') =>
          e1 == e1' && j1 == j1' && e2 == e2' && j2 == j2' && decide (a' ≤ a) && decide (b ≤ b')
        | _, _ => false))

/-- Every register, as `leAV` says. -/
def leS (A B : AState) : Bool := (List.range 32).all fun n => leAV A B (get A n) (get B n)

/-! ## The implication, proved -/

theorem regOK_zero {base : Word} {A : AState} {s1 s2 : Machine} : regOK base A s1 s2 0 := by
  unfold regOK valOK; simp [get]

theorem get_reg {c : Nat} (hc : c < 32) : (BitVec.ofNat 5 c).toNat = c := by
  rw [BitVec.toNat_ofNat]; omega

theorem get_big {A : AState} {c : Nat} (hc : ¬ c < 32) : get A c = .sec := by
  unfold get; simp [show c ≠ 0 by omega, hc]

/-- An exact counter's value is its one number. -/
theorem idx_exact {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {c x : Nat} (hx : get A c = .num x x ∨ get A c = .ptr x x) :
    idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) = some x := by
  have hc : c < 32 := by
    rcases Nat.lt_or_ge c 32 with hc | hc
    · exact hc
    · rw [get_big (by omega)] at hx; rcases hx with hx | hx <;> cases hx
  have hr := h (BitVec.ofNat 5 c)
  unfold regOK valOK at hr
  rw [get_reg hc] at hr
  rcases hx with hx | hx <;> rw [hx] at hr ⊢ <;> simp only [idxOf, Option.some.injEq] at hr ⊢ <;> omega

/-- `x0` reads as the counter 0. -/
theorem idx_zero {base : Word} {A : AState} {s : Machine} :
    idxOf base (get A 0) (s.reg (BitVec.ofNat 5 0)) = some 0 := by
  simp [get, idxOf]

/-- A counter has a reading. -/
theorem idxOf_counter {base : Word} {v : AV} (h : isCounter v = true) (w : Word) :
    ∃ x, idxOf base v w = some x := by
  cases v <;> simp_all [isCounter, idxOf]

/-- A counter that names one value reads as that value. -/
theorem exactIdx_val {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {c x : Nat} (hx : exactIdx A c = some x) : idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) = some x := by
  unfold exactIdx at hx
  cases hg : get A c with
  | num a b =>
    rw [hg] at hx; simp only at hx
    split at hx
    · rename_i hab; cases hx; rw [← hg]; exact idx_exact h (Or.inl (by rw [hg, hab]))
    · cases hx
  | ptr a b =>
    rw [hg] at hx; simp only at hx
    split at hx
    · rename_i hab; cases hx; rw [← hg]; exact idx_exact h (Or.inr (by rw [hg, hab]))
    · cases hx
  | _ => rw [hg] at hx; cases hx

theorem foldT_ok {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {c : Nat} {k : Int} {e : Nat} {j sh : Int} (hf : foldT A c k = some (e, j, sh)) :
    ∃ x y : Nat, idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) = some x ∧
      idxOf base (get A e) (s1.reg (BitVec.ofNat 5 e)) = some y ∧ k * (x : Int) = j * y + sh := by
  unfold foldT at hf
  split at hf
  · rename_i hc
    cases he : exactIdx A c with
    | some x =>
      rw [he] at hf; simp only [Option.some.injEq, Prod.mk.injEq] at hf
      obtain ⟨rfl, rfl, rfl⟩ := hf
      exact ⟨x, 0, exactIdx_val h he, idx_zero, by simp⟩
    | none =>
      rw [he] at hf; simp only [Option.some.injEq, Prod.mk.injEq] at hf
      obtain ⟨rfl, rfl, rfl⟩ := hf
      obtain ⟨x, hx⟩ := idxOf_counter (base := base) hc (s1.reg (BitVec.ofNat 5 c))
      exact ⟨x, x, hx, hx, by simp⟩
  · cases hf

/-- **What a folded value says**: `base + d + j₁ · y₁ + j₂ · y₂`, with `d` in the
folded range and `yᵢ` the folded counters' readings. -/
theorem fold_val {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {v : AV} {w1 w2 : Word} (hv : valOK base A s1 v w1 w2) {e1 e2 : Nat} {j1 j2 a b : Int}
    (hf : fold A v = some (e1, j1, e2, j2, a, b)) :
    ∃ y1 y2 : Nat, idxOf base (get A e1) (s1.reg (BitVec.ofNat 5 e1)) = some y1 ∧
      idxOf base (get A e2) (s1.reg (BitVec.ofNat 5 e2)) = some y2 ∧
      ∃ d : Int, a ≤ d ∧ d ≤ b ∧ w1 = base + BitVec.ofInt 32 (d + j1 * y1 + j2 * y2) := by
  cases v with
  | ptr lo hi =>
    simp only [fold, Option.some.injEq, Prod.mk.injEq] at hf
    obtain ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩ := hf
    unfold valOK at hv
    refine ⟨0, 0, idx_zero, idx_zero, ((w1 - base).toNat : Int), by omega, by omega, ?_⟩
    simp only [Int.zero_mul, Int.add_zero, BitVec.ofInt_natCast, base_off]
  | lin c1 k1 c2 k2 lo hi =>
    simp only [fold] at hf
    cases hf1 : foldT A c1 k1 with
    | none => rw [hf1] at hf; cases hf
    | some t1 =>
      cases hf2 : foldT A c2 k2 with
      | none => rw [hf1, hf2] at hf; cases hf
      | some t2 =>
        obtain ⟨e1', j1', s1'⟩ := t1
        obtain ⟨e2', j2', s2'⟩ := t2
        rw [hf1, hf2] at hf
        simp only [Option.some.injEq, Prod.mk.injEq] at hf
        obtain ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩ := hf
        obtain ⟨x1, y1, hx1, hy1, ek1⟩ := foldT_ok h hf1
        obtain ⟨x2, y2, hx2, hy2, ek2⟩ := foldT_ok h hf2
        simp only [valOK] at hv
        rw [hx1, hx2] at hv
        obtain ⟨d, hd1, hd2, hw⟩ := hv.2
        refine ⟨y1, y2, hy1, hy2, d + s1' + s2', by omega, by omega, ?_⟩
        rw [hw]; congr 2; omega
  | _ => simp [fold] at hf

/-- **What a folded claim asks**: a value of the folded form is one of the claim's. -/
theorem fold_lin {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {c1 c2 : Nat} {k1 k2 lo hi : Int} {e1 e2 : Nat} {j1 j2 a b : Int}
    (hf : fold A (.lin c1 k1 c2 k2 lo hi) = some (e1, j1, e2, j2, a, b))
    {x1 x2 y1 y2 : Nat} (hx1 : idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)) = some x1)
    (hx2 : idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2)) = some x2)
    (hy1 : idxOf base (get A e1) (s1.reg (BitVec.ofNat 5 e1)) = some y1)
    (hy2 : idxOf base (get A e2) (s1.reg (BitVec.ofNat 5 e2)) = some y2)
    {d' : Int} (h1 : a ≤ d') (h2 : d' ≤ b) :
    ∃ d : Int, lo ≤ d ∧ d ≤ hi ∧ d + k1 * x1 + k2 * x2 = d' + j1 * y1 + j2 * y2 := by
  simp only [fold] at hf
  cases hf1 : foldT A c1 k1 with
  | none => rw [hf1] at hf; cases hf
  | some t1 =>
    cases hf2 : foldT A c2 k2 with
    | none => rw [hf1, hf2] at hf; cases hf
    | some t2 =>
      obtain ⟨e1', j1', s1'⟩ := t1
      obtain ⟨e2', j2', s2'⟩ := t2
      rw [hf1, hf2] at hf
      simp only [Option.some.injEq, Prod.mk.injEq] at hf
      obtain ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩ := hf
      obtain ⟨x1', y1', hx1', hy1', ek1⟩ := foldT_ok h hf1
      obtain ⟨x2', y2', hx2', hy2', ek2⟩ := foldT_ok h hf2
      rw [hx1] at hx1'; rw [hx2] at hx2'; rw [hy1] at hy1'; rw [hy2] at hy2'
      cases hx1'; cases hx2'; cases hy1'; cases hy2'
      exact ⟨d' - s1' - s2', by omega, by omega, by omega⟩

theorem idxOf_same {base : Word} {v w : AV} (h : sameKind v w = true) (x : Word) :
    idxOf base w x = idxOf base v x := by
  cases v <;> cases w <;> simp_all [sameKind, idxOf]

theorem idxOf_none {base : Word} {v : AV} (h : isCounter v = false) (x : Word) : idxOf base v x = none := by
  cases v <;> simp_all [isCounter, idxOf]

theorem leS_at {A B : AState} (h : leS A B = true) (n : Nat) (hn : n < 32) :
    leAV A B (get A n) (get B n) = true := by
  unfold leS at h
  rw [List.all_eq_true] at h
  exact h n (List.mem_range.mpr hn)

/-- **A state implies any state above it.** -/
theorem rel_mono {base : Word} {prog : List Instr} {P : Pub} {A B : AState} {s1 s2 : Machine}
    (hle : leS A B = true) (h : Rel base prog P A s1 s2) : Rel base prog P B s1 s2 := by
  refine ⟨fun r => ?_, h.mem, h.code1, h.code2, h.consts1, h.consts2⟩
  have hl := leS_at hle r.toNat r.isLt
  have hA := h.regs r
  unfold regOK valOK at hA ⊢
  revert hl hA
  cases hB : get B r.toNat with
  | sec => intros; trivial
  | pub =>
    intro hl hA
    simp only [leAV] at hl
    exact regOK_eq (h.regs r) hl
  | num lo hi =>
    intro hl hA
    cases hv : get A r.toNat with
    | num a b =>
      rw [hv] at hl hA; simp only [leAV, Bool.and_eq_true, decide_eq_true_eq] at hl
      exact ⟨hA.1, by omega, by omega⟩
    | _ => rw [hv] at hl; simp [leAV] at hl
  | ptr lo hi =>
    intro hl hA
    cases hv : get A r.toNat with
    | ptr a b =>
      rw [hv] at hl hA; simp only [leAV, Bool.and_eq_true, decide_eq_true_eq] at hl
      exact ⟨hA.1, by omega, by omega, hl.1⟩
    | _ => rw [hv] at hl; simp [leAV] at hl
  | lin c1 k1 c2 k2 lo hi =>
    intro hl _
    simp only [leAV, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at hl
    obtain ⟨hp, hl⟩ := hl
    dsimp only
    refine ⟨regOK_eq (h.regs r) hp, ?_⟩
    rcases hl with (hnc | hnc) | ⟨⟨hk1, hk2⟩, hl⟩
    · rw [idxOf_none hnc]; trivial
    · rw [idxOf_none hnc]; split <;> trivial
    · rw [idxOf_same hk1, idxOf_same hk2]
      cases hx1 : idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)) with
      | none => trivial
      | some x1 =>
        cases hx2 : idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2)) with
        | none => trivial
        | some x2 =>
          simp only
          revert hl
          cases hfv : fold A (get A r.toNat) with
          | none => simp
          | some F =>
            obtain ⟨e1, j1, e2, j2, a, b⟩ := F
            cases hfw : fold A (.lin c1 k1 c2 k2 lo hi) with
            | none => simp
            | some G =>
              obtain ⟨e1', j1', e2', j2', a', b'⟩ := G
              simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq]
              rintro ⟨⟨⟨⟨⟨rfl, rfl⟩, rfl⟩, rfl⟩, ha⟩, hb⟩
              obtain ⟨y1, y2, hy1, hy2, d', hd1, hd2, hw⟩ := fold_val h.regs (h.regs r) hfv
              obtain ⟨d, hd3, hd4, he⟩ := fold_lin h.regs hfw hx1 hx2 hy1 hy2 (show a' ≤ d' by omega) (show d' ≤ b' by omega)
              exact ⟨d, hd3, hd4, by rw [hw, he]⟩

/-! ## One instruction, abstractly -/

/-- A 12-bit immediate, as the number `signExtend` makes of it. -/
def sext (imm : BitVec 12) : Int := if imm.toNat < 2048 then imm.toNat else (imm.toNat : Int) - 4096

/-- A branch's offset, in bytes: twice the immediate, signed. -/
def boff (off : BitVec 12) : Int := if off.toNat < 2048 then 2 * off.toNat else 2 * (off.toNat : Int) - 8192

/-- What writing register `n` does to a value affine in it: moved by `-k · d`
when `n` was stepped by `d` in place, and otherwise only kept equal. -/
def bump (n : Nat) (step : Option Int) (w : AV) : AV :=
  match w with
  | .lin c1 k1 c2 k2 lo hi =>
    if c1 = n ∨ c2 = n then
      (match step with
       | some d =>
         .lin c1 k1 c2 k2 (lo - ((if c1 = n then k1 * d else 0) + (if c2 = n then k2 * d else 0)))
           (hi - ((if c1 = n then k1 * d else 0) + (if c2 = n then k2 * d else 0)))
       | none => .pub)
    else w
  | w => w

/-- Whether `v` reads register `n` as one of its counters. -/
def dep (n : Nat) (v : AV) : Bool :=
  match v with
  | .lin c1 _ c2 _ _ _ => c1 == n || c2 == n
  | _ => false

theorem se_sext (imm : BitVec 12) : imm.signExtend 32 = BitVec.ofInt 32 (sext imm) := by
  apply BitVec.eq_of_toNat_eq
  have hlt := imm.isLt
  rw [BitVec.toNat_signExtend, BitVec.toNat_ofInt]
  simp only [BitVec.toNat_setWidth, sext, BitVec.msb_eq_decide]
  by_cases h : imm.toNat < 2048
  · rw [ifT h, decide_eq_false (by omega)]
    simp only [Bool.false_eq_true, ↓reduceIte, Nat.add_zero]
    omega
  · rw [ifF h, decide_eq_true (by omega)]
    simp only [↓reduceIte]
    omega

theorem boff_eq (off : BitVec 12) : (off ++ 0#1).signExtend 32 = BitVec.ofInt 32 (boff off) := by
  apply BitVec.eq_of_toNat_eq
  have hlt := off.isLt
  have ha : (off ++ 0#1).toNat = 2 * off.toNat := by
    rw [BitVec.toNat_append]; simp; omega
  rw [BitVec.toNat_signExtend, BitVec.toNat_ofInt]
  simp only [BitVec.toNat_setWidth, boff, BitVec.msb_eq_decide, ha]
  by_cases h : off.toNat < 2048
  · rw [ifT h, decide_eq_false (by omega)]
    simp only [Bool.false_eq_true, ↓reduceIte, Nat.add_zero]
    omega
  · rw [ifF h, decide_eq_true (by omega)]
    simp only [↓reduceIte]
    omega

/-- Register `n` written with `v`. -/
def write (A : AState) (n : Nat) (v : AV) (step : Option Int) : AState :=
  if n = 0 then A else (A.set n v).map (bump n step)

/-- `addi rd, rs, d` on what is known of `rs`. -/
def addiAV (rd : Nat) (v : AV) (d : Int) : AV :=
  match v with
  | .num lo hi => if 0 ≤ (lo : Int) + d ∧ (hi : Int) + d < 2 ^ 32 then .num ((lo : Int) + d).toNat ((hi : Int) + d).toNat
      else .pub
  | .ptr lo hi => if 0 ≤ (lo : Int) + d ∧ (hi : Int) + d < 0x10000 then .ptr ((lo : Int) + d).toNat ((hi : Int) + d).toNat
      else .pub
  | .lin c1 k1 c2 k2 lo hi => if c1 = rd ∨ c2 = rd then .pub else .lin c1 k1 c2 k2 (lo + d) (hi + d)
  | .pub => .pub
  | .sec => .sec

/-- A shift on what is known of the register shifted: a logical shift right of
a number in a range is a number in the range shifted. -/
def shAV (op : ShOp) (v : AV) (s : Nat) : AV :=
  match op, v with
  | .srli, .num lo hi => .num (lo >>> s) (hi >>> s)
  | _, v => if isPub v then .pub else .sec

/-- A counter's range. -/
def rng (A : AState) (c : Nat) : Option (Nat × Nat) :=
  match get A c with
  | .num a b | .ptr a b => some (a, b)
  | _ => none

/-- The least and the most `k · x` can be, `x` in `[a, b]`. -/
def tlo (k : Int) (ab : Nat × Nat) : Int := if 0 ≤ k then k * ab.1 else k * ab.2
def thi (k : Int) (ab : Nat × Nat) : Int := if 0 ≤ k then k * ab.2 else k * ab.1

/-- The offsets from `base` an access of `size` bytes at `v + i` may touch,
`[lo, hi)`, when they are known. -/
def rangeOf (A : AState) (v : AV) (i : Int) (size : Nat) : Option (Nat × Nat) :=
  match v with
  | .ptr lo hi => if 0 ≤ (lo : Int) + i then some (((lo : Int) + i).toNat, ((hi : Int) + i).toNat + size) else none
  | .lin c1 k1 c2 k2 lo hi =>
    match rng A c1, rng A c2 with
    | some r1, some r2 =>
      if 0 ≤ lo + tlo k1 r1 + tlo k2 r2 + i then
        some ((lo + tlo k1 r1 + tlo k2 r2 + i).toNat, (hi + thi k1 r1 + thi k2 r2 + i).toNat + size)
      else none
    | _, _ => none
  | _ => none

def within (lo hi : Nat) (ab : Nat × Nat) : Bool := ab.1 ≤ lo && hi ≤ ab.2

/-- `[lo, hi)` lies inside the program or inside one public place. -/
def pubRange (len : Nat) (P : Pub) (lo hi : Nat) : Bool :=
  within lo hi (0, 4 * len) || P.places.any (within lo hi)

/-- `[lo, hi)` meets no public place. -/
def apart (Q : List (Nat × Nat)) (lo hi : Nat) : Bool := Q.all fun ab => hi ≤ ab.1 || ab.2 ≤ lo

/-- `[lo, hi)` meets no constant's word. -/
def apartK (P : Pub) (lo hi : Nat) : Bool :=
  P.consts.all fun c => decide (c.1 + 4 ≤ 0x10000) && (decide (hi ≤ c.1) || decide (c.1 + 4 ≤ lo))

/-- After a comparison of `r1` with `r2`, what `r1` is known to be: equal to
`r2`'s one value, or not it — which narrows a range only at an end. -/
def refine (A : AState) (r1 r2 : Reg) (eq : Bool) : AState :=
  if r1.toNat = 0 then A else
  match get A r1.toNat, get A r2.toNat with
  | .num lo hi, .num e e' =>
    if e = e' then
      (if eq then A.set r1.toNat (.num e e)
       else A.set r1.toNat (.num (if e = lo then lo + 1 else lo) (if e = hi then hi - 1 else hi)))
    else A
  | .ptr lo hi, .ptr e e' =>
    if e = e' then
      (if eq then A.set r1.toNat (.ptr e e)
       else A.set r1.toNat (.ptr (if e = lo then lo + 1 else lo) (if e = hi then hi - 1 else hi)))
    else A
  | _, _ => A

/-- A value with counter `n`'s one value `x` folded into its range. -/
def normAV (n x : Nat) (w : AV) : AV :=
  match w with
  | .lin c1 k1 c2 k2 lo hi =>
    .lin (if c1 = n then 0 else c1) (if c1 = n then 0 else k1) (if c2 = n then 0 else c2) (if c2 = n then 0 else k2)
      (lo + (if c1 = n then k1 * x else 0) + (if c2 = n then k2 * x else 0))
      (hi + (if c1 = n then k1 * x else 0) + (if c2 = n then k2 * x else 0))
  | w => w

/-- Every value that reads counter `n`, with `n`'s value folded in, when it has
one: so a counter a comparison pinned down can be written again without
losing what was affine in it. -/
def norm (A : AState) (n : Nat) : AState :=
  match exactIdx A n with
  | some x => A.map (normAV n x)
  | none => A

/-- After learning that `a`'s number is at most `b`'s less `sub`: `a`'s range
capped by `b`'s top. Only for numbers below 2³¹, where the signed and the
unsigned orders agree. -/
def capLe (A : AState) (a b : Reg) (sub : Nat) : AState :=
  if a.toNat = 0 then A else
  match get A a.toNat, get A b.toNat with
  | .num la ha, .num _ hb =>
    if ha < 2 ^ 31 ∧ hb < 2 ^ 31 then A.set a.toNat (.num la (min ha (hb - sub))) else A
  | _, _ => A

/-- After a comparison: `refine`, and what it pinned down folded in. -/
def refineN (A : AState) (r1 r2 : Reg) (eq : Bool) : AState := norm (refine A r1 r2 eq) r1.toNat

/-- Where an instruction may go: on to the next, and to a branch's target. -/
structure Post where
  fall : Option AState
  jump : Option (Nat × AState)

/-- What a load brings: a constant's number when it reads exactly a constant's
word; equal in both runs when every byte it may read is public. -/
def ldAV (len : Nat) (P : Pub) (A : AState) (v : AV) (i : Int) (size : Nat) : AV :=
  match rangeOf A v i size with
  | some (lo, hi) =>
    match P.consts.find? (fun c => c.1 == lo) with
    | some c =>
      if size = 4 ∧ hi = lo + 4 ∧ c.2 < 2 ^ 32 then .num c.2 c.2
      else if hi ≤ 0x10000 ∧ pubRange len P lo hi = true then .pub else .sec
    | none => if hi ≤ 0x10000 ∧ pubRange len P lo hi = true then .pub else .sec
  | none => .sec

/-- A register-register operation: `add` of an offset and a number is an
offset; anything else of public values is public. -/
def opAV (op : ROp) (v1 v2 : AV) : AV :=
  match op, v1, v2 with
  | .add, .ptr a b, .num c d => if b + d < 0x10000 then .ptr (a + c) (b + d) else .pub
  | _, v1, v2 => if isPub v1 ∧ isPub v2 then .pub else .sec

/-- HASH's 32 bytes go above the program and in no public place. -/
def hashDst (len : Nat) (P : Pub) (A : AState) : Bool :=
  match rangeOf A (get A 12) 0 32 with
  | some (lo, hi) => decide (4 * len ≤ lo) && decide (hi ≤ 0x10000) && apart P.places lo hi && apartK P lo hi
  | none => false

/-- **One instruction**, at index `k` of a program `len` long, from `A`. `none`
is a refusal. -/
def transfer (len : Nat) (P : Pub) (k : Nat) (A : AState) : Instr → Option Post
  | .lui rd imm => some ⟨some (write A rd.toNat (.num (imm ++ 0#12).toNat (imm ++ 0#12).toNat) none), none⟩
  | .auipc rd imm =>
    some ⟨some (write A rd.toNat (if imm = 0 ∧ 4 * k < 0x10000 then .ptr (4 * k) (4 * k) else .pub) none), none⟩
  | .jal .. => none
  | .jalr .. => none
  | .br op r1 r2 off =>
    if isPub (get A r1.toNat) ∧ isPub (get A r2.toNat) ∧ 0 ≤ 4 * (k : Int) + boff off
        ∧ (4 * (k : Int) + boff off) % 4 = 0 then
      let t := ((4 * (k : Int) + boff off) / 4).toNat
      match op with
      | .bne => some ⟨some (refineN A r1 r2 true), some (t, refineN A r1 r2 false)⟩
      | .beq => some ⟨some (refineN A r1 r2 false), some (t, refineN A r1 r2 true)⟩
      | .blt | .bltu => some ⟨some (capLe A r2 r1 0), some (t, capLe A r1 r2 1)⟩
      | .bge | .bgeu => some ⟨some (capLe A r1 r2 1), some (t, capLe A r2 r1 0)⟩
    else none
  | .ld op rd r1 imm =>
    if isPub (get A r1.toNat) then
      some ⟨some (write A rd.toNat (ldAV len P A (get A r1.toNat) (sext imm) op.size) none), none⟩
    else none
  | .st op r1 r2 imm =>
    match rangeOf A (get A r1.toNat) (sext imm) op.size with
    | some (lo, hi) =>
      if 4 * len ≤ lo ∧ hi ≤ 0x10000 ∧ apartK P lo hi = true ∧ (isPub (get A r2.toNat) ∨ apart P.places lo hi) then
        some ⟨some A, none⟩
      else none
    | none => none
  | .opi op rd r1 imm =>
    let src := get A r1.toNat
    match op with
    | .addi =>
      let v := addiAV rd.toNat src (sext imm)
      some ⟨some (write A rd.toNat v
        (if r1 = rd ∧ isCounter src ∧ isCounter v then some (sext imm) else none)), none⟩
    | _ => some ⟨some (write A rd.toNat (if isPub src then .pub else .sec) none), none⟩
  | .sh op rd r1 sa => some ⟨some (write A rd.toNat (shAV op (get A r1.toNat) sa.toNat) none), none⟩
  | .op op rd r1 r2 => some ⟨some (write A rd.toNat (opAV op (get A r1.toNat) (get A r2.toNat)) none), none⟩
  | .ecall =>
    match get A 5 with
    | .num 0 0 =>
      if isPub (get A 10) ∧ isPub (get A 11) ∧
          hashDst len P A = true then some ⟨some A, none⟩
      else none
    | .num 1 1 => if isPub (get A 10) then some ⟨none, none⟩ else none
    | _ => none

/-! ## The whole program -/

/-- The loop heads: the abstract state at each, by instruction index. -/
abbrev Heads := List (Nat × AState)

def head (H : Heads) (k : Nat) : Option AState := (H.find? fun h => h.1 == k).map (·.2)

/-- At the start every register is the same in both runs. -/
def entry : AState := List.replicate 32 .pub

/-- The abstract state at instruction `k`: a head's, or what the instruction
before leaves; `none` where nothing falls through to it. -/
def stateAt (prog : List Instr) (P : Pub) (H : Heads) : Nat → Option AState
  | 0 => match head H 0 with
    | some B => some B
    | none => some entry
  | k + 1 => match head H (k + 1) with
    | some B => some B
    | none => match stateAt prog P H k, prog[k]? with
      | some A, some i => (transfer prog.length P k A i).bind (·.fall)
      | _, _ => none

/-- Each way out of an instruction lands in what is claimed there: an
instruction of the program, or one of the exits `X` -- an instruction index the
run may leave the program for, outside it or in it, where what the program
claims stops. -/
def succOK (len : Nat) (H : Heads) (X : List Nat) (k : Nat) (post : Post) : Bool :=
  (match post.fall with
   | some F => decide (k + 1 < len) && (match head H (k + 1) with | some B => leS F B | none => true)
   | none => true) &&
  (match post.jump with
   | some (t, T) => (decide (t < len) && (match head H t with | some B => leS T B | none => false)) || X.contains t
   | none => true)

/-- **The checker.** Every instruction a run can reach is accepted, and every
way out of it lands in what is claimed there, or at one of the exits `X`. -/
def checkX (prog : List Instr) (P : Pub) (H : Heads) (X : List Nat) : Bool :=
  decide (4 * prog.length < 0x10000) &&
  (match head H 0 with | some B => leS entry B | none => true) &&
  (List.range prog.length).all fun k =>
    match stateAt prog P H k, prog[k]? with
    | some A, some i => match transfer prog.length P k A i with
      | some post => succOK prog.length H X k post
      | none => false
    | _, _ => true

/-- The checker with no exits: every way out of every instruction is an
instruction of the program. -/
def check (prog : List Instr) (P : Pub) (H : Heads) : Bool := checkX prog P H []

/-! ## Soundness: writing a register -/

theorem bump_sec (n : Nat) (st : Option Int) : bump n st .sec = .sec := rfl

theorem get_write {A : AState} {n : Nat} (hn0 : n ≠ 0) (hn : n < 32) (v : AV) (st : Option Int) (m : Nat) :
    get (write A n v st) m = bump n st (if m = n ∧ n < A.length then v else get A m) := by
  unfold write get
  rw [ifF hn0]
  by_cases hm0 : m = 0
  · subst hm0; simp [show ¬ (0 = n) by omega, bump]
  · by_cases hm : m < 32
    · simp only [hm0, hm, ↓reduceIte]
      rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_map, List.getElem?_set]
      by_cases hmn : m = n
      · subst hmn
        by_cases hl : m < A.length
        · simp [hl]
        · simp [hl, bump]
      · simp only [Ne.symm hmn, false_and, ↓reduceIte, hmn]
        cases A[m]? <;> simp [bump]
    · simp only [hm0, hm, ↓reduceIte, show ¬ (m = n) by omega, false_and, bump]

theorem idxOf_bump (base : Word) (n : Nat) (st : Option Int) (w : AV) (x : Word) :
    idxOf base (bump n st w) x = idxOf base w x := by
  cases w with
  | lin c1 k1 c2 k2 lo hi =>
    simp only [bump]; split
    · cases st <;> rfl
    · rfl
  | _ => rfl

theorem dep_false {n c1 c2 : Nat} {k1 k2 lo hi : Int} :
    dep n (.lin c1 k1 c2 k2 lo hi) = false ↔ c1 ≠ n ∧ c2 ≠ n := by
  simp [dep]

theorem bump_self {n : Nat} {st : Option Int} {v : AV} (hv : dep n v = false) : bump n st v = v := by
  cases v with
  | lin c1 k1 c2 k2 lo hi =>
    rw [dep_false] at hv
    simp only [bump]
    rw [ifF (fun h => h.elim hv.1 hv.2)]
  | _ => rfl

theorem reg_ofNat_ne {rd : Reg} {c : Nat} (hc : c < 32) (hne : c ≠ rd.toNat) : BitVec.ofNat 5 c ≠ rd := by
  intro e; apply hne; rw [← e, get_reg hc]

/-- A counter other than the one written reads the same afterwards. -/
theorem read_after {base : Word} {A : AState} {s1 : Machine} {rd : Reg} (hrd0 : rd.toNat ≠ 0)
    (st : Option Int) (v' : AV) (w : Word) {c : Nat} (hc : c ≠ rd.toNat) :
    idxOf base (get (write A rd.toNat v' st) c) ((s1.setReg rd w).reg (BitVec.ofNat 5 c)) =
      idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) := by
  rcases Nat.lt_or_ge c 32 with hc32 | hc32
  · rw [get_write hrd0 rd.isLt, ifF (fun x => hc x.1), idxOf_bump, reg_setReg,
      ifF (fun x => reg_ofNat_ne hc32 hc x.1)]
  · simp [get_big (show ¬ c < 32 by omega), idxOf]

/-- What a value claims, read against the state after a write to another
register: unchanged. -/
theorem valOK_after {base : Word} {A : AState} {s1 : Machine} {rd : Reg} (hrd0 : rd.toNat ≠ 0)
    {v : AV} (st : Option Int) (v' : AV) (w : Word) (hv : dep rd.toNat v = false) {w1 w2 : Word}
    (h : valOK base A s1 v w1 w2) :
    valOK base (write A rd.toNat v' st) (s1.setReg rd w) v w1 w2 := by
  cases v with
  | lin c1 k1 c2 k2 lo hi =>
    rw [dep_false] at hv
    simp only [valOK] at h ⊢
    rw [read_after hrd0 st v' w hv.1, read_after hrd0 st v' w hv.2]
    exact h
  | _ => exact h

/-- **Writing a register.** With what `v` claims of the two new values, every
register's claim holds afterwards — a counter stepped in place moves the
values affine in it with it. -/
theorem regs_write {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    (rd : Reg) (v : AV) (st : Option Int) (w1 w2 : Word)
    (hv : valOK base A s1 v w1 w2) (hself : dep rd.toNat v = false)
    (hst : ∀ d, st = some d → ∃ x x' : Nat, idxOf base (get A rd.toNat) (s1.reg rd) = some x ∧
        idxOf base v w1 = some x' ∧ (x' : Int) = x + d) :
    ∀ r : Reg, regOK base (write A rd.toNat v st) (s1.setReg rd w1) (s2.setReg rd w2) r := by
  intro r
  by_cases hrd0 : rd = 0
  · subst hrd0
    have : write A (0 : Reg).toNat v st = A := by simp [write]
    rw [this]
    have e1 : s1.setReg 0 w1 = s1 := by simp [Machine.setReg]
    have e2 : s2.setReg 0 w2 = s2 := by simp [Machine.setReg]
    rw [e1, e2]; exact h r
  have hn0 : rd.toNat ≠ 0 := fun e => hrd0 (BitVec.eq_of_toNat_eq (by rw [e]; rfl))
  unfold regOK
  rw [get_write hn0 rd.isLt, reg_setReg, reg_setReg]
  by_cases hr : r = rd
  · rw [ifT (And.intro hr hrd0), ifT (And.intro hr hrd0)]
    have hrn : r.toNat = rd.toNat := by rw [hr]
    by_cases hl : rd.toNat < A.length
    · rw [ifT (And.intro hrn hl), bump_self hself]
      exact valOK_after hn0 st v w1 hself hv
    · rw [ifF (fun x => hl x.2)]
      have : get A r.toNat = .sec := by
        unfold get
        simp [hrn, hn0, rd.isLt, List.getD_eq_getElem?_getD, List.getElem?_eq_none (l := A) (i := rd.toNat) (by omega)]
      rw [this]; trivial
  · have hm : r.toNat ≠ rd.toNat := fun e => hr (BitVec.eq_of_toNat_eq e)
    simp only [hr, false_and, ↓reduceIte, hm]
    have hold := h r
    unfold regOK at hold
    cases hg : get A r.toNat with
    | lin c1 k1 c2 k2 lo hi =>
      rw [hg] at hold
      by_cases hd : c1 = rd.toNat ∨ c2 = rd.toNat
      · simp only [bump, ifT hd]
        cases st with
        | none => exact hold.1
        | some dd =>
          obtain ⟨x, x', hx, hx', hxx⟩ := hst dd rfl
          refine ⟨hold.1, ?_⟩
          have h2 := hold.2
          have hlen : rd.toNat < A.length := by
            rcases Nat.lt_or_ge rd.toNat A.length with hl | hl
            · exact hl
            · exfalso
              have : get A rd.toNat = .sec := by
                unfold get
                simp [hn0, rd.isLt, List.getD_eq_getElem?_getD, List.getElem?_eq_none (l := A) (i := rd.toNat) hl]
              rw [this] at hx; simp [idxOf] at hx
          have rdnew : idxOf base (get (write A rd.toNat v (some dd)) rd.toNat)
              ((s1.setReg rd w1).reg (BitVec.ofNat 5 rd.toNat)) = some x' := by
            rw [get_write hn0 rd.isLt, ifT (And.intro rfl hlen), bump_self hself, ofNat_toNat5, reg_setReg,
              ifT (And.intro rfl hrd0)]
            exact hx'
          have rdold : idxOf base (get A rd.toNat) (s1.reg (BitVec.ofNat 5 rd.toNat)) = some x := by
            rw [ofNat_toNat5]; exact hx
          by_cases e1 : c1 = rd.toNat <;> by_cases e2 : c2 = rd.toNat
          · subst e1; subst e2
            rw [rdnew]; rw [rdold] at h2
            obtain ⟨d, hd1, hd2, hw⟩ := h2
            simp only [↓reduceIte]
            refine ⟨d - (k1 * dd + k2 * dd), by omega, by omega, ?_⟩
            rw [hw]; congr 2; rw [hxx, Int.mul_add, Int.mul_add]; omega
          · subst e1
            rw [rdnew, read_after hn0 (some dd) v w1 e2]; rw [rdold] at h2
            simp only [↓reduceIte, ifF e2]
            revert h2
            cases idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2)) with
            | none => intro; trivial
            | some x2 =>
              intro h2
              obtain ⟨d, hd1, hd2, hw⟩ := h2
              refine ⟨d - (k1 * dd + 0), by omega, by omega, ?_⟩
              rw [hw]; congr 2; rw [hxx, Int.mul_add]; omega
          · subst e2
            rw [rdnew, read_after hn0 (some dd) v w1 e1]; rw [rdold] at h2
            simp only [↓reduceIte, ifF e1]
            revert h2
            cases idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)) with
            | none => intro; trivial
            | some x1 =>
              intro h2
              obtain ⟨d, hd1, hd2, hw⟩ := h2
              refine ⟨d - (0 + k2 * dd), by omega, by omega, ?_⟩
              rw [hw]; congr 2; rw [hxx, Int.mul_add]; omega
          · exact (hd.elim e1 e2).elim
      · simp only [bump, ifF hd]
        exact valOK_after hn0 st v w1 (dep_false.mpr (not_or.mp hd)) hold
    | _ =>
      rw [hg] at hold
      exact valOK_after hn0 st v w1 rfl hold

/-! ## Soundness: addresses and memory -/

theorem int_off (base : Word) (z : Int) (h : 0 ≤ z) :
    base + BitVec.ofInt 32 z = base + BitVec.ofNat 32 z.toNat := by
  rw [← BitVec.ofInt_natCast, Int.toNat_of_nonneg h]

/-- `base + offset + i` as one offset, when it stays in range. -/
theorem off_int (base : Word) (q : Nat) (i : Int) (h : 0 ≤ (q : Int) + i) :
    base + BitVec.ofNat 32 q + BitVec.ofInt 32 i = base + BitVec.ofNat 32 ((q : Int) + i).toNat := by
  rw [BitVec.add_assoc, ← BitVec.ofInt_natCast, ← BitVec.ofInt_add]; exact int_off base _ h

/-- A counter's value lies in its range. -/
theorem counter_range {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {r a b : Nat} (hc : get A r = .num a b ∨ get A r = .ptr a b) :
    ∃ x, idxOf base (get A r) (s1.reg (BitVec.ofNat 5 r)) = some x ∧ a ≤ x ∧ x ≤ b := by
  have hr32 : r < 32 := by
    rcases Nat.lt_or_ge r 32 with h' | h'
    · exact h'
    · rw [get_big (by omega)] at hc; rcases hc with hc | hc <;> cases hc
  have hr := h (BitVec.ofNat 5 r)
  unfold regOK valOK at hr
  rw [get_reg hr32] at hr
  rcases hc with hc | hc <;> rw [hc] at hr ⊢ <;> simp only [idxOf] at hr ⊢
  · exact ⟨_, rfl, hr.2.1, hr.2.2⟩
  · exact ⟨_, rfl, hr.2.1, hr.2.2.1⟩

theorem mul_between {k x a b : Int} (ha : a ≤ x) (hb : x ≤ b) :
    (if 0 ≤ k then k * a else k * b) ≤ k * x ∧ k * x ≤ (if 0 ≤ k then k * b else k * a) := by
  split
  · rename_i hk
    exact ⟨Int.mul_le_mul_of_nonneg_left ha hk, Int.mul_le_mul_of_nonneg_left hb hk⟩
  · rename_i hk
    exact ⟨Int.mul_le_mul_of_nonpos_left (by omega) hb, Int.mul_le_mul_of_nonpos_left (by omega) ha⟩

/-- **The address an access goes to** lies in the range `rangeOf` gives. -/
theorem range_addr {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {v : AV} {w1 w2 : Word} (hv : valOK base A s1 v w1 w2) {i : Int} {size lo hi : Nat}
    (hr : rangeOf A v i size = some (lo, hi)) :
    ∃ o, lo ≤ o ∧ o + size ≤ hi ∧ w1 + BitVec.ofInt 32 i = base + BitVec.ofNat 32 o := by
  cases v with
  | ptr a b =>
    simp only [rangeOf] at hr
    split at hr
    · rename_i hai
      cases hr
      unfold valOK at hv
      obtain ⟨-, h1, h2, -⟩ := hv
      refine ⟨((w1 - base).toNat + i).toNat, by omega, by omega, ?_⟩
      rw [← off_int base _ i (by omega), base_off]
    · cases hr
  | lin c1 k1 c2 k2 lo hi =>
    simp only [rangeOf] at hr
    unfold valOK at hv
    obtain ⟨-, hv⟩ := hv
    have cr : ∀ c, ∀ ab : Nat × Nat, rng A c = some ab →
        ∃ x, idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) = some x ∧ ab.1 ≤ x ∧ x ≤ ab.2 := by
      intro c ab hab
      unfold rng at hab
      cases hg : get A c with
      | num a b => rw [hg] at hab; cases hab; rw [← hg]; exact counter_range h (Or.inl hg)
      | ptr a b => rw [hg] at hab; cases hab; rw [← hg]; exact counter_range h (Or.inr hg)
      | _ => rw [hg] at hab; cases hab
    cases hr1 : rng A c1 with
    | none => rw [hr1] at hr; cases hr
    | some ab1 =>
      cases hr2 : rng A c2 with
      | none => rw [hr1, hr2] at hr; cases hr
      | some ab2 =>
        rw [hr1, hr2] at hr
        obtain ⟨x1, hx1, ha1, hb1⟩ := cr c1 ab1 hr1
        obtain ⟨x2, hx2, ha2, hb2⟩ := cr c2 ab2 hr2
        rw [hx1, hx2] at hv
        obtain ⟨d, hd1, hd2, hw⟩ := hv
        have m1 : tlo k1 ab1 ≤ k1 * x1 ∧ k1 * x1 ≤ thi k1 ab1 :=
          mul_between (k := k1) (Int.ofNat_le.mpr ha1) (Int.ofNat_le.mpr hb1)
        have m2 : tlo k2 ab2 ≤ k2 * x2 ∧ k2 * x2 ≤ thi k2 ab2 :=
          mul_between (k := k2) (Int.ofNat_le.mpr ha2) (Int.ofNat_le.mpr hb2)
        by_cases hnn : 0 ≤ lo + tlo k1 ab1 + tlo k2 ab2 + i
        · simp only [ifT hnn, Option.some.injEq, Prod.mk.injEq] at hr
          obtain ⟨h1, h2⟩ := hr
          subst h1 h2
          refine ⟨(d + k1 * x1 + k2 * x2 + i).toNat, by omega, by omega, ?_⟩
          rw [hw, BitVec.add_assoc, ← BitVec.ofInt_add, int_off base _ (by omega)]
        · simp only [ifF hnn] at hr; cases hr
  | _ => simp [rangeOf] at hr

/-- How far an offset is past another, in the region: no wrap. -/
theorem dist_offs {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {o o' : Nat} (ho : o < 0x10000)
    (ho' : o' < 0x10000) :
    (base + BitVec.ofNat 32 o' - (base + BitVec.ofNat 32 o)).toNat = (2^32 - o + o') % 2^32 := by
  rw [BitVec.toNat_sub, toNat_off hfit _ ho, toNat_off hfit _ ho']
  omega

theorem readLE_congr {m1 m2 : Word → Byte} {a : Word} :
    ∀ n, (∀ d < n, m1 (a + BitVec.ofNat 32 d) = m2 (a + BitVec.ofNat 32 d)) → readLE m1 a n = readLE m2 a n :=
  Rv32.readLE_congr

/-- A store of `n` bytes at offset `o` leaves every other offset alone. -/
theorem writeLE_out {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {o n o' : Nat}
    (v : Nat) (hn : n ≤ 4) (ho1 : o < 0x10000) (ho : o + n ≤ 0x10000) (ho' : o' < 0x10000)
    (hout : o' < o ∨ o + n ≤ o') :
    writeLE m (base + BitVec.ofNat 32 o) v n (base + BitVec.ofNat 32 o') = m (base + BitVec.ofNat 32 o') := by
  rw [writeLE_apply _ _ _ _ (by omega), dist_offs hfit (by omega) ho']
  have : ¬ (2 ^ 32 - o + o') % 2 ^ 32 < n := by
    rcases hout with h | h
    · rw [Nat.mod_eq_of_lt (by omega)]; omega
    · rw [show 2 ^ 32 - o + o' = (o' - o) + 2 ^ 32 by omega, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
      omega
  simp only [this, ↓reduceIte]

/-- The same store into two memories that agreed at `x` leaves them agreeing there. -/
theorem writeLE_same {m1 m2 : Word → Byte} {a x : Word} (v : Nat) {n : Nat} (hn : n ≤ 4) (h : m1 x = m2 x) :
    writeLE m1 a v n x = writeLE m2 a v n x := by
  rw [writeLE_apply _ _ _ _ (by omega), writeLE_apply _ _ _ _ (by omega)]
  split <;> simp_all

/-- HASH's 32 bytes at offset `o` leave every other offset alone. -/
theorem writeBytes_out {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {o o' : Nat}
    (f : Fin 32 → Byte) (ho : o + 32 ≤ 0x10000) (ho' : o' < 0x10000) (hout : o' < o ∨ o + 32 ≤ o') :
    writeBytes m (base + BitVec.ofNat 32 o) f (base + BitVec.ofNat 32 o') = m (base + BitVec.ofNat 32 o') := by
  rw [writeBytes_apply, dist_offs hfit (by omega) ho']
  have : ¬ (2 ^ 32 - o + o') % 2 ^ 32 < 32 := by
    rcases hout with h | h
    · rw [Nat.mod_eq_of_lt (by omega)]; omega
    · rw [show 2 ^ 32 - o + o' = (o' - o) + 2 ^ 32 by omega, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
      omega
  simp only [this, ↓reduceDIte]

/-- Every word is `base` plus its offset; inside the region, the offset is small. -/
theorem in_region {base x : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (h1 : base.toNat ≤ x.toNat)
    (h2 : x.toNat < base.toNat + 0x10000) :
    x = base + BitVec.ofNat 32 (x.toNat - base.toNat) ∧ x.toNat - base.toNat < 0x10000 := by
  refine ⟨?_, by omega⟩
  apply BitVec.eq_of_toNat_eq; rw [toNat_off hfit _ (by omega)]; omega

/-- A change of memory above the program keeps it loaded. -/
theorem code_keep {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr} {m m' : Word → Byte}
    (hlen : 4 * prog.length < 0x10000)
    (h : ∀ o', o' < 4 * prog.length → m' (base + BitVec.ofNat 32 o') = m (base + BitVec.ofNat 32 o'))
    (hc : CodeAt m base prog) : CodeAt m' base prog := by
  refine CodeAt.congr (by omega) (fun x h1 h2 => ?_) hc
  obtain ⟨hx, -⟩ := in_region hfit h1 (by omega)
  rw [hx]; exact (h _ (by omega)).symm

/-! ## Soundness: comparisons -/

theorem get_set {A : AState} {n : Nat} (hn0 : n ≠ 0) (hn : n < 32) (v : AV) (m : Nat) :
    get (A.set n v) m = if m = n ∧ n < A.length then v else get A m := by
  unfold get
  by_cases hm0 : m = 0
  · subst hm0; simp [show ¬ (0 = n) by omega]
  · by_cases hm : m < 32
    · simp only [hm0, hm, ↓reduceIte]
      rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_set]
      by_cases hmn : m = n
      · subst hmn
        by_cases hl : m < A.length <;> simp [hl]
      · simp [Ne.symm hmn, hmn]
    · simp only [hm0, hm, ↓reduceIte, show ¬ m = n by omega, false_and]

/-- A counter narrowed to a smaller range of the same kind: every claim that
held still holds. -/
theorem rel_narrow {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) {r : Reg} (hr0 : r.toNat ≠ 0) {v : AV}
    (hk : sameKind v (get A r.toNat) = true) (hv : valOK base A s1 v (s1.reg r) (s2.reg r)) :
    Rel base prog P (A.set r.toNat v) s1 s2 := by
  refine ⟨fun q => ?_, h.mem, h.code1, h.code2, h.consts1, h.consts2⟩
  have hidx : ∀ c, idxOf base (get (A.set r.toNat v) c) (s1.reg (BitVec.ofNat 5 c))
      = idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) := by
    intro c
    rw [get_set hr0 r.isLt]
    split
    · rename_i hc; rw [hc.1]; exact idxOf_same (by rw [hc.1] at *; exact hk) _ |>.symm ▸ rfl
    · rfl
  have hval : ∀ w w1 w2, valOK base A s1 w w1 w2 → valOK base (A.set r.toNat v) s1 w w1 w2 := by
    intro w w1 w2 hw
    cases w with
    | lin c1 k1 c2 k2 lo hi => exact ⟨hw.1, by rw [hidx, hidx]; exact hw.2⟩
    | _ => exact hw
  unfold regOK
  rw [get_set hr0 r.isLt]
  split
  · rename_i hq
    have : q = r := BitVec.eq_of_toNat_eq hq.1
    subst this; exact hval _ _ _ hv
  · exact hval _ _ _ (h.regs q)

theorem toNat_ne {a b : Word} (h : a ≠ b) : a.toNat ≠ b.toNat := fun e => h (BitVec.eq_of_toNat_eq e)

theorem off_ne {a b base : Word} (h : a ≠ b) : (a - base).toNat ≠ (b - base).toNat := by
  intro e; apply h
  have := BitVec.eq_of_toNat_eq e
  rw [← base_off a base, ← base_off b base, this]

/-- **After a comparison**, what `refine` narrows to holds. -/
theorem rel_refine {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (r1 r2 : Reg) (eq : Bool)
    (hcmp : if eq then s1.reg r1 = s1.reg r2 else s1.reg r1 ≠ s1.reg r2) :
    Rel base prog P (refine A r1 r2 eq) s1 s2 := by
  unfold refine
  split
  · exact h
  rename_i hr0
  have h1 := h.regs r1
  have h2 := h.regs r2
  unfold regOK valOK at h1 h2
  split
  · rename_i lo hi e e' hg1 hg2
    rw [hg1] at h1; rw [hg2] at h2
    split
    · rename_i hee
      subst hee
      cases eq with
      | true =>
        simp only [↓reduceIte] at hcmp ⊢
        refine rel_narrow h hr0 (by rw [hg1]; rfl) ⟨h1.1, ?_, ?_⟩ <;> rw [hcmp] <;> omega
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte] at hcmp ⊢
        have hne := toNat_ne hcmp
        refine rel_narrow h hr0 (by rw [hg1]; rfl) ⟨h1.1, ?_, ?_⟩
        · split <;> omega
        · split <;> omega
    · exact h
  · rename_i lo hi e e' hg1 hg2
    rw [hg1] at h1; rw [hg2] at h2
    split
    · rename_i hee
      subst hee
      cases eq with
      | true =>
        simp only [↓reduceIte] at hcmp ⊢
        refine rel_narrow h hr0 (by rw [hg1]; rfl) ⟨h1.1, ?_, ?_, ?_⟩
        · rw [hcmp]; omega
        · rw [hcmp]; omega
        · omega
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte] at hcmp ⊢
        have hne := off_ne (base := base) hcmp
        refine rel_narrow h hr0 (by rw [hg1]; rfl) ⟨h1.1, ?_, ?_, ?_⟩
        · split <;> omega
        · split <;> omega
        · split <;> omega
    · exact h
  · exact h

theorem get_map {A : AState} {f : AV → AV} (h0 : f (.num 0 0) = .num 0 0) (hs : f .sec = .sec) (m : Nat) :
    get (A.map f) m = f (get A m) := by
  unfold get
  by_cases hm0 : m = 0
  · simp [hm0, h0]
  · by_cases hm : m < 32
    · simp only [hm0, hm, ↓reduceIte]
      rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_map]
      cases A[m]? <;> simp [hs]
    · simp [hm0, hm, hs]

theorem idxOf_normAV {base : Word} (n x : Nat) (w : AV) (y : Word) :
    idxOf base (normAV n x w) y = idxOf base w y := by
  cases w <;> rfl

/-- **Folding a pinned counter in** keeps every claim. -/
theorem rel_norm {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (n : Nat) : Rel base prog P (norm A n) s1 s2 := by
  unfold norm
  cases hx : exactIdx A n with
  | none => exact h
  | some x =>
    simp only
    have gm : ∀ m, get (A.map (normAV n x)) m = normAV n x (get A m) := get_map rfl rfl
    have rd : ∀ c, idxOf base (get (A.map (normAV n x)) c) (s1.reg (BitVec.ofNat 5 c)) =
        idxOf base (get A c) (s1.reg (BitVec.ofNat 5 c)) := fun c => by rw [gm, idxOf_normAV]
    have hxn := exactIdx_val h.regs hx
    refine ⟨fun r => ?_, h.mem, h.code1, h.code2, h.consts1, h.consts2⟩
    have hr := h.regs r
    unfold regOK at hr ⊢
    rw [gm]
    cases hg : get A r.toNat with
    | lin c1 k1 c2 k2 lo hi =>
      rw [hg] at hr
      simp only [normAV, valOK] at hr ⊢
      refine ⟨hr.1, ?_⟩
      have h2 := hr.2
      rw [rd, rd]
      by_cases e1 : c1 = n <;> by_cases e2 : c2 = n
      · subst e1; subst e2
        rw [hxn] at h2
        simp only [↓reduceIte, idx_zero]
        obtain ⟨d, hd1, hd2, hw⟩ := h2
        exact ⟨d + k1 * x + k2 * x, by omega, by omega, by rw [hw]; congr 2; omega⟩
      · subst e1
        rw [hxn] at h2
        simp only [↓reduceIte, ifF e2, idx_zero]
        revert h2
        cases idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2)) with
        | none => intro; trivial
        | some x2 =>
          intro ⟨d, hd1, hd2, hw⟩
          exact ⟨d + k1 * x, by omega, by omega, by rw [hw]; congr 2; omega⟩
      · subst e2
        rw [hxn] at h2
        simp only [↓reduceIte, ifF e1, idx_zero]
        revert h2
        cases idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)) with
        | none => intro h2; simp only at h2 ⊢
        | some x1 =>
          intro ⟨d, hd1, hd2, hw⟩
          exact ⟨d + k2 * x, by omega, by omega, by rw [hw]; congr 2; omega⟩
      · simp only [ifF e1, ifF e2, Int.add_zero]
        exact h2
    | _ => rw [hg] at hr; exact hr

theorem slt_small {x y : Word} (hx : x.toNat < 2 ^ 31) (hy : y.toNat < 2 ^ 31) :
    x.slt y = decide (x.toNat < y.toNat) := by
  rw [BitVec.slt, BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond]
  simp only [show 2 * x.toNat < 2 ^ 32 by omega, show 2 * y.toNat < 2 ^ 32 by omega, ↓reduceIte]
  simp

theorem ult_nat {x y : Word} : x.ult y = decide (x.toNat < y.toNat) := by
  simp [BitVec.ult]

/-- A register whose claim is a number below `ha` holds a number below it. -/
theorem num_small {base : Word} {A : AState} {s1 s2 : Machine} (h : ∀ r : Reg, regOK base A s1 s2 r)
    {a : Reg} {la ha : Nat} (g : get A a.toNat = .num la ha) : la ≤ (s1.reg a).toNat ∧ (s1.reg a).toNat ≤ ha := by
  have := h a
  unfold regOK at this
  rw [g] at this
  exact ⟨this.2.1, this.2.2⟩

/-- **After an ordered comparison**, what `capLe` narrows to holds. -/
theorem rel_cap {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (a b : Reg) (sub : Nat)
    (hc : ∀ la ha lb hb, get A a.toNat = .num la ha → get A b.toNat = .num lb hb → ha < 2 ^ 31 → hb < 2 ^ 31 →
      (s1.reg a).toNat + sub ≤ (s1.reg b).toNat) :
    Rel base prog P (capLe A a b sub) s1 s2 := by
  unfold capLe
  split
  · exact h
  rename_i hr0
  split
  · rename_i la ha lb hb g1 g2
    split
    · rename_i hs
      have ha' := num_small h.regs g1
      have hb' := num_small h.regs g2
      have hab := hc la ha lb hb g1 g2 hs.1 hs.2
      have h1 := h.regs a
      unfold regOK at h1
      rw [g1] at h1
      exact rel_narrow h hr0 (by rw [g1]; rfl) ⟨h1.1, ha'.1, by omega⟩
    · exact h
  · exact h

/-! ## Where a program runs

The checker's soundness asks three things of the world a run is in: `base`
word-aligned, the 64 KiB above it addressed without wrapping, and the
program's own words inside the region, so that fetching one does not fault.
`Placed` gives all three. So does a program placed partway into a larger box,
which `Placed` -- the region exactly the 64 KiB from `base` -- does not. -/

structure Hosted (env : Env) (base : Word) (len : Nat) : Prop where
  align : base.toNat % 4 = 0
  fit : base.toNat + 0x10000 ≤ 2^32
  code : env.region.lo ≤ base.toNat ∧ base.toNat + 4 * len ≤ env.region.hi

theorem _root_.Rv32.Placed.hosted {env : Env} {base : Word} (hp : Placed env base) {len : Nat} (hlen : 4 * len ≤ 0x10000) :
    Hosted env base len :=
  ⟨hp.align, hp.fit, by rw [hp.region]; exact ⟨Nat.le_refl _, Nat.add_le_add_left hlen _⟩⟩

theorem Hosted.fetch_ok {env : Env} {base : Word} {len : Nat} (hh : Hosted env base len) {k : Nat}
    (hk : k < len) (hlen : 4 * len < 0x10000) : env.region.ok (base + BitVec.ofNat 32 (4 * k)) 4 := by
  have := hh.code
  simp only [Region.ok]
  rw [toNat_off hh.fit _ (by omega)]
  omega

/-! ## Soundness: the checker's verdict, one instruction at a time -/

/-- Two runs at one accepted instruction, related as the checker claims there. -/
def AtIn (base : Word) (prog : List Instr) (P : Pub) (H : Heads) (s1 s2 : Machine) : Prop :=
  ∃ k A, k < prog.length ∧ stateAt prog P H k = some A ∧
    s1.pc = base + BitVec.ofNat 32 (4 * k) ∧ s2.pc = base + BitVec.ofNat 32 (4 * k) ∧ Rel base prog P A s1 s2

/-- Two runs at one of the exits, related as the jump there left them. -/
def AtExit (base : Word) (prog : List Instr) (P : Pub) (X : List Nat) (s1 s2 : Machine) : Prop :=
  ∃ t ∈ X, ∃ T, s1.pc = base + BitVec.ofNat 32 (4 * t) ∧ s2.pc = base + BitVec.ofNat 32 (4 * t) ∧
    Rel base prog P T s1 s2

/-- Two runs that step together: on to related states at the same
instruction, or at the same exit, or halted with the same code, or faulted the
same way. -/
def Lock (base : Word) (prog : List Instr) (P : Pub) (H : Heads) (X : List Nat) :
    Outcome → Outcome → Prop
  | .running s1, .running s2 => AtIn base prog P H s1 s2 ∨ AtExit base prog P X s1 s2
  | .halted c1 _, .halted c2 _ => c1 = c2
  | .fault f1 _, .fault f2 _ => f1 = f2
  | _, _ => False

theorem check_len {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} (hc : checkX prog P H X = true) :
    4 * prog.length < 0x10000 := by
  unfold checkX at hc
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
  exact hc.1.1

theorem check_at {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} (hc : checkX prog P H X = true)
    {k : Nat} (hk : k < prog.length) {A : AState} (hA : stateAt prog P H k = some A) :
    ∃ post, transfer prog.length P k A prog[k] = some post ∧ succOK prog.length H X k post = true := by
  unfold checkX at hc
  simp only [Bool.and_eq_true, List.all_eq_true, List.mem_range] at hc
  have := hc.2 k hk
  rw [hA, List.getElem?_eq_getElem hk] at this
  simp only at this
  split at this
  · rename_i post hpost; exact ⟨post, hpost, this⟩
  · cases this

theorem check_entry {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} (hc : checkX prog P H X = true) :
    ∃ B, stateAt prog P H 0 = some B ∧ ∀ base s1 s2, Rel base prog P entry s1 s2 → Rel base prog P B s1 s2 := by
  unfold checkX at hc
  simp only [Bool.and_eq_true] at hc
  have h0 := hc.1.2
  unfold stateAt
  revert h0
  cases head H 0 with
  | none => intro; exact ⟨entry, rfl, fun _ _ _ h => h⟩
  | some B => intro h0; exact ⟨B, rfl, fun _ _ _ h => rel_mono h0 h⟩

theorem stateAt_head {prog : List Instr} {P : Pub} {H : Heads} {t : Nat} {B : AState}
    (h : head H t = some B) : stateAt prog P H t = some B := by
  cases t with
  | zero => simp only [stateAt, h]
  | succ t => simp only [stateAt, h]

/-- Falling through: the next instruction exists, and what holds after this
one holds of what is claimed there. -/
theorem succ_fall {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} {k : Nat} (hk : k < prog.length)
    {A : AState} (hA : stateAt prog P H k = some A) {post : Post}
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {F : AState} (hF : post.fall = some F) :
    k + 1 < prog.length ∧ ∃ B, stateAt prog P H (k + 1) = some B ∧
      ∀ base s1 s2, Rel base prog P F s1 s2 → Rel base prog P B s1 s2 := by
  unfold succOK at hs
  rw [hF] at hs
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hs
  refine ⟨hs.1.1, ?_⟩
  have h2 := hs.1.2
  cases hh : head H (k + 1) with
  | some B =>
    rw [hh] at h2
    exact ⟨B, stateAt_head hh, fun _ _ _ h => rel_mono h2 h⟩
  | none =>
    refine ⟨F, ?_, fun _ _ _ h => h⟩
    simp only [stateAt, hh, hA, List.getElem?_eq_getElem hk, htr, Option.bind_some, hF]

/-- Jumping: the target exists, is a head, and what holds after this
instruction holds of what is claimed there. -/
theorem succ_jump {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} {k : Nat}
    {post : Post} (hs : succOK prog.length H X k post = true) {t : Nat} {T : AState} (hT : post.jump = some (t, T)) :
    (t < prog.length ∧ ∃ B, stateAt prog P H t = some B ∧
      ∀ base s1 s2, Rel base prog P T s1 s2 → Rel base prog P B s1 s2) ∨ t ∈ X := by
  unfold succOK at hs
  rw [hT] at hs
  simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq] at hs
  rcases hs.2 with ⟨h1, h2⟩ | hx
  · left
    refine ⟨h1, ?_⟩
    cases hh : head H t with
    | some B =>
      rw [hh] at h2
      exact ⟨B, stateAt_head hh, fun _ _ _ h => rel_mono h2 h⟩
    | none => rw [hh] at h2; cases h2
  · right
    simpa using hx

/-! ## Soundness: what each kind of instruction computes -/

theorem toNat_add_int (x : Word) (d : Int) (h1 : 0 ≤ (x.toNat : Int) + d) (h2 : (x.toNat : Int) + d < 2 ^ 32) :
    (x + BitVec.ofInt 32 d).toNat = ((x.toNat : Int) + d).toNat := by
  have e : x + BitVec.ofInt 32 d = BitVec.ofInt 32 ((x.toNat : Int) + d) := by
    rw [BitVec.ofInt_add, BitVec.ofInt_natCast, BitVec.ofNat_toNat, BitVec.setWidth_eq]
  rw [e, BitVec.toNat_ofInt, Int.emod_eq_of_lt h1 (by simpa using h2)]

theorem off_of (base : Word) (m : Nat) (hm : m < 2 ^ 32) : (base + BitVec.ofNat 32 m - base).toNat = m := by
  rw [BitVec.add_comm, BitVec.add_sub_cancel, BitVec.toNat_ofNat]; omega

/-- An offset stepped by `d`: still `base` plus an offset, `d` further on. -/
theorem off_step (base x : Word) (d : Int) (h1 : 0 ≤ ((x - base).toNat : Int) + d)
    (h2 : ((x - base).toNat : Int) + d < 0x10000) :
    (x + BitVec.ofInt 32 d - base).toNat = (((x - base).toNat : Int) + d).toNat := by
  rw [show x + BitVec.ofInt 32 d = base + BitVec.ofNat 32 (x - base).toNat + BitVec.ofInt 32 d by rw [base_off],
    off_int base _ d h1, off_of base _ (by omega)]

theorem addi_ok {base : Word} {A : AState} {s1 : Machine} (rd : Nat) {src : AV} {x1 x2 : Word}
    (h : valOK base A s1 src x1 x2) (d : Int) :
    valOK base A s1 (addiAV rd src d) (x1 + BitVec.ofInt 32 d) (x2 + BitVec.ofInt 32 d) := by
  cases src with
  | sec => trivial
  | pub => exact (show x1 + _ = x2 + _ by rw [show x1 = x2 from h])
  | num lo hi =>
    unfold valOK at h
    simp only [addiAV]
    split
    · rename_i hc
      refine ⟨by rw [h.1], ?_, ?_⟩ <;> rw [toNat_add_int _ _ (by omega) (by omega)] <;> omega
    · exact (show x1 + _ = x2 + _ by rw [h.1])
  | ptr lo hi =>
    unfold valOK at h
    simp only [addiAV]
    split
    · rename_i hc
      refine ⟨by rw [h.1], ?_, ?_, by omega⟩ <;> rw [off_step _ _ _ (by omega) (by omega)] <;> omega
    · exact (show x1 + _ = x2 + _ by rw [h.1])
  | lin c1 k1 c2 k2 lo hi =>
    unfold valOK at h
    simp only [addiAV]
    split
    · exact (show x1 + _ = x2 + _ by rw [h.1])
    · simp only [valOK]
      refine ⟨by rw [h.1], ?_⟩
      have h2 := h.2
      revert h2
      cases idxOf base (get A c1) (s1.reg (BitVec.ofNat 5 c1)) <;>
        cases idxOf base (get A c2) (s1.reg (BitVec.ofNat 5 c2))
      all_goals try (intro; trivial)
      intro ⟨d0, hd1, hd2, hw⟩
      refine ⟨d0 + d, by omega, by omega, ?_⟩
      rw [hw, BitVec.add_assoc, ← BitVec.ofInt_add]
      congr 2; omega

/-- A counter stepped in place by `addi`: its new value is the old one plus `d`. -/
theorem addi_idx {base : Word} {A : AState} {s1 : Machine} (rd : Nat) {src : AV} {x1 x2 : Word}
    (h : valOK base A s1 src x1 x2) (d : Int) (hc : isCounter src = true)
    (hc' : isCounter (addiAV rd src d) = true) :
    ∃ x x' : Nat, idxOf base src x1 = some x ∧ idxOf base (addiAV rd src d) (x1 + BitVec.ofInt 32 d) = some x' ∧
      (x' : Int) = x + d := by
  cases src with
  | num lo hi =>
    unfold valOK at h
    simp only [addiAV] at hc' ⊢
    split
    · rename_i hcond
      refine ⟨x1.toNat, (x1 + BitVec.ofInt 32 d).toNat, rfl, rfl, ?_⟩
      rw [toNat_add_int _ _ (by omega) (by omega)]; omega
    · rename_i hcond; rw [ifF hcond] at hc'; cases hc'
  | ptr lo hi =>
    unfold valOK at h
    simp only [addiAV] at hc' ⊢
    split
    · rename_i hcond
      refine ⟨(x1 - base).toNat, (x1 + BitVec.ofInt 32 d - base).toNat, rfl, rfl, ?_⟩
      rw [off_step _ _ _ (by omega) (by omega)]; omega
    · rename_i hcond; rw [ifF hcond] at hc'; cases hc'
  | _ => cases hc

/-- `add` of an offset and a number, and everything else of public values. -/
theorem op_ok {base : Word} {A : AState} {s1 : Machine} (op : ROp) {v1 v2 : AV} {x1 x2 y1 y2 : Word}
    (h1 : valOK base A s1 v1 x1 x2) (h2 : valOK base A s1 v2 y1 y2) :
    valOK base A s1 (opAV op v1 v2) (aluR op x1 y1) (aluR op x2 y2) := by
  unfold opAV
  split
  · rename_i a b c d
    unfold valOK at h1 h2
    split
    · rename_i hbd
      simp only [aluR]
      have hx : x1 + y1 = base + BitVec.ofNat 32 ((x1 - base).toNat + y1.toNat) := by
        rw [BitVec.ofNat_add, ← BitVec.add_assoc, base_off, BitVec.ofNat_toNat, BitVec.setWidth_eq]
      refine ⟨by rw [h1.1, h2.1], ?_, ?_, by omega⟩ <;> rw [hx, off_of base _ (by omega)] <;> omega
    · show aluR .add x1 y1 = aluR .add x2 y2
      rw [h1.1, h2.1]
  · split
    · rename_i hp
      show aluR op x1 y1 = aluR op x2 y2
      have e1 : x1 = x2 := by cases v1 <;> simp_all [isPub, valOK]
      have e2 : y1 = y2 := by cases v2 <;> simp_all [isPub, valOK]
      rw [e1, e2]
    · trivial

/-- Any operation of one public value is public. -/
theorem pub_ok {base : Word} {A : AState} {s1 : Machine} {v : AV} {x1 x2 : Word} (h : valOK base A s1 v x1 x2)
    (f : Word → Word) : valOK base A s1 (if isPub v = true then .pub else .sec) (f x1) (f x2) := by
  split
  · rename_i hp
    show f x1 = f x2
    have e : x1 = x2 := by cases v <;> simp_all [isPub, valOK]
    rw [e]
  · trivial

/-- A shift, as `shAV` says. -/
theorem sh_ok {base : Word} {A : AState} {s1 : Machine} {v : AV} {x1 x2 : Word} (h : valOK base A s1 v x1 x2)
    (op : ShOp) (s : Nat) : valOK base A s1 (shAV op v s) (shiftI op x1 s) (shiftI op x2 s) := by
  cases op <;> cases v
  case srli.num lo hi =>
    unfold valOK at h
    simp only [shAV, valOK, shiftI, BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    exact ⟨by rw [h.1], Nat.div_le_div_right h.2.1, Nat.div_le_div_right h.2.2⟩
  all_goals exact pub_ok h (fun x => shiftI _ x s)

theorem shAV_self (op : ShOp) (v : AV) (s rd : Nat) : dep rd (shAV op v s) = false := by
  unfold shAV; split <;> (try split) <;> rfl

/-! ## Soundness: states after a step -/

theorem rel_write {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (rd : Reg) (v : AV) (st : Option Int) (w1 w2 : Word)
    (hv : valOK base A s1 v w1 w2) (hself : dep rd.toNat v = false)
    (hst : ∀ d, st = some d → ∃ x x' : Nat, idxOf base (get A rd.toNat) (s1.reg rd) = some x ∧
        idxOf base v w1 = some x' ∧ (x' : Int) = x + d) :
    Rel base prog P (write A rd.toNat v st) (s1.setReg rd w1).next (s2.setReg rd w2).next :=
  ⟨regs_write h.regs rd v st w1 w2 hv hself hst,
   fun o h1 h2 => by simp only [next_mem, setReg_mem]; exact h.mem o h1 h2,
   by simp only [next_mem, setReg_mem]; exact h.code1,
   by simp only [next_mem, setReg_mem]; exact h.code2,
   by simp only [next_mem, setReg_mem]; exact h.consts1,
   by simp only [next_mem, setReg_mem]; exact h.consts2⟩

theorem rel_pc {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (p1 p2 : Word) : Rel base prog P A (s1.setPc p1) (s2.setPc p2) :=
  ⟨h.regs, h.mem, h.code1, h.code2, h.consts1, h.consts2⟩

theorem rel_mem {base : Word} {prog : List Instr} {P : Pub} {A : AState} {s1 s2 : Machine}
    (h : Rel base prog P A s1 s2) (m1 m2 : Word → Byte)
    (hm : ∀ o, o < 0x10000 → InP prog.length P o → m1 (base + BitVec.ofNat 32 o) = m2 (base + BitVec.ofNat 32 o))
    (hc1 : CodeAt m1 base prog) (hc2 : CodeAt m2 base prog)
    (hk1 : ∀ c ∈ P.consts, readLE m1 (base + BitVec.ofNat 32 c.1) 4 = c.2)
    (hk2 : ∀ c ∈ P.consts, readLE m2 (base + BitVec.ofNat 32 c.1) 4 = c.2) :
    Rel base prog P A ({ s1 with mem := m1 } : Machine).next ({ s2 with mem := m2 } : Machine).next :=
  ⟨h.regs, hm, hc1, hc2, hk1, hk2⟩

theorem lock_fall {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr}
    {P : Pub} {H : Heads} {X : List Nat} (hlen : 4 * prog.length < 0x10000) {k : Nat} (hk : k < prog.length)
    {A : AState} (hA : stateAt prog P H k = some A) {post : Post}
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {F : AState} (hF : post.fall = some F) {s1 s2 : Machine} (hr : Rel base prog P F s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k) + 4) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k) + 4) :
    Lock base prog P H X (.running s1) (.running s2) := by
  obtain ⟨hk1, B, hB, hFB⟩ := succ_fall hk hA htr hs hF
  refine Or.inl ⟨k + 1, B, hk1, hB, ?_, ?_, hFB base s1 s2 hr⟩
  · rw [hp1]; exact pc_next hfit k (by omega)
  · rw [hp2]; exact pc_next hfit k (by omega)

theorem lock_jump {base : Word} {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat} {k : Nat}
    {post : Post} (hs : succOK prog.length H X k post = true) {t : Nat} {T : AState}
    (hT : post.jump = some (t, T)) {s1 s2 : Machine} (hr : Rel base prog P T s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * t)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * t)) :
    Lock base prog P H X (.running s1) (.running s2) := by
  rcases succ_jump (P := P) hs hT with ⟨ht, B, hB, hTB⟩ | hx
  · exact Or.inl ⟨t, B, ht, hB, hp1, hp2, hTB base s1 s2 hr⟩
  · exact Or.inr ⟨t, hx, T, hp1, hp2, hr⟩

/-- A branch's target, as an offset: four times the instruction it names. -/
theorem br_target (base : Word) (k : Nat) (off : BitVec 12) (h0 : 0 ≤ 4 * (k : Int) + boff off)
    (h4 : (4 * (k : Int) + boff off) % 4 = 0) :
    base + BitVec.ofNat 32 (4 * k) + (off ++ 0#1).signExtend 32
      = base + BitVec.ofNat 32 (4 * ((4 * (k : Int) + boff off) / 4).toNat) := by
  rw [boff_eq]
  have h0' : 0 ≤ ((4 * k : Nat) : Int) + boff off := by push_cast; exact h0
  rw [off_int base (4 * k) (boff off) h0']
  congr 2
  have e := Int.mul_ediv_add_emod (4 * (k : Int) + boff off) 4
  push_cast
  generalize 4 * (k : Int) + boff off = z at h0 h4 e ⊢
  omega

/-! ## Soundness: one step, by kind of instruction

Each lemma: the two runs at instruction `k` in a related state, the checker
having accepted it; the two steps lock. -/

section
variable {env : Env} {base : Word} {prog : List Instr} {P : Pub} {H : Heads} {X : List Nat}
  {k : Nat} {A : AState} {s1 s2 : Machine} {post : Post}

theorem lock_reg (hfit : base.toNat + 0x10000 ≤ 2^32) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    (rd : Reg) (v : AV) (st : Option Int) (hF : post.fall = some (write A rd.toNat v st)) (w1 w2 : Word)
    (hv : valOK base A s1 v w1 w2) (hself : dep rd.toNat v = false)
    (hst : ∀ d, st = some d → ∃ x x' : Nat, idxOf base (get A rd.toNat) (s1.reg rd) = some x ∧
        idxOf base v w1 = some x' ∧ (x' : Int) = x + d) :
    Lock base prog P H X (.running (s1.setReg rd w1).next) (.running (s2.setReg rd w2).next) :=
  lock_fall hfit hlen hk hA htr hs hF (rel_write h rd v st w1 w2 hv hself hst)
    (by simp [hp1]) (by simp [hp2])

theorem addiAV_self (rd : Nat) (src : AV) (d : Int) : dep rd (addiAV rd src d) = false := by
  cases src with
  | lin c1 k1 c2 k2 lo hi =>
    simp only [addiAV]
    split
    · rfl
    · rename_i hr; exact dep_false.mpr (not_or.mp hr)
  | num lo hi => simp only [addiAV]; split <;> rfl
  | ptr lo hi => simp only [addiAV]; split <;> rfl
  | _ => rfl

theorem opAV_self (op : ROp) (v1 v2 : AV) (rd : Nat) : dep rd (opAV op v1 v2) = false := by
  unfold opAV
  split
  · split <;> rfl
  · split <;> rfl

theorem lock_opi (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : IOp} {rd r1 : Reg} {imm : BitVec 12} (hi : prog[k] = .opi op rd r1 imm) :
    Lock base prog P H X (exec env s1 (.opi op rd r1 imm)) (exec env s2 (.opi op rd r1 imm)) := by
  have ht := htr
  rw [hi] at ht
  simp only [exec]
  cases op with
  | addi =>
    simp only [transfer, Option.some.injEq] at ht
    subst ht
    simp only [aluI, se_sext]
    refine lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ _ rfl _ _
      (addi_ok rd.toNat (h.regs r1) (sext imm)) (addiAV_self _ _ _) ?_
    intro d hd
    split at hd
    · rename_i hc
      cases hd
      obtain ⟨he, hc1, hc2⟩ := hc
      subst he
      exact addi_idx r1.toNat (h.regs r1) (sext imm) hc1 hc2
    · cases hd
  | _ =>
    simp only [transfer, Option.some.injEq] at ht
    subst ht
    exact lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _
      (pub_ok (h.regs r1) (fun x => aluI _ x (BitVec.signExtend 32 imm)))
      (by split <;> rfl) (fun _ e => by cases e)

theorem lock_sh (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : ShOp} {rd r1 : Reg} {sa : BitVec 5} (hi : prog[k] = .sh op rd r1 sa) :
    Lock base prog P H X (exec env s1 (.sh op rd r1 sa)) (exec env s2 (.sh op rd r1 sa)) := by
  have ht := htr
  rw [hi] at ht
  simp only [transfer, Option.some.injEq] at ht
  subst ht
  exact lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _
    (sh_ok (h.regs r1) op sa.toNat) (shAV_self _ _ _ _) (fun _ e => by cases e)

theorem lock_op (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : ROp} {rd r1 r2 : Reg} (hi : prog[k] = .op op rd r1 r2) :
    Lock base prog P H X (exec env s1 (.op op rd r1 r2)) (exec env s2 (.op op rd r1 r2)) := by
  have ht := htr
  rw [hi] at ht
  simp only [transfer, Option.some.injEq] at ht
  subst ht
  exact lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _ (op_ok op (h.regs r1) (h.regs r2))
    (opAV_self _ _ _ _) (fun _ e => by cases e)

theorem lock_lui (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {rd : Reg} {imm : BitVec 20} (hi : prog[k] = .lui rd imm) :
    Lock base prog P H X (exec env s1 (.lui rd imm)) (exec env s2 (.lui rd imm)) := by
  have ht := htr
  rw [hi] at ht
  simp only [transfer, Option.some.injEq] at ht
  subst ht
  exact lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _ ⟨rfl, Nat.le_refl _, Nat.le_refl _⟩
    rfl (fun _ e => by cases e)

theorem lock_auipc (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {rd : Reg} {imm : BitVec 20} (hi : prog[k] = .auipc rd imm) :
    Lock base prog P H X (exec env s1 (.auipc rd imm)) (exec env s2 (.auipc rd imm)) := by
  have ht := htr
  rw [hi] at ht
  simp only [transfer, Option.some.injEq] at ht
  subst ht
  simp only [exec]
  refine lock_reg hp.fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _ ?_ (by split <;> rfl)
    (fun _ e => by cases e)
  split
  · rename_i hc
    obtain ⟨h0, h4⟩ := hc
    subst h0
    rw [hp1, hp2, show ((0 : BitVec 20) ++ 0#12) = 0#32 by decide, BitVec.add_zero]
    exact ⟨rfl, by rw [off_of base _ (by omega)]; exact Nat.le_refl _, by rw [off_of base _ (by omega)]; exact Nat.le_refl _, h4⟩
  · show _ = _
    rw [hp1, hp2]

theorem lock_br (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : BrOp} {r1 r2 : Reg} {off : BitVec 12} (hi : prog[k] = .br op r1 r2 off) :
    Lock base prog P H X (exec env s1 (.br op r1 r2 off)) (exec env s2 (.br op r1 r2 off)) := by
  have ht := htr
  rw [hi] at ht
  simp only [transfer] at ht
  split at ht
  case isFalse => cases ht
  rename_i hc
  obtain ⟨hpub1, hpub2, h0, h4⟩ := hc
  have e1 := regOK_eq (h.regs r1) hpub1
  have e2 := regOK_eq (h.regs r2) hpub2
  simp only [exec]
  rw [← e1, ← e2]
  have tgt : ∀ s : Machine, s.pc = base + BitVec.ofNat 32 (4 * k) →
      (s.setPc (s.pc + (off ++ 0#1).signExtend 32)).pc
        = base + BitVec.ofNat 32 (4 * ((4 * (k : Int) + boff off) / 4).toNat) := by
    intro s hs; simp only [setPc_pc, hs]; exact br_target base k off h0 h4
  have nxt : ∀ s : Machine, s.pc = base + BitVec.ofNat 32 (4 * k) →
      s.next.pc = base + BitVec.ofNat 32 (4 * k) + 4 := by
    intro s hs; simp only [next_pc, hs]
  cases op with
  | bne =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .bne (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      have hcmp : s1.reg r1 ≠ s1.reg r2 := by simpa [taken] using hT
      exact lock_jump hs rfl (rel_pc (rel_norm (rel_refine h r1 r2 false (by simpa using hcmp)) _) _ _) (tgt s1 hp1) (tgt s2 hp2)
    · rw [ifF hT, ifF hT]
      have hcmp : s1.reg r1 = s1.reg r2 := by simpa [taken] using hT
      exact lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_norm (rel_refine h r1 r2 true (by simpa using hcmp)) _) _ _)
        (nxt s1 hp1) (nxt s2 hp2)
  | beq =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .beq (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      have hcmp : s1.reg r1 = s1.reg r2 := by simpa [taken] using hT
      exact lock_jump hs rfl (rel_pc (rel_norm (rel_refine h r1 r2 true (by simpa using hcmp)) _) _ _) (tgt s1 hp1) (tgt s2 hp2)
    · rw [ifF hT, ifF hT]
      have hcmp : s1.reg r1 ≠ s1.reg r2 := by simpa [taken] using hT
      exact lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_norm (rel_refine h r1 r2 false (by simpa using hcmp)) _) _ _)
        (nxt s1 hp1) (nxt s2 hp2)
  | blt =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .blt (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      refine lock_jump hs rfl (rel_pc (rel_cap h r1 r2 1 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (tgt s1 hp1) (tgt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
    · rw [ifF hT, ifF hT]
      refine lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_cap h r2 r1 0 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (nxt s1 hp1) (nxt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
  | bltu =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .bltu (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      refine lock_jump hs rfl (rel_pc (rel_cap h r1 r2 1 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (tgt s1 hp1) (tgt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
    · rw [ifF hT, ifF hT]
      refine lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_cap h r2 r1 0 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (nxt s1 hp1) (nxt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
  | bge =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .bge (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      refine lock_jump hs rfl (rel_pc (rel_cap h r2 r1 0 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (tgt s1 hp1) (tgt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
    · rw [ifF hT, ifF hT]
      refine lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_cap h r1 r2 1 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (nxt s1 hp1) (nxt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
  | bgeu =>
    simp only [Option.some.injEq] at ht
    subst ht
    by_cases hT : taken .bgeu (s1.reg r1) (s1.reg r2) = true
    · rw [ifT hT, ifT hT]
      refine lock_jump hs rfl (rel_pc (rel_cap h r2 r1 0 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (tgt s1 hp1) (tgt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)
    · rw [ifF hT, ifF hT]
      refine lock_fall hp.fit hlen hk hA htr hs rfl (rel_pc (rel_cap h r1 r2 1 fun la ha lb hb g1 g2 b1 b2 => ?_) _ _) (nxt s1 hp1) (nxt s2 hp2)
      have := num_small h.regs g1; have := num_small h.regs g2
      simp only [taken] at hT
      first
        | (rw [slt_small (by omega) (by omega)] at hT; simp at hT; omega)
        | (rw [ult_nat] at hT; simp at hT; omega)

/-- Every byte of a public range is public. -/
theorem pub_inP {len : Nat} {P : Pub} {lo hi : Nat} (h : pubRange len P lo hi = true)
    {o : Nat} (h1 : lo ≤ o) (h2 : o < hi) : InP len P o := by
  unfold pubRange within at h
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, List.any_eq_true] at h
  rcases h with h | ⟨ab, hab, h⟩
  · left; omega
  · right; exact ⟨ab, hab, by omega, by omega⟩

theorem lock_ld (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : LdOp} {rd r1 : Reg} {imm : BitVec 12} (hi : prog[k] = .ld op rd r1 imm) :
    Lock base prog P H X (exec env s1 (.ld op rd r1 imm)) (exec env s2 (.ld op rd r1 imm)) := by
  have fit := hp.fit
  have ht := htr
  rw [hi] at ht
  simp only [transfer] at ht
  split at ht
  case isFalse => cases ht
  rename_i hpub
  simp only [Option.some.injEq] at ht
  subst ht
  have e1 := regOK_eq (h.regs r1) hpub
  simp only [exec]
  rw [← e1]
  split
  · rfl
  split
  · rfl
  refine lock_reg fit hlen hk hA h hp1 hp2 htr hs rd _ none rfl _ _ ?_
    (by unfold ldAV; split <;> (try split) <;> (try split) <;> (try split) <;> rfl) (fun _ e => by cases e)
  have pubcase : ∀ lo hi', rangeOf A (get A r1.toNat) (sext imm) op.size = some (lo, hi') →
      valOK base A s1 (if hi' ≤ 0x10000 ∧ pubRange prog.length P lo hi' = true then .pub else .sec)
        (op.extend (readLE s1.mem (s1.reg r1 + imm.signExtend 32) op.size))
        (op.extend (readLE s2.mem (s1.reg r1 + imm.signExtend 32) op.size)) := by
    intro lo hi' hr
    split
    · rename_i hc
      show op.extend (readLE s1.mem _ op.size) = op.extend (readLE s2.mem _ op.size)
      congr 1
      obtain ⟨o, hlo, hhi, ha⟩ := range_addr h.regs (h.regs r1) hr
      rw [se_sext, ha]
      apply readLE_congr
      intro d hd
      rw [off_add fit o d (by omega)]
      exact h.mem _ (by omega) (pub_inP hc.2 (by omega) (by omega))
    · trivial
  unfold ldAV
  split
  · rename_i lo hi' hr
    split
    · rename_i c hfind
      split
      · rename_i hc
        obtain ⟨h4, hhi, hc2⟩ := hc
        have hcm : c ∈ P.consts := List.mem_of_find?_eq_some hfind
        have hcl : c.1 = lo := by simpa using List.find?_some hfind
        have hop : op = .lw := by cases op <;> simp_all [LdOp.size]
        subst hop
        obtain ⟨o, hlo, hhi', ha⟩ := range_addr h.regs (h.regs r1) hr
        have ho : o = c.1 := by simp [LdOp.size] at hhi'; omega
        have e1 : readLE s1.mem (s1.reg r1 + imm.signExtend 32) 4 = c.2 := by
          rw [se_sext, ha, ho]; exact h.consts1 c hcm
        have e2 : readLE s2.mem (s1.reg r1 + imm.signExtend 32) 4 = c.2 := by
          rw [se_sext, ha, ho]; exact h.consts2 c hcm
        simp only [LdOp.size, LdOp.extend, valOK, e1, e2, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hc2]
        exact ⟨trivial, Nat.le_refl _, Nat.le_refl _⟩
      · exact pubcase lo hi' hr
    · exact pubcase lo hi' hr
  · trivial

theorem apartK_out {P : Pub} {lo hi : Nat} (hk : apartK P lo hi = true) {c : Nat × Nat} (hc : c ∈ P.consts) :
    c.1 + 4 ≤ 0x10000 ∧ (hi ≤ c.1 ∨ c.1 + 4 ≤ lo) := by
  unfold apartK at hk
  have := List.all_eq_true.mp hk c hc
  simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq] at this
  exact this

/-- A write that misses every byte of a word leaves what the word reads. -/
theorem readLE_kept {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte} {c : Nat}
    (hc : c + 4 ≤ 0x10000)
    (h : ∀ d < 4, m' (base + BitVec.ofNat 32 (c + d)) = m (base + BitVec.ofNat 32 (c + d))) :
    readLE m' (base + BitVec.ofNat 32 c) 4 = readLE m (base + BitVec.ofNat 32 c) 4 := by
  apply readLE_congr
  intro d hd
  rw [off_add hfit c d (by omega)]
  exact h d hd

theorem rangeOf_pub {A : AState} {v : AV} {i : Int} {n : Nat} {r : Nat × Nat} (h : rangeOf A v i n = some r) :
    isPub v = true := by
  cases v <;> simp_all [rangeOf, isPub]

/-- What a range that meets no public place leaves out of a public offset. -/
theorem apart_out {len : Nat} {P : Pub} {lo hi o n o' : Nat} (hap : apart P.places lo hi = true)
    (hlo : 4 * len ≤ lo) (h1 : lo ≤ o) (h2 : o + n ≤ hi) (hin : InP len P o') : o' < o ∨ o + n ≤ o' := by
  unfold apart at hap
  rw [List.all_eq_true] at hap
  rcases hin with hin | ⟨ab, hab, ha1, ha2⟩
  · left; omega
  · have := hap ab hab
    simp only [Bool.or_eq_true, decide_eq_true_eq] at this
    omega

theorem lock_st (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    {op : StOp} {r1 r2 : Reg} {imm : BitVec 12} (hi : prog[k] = .st op r1 r2 imm) :
    Lock base prog P H X (exec env s1 (.st op r1 r2 imm)) (exec env s2 (.st op r1 r2 imm)) := by
  have fit := hp.fit
  have ht := htr
  rw [hi] at ht
  simp only [transfer] at ht
  split at ht
  case h_2 => cases ht
  rename_i lo hi' hr
  split at ht
  case isFalse => cases ht
  rename_i hc
  simp only [Option.some.injEq] at ht
  subst ht
  obtain ⟨hlo, hhi, hkk, hdata⟩ := hc
  have e1 := regOK_eq (h.regs r1) (rangeOf_pub hr)
  have hsz : 1 ≤ op.size ∧ op.size ≤ 4 := by cases op <;> decide
  obtain ⟨o, h1, h2, ha⟩ := range_addr h.regs (h.regs r1) hr
  simp only [exec]
  rw [← e1]
  split
  · rfl
  split
  · rfl
  rw [se_sext, ha]
  have hout : ∀ (m : Word → Byte) (v : Nat) o', o' < 4 * prog.length →
      writeLE m (base + BitVec.ofNat 32 o) v op.size (base + BitVec.ofNat 32 o') = m (base + BitVec.ofNat 32 o') :=
    fun m v o' ho' => writeLE_out fit m v hsz.2 (by omega) (by omega) (by omega) (Or.inl (by omega))
  have kept : ∀ (m : Word → Byte) (v : Nat), (∀ c ∈ P.consts, readLE m (base + BitVec.ofNat 32 c.1) 4 = c.2) →
      ∀ c ∈ P.consts, readLE (writeLE m (base + BitVec.ofNat 32 o) v op.size) (base + BitVec.ofNat 32 c.1) 4 = c.2 := by
    intro m v hm c hc
    obtain ⟨hc4, hap⟩ := apartK_out hkk hc
    rw [readLE_kept fit hc4 (fun d hd => writeLE_out fit m v hsz.2 (by omega) (by omega) (by omega) (by omega))]
    exact hm c hc
  refine lock_fall fit hlen hk hA htr hs rfl (rel_mem h _ _ ?_ (code_keep fit hlen (hout _ _) h.code1)
    (code_keep fit hlen (hout _ _) h.code2) (kept _ _ h.consts1) (kept _ _ h.consts2)) (by simp [hp1]) (by simp [hp2])
  intro o' ho' hin
  rcases hdata with hpub | hap
  · rw [regOK_eq (h.regs r2) hpub]
    exact writeLE_same _ hsz.2 (h.mem o' ho' hin)
  · have hx := apart_out hap hlo h1 h2 hin
    rw [writeLE_out fit _ _ hsz.2 (by omega) (by omega) ho' hx,
      writeLE_out fit _ _ hsz.2 (by omega) (by omega) ho' hx]
    exact h.mem o' ho' hin

theorem lock_ecall (hp : Hosted env base prog.length) (hlen : 4 * prog.length < 0x10000)
    (hk : k < prog.length) (hA : stateAt prog P H k = some A) (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k))
    (htr : transfer prog.length P k A prog[k] = some post) (hs : succOK prog.length H X k post = true)
    (hi : prog[k] = .ecall) :
    Lock base prog P H X (exec env s1 .ecall) (exec env s2 .ecall) := by
  have fit := hp.fit
  have ht := htr
  rw [hi] at ht
  simp only [transfer] at ht
  have hT := h.regs T0
  unfold regOK valOK at hT
  rw [show T0.toNat = 5 from rfl] at hT
  simp only [exec, syscall]
  split at ht
  · rename_i hg
    rw [hg] at hT
    have t1 : s1.reg T0 = 0 := BitVec.eq_of_toNat_eq (by have := hT.2; simp; omega)
    rw [← hT.1, t1]
    by_cases hsv : env.servesHash = true
    case neg => simp [hsv, Lock]
    simp only [hsv, and_true, ↓reduceIte]
    split at ht
    case isFalse => cases ht
    rename_i hc
    obtain ⟨hp0, hp1', hdst⟩ := hc
    simp only [Option.some.injEq] at ht
    subst ht
    rw [← regOK_eq (h.regs A0) hp0, ← regOK_eq (h.regs A1) hp1']
    unfold hashDst at hdst
    split at hdst
    case h_2 => cases hdst
    rename_i lo hi' hr
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hdst
    obtain ⟨⟨⟨hlo, hhi⟩, hap⟩, hkk⟩ := hdst
    have e2 := regOK_eq (h.regs A2) (rangeOf_pub hr)
    rw [← e2]
    obtain ⟨o, h1, h2, ha⟩ := range_addr h.regs (h.regs A2) hr
    rw [show BitVec.ofInt 32 0 = 0#32 by decide, BitVec.add_zero] at ha
    split
    · rw [ha]
      have hout : ∀ (m : Word → Byte) (f : Fin 32 → Byte) o', o' < 4 * prog.length →
          writeBytes m (base + BitVec.ofNat 32 o) f (base + BitVec.ofNat 32 o') = m (base + BitVec.ofNat 32 o') :=
        fun m f o' ho' => writeBytes_out fit m f (by omega) (by omega) (Or.inl (by omega))
      have kept : ∀ (m : Word → Byte) (f : Fin 32 → Byte),
          (∀ c ∈ P.consts, readLE m (base + BitVec.ofNat 32 c.1) 4 = c.2) →
          ∀ c ∈ P.consts, readLE (writeBytes m (base + BitVec.ofNat 32 o) f) (base + BitVec.ofNat 32 c.1) 4 = c.2 := by
        intro m f hm c hc
        obtain ⟨hc4, hapk⟩ := apartK_out hkk hc
        rw [readLE_kept fit hc4 (fun d hd => writeBytes_out fit m f (by omega) (by omega) (by omega))]
        exact hm c hc
      refine lock_fall fit hlen hk hA htr hs rfl (rel_mem h _ _ ?_ (code_keep fit hlen (hout _ _) h.code1)
        (code_keep fit hlen (hout _ _) h.code2) (kept _ _ h.consts1) (kept _ _ h.consts2)) (by simp [hp1]) (by simp [hp2])
      intro o' ho' hin
      have hx := apart_out hap hlo h1 h2 hin
      rw [writeBytes_out fit _ _ (by omega) ho' hx, writeBytes_out fit _ _ (by omega) ho' hx]
      exact h.mem o' ho' hin
    · rfl
  · rename_i hg
    rw [hg] at hT
    have t1 : s1.reg T0 = 1 := BitVec.eq_of_toNat_eq (by have := hT.2; simp; omega)
    rw [← hT.1, t1]
    simp only [show (1 : Word) ≠ 0 by decide, false_and, ↓reduceIte]
    split at ht
    case isFalse => cases ht
    rename_i hp0
    exact regOK_eq (h.regs A0) hp0
  · cases ht

end

/-! ## Soundness: one step, and every step -/

/-- **One step.** Two related runs at an instruction the checker accepted take
it together. -/
theorem step_lock {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length) {P : Pub}
    {H : Heads} {X : List Nat} (hc : checkX prog P H X = true) {k : Nat} (hk : k < prog.length) {A : AState}
    (hA : stateAt prog P H k = some A) {s1 s2 : Machine} (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k)) :
    Lock base prog P H X (step env s1) (step env s2) := by
  have fit := hp.fit
  have hlen := check_len hc
  obtain ⟨post, htr, hs⟩ := check_at hc hk hA
  rw [step_of_code hk h.code1 hp1 (by rw [hp1]; exact align_off hp.align fit _ (by omega) (by omega))
      (by rw [hp1]; exact hp.fetch_ok hk hlen),
    step_of_code hk h.code2 hp2 (by rw [hp2]; exact align_off hp.align fit _ (by omega) (by omega))
      (by rw [hp2]; exact hp.fetch_ok hk hlen)]
  cases hi : prog[k] with
  | lui rd imm => exact lock_lui hp hlen hk hA h hp1 hp2 htr hs hi
  | auipc rd imm => exact lock_auipc hp hlen hk hA h hp1 hp2 htr hs hi
  | jal rd off => rw [hi] at htr; simp [transfer] at htr
  | jalr rd r1 imm => rw [hi] at htr; simp [transfer] at htr
  | br op r1 r2 off => exact lock_br hp hlen hk hA h hp1 hp2 htr hs hi
  | ld op rd r1 imm => exact lock_ld hp hlen hk hA h hp1 hp2 htr hs hi
  | st op r1 r2 imm => exact lock_st hp hlen hk hA h hp1 hp2 htr hs hi
  | opi op rd r1 imm => exact lock_opi hp hlen hk hA h hp1 hp2 htr hs hi
  | sh op rd r1 sa => exact lock_sh hp hlen hk hA h hp1 hp2 htr hs hi
  | op op rd r1 r2 => exact lock_op hp hlen hk hA h hp1 hp2 htr hs hi
  | ecall => exact lock_ecall hp hlen hk hA h hp1 hp2 htr hs hi

/-- What an observer of the core sees an instruction do: the address it loads
or stores, HASH's arguments, the code HALT is given. -/
def access (s : Machine) : Instr → List Word
  | .ld _ _ r1 imm => [s.reg r1 + imm.signExtend 32]
  | .st _ r1 _ imm => [s.reg r1 + imm.signExtend 32]
  | .ecall => if s.reg T0 = 0 then [s.reg T0, s.reg A0, s.reg A1, s.reg A2] else [s.reg T0, s.reg A0]
  | _ => []

/-- One step, observed: where it is, and what it touches. -/
def obs (env : Env) (s : Machine) : Word × List Word :=
  match fetch env s with
  | .ok i => (s.pc, access s i)
  | .error _ => (s.pc, [])

/-- `n` steps, observed: the `pc` of each, and what each touches. -/
def trace (env : Env) : Nat → Machine → List (Word × List Word)
  | 0, _ => []
  | n + 1, s => obs env s :: match step env s with
    | .running s' => trace env n s'
    | _ => []

/-- The same kind of outcome: both running, or both halted with one code, or
both faulted the same way. -/
def Same : Outcome → Outcome → Prop
  | .running _, .running _ => True
  | .halted c1 _, .halted c2 _ => c1 = c2
  | .fault f1 _, .fault f2 _ => f1 = f2
  | _, _ => False

/-- One step, observed the same in both runs. -/
theorem obs_eq {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length) {P : Pub}
    {H : Heads} {X : List Nat} (hc : checkX prog P H X = true) {k : Nat} (hk : k < prog.length) {A : AState}
    (hA : stateAt prog P H k = some A) {s1 s2 : Machine} (h : Rel base prog P A s1 s2)
    (hp1 : s1.pc = base + BitVec.ofNat 32 (4 * k)) (hp2 : s2.pc = base + BitVec.ofNat 32 (4 * k)) :
    obs env s1 = obs env s2 := by
  have fit := hp.fit
  have hlen := check_len hc
  obtain ⟨post, htr, -⟩ := check_at hc hk hA
  unfold obs
  rw [fetch_of_code hk h.code1 hp1 (by rw [hp1]; exact align_off hp.align fit _ (by omega) (by omega))
      (by rw [hp1]; exact hp.fetch_ok hk hlen),
    fetch_of_code hk h.code2 hp2 (by rw [hp2]; exact align_off hp.align fit _ (by omega) (by omega))
      (by rw [hp2]; exact hp.fetch_ok hk hlen)]
  simp only
  rw [hp1, hp2]
  congr 1
  cases hi : prog[k] with
  | ld op rd r1 imm =>
    rw [hi] at htr; simp only [transfer] at htr
    split at htr
    · rename_i hpub; simp only [access]; rw [regOK_eq (h.regs r1) hpub]
    · cases htr
  | st op r1 r2 imm =>
    rw [hi] at htr; simp only [transfer] at htr
    split at htr
    · rename_i lo hi' hr; simp only [access]; rw [regOK_eq (h.regs r1) (rangeOf_pub hr)]
    · cases htr
  | ecall =>
    rw [hi] at htr; simp only [transfer] at htr
    have hT := h.regs T0
    unfold regOK valOK at hT
    rw [show T0.toNat = 5 from rfl] at hT
    simp only [access]
    split at htr
    · rename_i hg
      rw [hg] at hT
      split at htr
      · rename_i hcd
        obtain ⟨hp0, hp1', hdst⟩ := hcd
        unfold hashDst at hdst
        split at hdst
        · rename_i lo hi' hr
          rw [hT.1, regOK_eq (h.regs A0) hp0, regOK_eq (h.regs A1) hp1', regOK_eq (h.regs A2) (rangeOf_pub hr)]
        · cases hdst
      · cases htr
    · rename_i hg
      rw [hg] at hT
      have t1 : s1.reg T0 = 1 := BitVec.eq_of_toNat_eq (by have := hT.2; simp; omega)
      split at htr
      · rename_i hp0
        rw [← hT.1, t1, ifF (by decide), ifF (by decide), regOK_eq (h.regs A0) hp0]
      · cases htr
    · cases htr
  | _ => rfl

/-- **Every step.** From related states at an accepted instruction, `n` steps
are observed the same in both runs and end the same way. -/
theorem run_lock {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length) {P : Pub}
    {H : Heads} (hc : check prog P H = true) :
    ∀ n k A s1 s2, k < prog.length → stateAt prog P H k = some A → Rel base prog P A s1 s2 →
      s1.pc = base + BitVec.ofNat 32 (4 * k) → s2.pc = base + BitVec.ofNat 32 (4 * k) →
      trace env n s1 = trace env n s2 ∧ Same (run env n s1) (run env n s2) := by
  intro n
  induction n with
  | zero => intros; exact ⟨rfl, trivial⟩
  | succ n ih =>
    intro k A s1 s2 hk hA h hp1 hp2
    have ho := obs_eq (env := env) hp hc hk hA h hp1 hp2
    have hl := step_lock (env := env) hp hc hk hA h hp1 hp2
    simp only [trace, run]
    revert hl
    cases step env s1 <;> cases step env s2 <;> simp only [Lock] <;> intro hl
    · rcases hl with ⟨k', A', hk', hA', q1, q2, h'⟩ | ⟨t, ht, -⟩
      · obtain ⟨t, r⟩ := ih k' A' _ _ hk' hA' h' q1 q2
        exact ⟨by rw [ho, t], r⟩
      · simp at ht
    all_goals first | exact hl.elim | exact ⟨by rw [ho], hl⟩

/-! ## The theorem -/

theorem get_entry_all : ∀ n, n < 32 → n = 0 ∨ get entry n = .pub := by decide

theorem get_entry (n : Nat) (h0 : n ≠ 0) (h : n < 32) : get entry n = .pub := by
  rcases get_entry_all n h with e | e
  · exact absurd e h0
  · exact e

/-- **Constant time.** For a program the checker accepts, with public places
`P`: two runs from `base` that start with the same registers and the same
bytes in the program and in `P` — and anything at all elsewhere — are observed
the same at every step: the same `pc`, the same address loaded or stored, the
same HASH arguments, the same halt code. -/
theorem constant_time {env : Env} {base : Word} (hp : Placed env base) {prog : List Instr}
    {P : Pub} {H : Heads} (hc : check prog P H = true) (hne : 0 < prog.length)
    (s1 s2 : Machine) (hpc1 : s1.pc = base) (hpc2 : s2.pc = base) (hregs : ∀ r, s1.reg r = s2.reg r)
    (hmem : ∀ o, o < 0x10000 → InP prog.length P o →
      s1.mem (base + BitVec.ofNat 32 o) = s2.mem (base + BitVec.ofNat 32 o))
    (hcode : CodeAt s1.mem base prog)
    (hk1 : ∀ c ∈ P.consts, readLE s1.mem (base + BitVec.ofNat 32 c.1) 4 = c.2 := by intro c hc; cases hc)
    (hk2 : ∀ c ∈ P.consts, readLE s2.mem (base + BitVec.ofNat 32 c.1) 4 = c.2 := by intro c hc; cases hc) :
    ∀ n, trace env n s1 = trace env n s2 ∧ Same (run env n s1) (run env n s2) := by
  have fit := hp.fit
  have hlen := check_len hc
  have hcode2 : CodeAt s2.mem base prog := by
    refine CodeAt.congr (by omega) (fun x h1 h2 => ?_) hcode
    obtain ⟨hx, -⟩ := in_region fit h1 (by omega)
    rw [hx]; exact hmem _ (by omega) (Or.inl (by omega))
  have h0 : Rel base prog P entry s1 s2 := by
    refine ⟨fun r => ?_, hmem, hcode, hcode2, hk1, hk2⟩
    unfold regOK
    by_cases hr0 : r.toNat = 0
    · have : r = 0 := BitVec.eq_of_toNat_eq hr0
      subst this; exact regOK_zero
    · rw [get_entry r.toNat hr0 r.isLt]; exact hregs r
  obtain ⟨B, hB, hEB⟩ := check_entry hc
  intro n
  exact run_lock (hp.hosted (by omega)) hc n 0 B s1 s2 hne hB (hEB base s1 s2 h0) (by simp [hpc1]) (by simp [hpc2])

/-- **From the state the shell builds**: two images whose bytes agree in the
program and in `P`. -/
theorem constant_time_boot {env : Env} {base : Word} (hp : Placed env base) {prog : List Instr}
    {P : Pub} {H : Heads} (hc : check prog P H = true) (hne : 0 < prog.length)
    (img1 img2 : ByteArray)
    (hmem : ∀ o, o < 0x10000 → InP prog.length P o →
      memOfImage base img1 (base + BitVec.ofNat 32 o) = memOfImage base img2 (base + BitVec.ofNat 32 o))
    (hcode : CodeAt (memOfImage base img1) base prog)
    (hk1 : ∀ c ∈ P.consts, readLE (memOfImage base img1) (base + BitVec.ofNat 32 c.1) 4 = c.2 := by
      intro c hc; cases hc)
    (hk2 : ∀ c ∈ P.consts, readLE (memOfImage base img2) (base + BitVec.ofNat 32 c.1) 4 = c.2 := by
      intro c hc; cases hc) :
    ∀ n, trace env n (boot env.region img1) = trace env n (boot env.region img2)
      ∧ Same (run env n (boot env.region img1)) (run env n (boot env.region img2)) := by
  have hb : ∀ img, (boot env.region img).pc = base ∧ (boot env.region img).mem = memOfImage base img := by
    intro img; simp [boot, hp.region]
  exact constant_time hp hc hne _ _ (hb img1).1 (hb img2).1 (fun r => rfl)
    (by rw [(hb img1).2, (hb img2).2]; exact hmem) (by rw [(hb img1).2]; exact hcode)
    (by rw [(hb img1).2]; exact hk1) (by rw [(hb img2).2]; exact hk2)

/-! ## Every state on the way

`run_lock` is about what the two runs are seen to do and how they end. The
relation it carries holds at every step as well, and with the two runs one and
the same, that says what a single run of an accepted program can reach: one of
the program's instructions, with the program still in memory and every
register what the checker's state there says. That includes `t0` at an
`ecall`. The checker lets an `ecall` through only as HASH (`t0 = 0`) or HALT
(`t0 = 1`), so at an `ecall` where it knows `t0` is 1, the run makes no call
but HALT. -/

/-- **Every step, still locked.** From related states at an accepted
instruction, after any `n` steps the two runs are both running, related, at one
accepted instruction; or they ended the same way. -/
theorem lock_run {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length) {P : Pub}
    {H : Heads} (hc : check prog P H = true) :
    ∀ n k A s1 s2, k < prog.length → stateAt prog P H k = some A → Rel base prog P A s1 s2 →
      s1.pc = base + BitVec.ofNat 32 (4 * k) → s2.pc = base + BitVec.ofNat 32 (4 * k) →
      Lock base prog P H [] (run env n s1) (run env n s2) := by
  intro n
  induction n with
  | zero => intro k A s1 s2 hk hA h hp1 hp2; exact Or.inl ⟨k, A, hk, hA, hp1, hp2, h⟩
  | succ n ih =>
    intro k A s1 s2 hk hA h hp1 hp2
    have hl := step_lock (env := env) hp hc hk hA h hp1 hp2
    simp only [run]
    revert hl
    cases step env s1 <;> cases step env s2 <;> simp only [Lock] <;> intro hl
    · rcases hl with ⟨k', A', hk', hA', q1, q2, h'⟩ | ⟨t, ht, -⟩
      · exact ih k' A' _ _ hk' hA' h' q1 q2
      · simp at ht
    all_goals first | exact hl.elim | exact hl

/-- Every `ecall` the checker reaches, it reaches knowing `t0` is 1. -/
def haltsOnly (prog : List Instr) (P : Pub) (H : Heads) : Bool :=
  (List.range prog.length).all fun k =>
    match prog[k]?, stateAt prog P H k with
    | some .ecall, some A => get A 5 == .num 1 1
    | _, _ => true

theorem haltsOnly_at {prog : List Instr} {P : Pub} {H : Heads} (hq : haltsOnly prog P H = true)
    {k : Nat} (hk : k < prog.length) {A : AState} (hA : stateAt prog P H k = some A) (hi : prog[k] = .ecall) :
    get A 5 = .num 1 1 := by
  unfold haltsOnly at hq
  simp only [List.all_eq_true, List.mem_range] at hq
  have := hq k hk
  rw [List.getElem?_eq_getElem hk, hi, hA] at this
  simpa using this

/-- **The run calls nothing but HALT.** A program the checker accepts, every
`ecall` of which it reaches knowing `t0 = 1`, run from `base` with the program
in memory: every state the run reaches while it is still running is at one of
the program's instructions, the program is still in memory, and at an `ecall`
`t0` is 1. -/
theorem ecalls_halt {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length)
    {P : Pub} {H : Heads} (hc : check prog P H = true) (hq : haltsOnly prog P H = true)
    (hne : 0 < prog.length) {s : Machine} (hpc : s.pc = base) (hcode : CodeAt s.mem base prog)
    (hkc : ∀ c ∈ P.consts, readLE s.mem (base + BitVec.ofNat 32 c.1) 4 = c.2 := by intro c hc; cases hc) :
    ∀ n s', run env n s = .running s' → ∃ k, ∃ hk : k < prog.length,
      s'.pc = base + BitVec.ofNat 32 (4 * k) ∧ CodeAt s'.mem base prog ∧
      (prog[k] = .ecall → s'.reg T0 = 1) := by
  intro n s' hr
  have h0 : Rel base prog P entry s s := by
    refine ⟨fun r => ?_, fun _ _ _ => rfl, hcode, hcode, hkc, hkc⟩
    unfold regOK
    by_cases hr0 : r.toNat = 0
    · have : r = 0 := BitVec.eq_of_toNat_eq hr0
      subst this; exact regOK_zero
    · rw [get_entry r.toNat hr0 r.isLt]; rfl
  obtain ⟨B, hB, hEB⟩ := check_entry hc
  have hl := lock_run (env := env) hp hc n 0 B s s hne hB (hEB base s s h0) (by simp [hpc]) (by simp [hpc])
  rw [hr] at hl
  rcases hl with ⟨k, A, hk, hA, q1, -, h'⟩ | ⟨t, ht, -⟩
  case inr => simp at ht
  refine ⟨k, hk, q1, h'.code1, fun hi => ?_⟩
  have hT := h'.regs T0
  unfold regOK valOK at hT
  rw [show T0.toNat = 5 from rfl, haltsOnly_at hq hk hA hi] at hT
  exact BitVec.eq_of_toNat_eq (by have := hT.2; simp; omega)

end Rv32.Ct
