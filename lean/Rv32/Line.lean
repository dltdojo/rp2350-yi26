/-
SPDX-License-Identifier: Apache-2.0

# A straight line of register instructions

`op`, `opi` and `sh` write one register from registers and go on; nothing
else happens. A run of them is a function of the registers alone, so a block
of them is stated once as `Machine.line` — the instructions folded over the
machine — and run in one lemma, `run_line`, instead of one `regStep` each.
What a register holds afterwards is then `simp` over the fold, and the
kernel's proof compares that with its specification. exp208's SHA-256 rounds
are fifty instructions, forty-eight of them of this kind.
-/
import Rv32.Kernel

namespace Rv32

/-- The register instructions: they write `rd` and go on. -/
def isAlu : Instr → Bool
  | .op .. | .opi .. | .sh .. => true
  | _ => false

/-- One register instruction, as `exec` takes it. -/
def Machine.alu (s : Machine) : Instr → Machine
  | .op op rd rs1 rs2 => (s.setReg rd (aluR op (s.reg rs1) (s.reg rs2))).next
  | .opi op rd rs1 imm => (s.setReg rd (aluI op (s.reg rs1) (imm.signExtend 32))).next
  | .sh op rd rs1 sa => (s.setReg rd (shiftI op (s.reg rs1) sa.toNat)).next
  | _ => s.next

/-- A straight line of them. -/
def Machine.line (s : Machine) (blk : List Instr) : Machine := blk.foldl Machine.alu s

theorem exec_alu {env : Env} {s : Machine} {i : Instr} (h : isAlu i = true) :
    exec env s i = .running (s.alu i) := by
  cases i <;> simp_all [isAlu, exec, Machine.alu]

@[simp] theorem alu_mem (s : Machine) (i : Instr) : (s.alu i).mem = s.mem := by
  cases i <;> simp [Machine.alu]

@[simp] theorem alu_pc (s : Machine) (i : Instr) : (s.alu i).pc = s.pc + 4 := by
  cases i <;> simp [Machine.alu]

@[simp] theorem line_nil (s : Machine) : s.line [] = s := rfl

@[simp] theorem line_cons (s : Machine) (i : Instr) (blk : List Instr) :
    s.line (i :: blk) = (s.alu i).line blk := rfl

theorem line_append (s : Machine) (a b : List Instr) : s.line (a ++ b) = (s.line a).line b := by
  simp [Machine.line, List.foldl_append]

@[simp] theorem line_mem (s : Machine) (blk : List Instr) : (s.line blk).mem = s.mem := by
  induction blk generalizing s with
  | nil => rfl
  | cons i blk ih => rw [line_cons, ih, alu_mem]

theorem line_pc (s : Machine) (blk : List Instr) :
    (s.line blk).pc = s.pc + BitVec.ofNat 32 (4 * blk.length) := by
  induction blk generalizing s with
  | nil => simp
  | cons i blk ih =>
    rw [line_cons, ih, alu_pc, BitVec.add_assoc, show (4 : Word) = BitVec.ofNat 32 4 from rfl,
      BitVec.ofNat_add_ofNat]
    congr 2
    simp only [List.length_cons]
    omega

/-- The register an instruction of a line writes. -/
def rdOf : Instr → Option Reg
  | .op _ rd _ _ | .opi _ rd _ _ | .sh _ rd _ _ => some rd
  | _ => none

/-- A register no instruction of the line writes is the same after it. -/
theorem line_keeps (s : Machine) (blk : List Instr) (r : Reg) (h : ∀ i ∈ blk, rdOf i ≠ some r) :
    (s.line blk).reg r = s.reg r := by
  induction blk generalizing s with
  | nil => rfl
  | cons i blk ih =>
    rw [line_cons, ih _ (fun j hj => h j (List.mem_cons_of_mem _ hj))]
    have key : ∀ rd, rdOf i = some rd → r ≠ rd := fun rd e h' => h i (List.mem_cons_self ..) (by rw [e, h'])
    cases i <;> simp only [Machine.alu, next_reg, reg_setReg] <;> simp [key _ rfl]

variable {env : Env} {base : Word} {prog : List Instr}

/-- **A straight line, run**: `blk`, sitting at instruction `k` of `prog`, all
register instructions, takes `blk.length` steps to `s.line blk`. -/
theorem run_line (hp : Placed env base) (blk : List Instr) (halu : blk.all isAlu = true) :
    ∀ (k : Nat) (s : Machine), (prog.drop k).take blk.length = blk → k + blk.length ≤ prog.length →
      CodeAt s.mem base prog → s.pc = base + BitVec.ofNat 32 (4 * k) → 4 * prog.length < 0x10000 →
      run env blk.length s = .running (s.line blk) := by
  induction blk with
  | nil => intro k s _ _ _ _ _; rfl
  | cons i blk ih =>
    intro k s hseg hk hcode hpc hlen
    simp only [List.all_cons, Bool.and_eq_true] at halu
    have hk' : k < prog.length := by simp at hk; omega
    have hi : prog.getD k .ecall = i := by
      have h := congrArg List.head? hseg
      simp only [List.length_cons, List.head?_cons] at h
      rw [List.head?_take, List.head?_drop] at h
      simp only [Nat.add_one_ne_zero, ↓reduceIte] at h
      rw [List.getD_eq_getElem?_getD, h]; rfl
    have hseg' : (prog.drop (k + 1)).take blk.length = blk := by
      have h := congrArg List.tail hseg
      rw [List.length_cons, List.tail_cons, ← List.drop_one, List.drop_take, List.drop_drop] at h
      simpa [Nat.add_comm] using h
    rw [show (i :: blk).length = blk.length + 1 by simp,
      stepK hp k hk' hcode hpc hi (exec_alu halu.1) blk.length hlen, line_cons]
    exact ih halu.2 (k + 1) _ hseg' (by simp at hk; omega) (by simpa using hcode)
      (by rw [alu_pc, hpc]; exact pc_next hp.fit k (by omega)) hlen

/-- And where it ends: `blk.length` instructions on. -/
theorem line_pc_at {s : Machine} {k : Nat} (blk : List Instr)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) (hk : 4 * (k + blk.length) < 0x10000) :
    (s.line blk).pc = base + BitVec.ofNat 32 (4 * (k + blk.length)) := by
  rw [line_pc, hpc, BitVec.add_assoc]
  congr 1
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
  rw [Nat.mod_eq_of_lt (show 4 * k < 2 ^ 32 by omega), Nat.mod_eq_of_lt (show 4 * blk.length < 2 ^ 32 by omega),
    Nat.mod_eq_of_lt (show 4 * (k + blk.length) < 2 ^ 32 by omega)]
  omega

end Rv32
