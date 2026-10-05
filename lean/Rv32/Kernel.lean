/-
SPDX-License-Identifier: Apache-2.0

# One instruction of a kernel at a time

A kernel proof walks its program an instruction at a time, and the way it
does so does not depend on which kernel it is: `stepK` takes one step of
`prog` at `base`, and `regStep`, `loadStep`, `lbuStep`, `storeStep` and
`sbStep` each hand back a fresh machine and only what is true of it. Naming
each step's machine is not style: holding the term for a machine many
instructions deep is what ran Lean's kernel out of recursion when it was
tried (exp203).

And the memory and word facts every kernel that compares hashes needs:
`overlay`, a block of memory replaced; eight words equal as 32 bytes equal;
`or` and `xor` reaching zero; `sltu` against `x0`.

exp204 wrote these for its own kernel; exp205 needed them second.

`hlen`, that the program fits in the region, is an auto-parameter: for a
concrete kernel `decide` discharges it, and callers never write it.
-/
import Rv32.Place

namespace Rv32

variable {env : Env} {base : Word} {prog : List Instr}

/-- One instruction of `prog`: at `base + 4k`, with the program in memory,
`run` takes the step `exec` says the instruction there takes. -/
theorem stepK (hp : Placed env base) {s s' : Machine} (k : Nat) (hk : k < prog.length)
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {i : Instr} (hi : prog.getD k .ecall = i) (hexec : exec env s i = .running s') (n : Nat)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    run env (n + 1) s = run env n s' := by
  have : prog[k] = i := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk]
  exact run_code n hk hcode hpc
    (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (this ▸ hexec)

/-- The pc after instruction `k`: nothing wraps. -/
theorem pc_next (hfit : base.toNat + 0x10000 ≤ 2^32) (k : Nat) (hk : 4 * k + 4 < 0x10000) :
    base + BitVec.ofNat 32 (4 * k) + 4 = base + BitVec.ofNat 32 (4 * (k + 1)) := by
  rw [show (4 : Word) = BitVec.ofNat 32 4 from rfl, off_add hfit _ _ (by omega)]; congr 2

/-- Runs chain: one instruction, then `n` more. -/
theorem run_cons {s s1 s2 : Machine} {n : Nat} (h1 : run env 1 s = .running s1)
    (h2 : run env n s1 = .running s2) : run env (n + 1) s = .running s2 := by
  rw [Nat.add_comm, run_add_running h1, h2]

/-- An instruction that writes one register and goes on. -/
theorem regStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {i : Instr} (hi : prog.getD k .ecall = i) {rd : Reg} {v : Word}
    (hexec : exec env s i = .running (s.setReg rd v).next)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1)) ∧ s'.mem = s.mem
      ∧ ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0 then v else s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi hexec 0 hlen).trans (run_zero _ _),
    by simp only [next_pc, setReg_pc, hpc]; exact pc_next hp.fit k (by omega), by simp,
    fun r => by simp [reg_setReg]⟩

/-- `sw`, at an address `c` past `base`. -/
theorem storeStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {rs1 rs2 : Reg} {imm : BitVec 12} (hi : prog.getD k .ecall = .st .sw rs1 rs2 imm)
    (c : Nat) (ha : s.reg rs1 + imm.signExtend 32 = base + BitVec.ofNat 32 c) (hc : c + 4 ≤ 0x10000)
    (h4 : c % 4 = 0) (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1))
      ∧ s'.mem = writeLE s.mem (base + BitVec.ofNat 32 c) (s.reg rs2).toNat 4 ∧ ∀ r, s'.reg r = s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi
      (exec_sw (by rw [ha]; exact align_off hp.align hp.fit _ (by omega) h4)
        (by rw [ha]; exact ok_off hp _ 4 (by omega) hc)) 0 hlen).trans (run_zero _ _),
    by simp only [next_pc, hpc]; exact pc_next hp.fit k (by omega), by simp [ha], fun r => rfl⟩

/-- `lw`, from an address `c` past `base`. -/
theorem loadStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {rd rs1 : Reg} {imm : BitVec 12} (hi : prog.getD k .ecall = .ld .lw rd rs1 imm)
    (c : Nat) (ha : s.reg rs1 + imm.signExtend 32 = base + BitVec.ofNat 32 c) (hc : c + 4 ≤ 0x10000)
    (h4 : c % 4 = 0) (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1)) ∧ s'.mem = s.mem
      ∧ ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0
          then BitVec.ofNat 32 (readLE s.mem (base + BitVec.ofNat 32 c) 4) else s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi
      (exec_lw (by rw [ha]; exact align_off hp.align hp.fit _ (by omega) h4)
        (by rw [ha]; exact ok_off hp _ 4 (by omega) hc)) 0 hlen).trans (run_zero _ _),
    by simp only [next_pc, setReg_pc, hpc]; exact pc_next hp.fit k (by omega), by simp,
    fun r => by simp [reg_setReg, ha]⟩

