/-! # exp253 — exp225's kernel, through the reach checker

exp225 proved what its kernel leaves: from any seed, after 3079 instructions, HALT 0 and generations 1 to 256 of
Rule 30 at `+0x200`. That is how the run ends. exp240's monitor boxes a payload with no byte both writable and
runnable, and a box asks about every step: where it fetches, where it loads, where it stores. This is the kernel's run,
every step of it, from lean/Rv32/Reach.lean, with three facts read off the checker's relation by `decide`. -/

namespace Exp253
open Rv32 Rv32.Ct Rv32.Reach

/-- One run: every place public, so the checker refuses nothing for being secret. -/
def P : List (Nat × Nat) := [(0, 0x10000)]

/-- A state where the registers named are known, and the rest are whatever they are. -/
def known (o : List (Nat × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1 == n) with
    | some (_, v) => v
    | none => .pub

/-- The loop's head, at instruction 4: `t1` (x6) is where the next generation goes, `base + 0x600 - 4 · t2`, with
`t2` (x7) the generations to go, 1 to 256. -/
def heads : Heads := [(4, known [(6, .aff 7 (-4) 0x600), (7, .num 1 256)])]

/-- The seed, the one word the kernel loads: `[base + 0x100, base + 0x104)`. -/
def seed : Nat × Nat := (0x100, 0x104)

/-- The history, where it stores: `[base + 0x200, base + 0x600)`, 256 words. -/
def history : Nat × Nat := (0x200, 0x600)

set_option maxRecDepth 100000 in
theorem accepted : check Exp225.kernel P heads = true := by decide

set_option maxRecDepth 100000 in
theorem windows : windowed Exp225.kernel P heads seed history = true := by decide

set_option maxRecDepth 100000 in
theorem halts_only : haltsOnly Exp225.kernel P heads = true := by decide

/-- **Every step the kernel takes.** From its first word, wherever it is `Hosted`: every state of the run is `Good`
-- at one of its 19 instructions, the kernel in memory, a load only of the seed, a store only into the history, an
`ecall` only with `t0 = 1`. -/
theorem life_reach {env : Env} {base : Word} (hp : Hosted env base Exp225.kernel.length) {s : Machine}
    (hpc : s.pc = base) (hcode : CodeAt s.mem base Exp225.kernel) :
    ∀ n m, run env n s = .running m → Good env base Exp225.kernel seed history m :=
  reach hp accepted windows halts_only (by decide) hpc hcode

/-- **exp225's run, and every step of it.** In its own 64 KiB: HALT 0 after exactly 3079 instructions with the
history Rule 30's, as exp225 proved; every state on the way is `Good`; and memory outside the history is as it was. -/
theorem life_whole {env : Env} {base : Word} (hp : Placed env base) {s : Machine} (hpc : s.pc = base)
    (hcode : CodeAt s.mem base Exp225.kernel) :
    ∃ s', run env 3079 s = .halted 0 s' ∧ s'.mem = Exp225.lived s.mem base Exp225.N ∧
      (∀ n m, run env n s = .running m → Good env base Exp225.kernel seed history m ∧
        ∀ x : Word, ¬ (base.toNat + 0x200 ≤ x.toNat ∧ x.toNat < base.toNat + 0x600) → m.mem x = s.mem x) := by
  have hh : Hosted env base Exp225.kernel.length := hp.hosted (by rw [Exp225.kernel_length]; decide)
  obtain ⟨s', h, hm⟩ := Exp225.lives hp s hpc hcode
  refine ⟨s', h, hm, fun n m hm' => ⟨life_reach hh hpc hcode n m hm', fun x hx => ?_⟩⟩
  exact frame hp.fit (by decide) n s m (fun i _ m' h' => life_reach hh hpc hcode i m' h') hm' x hx

end Exp253

#print axioms Exp253.accepted
#print axioms Exp253.windows
#print axioms Exp253.halts_only
#print axioms Rv32.Reach.reach
#print axioms Rv32.Reach.frame
#print axioms Exp253.life_reach
#print axioms Exp253.life_whole
