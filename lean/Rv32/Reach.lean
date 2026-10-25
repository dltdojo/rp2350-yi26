/-
SPDX-License-Identifier: Apache-2.0

# Where a run can reach

`Ct`'s checker is an abstract interpretation of two runs at once; its relation,
read with the two runs one and the same, says what a single run can reach. This
file reads it that way, for three facts a kernel's outcome theorem does not
give and a monitor's box needs:

  * **every load and every store lands in a window**, offsets from `base` the
    checker computes: `windowed` checks it, by `decide`, at every instruction
    the checker reaches;
  * **every `ecall` is a HALT**: `haltsOnly`, `Ct`'s;
  * **the program is still in memory**, so the next instruction is the
    program's: `Ct`'s `Rel` carries it.

A run may leave the program at one of the checker's exits `X` -- a branch to
another program, checked on its own -- and `reach_until` says the facts hold of
every state up to the first exit, and where that exit is. `Good` is the facts,
of one state.

For a single run, "public" is not a restriction: with every place public the
checker refuses nothing for being secret, and is left checking what this file
is about.
-/
import Rv32.Ct
import Rv32.Sandbox

namespace Rv32.Reach
open Rv32 Rv32.Ct

/-! ## The windows -/

/-- Every load a run can reach is known to read inside `lw`, and every store to
write inside `sw`: offsets from `base`, `[lo, hi)`. -/
def windowed (prog : List Instr) (P : List (Nat × Nat)) (H : Heads) (lw sw : Nat × Nat) : Bool :=
  (List.range prog.length).all fun k =>
    match stateAt prog P H k, prog[k]? with
    | some A, some (.ld op _ r1 imm) =>
      match rangeOf A (get A r1.toNat) (sext imm) op.size with
      | some ab => within ab.1 ab.2 lw
      | none => false
    | some A, some (.st op r1 _ imm) =>
      match rangeOf A (get A r1.toNat) (sext imm) op.size with
      | some ab => within ab.1 ab.2 sw
      | none => false
    | _, _ => true

/-- What an instruction touches, from machine `m`: a load inside `lw`, a store
inside `sw`. -/
def Touches (base : Word) (lw sw : Nat × Nat) (m : Machine) : Instr → Prop
  | .ld op _ r1 imm => ∃ o, lw.1 ≤ o ∧ o + op.size ≤ lw.2 ∧ m.reg r1 + imm.signExtend 32 = base + BitVec.ofNat 32 o
  | .st op r1 _ imm => ∃ o, sw.1 ≤ o ∧ o + op.size ≤ sw.2 ∧ m.reg r1 + imm.signExtend 32 = base + BitVec.ofNat 32 o
  | _ => True

theorem windowed_ld {prog : List Instr} {P : List (Nat × Nat)} {H : Heads} {lw sw : Nat × Nat}
    (hw : windowed prog P H lw sw = true) {k : Nat} (hk : k < prog.length) {A : AState}
    (hA : stateAt prog P H k = some A) {op : LdOp} {rd r1 : Reg} {imm : BitVec 12}
    (hi : prog[k] = .ld op rd r1 imm) :
    ∃ lo hi, rangeOf A (get A r1.toNat) (sext imm) op.size = some (lo, hi) ∧ lw.1 ≤ lo ∧ hi ≤ lw.2 := by
  unfold windowed at hw
  simp only [List.all_eq_true, List.mem_range] at hw
  have := hw k hk
  rw [hA, List.getElem?_eq_getElem hk, hi] at this
  simp only at this
  split at this
  · rename_i ab hab
    simp only [within, Bool.and_eq_true, decide_eq_true_eq] at this
    exact ⟨ab.1, ab.2, hab, this.1, this.2⟩
  · cases this