/-- `lbu`, from an address `c` past `base`. -/
theorem lbuStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {rd rs1 : Reg} {imm : BitVec 12} (hi : prog.getD k .ecall = .ld .lbu rd rs1 imm)
    (c : Nat) (ha : s.reg rs1 + imm.signExtend 32 = base + BitVec.ofNat 32 c) (hc : c < 0x10000)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1)) ∧ s'.mem = s.mem
      ∧ ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0
          then BitVec.ofNat 32 (s.mem (base + BitVec.ofNat 32 c)).toNat else s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi (exec_lbu (by rw [ha]; exact ok_off hp _ 1 hc (by omega))) 0 hlen).trans
      (run_zero _ _),
    by simp only [next_pc, setReg_pc, hpc]; exact pc_next hp.fit k (by omega), by simp,
    fun r => by simp [reg_setReg, ha]⟩

theorem exec_sb {s : Machine} {rs1 rs2 : Reg} {imm : BitVec 12}
    (hok : env.region.ok (s.reg rs1 + imm.signExtend 32) 1) :
    exec env s (.st .sb rs1 rs2 imm) =
      .running ({ s with mem := writeByte s.mem (s.reg rs1 + imm.signExtend 32) (BitVec.ofNat 8 (s.reg rs2).toNat) }).next := by
  have h1 : ¬ (s.reg rs1 + imm.signExtend 32).toNat % 1 ≠ 0 := by omega
  have h2 : ¬ ¬ env.region.ok (s.reg rs1 + imm.signExtend 32) 1 := by simpa using hok
  simp only [exec, StOp.size]
  simp only [h1, h2, ↓reduceIte]
  rfl

/-- `sb`, at an address `c` past `base`: the low byte of `rs2`. -/
theorem sbStep (hp : Placed env base) (k : Nat) (hk : k < prog.length) {s : Machine}
    (hcode : CodeAt s.mem base prog) (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    {rs1 rs2 : Reg} {imm : BitVec 12} (hi : prog.getD k .ecall = .st .sb rs1 rs2 imm)
    (c : Nat) (ha : s.reg rs1 + imm.signExtend 32 = base + BitVec.ofNat 32 c) (hc : c < 0x10000)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1))
      ∧ s'.mem = writeByte s.mem (base + BitVec.ofNat 32 c) (BitVec.ofNat 8 (s.reg rs2).toNat)
      ∧ ∀ r, s'.reg r = s.reg r :=
  ⟨_, (stepK hp k hk hcode hpc hi (exec_sb (by rw [ha]; exact ok_off hp _ 1 hc (by omega))) 0 hlen).trans
      (run_zero _ _),
    by simp only [next_pc, hpc]; exact pc_next hp.fit k (by omega), by simp [ha], fun r => rfl⟩

