/-! # exp248 — exp223's front, through the reach checker

exp223 proved what its front decides: an unhealthy block HALTs with 1 after 17425
instructions, a healthy one is at SHA-256's first word after 17422, memory untouched
either way. That is about where the run ends up, not about the steps on the way. A
monitor's box needs the steps: where each one reads, whether it writes, what it calls.
This is the front's run, every step of it, from lean/Rv32/Reach.lean: the checker of
lean/Rv32/Ct.lean, one run at a time, with every place public, and three facts read off
its relation by `decide`. -/

namespace Exp248
open Rv32 Rv32.Ct Rv32.Reach

/-- One run: every place public, so the checker refuses nothing for being secret. -/
def P : List (Nat × Nat) := [(0, 0x10000)]

/-- A state where the registers named are known, and the rest are whatever they are. -/
def known (o : List (Nat × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1 == n) with
    | some (_, v) => v
    | none => .pub

/-- The loop's head, at instruction 10 (`lw t1, 0(s1)`): `s1` is the next sample,
`base + 0x4000 - 4 · s3`, with `s3` the samples left, 1 to 1024. -/
def heads : Heads := [(10, known [(8, .ptr 0 0), (9, .aff 19 (-4) 0x4000), (19, .num 1 1024)])]

/-- The front's one way out: the branch to SHA-256, instruction 0x400, `base + 0x1000`. -/
def exits : List Nat := [0x400]

/-- The samples: `[base + 0x3000, base + 0x4000)`. -/
def samples : Nat × Nat := (0x3000, 0x4000)

/-- Nowhere: the front stores nothing. -/
def nowhere : Nat × Nat := (0, 0)

set_option maxRecDepth 100000 in
theorem accepted : checkX Exp223.kernel P heads exits = true := by decide

set_option maxRecDepth 100000 in
theorem windows : windowed Exp223.kernel P heads samples nowhere = true := by decide

set_option maxRecDepth 100000 in
theorem halts_only : haltsOnly Exp223.kernel P heads = true := by decide

/-- **The front reads only samples, writes nothing, and calls nothing but HALT,
up to SHA-256.** exp223's front, from its first word wherever it is `Hosted` -- its own
64 KiB, or a box it sits at the start of: either every state of the first `n` steps is
`Good` -- at one of its 34 instructions, the front in memory, a load only of a sample in
`[base + 0x3000, base + 0x4000)`, no store, an `ecall` only with `t0 = 1` -- with memory
as it was; or after some `j ≤ n` steps the run is at SHA-256's first word,
`base + 0x1000`, memory as it was, every state before that `Good`. -/
theorem front_reach {env : Env} {base : Word} (hp : Hosted env base Exp223.kernel.length) {s : Machine}
    (hpc : s.pc = base) (hcode : CodeAt s.mem base Exp223.kernel) :
    ∀ n,
      (∀ i ≤ n, ∀ m, run env i s = .running m → Good env base Exp223.kernel samples nowhere m ∧ m.mem = s.mem) ∨
      (∃ j, j ≤ n ∧ ∃ m, run env j s = .running m ∧ m.pc = base + BitVec.ofNat 32 0x1000 ∧ m.mem = s.mem ∧
        ∀ i < j, ∀ m', run env i s = .running m' → Good env base Exp223.kernel samples nowhere m') := by
  intro n
  have kept : ∀ i, (∀ i' < i, ∀ m', run env i' s = .running m' → Good env base Exp223.kernel samples nowhere m') →
      ∀ m, run env i s = .running m → m.mem = s.mem := by
    intro i hb m hm
    funext x
    exact frame hp.fit (by decide) i s m hb hm x (by simp only [nowhere]; omega)
  rcases reach_until hp accepted windows halts_only n s (at_entry accepted (by decide) hpc hcode) with
    hall | ⟨j, hj, m, hm, ⟨t, ht, -, hpc', -, -⟩, hb⟩
  · left
    intro i hi m hm
    exact ⟨hall i hi m hm, kept i (fun i' hi' m' h => hall i' (by omega) m' h) m hm⟩
  · right
    simp only [exits, List.mem_singleton] at ht
    subst ht
    exact ⟨j, hj, m, hm, hpc', kept j hb m hm, hb⟩

end Exp248

#print axioms Exp248.accepted
#print axioms Exp248.windows
#print axioms Exp248.halts_only
#print axioms Rv32.Reach.reach_until
#print axioms Rv32.Reach.frame
#print axioms Exp248.front_reach