theorem windowed_st {prog : List Instr} {P : List (Nat × Nat)} {H : Heads} {lw sw : Nat × Nat}
    (hw : windowed prog P H lw sw = true) {k : Nat} (hk : k < prog.length) {A : AState}
    (hA : stateAt prog P H k = some A) {op : StOp} {r1 r2 : Reg} {imm : BitVec 12}
    (hi : prog[k] = .st op r1 r2 imm) :
    ∃ lo hi, rangeOf A (get A r1.toNat) (sext imm) op.size = some (lo, hi) ∧ sw.1 ≤ lo ∧ hi ≤ sw.2 := by
  unfold windowed at hw
  simp only [List.all_eq_true, List.mem_range] at hw
  have := hw k hk
  rw [hA, List.getElem?_eq_getElem hk, hi] at this
  simp only at this
  split at this
  · rename_i ab hab
    simp only [within, Bool.and_eq_true, decide_eq_true_eq] at this
    exact ⟨ab.1, ab.2, hab, this.1, this.2⟩
  · cases this

/-! ## One state -/

/-- **What the checker says of one state of a run**: it is at instruction `k` of
the program, the program is in memory, the step is that instruction's, what it
loads or stores is inside its window, and an `ecall` is at `t0 = 1`. -/
def Good (env : Env) (base : Word) (prog : List Instr) (lw sw : Nat × Nat) (m : Machine) : Prop :=
  ∃ k, ∃ hk : k < prog.length, m.pc = base + BitVec.ofNat 32 (4 * k) ∧ CodeAt m.mem base prog ∧
    step env m = exec env m prog[k] ∧ Touches base lw sw m prog[k] ∧ (prog[k] = .ecall → m.reg T0 = 1)

theorem good_of_at {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length)
    {P : List (Nat × Nat)} {H : Heads} {X : List Nat} (hc : checkX prog P H X = true)
    {lw sw : Nat × Nat} (hw : windowed prog P H lw sw = true) (hq : haltsOnly prog P H = true)
    {m : Machine} (h : AtIn base prog P H m m) : Good env base prog lw sw m := by
  obtain ⟨k, A, hk, hA, hp1, -, hr⟩ := h
  have hlen := check_len hc
  have fit := hp.fit
  refine ⟨k, hk, hp1, hr.code1, ?_, ?_, fun hi => ?_⟩
  · exact step_of_code hk hr.code1 hp1 (by rw [hp1]; exact align_off hp.align fit _ (by omega) (by omega))
      (by rw [hp1]; exact hp.fetch_ok hk hlen)
  · cases hi : prog[k] with
    | ld op rd r1 imm =>
      obtain ⟨lo, hi', hr', h1, h2⟩ := windowed_ld hw hk hA hi
      obtain ⟨o, o1, o2, e⟩ := range_addr hr.regs (hr.regs r1) hr'
      exact ⟨o, by omega, by omega, by rw [se_sext]; exact e⟩
    | st op r1 r2 imm =>
      obtain ⟨lo, hi', hr', h1, h2⟩ := windowed_st hw hk hA hi
      obtain ⟨o, o1, o2, e⟩ := range_addr hr.regs (hr.regs r1) hr'
      exact ⟨o, by omega, by omega, by rw [se_sext]; exact e⟩
    | _ => trivial
  · have hT := hr.regs T0
    unfold regOK valOK at hT
    rw [show T0.toNat = 5 from rfl, haltsOnly_at hq hk hA hi] at hT
    exact BitVec.eq_of_toNat_eq (by have := hT.2; simp; omega)

/-! ## Every state, up to the first exit -/