/-- Reading a step's registers back: the one it wrote, and the others. -/
theorem reg_wrote {s s' : Machine} {rd : Reg} {v : Word}
    (h : ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0 then v else s.reg r) (hz : rd ≠ 0) : s'.reg rd = v := by
  rw [h]; exact ite_eq_left_of_eq_true _ _ (eq_true ⟨rfl, hz⟩)

theorem reg_kept {s s' : Machine} {rd : Reg} {v : Word}
    (h : ∀ r, s'.reg r = if r = rd ∧ rd ≠ 0 then v else s.reg r) {r : Reg} (hr : r ≠ rd) :
    s'.reg r = s.reg r := by
  rw [h]; simp [hr]

/-! ## Memory, as a base and what has been written over it -/

/-- `m`, with the `n` bytes from `a` replaced: byte `d` of them is `f d`. -/
def overlay (m : Word → Byte) (a : Word) (n : Nat) (f : Nat → Byte) : Word → Byte := fun x =>
  if (x - a).toNat < n then f (x - a).toNat else m x

/-- A word stored right after what has been overlaid extends the overlay by
four bytes — when its bytes are the next four of `f`. -/
theorem overlay_step {m : Word → Byte} {a : Word} {j v : Nat} {f : Nat → Byte}
    (hfit : a.toNat + 4 * j + 4 ≤ 2^32)
    (hv : ∀ d < 4, BitVec.ofNat 8 (v / 256 ^ d) = f (4 * j + d)) (x : Word) :
    writeLE (overlay m a (4 * j) f) (a + BitVec.ofNat 32 (4 * j)) v 4 x = overlay m a (4 * (j + 1)) f x := by
  rw [writeLE_apply _ _ _ _ (by decide)]
  have hx := x.isLt
  have ha := a.isLt
  have hd : (x - (a + BitVec.ofNat 32 (4 * j))).toNat
      = (2^32 - (a.toNat + 4 * j) + x.toNat) % 2^32 := by
    rw [BitVec.toNat_sub, BitVec.toNat_add, BitVec.toNat_ofNat,
      Nat.mod_eq_of_lt (show 4 * j < 2^32 by omega), Nat.mod_eq_of_lt (show a.toNat + 4 * j < 2^32 by omega)]
  have he : (x - a).toNat = (2^32 - a.toNat + x.toNat) % 2^32 := by rw [BitVec.toNat_sub]
  unfold overlay
  generalize (x - (a + BitVec.ofNat 32 (4 * j))).toNat = d at hd ⊢
  generalize (x - a).toNat = e at he ⊢
  by_cases hlt : d < 4
  · have hed : e = 4 * j + d := by omega
    simp only [hlt, ↓reduceIte, hed, show 4 * j + d < 4 * (j + 1) by omega]
    exact hv d hlt
  · simp only [hlt, ↓reduceIte]
    by_cases c : e < 4 * j
    · simp only [c, show e < 4 * (j + 1) by omega, ↓reduceIte]
    · simp only [c, show ¬ e < 4 * (j + 1) by omega, ↓reduceIte]

/-- How far past `base + c` the address `base + c + d` is: `d`. -/
theorem dist_off (hfit : base.toNat + 0x10000 ≤ 2^32) (c d : Nat) (h : c + d < 0x10000) :
    (base + BitVec.ofNat 32 (c + d) - (base + BitVec.ofNat 32 c)).toNat = d := by
  rw [← off_add hfit c d h, BitVec.add_comm (base + _), BitVec.add_sub_cancel, BitVec.toNat_ofNat]; omega

theorem app_congr {α : Type} {a b c d : List α} (h1 : a = c) (h2 : b = d) : a ++ b = c ++ d := by
  subst h1; subst h2; rfl

/-- The distance from `a` up to `X`, round the 32-bit circle, without a
remainder in it: `omega` meets its recursion limit when two of these meet. -/
theorem wrapdist (a X : Nat) (ha : a ≤ 2 ^ 32) (hX : X < 2 ^ 32) :
    (2 ^ 32 - a + X) % 2 ^ 32 = if a ≤ X then X - a else 2 ^ 32 - a + X := by
  split
  · rw [show 2 ^ 32 - a + X = (X - a) + 2 ^ 32 by omega, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
  · exact Nat.mod_eq_of_lt (by omega)

/-! ## Words -/

/-- An `or` is zero when both sides are. -/
theorem orz (a b : BitVec 32) : a ||| b = 0 ↔ a = 0 ∧ b = 0 := by
  constructor
  · intro h
    have hb : ∀ i, (a ||| b).getLsbD i = false := by intro i; rw [h]; simp
    simp only [BitVec.getLsbD_or, Bool.or_eq_false_iff] at hb
    exact ⟨BitVec.eq_of_getLsbD_eq (fun i _ => by simp [(hb i).1]),
      BitVec.eq_of_getLsbD_eq (fun i _ => by simp [(hb i).2])⟩
  · rintro ⟨rfl, rfl⟩; rfl

/-- An `xor` is zero when the sides are equal. -/
theorem xorz (a b : BitVec 32) : a ^^^ b = 0 ↔ a = b := by
  constructor
  · intro h
    have hb : ∀ i, (a ^^^ b).getLsbD i = false := by intro i; rw [h]; simp
    simp only [BitVec.getLsbD_xor] at hb
    exact BitVec.eq_of_getLsbD_eq (fun i _ => by have := hb i; revert this; cases a.getLsbD i <;> cases b.getLsbD i <;> simp)
  · rintro rfl; simp

/-- `sltu a0, x0, s6`: one exactly when `s6` is not zero. -/
theorem sltu_zero (x : Word) : (if (0 : Word).ult x then (1 : Word) else 0) = if x = 0 then 0 else 1 := by
  by_cases h : x = 0
  · subst h; decide
  · have pos : 0 < x.toNat := Nat.pos_of_ne_zero (fun e => h (BitVec.eq_of_toNat_eq (by simpa using e)))
    have : (0 : Word).ult x = true := by
      simp only [BitVec.ult]; simpa using pos
    rw [ite_eq_left_of_eq_true _ _ (eq_true this)]
    exact (ite_eq_right_of_eq_false _ _ (eq_false h)).symm

/-- Eight words equal at two places is 32 bytes equal there. -/
theorem words_iff_bytes {m : Word → Byte} {a a' : Word} :
    (∀ j < 8, readLE m (a + BitVec.ofNat 32 (4 * j)) 4 = readLE m (a' + BitVec.ofNat 32 (4 * j)) 4)
      ↔ ∀ d < 32, m (a + BitVec.ofNat 32 d) = m (a' + BitVec.ofNat 32 d) := by
  have shift : ∀ (x : Word) (j e : Nat), j < 8 → e < 4 →
      x + BitVec.ofNat 32 (4 * j) + BitVec.ofNat 32 e = x + BitVec.ofNat 32 (4 * j + e) := by
    intro x j e _ _
    rw [BitVec.add_assoc]; congr 1
    apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega
  constructor
  · intro h d hd
    have := congrArg (fun v => BitVec.ofNat 8 (v / 256 ^ (d % 4))) (h (d / 4) (by omega))
    rw [readLE_four_byte _ _ _ (by omega), readLE_four_byte _ _ _ (by omega),
      shift _ _ _ (by omega) (by omega), shift _ _ _ (by omega) (by omega),
      show 4 * (d / 4) + d % 4 = d by omega] at this
    exact this
  · intro h j hj
    apply readLE_four_eq
    intro e he
    rw [shift _ _ _ hj he, shift _ _ _ hj he]
    exact h _ (by omega)

end Rv32
