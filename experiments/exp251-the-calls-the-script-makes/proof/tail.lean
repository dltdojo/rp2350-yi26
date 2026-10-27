/-! # exp251 — the calls the script makes

exp228 proved its kernel for every world: whatever `env.hash` and `env.sig` are, the run halts with the
specification's verdict. A world is also what its shell serves, and exp238's monitor serves `HALT`, `HASHB` and
`CHECKSIG` and nothing else -- not the first call, `HASH` of whole 64-byte blocks (`t0 = 0`). So take exp228's
theorem in a world that does not serve it, and read the run with lean/Rv32/Join.lean's `calls_of_halted`: a step
that faults ends the run, so a run that halted made, at every step, only calls its world serves, with the
arguments that world asks for. -/

namespace Exp251
open Rv32 Exp228 Rv32.Join

/-- `[a, a + n)` lies in the 64 KiB box from `base`. -/
def InBox (base a : Word) (n : Nat) : Prop := base.toNat ≤ a.toNat ∧ a.toNat + n ≤ base.toNat + 0x10000

/-- A call exp238's monitor serves: `HALT`; `HASHB` of a range in the box, written in the box; `CHECKSIG` of a
32-byte key and a 64-byte signature in the box. -/
def Served (base : Word) (m : Machine) : Prop :=
  m.reg T0 = 1 ∨
  (m.reg T0 = 2 ∧ InBox base (m.reg A0) (m.reg A1).toNat ∧ InBox base (m.reg A2) 32) ∨
  (m.reg T0 = 3 ∧ InBox base (m.reg A0) 32 ∧ InBox base (m.reg A1) 64)

/-- **The calls the script makes.** exp228's kernel at `base`, its 64 KiB box the region, the script and stack
as `Input` describes them, in a world that does not serve `HASH`: the run halts with the specification's
verdict, and every `ecall` on the way is a call exp238's monitor serves. -/
theorem calls_the_script_makes {env : Env} {base : Word} (hp : Placed env base) (hs : env.servesHash = false)
    {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem} (hin : Input m0 base scr st0) {s : Machine}
    (hpc : s.pc = base) (hmem : s.mem = m0) :
    ∃ k s', run env k s = .halted (BitVec.ofNat 32 (verdict env scr st0)) s' ∧
      ∀ i < k, ∀ m, run env i s = .running m → decode (fetched m) = some .ecall → Served base m := by
  obtain ⟨k, s', h⟩ := kernel_verdict hp hin hpc hmem
  refine ⟨k, s', h, fun i hi m hm hd => ?_⟩
  have hr := hp.region
  rcases calls_of_halted hs h i hi m hm hd with h1 | ⟨h2, a, b⟩ | ⟨h3, a, b⟩
  · exact Or.inl h1
  · rw [hr] at a b; exact Or.inr (Or.inl ⟨h2, a, b⟩)
  · rw [hr] at a b; exact Or.inr (Or.inr ⟨h3, a, b⟩)

end Exp251

#print axioms Exp228.kernel_verdict
#print axioms Rv32.Join.calls_of_halted
#print axioms Exp251.calls_the_script_makes
