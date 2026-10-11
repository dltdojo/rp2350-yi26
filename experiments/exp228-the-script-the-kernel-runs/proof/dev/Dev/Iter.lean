import Dev.Sig

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- The opcodes the subset has. -/
def known (op : Nat) : Prop :=
  op ≤ 0x4b ∨ op = 0x4f ∨ (0x51 ≤ op ∧ op ≤ 0x60) ∨ op = 0x61 ∨ op = 0x69 ∨ op = 0x75 ∨ op = 0x76 ∨ op = 0x77 ∨
  op = 0x78 ∨ op = 0x7c ∨ op = 0x87 ∨ op = 0x88 ∨ op = 0x8b ∨ op = 0x8c ∨ op = 0x93 ∨ op = 0x94 ∨ op = 0xa8 ∨
  op = 0xac

instance (op : Nat) : Decidable (known op) := by unfold known; infer_instance

theorem tab_push : ∀ op < 256, 1 ≤ op → op ≤ 0x4b → table.getD op 0 = 4 * H_PUSH := by decide
theorem tab_opn : ∀ op < 256, 0x51 ≤ op → op ≤ 0x60 → table.getD op 0 = 4 * H_OPN := by decide
theorem tab_bad : ∀ op < 256, ¬ known op → table.getD op 0 = 4 * F_BAD := by decide

theorem f_bad (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_BAD)) : Goes env base m0 scr s (.done C_BAD) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem step_bad {c : Cfg} {op : Nat} (hop : (scr.getD c.pc 0).toNat = op) (hk : ¬ known op) :
    stepOp env scr c = .done C_BAD := by
  simp only [known, not_or, not_and] at hk
  obtain ⟨h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17⟩ := hk
  simp only [stepOp]; rw [hop]
  simp only [show ¬ op = 0 by omega, show ¬ op ≤ 0x4b by omega, h1, show ¬ (0x51 ≤ op ∧ op ≤ 0x60) by omega,
    h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, show ¬ (op = 0x8b ∨ op = 0x8c) by omega,
    show ¬ (op = 0x93 ∨ op = 0x94) by omega, h15, h16, h17, ↓reduceIte, false_or, or_false]
  simp only [h12, h13, h14, h15, h16, h17, ↓reduceIte]

/-- **One opcode, from the top of the loop.** -/
theorem iter (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (h : Inv base m0 scr c s) (hlt : c.pc < scr.length) :
    Goes env base m0 scr s (stepOp env scr c) := by
  obtain ⟨s1, e1, p1, hc1, r18, r5⟩ := dispatch hp hin h hlt
  generalize hop : (scr.getD c.pc 0).toNat = op at p1 r5
  have hop256 : op < 256 := by rw [← hop]; exact (scr.getD c.pc 0).isLt
  have E (k : Nat) (hk : table.getD op 0 = 4 * k) : Entry base m0 scr c op k s1 :=
    ⟨hc1, by rw [p1, hk], r18, r5, hlt⟩
  have T (k : Nat) (hk : table.getD op 0 = 4 * k) : Entry base m0 scr c op k s1 := E k hk
  by_cases hknown : ¬ known op
  · exact Goes.prepend e1 (by rw [step_bad hop hknown]; exact f_bad hp (hc1.code hp hin) (by rw [p1, tab_bad op hop256 hknown]))
  replace hknown : known op := Classical.not_not.mp hknown
  unfold known at hknown
  rcases hknown with h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h | h
  · by_cases h0 : op = 0
    · subst h0; exact Goes.prepend e1 (h_op0 hp hin (E H_OP0 (by decide)) hop)
    · exact Goes.prepend e1 (h_push hp hin (E H_PUSH (tab_push op hop256 (by omega) h)) hop (by omega) h)
  · subst h; exact Goes.prepend e1 (h_neg1 hp hin (E H_NEG1 (by decide)) hop)
  · exact Goes.prepend e1 (h_opn hp hin (E H_OPN (tab_opn op hop256 h.1 h.2)) hop h.1 h.2)
  · -- OP_NOP: the table sends it straight back to the top of the loop
    subst h
    rw [show stepOp env scr c = .next ⟨c.pc + 1, c.st, c.sigs⟩ by simp only [stepOp]; rw [hop]; simp]
    exact ⟨7, s1, e1, ⟨{ hc1 with pcle := (by simp only; omega) }, (by rw [p1]; rfl),
      (by rw [r18, Nat.add_assoc])⟩⟩
  · subst h; exact Goes.prepend e1 (h_verify hp hin (E H_VERIFY (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_drop hp hin (E H_DROP (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_dup hp hin (E H_DUP (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_nip hp hin (E H_NIP (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_over hp hin (E H_OVER (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_swap hp hin (E H_SWAP (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_equal hp hin (E H_EQUAL (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_eqv hp hin (E H_EQV (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_1add hp hin (E H_1ADD (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_1sub hp hin (E H_1SUB (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_add hp hin (E H_ADD (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_sub hp hin (E H_SUB (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_sha hp hin (E H_SHA (by decide)) hop)
  · subst h; exact Goes.prepend e1 (h_checksig hp hin (E H_CHECKSIG (by decide)) hop)

end Exp228
