import Dev.H1

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

theorem tab_drop : table.getD 0x75 0 = 4 * H_DROP := by decide

/-- One opcode, from the top of the loop. -/
theorem iter (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (h : Inv base m0 scr c s) (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (stepOp env scr c) := by
  obtain ⟨s1, e1, p1, hc1, r18, r5⟩ := dispatch hp hin h hlt
  refine Goes.prepend e1 ?_
  generalize hop : (scr.getD c.pc 0).toNat = op at p1 r5
  have hop256 : op < 256 := by rw [← hop]; exact (scr.getD c.pc 0).isLt
  have E (k : Nat) (hk : table.getD op 0 = 4 * k) : Entry base m0 scr c op k s1 :=
    ⟨hc1, by rw [p1, hk], r18, r5, hlt⟩
  by_cases h75 : op = 0x75
  · subst h75
    exact h_drop hp hin (E _ tab_drop) hop
  · sorry

end Exp228
