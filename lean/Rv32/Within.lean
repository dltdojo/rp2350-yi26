/-
SPDX-License-Identifier: Apache-2.0

# A run inside a smaller region is the same run in a larger one

The region only ever says no: a fetch, a load, a store or `HASH` outside it is
a fault, and nothing inside it depends on where its edges are. So a run that
went on, or halted, with the region `[lo, hi)` goes on, or halts, the same way
with any region holding `[lo, hi)`.

That is what lets two kernels proved each in its own 64 KiB — each from its
own first instruction, as `Placed` has it — run as one, in a region holding
both (exp223: exp222's health tests, then exp208's SHA-256 at 0x1000).
-/
import Rv32.Place

namespace Rv32

/-- `r` lies inside `r'`. -/
def Region.within (r r' : Region) : Prop := r'.lo ≤ r.lo ∧ r.hi ≤ r'.hi

theorem Region.ok_within {r r' : Region} (h : r.within r') {a : Word} {n : Nat} (hok : r.ok a n) :
    r'.ok a n := by
  simp only [Region.ok, Region.within] at *; omega

variable {env env' : Env}

/-- One instruction: what a smaller region lets go on, or halt, a larger one
lets go on or halt the same way. -/
theorem step_within (hh : env.hash = env'.hash) (hr : env.region.within env'.region) {s : Machine} :
    (∀ s', step env s = .running s' → step env' s = .running s') ∧
    (∀ c s', step env s = .halted c s' → step env' s = .halted c s') := by
  have fetch_eq : ∀ i, fetch env s = .ok i → fetch env' s = .ok i := by
    intro i h
    unfold fetch at h ⊢
    by_cases ha : s.pc.toNat % 4 ≠ 0
    · simp [ha] at h
    · by_cases hok : env.region.ok s.pc 4
      · simp only [ha, hok, not_true_eq_false, ↓reduceIte] at h
        simp only [ha, Region.ok_within hr hok, not_true_eq_false, ↓reduceIte]
        exact h
      · simp [ha, hok] at h
  unfold step
  cases hf : fetch env s with
  | error f => simp
  | ok i =>
    rw [fetch_eq i hf]
    simp only
    cases i with
    | ld op rd rs1 imm =>
      dsimp only [exec]
      by_cases ha : (s.reg rs1 + imm.signExtend 32).toNat % op.size ≠ 0
      · simp only [eq_true ha, ↓reduceIte]; exact ⟨nofun, nofun⟩
      · by_cases hok : env.region.ok (s.reg rs1 + imm.signExtend 32) op.size
        · have hok' := Region.ok_within hr hok
          simp only [eq_false ha, hok, hok', not_true_eq_false, ↓reduceIte]
          exact ⟨fun _ h => h, fun _ _ h => h⟩
        · simp only [eq_false ha, eq_true hok, ↓reduceIte]; exact ⟨nofun, nofun⟩
    | st op rs1 rs2 imm =>
      dsimp only [exec]
      by_cases ha : (s.reg rs1 + imm.signExtend 32).toNat % op.size ≠ 0
      · simp only [eq_true ha, ↓reduceIte]; exact ⟨nofun, nofun⟩
      · by_cases hok : env.region.ok (s.reg rs1 + imm.signExtend 32) op.size
        · have hok' := Region.ok_within hr hok
          simp only [eq_false ha, hok, hok', not_true_eq_false, ↓reduceIte]
          exact ⟨fun _ h => h, fun _ _ h => h⟩
        · simp only [eq_false ha, eq_true hok, ↓reduceIte]; exact ⟨nofun, nofun⟩
    | ecall =>
      simp only [exec, syscall]
      by_cases h0 : s.reg T0 = 0
      · by_cases hargs : (s.reg A1).toNat % 64 = 0 ∧ (s.reg A0).toNat % 4 = 0 ∧ (s.reg A2).toNat % 4 = 0
            ∧ env.region.ok (s.reg A0) (s.reg A1).toNat ∧ env.region.ok (s.reg A2) 32
        · have hargs' : (s.reg A1).toNat % 64 = 0 ∧ (s.reg A0).toNat % 4 = 0 ∧ (s.reg A2).toNat % 4 = 0
              ∧ env'.region.ok (s.reg A0) (s.reg A1).toNat ∧ env'.region.ok (s.reg A2) 32 :=
            ⟨hargs.1, hargs.2.1, hargs.2.2.1, Region.ok_within hr hargs.2.2.2.1,
              Region.ok_within hr hargs.2.2.2.2⟩
          simp only [h0, ↓reduceIte, hargs, hargs', hh, and_self]
          exact ⟨fun _ h => h, fun _ _ h => h⟩
        · simp only [h0, ↓reduceIte, hargs]
          exact ⟨nofun, nofun⟩
      · simp only [h0, ↓reduceIte]
        exact ⟨fun _ h => h, fun _ _ h => h⟩
    | _ => simp [exec]

/-- **A run inside a smaller region**: a run that is still going, or has
halted, after `n` instructions with `env`'s region does the same, to the same
machine, with any region holding it. -/
theorem run_within (hh : env.hash = env'.hash) (hr : env.region.within env'.region) :
    ∀ (n : Nat) (s : Machine),
      (∀ s', run env n s = .running s' → run env' n s = .running s') ∧
      (∀ c s', run env n s = .halted c s' → run env' n s = .halted c s') := by
  intro n
  induction n with
  | zero => intro s; exact ⟨fun _ h => h, nofun⟩
  | succ n ih =>
    intro s
    obtain ⟨hrun, hhalt⟩ := step_within hh hr (s := s)
    simp only [run]
    cases hs : step env s with
    | running s1 =>
      rw [hrun s1 hs]
      exact ih s1
    | halted c s1 =>
      rw [hhalt c s1 hs]
      exact ⟨fun _ h => h, fun _ _ h => h⟩
    | fault f s1 => exact ⟨nofun, nofun⟩

/-! ## A 128 KiB region, holding a kernel's 64 KiB

exp223 wrote these for its two kernels in one region, and exp224's judge,
run in the same region, needed them second. -/

/-- What the theorems assume about where the kernel is: `Placed`, with the
region 128 KiB. -/
structure Wide (env : Env) (base : Word) : Prop where
  align : base.toNat % 4 = 0
  fit : base.toNat + 0x20000 ≤ 2^32
  region : env.region = ⟨base.toNat, base.toNat + 0x20000⟩

/-- The same world with only the region's first 64 KiB: where `Placed`
proofs are about. -/
def low (env : Env) (base : Word) : Env := { env with region := ⟨base.toNat, base.toNat + 0x10000⟩ }

namespace Wide

variable {env : Env} {base : Word}

theorem fit64 (hw : Wide env base) : base.toNat + 0x10000 ≤ 2^32 := by have := hw.fit; omega

theorem placed (hw : Wide env base) : Placed (low env base) base := ⟨hw.align, hw.fit64, rfl⟩

theorem within (hw : Wide env base) : (low env base).region.within env.region := by
  simp only [low, Region.within, hw.region]; omega

/-- A run in the first 64 KiB that is still going is the same run in the 128. -/
theorem running (hw : Wide env base) {n : Nat} {s s' : Machine} (h : run (low env base) n s = .running s') :
    run env n s = .running s' := (run_within (env := low env base) (env' := env) rfl hw.within n s).1 s' h

/-- And one that halted. -/
theorem halted (hw : Wide env base) {n : Nat} {c : Word} {s s' : Machine}
    (h : run (low env base) n s = .halted c s') : run env n s = .halted c s' :=
  (run_within (env := low env base) (env' := env) rfl hw.within n s).2 c s' h

end Wide

#print axioms run_within

end Rv32
