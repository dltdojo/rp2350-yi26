/-
SPDX-License-Identifier: Apache-2.0

# exp249 — the words the hash touches

exp208's SHA-256 kernel, through the reach checker: at every step of its run over a 4096-byte message, every load is
inside `[base + 0x400, base + 0x3040)`, every store inside `[base + 0x1140, base + 0x1440)` -- the digest, H, the
schedule and the padding block -- memory outside that is as it was, and the only call is HALT.

exp208 proved what the run ends with: the digest, after exactly 4990 + 4873 · n instructions. This is about the
steps on the way, and it needs what exp208's proof did not: the block count is read from memory (the length word at
`+0x1120`, shifted right by 6), the message pointer is affine in two nested counters, and the padding block's
pointer joins the message's where the two paths meet. lean/Rv32/Ct.lean's checker gained exactly those -- values
affine in two counters with a ranged offset (`lin`), constant words in memory (`Pub.consts`), `srli` of a number,
ranges narrowed by an ordered comparison (`capLe`), and a counter pinned by a comparison folded in (`norm`).
-/
import Rv32.Sha
import Rv32.Reach

namespace Exp249
open Rv32 Rv32.Ct Rv32.Reach

/-- One run: every place public; the length word, 4096, a constant no store may touch. -/
def P : Pub := { places := [(0, 0x10000)], consts := [(0x1120, 4096)] }

/-- A state where the registers named are known, and the rest are whatever they are. -/
def known (o : List (Nat × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1 == n) with
    | some (_, v) => v
    | none => .pub

/-- The block loop: `s1` at R, `s5` the blocks done, 0 to 64, `s6` the 64 blocks, and `s4` the next block,
`R + d + 64 · s5` for some `d` in `[0x400, 0x2000]` -- the message's `0x2000`, or the padding block's `0x400`
reached at `s5 = 64`. -/
def outer : List (Nat × AV) := [(9, .ptr 0x1000 0x1000), (20, .lin 21 64 0 0 0x400 0x2000), (21, .num 0 64),
  (22, .num 64 64)]

/-- After a block's words are loaded: `s4` 64 bytes on. -/
def done : List (Nat × AV) := [(9, .ptr 0x1000 0x1000), (20, .lin 21 64 0 0 0x440 0x2040), (21, .num 0 64),
  (22, .num 64 64)]

/-- The loop heads: the block loop at `choose` (49) and where its two paths meet (51); the load loop (53), `s4`
affine in `s5` and in `s8`, the words left; the schedule (69) and the rounds (109), `s9` and `s10` affine in `s8`. -/
def heads : Heads := [
  (49, known outer),
  (51, known outer),
  (53, known [(9, .ptr 0x1000 0x1000), (20, .lin 21 64 24 (-4) 0x440 0x2040), (21, .num 0 64), (22, .num 64 64),
    (24, .num 1 16), (25, .aff 24 (-4) 0x1340)]),
  (69, known (done ++ [(24, .num 1 48), (25, .aff 24 (-4) 0x1400)])),
  (109, known (done ++ [(24, .num 1 64), (25, .aff 24 (-4) 0x1400), (26, .aff 24 (-4) 0x1100)]))]

/-- Where the loads may go: from the checker's bound on the joined block pointer, `+0x400`, to the message's end
and a few bytes the bound cannot rule out, `+0x3040`. -/
def loads : Nat × Nat := (0x400, 0x3040)

/-- Where the stores go: the digest at `+0x1140`, H, the schedule, the padding block up to `+0x1440`. -/
def stores : Nat × Nat := (0x1140, 0x1440)

set_option maxRecDepth 100000 in
theorem accepted : check Sha.kernel P heads = true := by decide

set_option maxRecDepth 100000 in
theorem windows : windowed Sha.kernel P heads loads stores = true := by decide

set_option maxRecDepth 100000 in
theorem halts_only : haltsOnly Sha.kernel P heads = true := by decide

/-- **SHA-256's every step, in its windows.** exp208's kernel from its first word, wherever it is `Hosted` -- its
own 64 KiB, or a box it sits partway into -- with the length 4096 at `+0x1120`: every state of the run is `Good` --
at one of its 252 instructions, the kernel in memory, a load inside `loads`, a store inside `stores`, an `ecall`
only at `t0 = 1` -- and memory outside `stores` is as it was. -/
theorem sha_reach {env : Env} {base : Word} (hp : Hosted env base Sha.kernel.length) {s : Machine}
    (hpc : s.pc = base) (hcode : CodeAt s.mem base Sha.kernel)
    (hlen : readLE s.mem (base + BitVec.ofNat 32 0x1120) 4 = 4096) :
    ∀ n m, run env n s = .running m →
      Good env base Sha.kernel loads stores m ∧
      ∀ x : Word, ¬ (base.toNat + 0x1140 ≤ x.toNat ∧ x.toNat < base.toNat + 0x1440) → m.mem x = s.mem x := by
  have hkc : ∀ c ∈ P.consts, readLE s.mem (base + BitVec.ofNat 32 c.1) 4 = c.2 := by
    intro c hc
    simp only [P, List.mem_singleton] at hc
    subst hc
    exact hlen
  have all := reach hp accepted windows halts_only (by rw [Sha.kernel_length]; decide) hpc hcode hkc
  intro n m hm
  exact ⟨all n m hm, frame hp.fit (by decide) n s m (fun i _ m' h => all i m' h) hm⟩

/-- **exp208's run, and every step of it.** With exp208's own hypotheses for a 4096-byte message: the run halts
with 0 after 4990 + 4873 · 64 instructions, the digest at `+0x1140` is SHA-256 of the message -- exp208's
`computes` -- and every state on the way is `Good`, memory outside `stores` as it was. -/
theorem sha_whole {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base Sha.kernel)
    (hK : ∀ t < 64, Sha.wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = Sha.K.getD t 0)
    (hIV : ∀ j < 8, Sha.wordAt s.mem (base + BitVec.ofNat 32 (0x1100 + 4 * j)) = Sha.IV.getD j 0)
    (hlen : Sha.wordAt s.mem (base + BitVec.ofNat 32 0x1120) = BitVec.ofNat 32 (64 * 64)) :
    (∃ s', run env (4990 + 4873 * 64) s = .halted 0 s' ∧
      readBytes s'.mem (base + BitVec.ofNat 32 0x1140) 32 =
        Sha.sha256 (readBytes s.mem (base + BitVec.ofNat 32 0x2000) (64 * 64))) ∧
    ∀ n m, run env n s = .running m →
      Good env base Sha.kernel loads stores m ∧
      ∀ x : Word, ¬ (base.toNat + 0x1140 ≤ x.toNat ∧ x.toNat < base.toNat + 0x1440) → m.mem x = s.mem x := by
  obtain ⟨s', e, d, -⟩ := Sha.computes hp s hpc hcode hK hIV hlen (by decide)
  refine ⟨⟨s', e, d⟩, sha_reach (hp.hosted (by rw [Sha.kernel_length]; decide)) hpc hcode ?_⟩
  have h := congrArg BitVec.toNat hlen
  simp only [Sha.wordAt, BitVec.toNat_ofNat] at h
  have := readLE_four_lt s.mem (base + BitVec.ofNat 32 0x1120)
  omega

end Exp249

#print axioms Exp249.accepted
#print axioms Exp249.windows
#print axioms Exp249.halts_only
#print axioms Rv32.Reach.reach
#print axioms Rv32.Reach.frame
#print axioms Exp249.sha_reach
#print axioms Exp249.sha_whole