/-- **Every state up to the first exit is `Good`.** From a state at an accepted
instruction, related to itself: either every state of the first `n` steps is
`Good`, or the run is at one of the exits after some `j ≤ n` steps -- related as
the jump there left it -- and every state before that is `Good`. -/
theorem reach_until {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length)
    {P : List (Nat × Nat)} {H : Heads} {X : List Nat} (hc : checkX prog P H X = true)
    {lw sw : Nat × Nat} (hw : windowed prog P H lw sw = true) (hq : haltsOnly prog P H = true) :
    ∀ n m, AtIn base prog P H m m →
      (∀ i ≤ n, ∀ m', run env i m = .running m' → Good env base prog lw sw m') ∨
      (∃ j, j ≤ n ∧ ∃ m', run env j m = .running m' ∧ AtExit base prog P X m' m' ∧
        ∀ i < j, ∀ m'', run env i m = .running m'' → Good env base prog lw sw m'') := by
  intro n
  induction n with
  | zero =>
    intro m h
    left
    intro i hi m' hm
    rw [show i = 0 by omega] at hm
    simp only [run, Outcome.running.injEq] at hm
    subst hm
    exact good_of_at hp hc hw hq h
  | succ n ih =>
    intro m h
    have hg := good_of_at hp hc hw hq h
    obtain ⟨k, A, hk, hA, hp1, -, hr⟩ := h
    have hl := step_lock (env := env) hp hc hk hA hr hp1 hp1
    have run_succ : ∀ i, run env (i + 1) m = match step env m with
        | .running m1 => run env i m1
        | o => o := fun i => rfl
    revert hl
    cases hs : step env m with
    | running m1 =>
      simp only [Lock]
      intro hl
      rcases hl with hin | hex
      · rcases ih m1 hin with hall | ⟨j, hj, m', hm', hx, hb⟩
        · left
          intro i hi m' hm
          cases i with
          | zero => simp only [run, Outcome.running.injEq] at hm; subst hm; exact hg
          | succ i => rw [run_succ, hs] at hm; exact hall i (by omega) m' hm
        · right
          refine ⟨j + 1, by omega, m', by rw [run_succ, hs]; exact hm', hx, fun i hi m'' hm => ?_⟩
          cases i with
          | zero => simp only [run, Outcome.running.injEq] at hm; subst hm; exact hg
          | succ i => rw [run_succ, hs] at hm; exact hb i (by omega) m'' hm
      · right
        refine ⟨1, by omega, m1, by rw [run_succ, hs]; rfl, hex, fun i hi m'' hm => ?_⟩
        rw [show i = 0 by omega] at hm
        simp only [run, Outcome.running.injEq] at hm
        subst hm
        exact hg
    | halted c m1 =>
      intro _
      left
      intro i hi m' hm
      cases i with
      | zero => simp only [run, Outcome.running.injEq] at hm; subst hm; exact hg
      | succ i =>
        rw [run_succ, hs] at hm
        cases hm
    | fault f m1 =>
      intro _
      left
      intro i hi m' hm
      cases i with
      | zero => simp only [run, Outcome.running.injEq] at hm; subst hm; exact hg
      | succ i =>
        rw [run_succ, hs] at hm
        cases hm

/-- A run from `base`, with the program in memory, is at the checker's entry. -/
theorem at_entry {base : Word} {prog : List Instr} {P : List (Nat × Nat)} {H : Heads} {X : List Nat}
    (hc : checkX prog P H X = true) (hne : 0 < prog.length) {s : Machine} (hpc : s.pc = base)
    (hcode : CodeAt s.mem base prog) : AtIn base prog P H s s := by
  have h0 : Rel base prog P entry s s := by
    refine ⟨fun r => ?_, fun _ _ _ => rfl, hcode, hcode⟩
    unfold regOK
    by_cases hr0 : r.toNat = 0
    · have : r = 0 := BitVec.eq_of_toNat_eq hr0
      subst this; exact regOK_zero
    · rw [get_entry r.toNat hr0 r.isLt]; rfl
  obtain ⟨B, hB, hEB⟩ := check_entry hc
  exact ⟨0, B, hne, hB, by simp [hpc], by simp [hpc], hEB base s s h0⟩

/-- **A program with no exits: every state of its run is `Good`.** -/
theorem reach {env : Env} {base : Word} {prog : List Instr} (hp : Hosted env base prog.length)
    {P : List (Nat × Nat)} {H : Heads} (hc : check prog P H = true)
    {lw sw : Nat × Nat} (hw : windowed prog P H lw sw = true) (hq : haltsOnly prog P H = true)
    (hne : 0 < prog.length) {s : Machine} (hpc : s.pc = base) (hcode : CodeAt s.mem base prog) :
    ∀ n m, run env n s = .running m → Good env base prog lw sw m := by
  intro n m hm
  rcases reach_until hp hc hw hq n s (at_entry hc hne hpc hcode) with hall | ⟨j, -, m', -, ⟨t, ht, -⟩, -⟩
  · exact hall n (Nat.le_refl _) m hm
  · simp at ht

/-! ## What the stores leave alone -/

/-- **A run's stores stay in their window.** If every state before the `n`-th
is `Good`, the `n`-th's memory is the first's outside the store window `sw`. -/
theorem frame {env : Env} {base : Word} {prog : List Instr} {lw sw : Nat × Nat}
    (hfit : base.toNat + 0x10000 ≤ 2^32) (hsw : sw.2 ≤ 0x10000) :
    ∀ n s m, (∀ i < n, ∀ m', run env i s = .running m' → Good env base prog lw sw m') →
      run env n s = .running m →
      ∀ x : Word, ¬ (base.toNat + sw.1 ≤ x.toNat ∧ x.toNat < base.toNat + sw.2) → m.mem x = s.mem x := by
  intro n
  induction n with
  | zero =>
    intro s m _ hm x _
    simp only [run, Outcome.running.injEq] at hm
    subst hm; rfl
  | succ n ih =>
    intro s m hg hm x hx
    obtain ⟨k, hk, -, -, hstep, htouch, hecall⟩ := hg 0 (by omega) s rfl
    have run_succ : run env (n + 1) s = match step env s with
        | .running m1 => run env n m1
        | o => o := rfl
    rw [run_succ] at hm
    cases hs : step env s with
    | halted c m1 => rw [hs] at hm; cases hm
    | fault f m1 => rw [hs] at hm; cases hm
    | running m1 =>
      rw [hs] at hm
      have hg1 : ∀ i < n, ∀ m', run env i m1 = .running m' → Good env base prog lw sw m' :=
        fun i hi m' h => hg (i + 1) (by omega) m' (by
          show (match step env s with | .running m1 => run env i m1 | o => o) = _
          rw [hs]; exact h)
      rw [ih m1 m hg1 hm x hx]
      rw [hstep] at hs
      generalize hI : prog[k] = I at hs htouch hecall
      cases I with
      | st op r1 r2 imm =>
        obtain ⟨o, o1, o2, e⟩ := htouch
        simp only [exec] at hs
        split at hs
        · cases hs
        split at hs
        · cases hs
        injection hs with e'
        subst e'
        have hsz : op.size ≤ 4 := by cases op <;> decide
        have hsz1 : 1 ≤ op.size := by cases op <;> decide
        show writeLE s.mem (s.reg r1 + imm.signExtend 32) (s.reg r2).toNat op.size x = s.mem x
        rw [e, writeLE_apply _ _ _ _ (by omega)]
        have : ¬ (x - (base + BitVec.ofNat 32 o)).toNat < op.size := by
          rw [BitVec.toNat_sub, toNat_off hfit o (by omega)]
          have := x.isLt
          omega
        simp only [this, ↓reduceIte]
      | ecall =>
        simp [exec, syscall, hecall rfl] at hs
      | _ =>
        rw [Rv32.Priv.exec_mem_of_not_st (fun _ _ _ _ h => by cases h) (by simp) hs]

end Rv32.Reach

#print axioms Rv32.Reach.good_of_at
#print axioms Rv32.Reach.reach_until
#print axioms Rv32.Reach.reach
#print axioms Rv32.Reach.frame
