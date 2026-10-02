/-
SPDX-License-Identifier: Apache-2.0

# What a proof about a kernel needs, once

Lemmas about the model in `Rv32.Machine` that every kernel proof uses, so that a
kernel's own file holds only what that kernel is asking about:

- **runs compose**: `run (a + b)` is `run a`, then `run b` from where it stopped;
- **a loaded program fetches**: if memory holds the encoding of `i` at `pc`,
  `step` executes `i` — the bridge from `kernel.bin`'s bytes to instructions,
  through exp201's `decode_encode`;
- **registers**: what a read sees after a write;
- **memory**: what a byte holds after a store, and which bytes a load reads.

Addresses are `BitVec 32`, and every fact about them goes through `toNat` and
`omega`, with the region's own bound — `base + size ≤ 2^32` — saying nothing
wraps.
-/
import Rv32.Machine
import Rv32.Load

namespace Rv32

/-! ## Runs compose -/

theorem run_zero (env : Env) (s : Machine) : run env 0 s = .running s := rfl

theorem run_succ_running {env : Env} {s s' : Machine} (n : Nat) (h : step env s = .running s') :
    run env (n + 1) s = run env n s' := by
  simp [run, h]

theorem run_succ_halted {env : Env} {s s' : Machine} {c : Word} (n : Nat)
    (h : step env s = .halted c s') : run env (n + 1) s = .halted c s' := by
  simp [run, h]

theorem run_add (env : Env) (a b : Nat) (s : Machine) :
    run env (a + b) s = match run env a s with
      | .running s' => run env b s'
      | o => o := by
  induction a generalizing s with
  | zero => simp [run]
  | succ a ih =>
    rw [Nat.add_right_comm, run, run]
    cases h : step env s with
    | running s' => exact ih s'
    | halted c s' => rfl
    | fault f s' => rfl

theorem run_add_running {env : Env} {a b : Nat} {s s' : Machine} (h : run env a s = .running s') :
    run env (a + b) s = run env b s' := by
  rw [run_add, h]

/-! ## Registers -/

@[simp] theorem reg_zero (s : Machine) : s.reg 0 = 0 := by simp [Machine.reg]

/-- The same, for `x0` written as the literal an instruction carries. -/
@[simp] theorem reg_zero' (s : Machine) : s.reg 0#5 = 0 := by unfold Machine.reg; rfl

theorem reg_setReg (s : Machine) (rd r : Reg) (v : Word) :
    (s.setReg rd v).reg r = if r = rd ∧ rd ≠ 0 then v else s.reg r := by
  unfold Machine.setReg Machine.reg
  by_cases h0 : rd = 0 <;> by_cases hr : r = rd <;> by_cases hr0 : r = 0 <;> simp_all

@[simp] theorem setReg_mem (s : Machine) (rd : Reg) (v : Word) : (s.setReg rd v).mem = s.mem := by
  unfold Machine.setReg; split <;> rfl

@[simp] theorem setReg_pc (s : Machine) (rd : Reg) (v : Word) : (s.setReg rd v).pc = s.pc := by
  unfold Machine.setReg; split <;> rfl

@[simp] theorem setPc_mem (s : Machine) (p : Word) : (s.setPc p).mem = s.mem := rfl
@[simp] theorem setPc_pc (s : Machine) (p : Word) : (s.setPc p).pc = p := rfl
@[simp] theorem setPc_reg (s : Machine) (p : Word) (r : Reg) : (s.setPc p).reg r = s.reg r := rfl
@[simp] theorem next_mem (s : Machine) : s.next.mem = s.mem := rfl
@[simp] theorem next_pc (s : Machine) : s.next.pc = s.pc + 4 := rfl
@[simp] theorem next_reg (s : Machine) (r : Reg) : s.next.reg r = s.reg r := rfl

/-- A store rebuilds the machine with new memory and the same registers;
these read through that, whatever the `pc` field has been rewritten to. -/
@[simp] theorem mk_mem (p : Word) (s : Machine) (m : Word → Byte) :
    ({ pc := p, regs := s.regs, mem := m } : Machine).mem = m := rfl
@[simp] theorem mk_pc (p : Word) (s : Machine) (m : Word → Byte) :
    ({ pc := p, regs := s.regs, mem := m } : Machine).pc = p := rfl
@[simp] theorem mk_reg (p : Word) (s : Machine) (m : Word → Byte) (r : Reg) :
    ({ pc := p, regs := s.regs, mem := m } : Machine).reg r = s.reg r := rfl

/-! ## Memory -/

/-- `n` bytes from `a`: byte `j` at weight `256^j`. -/
theorem readLE_four (m : Word → Byte) (a : Word) :
    readLE m a 4 = (m a).toNat + 256 * (m (a + 1)).toNat + 65536 * (m (a + 2)).toNat
      + 16777216 * (m (a + 3)).toNat := by
  simp only [readLE]
  have e2 : a + 1 + 1 = a + 2 := by rw [BitVec.add_assoc]; rfl
  have e3 : a + 1 + 1 + 1 = a + 3 := by rw [BitVec.add_assoc, BitVec.add_assoc]; rfl
  rw [e3, e2]; omega

theorem readLE_four_lt (m : Word → Byte) (a : Word) : readLE m a 4 < 2^32 := by
  rw [readLE_four]
  have := (m a).isLt; have := (m (a + 1)).isLt; have := (m (a + 2)).isLt; have := (m (a + 3)).isLt
  omega

/-- What a byte holds after a store of `n` bytes at `a`: the store's byte if it
is one of them, what it held before otherwise. -/
theorem writeLE_apply (m : Word → Byte) (a : Word) (v n : Nat) (hn : n < 2^32) (x : Word) :
    writeLE m a v n x =
      if (x - a).toNat < n then BitVec.ofNat 8 (v / 256 ^ (x - a).toNat) else m x := by
  induction n generalizing m a v with
  | zero => simp [writeLE]
  | succ n ih =>
    simp only [writeLE]
    rw [ih _ _ _ (by omega)]
    by_cases hx : x = a
    · subst hx
      have h1 : (1 : Word).toNat = 1 := rfl
      have : (x - (x + 1)).toNat = 2^32 - 1 := by
        have := x.isLt
        rw [BitVec.toNat_sub, BitVec.toNat_add, h1]; omega
      have hn' : ¬ (x - (x + 1)).toNat < n := by omega
      have hz : (x - x).toNat = 0 := by simp
      have hpos : 0 < n + 1 := by omega
      simp only [hn', hz, hpos, ↓reduceIte, writeByte, Nat.pow_zero, Nat.div_one]
    · have hd : (x - (a + 1)).toNat + 1 = (x - a).toNat := by
        have hne : x.toNat ≠ a.toNat := fun h => hx (BitVec.eq_of_toNat_eq h)
        have := x.isLt; have := a.isLt
        have h1 : (1 : Word).toNat = 1 := rfl
        rw [BitVec.toNat_sub, BitVec.toNat_sub, BitVec.toNat_add, h1]
        omega
      simp only [writeByte, hx, ↓reduceIte]
      by_cases hlt : (x - (a + 1)).toNat < n
      · have hlt' : (x - a).toNat < n + 1 := by omega
        simp only [hlt, hlt', ↓reduceIte]
        congr 1
        rw [← hd, Nat.pow_succ, Nat.mul_comm, ← Nat.div_div_eq_div_mul]
      · have hlt' : ¬ (x - a).toNat < n + 1 := by omega
        simp only [hlt, hlt', ↓reduceIte]

/-- The bytes a load of four read, one at a time. -/
theorem readLE_four_byte (m : Word → Byte) (a : Word) (d : Nat) (hd : d < 4) :
    BitVec.ofNat 8 (readLE m a 4 / 256 ^ d) = m (a + BitVec.ofNat 32 d) := by
  rw [readLE_four]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ofNat]
  have h0 := (m a).isLt; have h1 := (m (a + 1)).isLt
  have h2 := (m (a + 2)).isLt; have h3 := (m (a + 3)).isLt
  rcases (by omega : d = 0 ∨ d = 1 ∨ d = 2 ∨ d = 3) with h | h | h | h <;> subst h
  · simp only [Nat.pow_zero, Nat.div_one]
    rw [show a + BitVec.ofNat 32 0 = a by simp]; omega
  · rw [show a + BitVec.ofNat 32 1 = a + 1 by rfl]; omega
  · rw [show a + BitVec.ofNat 32 2 = a + 2 by rfl]; omega
  · rw [show a + BitVec.ofNat 32 3 = a + 3 by rfl]; omega

/-- Two memories that agree on four bytes read the same word there. -/
theorem readLE_four_congr {m m' : Word → Byte} {a : Word}
    (h : ∀ d : Nat, d < 4 → m (a + BitVec.ofNat 32 d) = m' (a + BitVec.ofNat 32 d)) :
    readLE m a 4 = readLE m' a 4 := by
  rw [readLE_four, readLE_four]
  have h0 := h 0 (by decide); have h1 := h 1 (by decide)
  have h2 := h 2 (by decide); have h3 := h 3 (by decide)
  simp only [show a + BitVec.ofNat 32 0 = a by simp] at h0
  rw [h0, show a + 1 = a + BitVec.ofNat 32 1 from rfl, h1, show a + 2 = a + BitVec.ofNat 32 2 from rfl,
    h2, show a + 3 = a + BitVec.ofNat 32 3 from rfl, h3]

/-! ## A loaded program fetches -/

/-- The program `prog` is at `base`: word `k` of memory there is the encoding
of instruction `k`. -/
def CodeAt (m : Word → Byte) (base : Word) (prog : List Instr) : Prop :=
  ∀ k (h : k < prog.length), readLE m (base + BitVec.ofNat 32 (4 * k)) 4 = (encode prog[k]).toNat

theorem fetch_of_code {env : Env} {s : Machine} {base : Word} {prog : List Instr} {k : Nat}
    (hk : k < prog.length) (hcode : CodeAt s.mem base prog)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (halign : s.pc.toNat % 4 = 0) (hok : env.region.ok s.pc 4) :
    fetch env s = .ok prog[k] := by
  unfold fetch
  have h1 : ¬ s.pc.toNat % 4 ≠ 0 := by omega
  have h2 : ¬ ¬ env.region.ok s.pc 4 := by simpa using hok
  simp only [h1, h2, ↓reduceIte]
  rw [hpc, hcode k hk, BitVec.ofNat_toNat, BitVec.setWidth_eq, decode_encode]

/-- A program stays loaded through any change of memory that leaves its bytes
alone. -/
theorem CodeAt.congr {m m' : Word → Byte} {base : Word} {prog : List Instr}
    (hfit : base.toNat + 4 * prog.length ≤ 2^32)
    (h : ∀ x : Word, base.toNat ≤ x.toNat → x.toNat < base.toNat + 4 * prog.length → m x = m' x)
    (hc : CodeAt m base prog) : CodeAt m' base prog := by
  intro k hk
  rw [← hc k hk]
  apply (readLE_four_congr _).symm
  intro d hd
  have := base.isLt
  apply h <;> simp only [BitVec.toNat_add, BitVec.toNat_ofNat] <;> omega

theorem step_of_code {env : Env} {s : Machine} {base : Word} {prog : List Instr} {k : Nat}
    (hk : k < prog.length) (hcode : CodeAt s.mem base prog)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (halign : s.pc.toNat % 4 = 0) (hok : env.region.ok s.pc 4) :
    step env s = exec env s prog[k] := by
  unfold step; rw [fetch_of_code hk hcode hpc halign hok]

theorem run_code {env : Env} {s s' : Machine} {base : Word} {prog : List Instr} {k : Nat}
    (n : Nat) (hk : k < prog.length) (hcode : CodeAt s.mem base prog)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (halign : s.pc.toNat % 4 = 0) (hok : env.region.ok s.pc 4)
    (hexec : exec env s prog[k] = .running s') : run env (n + 1) s = run env n s' :=
  run_succ_running n ((step_of_code hk hcode hpc halign hok).trans hexec)

/-! ## The two instructions that touch memory -/

theorem exec_lw {env : Env} {s : Machine} {rd rs1 : Reg} {imm : BitVec 12}
    (halign : (s.reg rs1 + imm.signExtend 32).toNat % 4 = 0)
    (hok : env.region.ok (s.reg rs1 + imm.signExtend 32) 4) :
    exec env s (.ld .lw rd rs1 imm) =
      .running (s.setReg rd (BitVec.ofNat 32 (readLE s.mem (s.reg rs1 + imm.signExtend 32) 4))).next := by
  have h1 : ¬ (s.reg rs1 + imm.signExtend 32).toNat % 4 ≠ 0 := by omega
  have h2 : ¬ ¬ env.region.ok (s.reg rs1 + imm.signExtend 32) 4 := by simpa using hok
  simp only [exec, LdOp.extend, LdOp.size]
  simp only [h1, h2, ↓reduceIte]

theorem exec_sw {env : Env} {s : Machine} {rs1 rs2 : Reg} {imm : BitVec 12}
    (halign : (s.reg rs1 + imm.signExtend 32).toNat % 4 = 0)
    (hok : env.region.ok (s.reg rs1 + imm.signExtend 32) 4) :
    exec env s (.st .sw rs1 rs2 imm) =
      .running ({ s with mem := writeLE s.mem (s.reg rs1 + imm.signExtend 32) (s.reg rs2).toNat 4 }).next := by
  have h1 : ¬ (s.reg rs1 + imm.signExtend 32).toNat % 4 ≠ 0 := by omega
  have h2 : ¬ ¬ env.region.ok (s.reg rs1 + imm.signExtend 32) 4 := by simpa using hok
  simp only [exec, StOp.size]
  simp only [h1, h2, ↓reduceIte]

/-- A branch always continues; where to is a question about the registers. -/
theorem exec_br {env : Env} {s : Machine} {op : BrOp} {rs1 rs2 : Reg} {off : BitVec 12} :
    exec env s (.br op rs1 rs2 off) = .running
      (if taken op (s.reg rs1) (s.reg rs2) then s.setPc (s.pc + (off ++ 0#1).signExtend 32)
       else s.next) := by
  simp only [exec]; split <;> rfl

/-- `ecall` with `t0 = 1` is HALT, with `a0` as the result. -/
theorem exec_halt {env : Env} {s : Machine} (h : s.reg T0 = 1) :
    exec env s .ecall = .halted (s.reg A0) s := by
  have h0 : ¬ s.reg T0 = 0 := by rw [h]; decide
  simp only [exec, syscall, h0, ↓reduceIte]
  simp only [h, ↓reduceIte]

theorem run_code_halt {env : Env} {s s' : Machine} {base : Word} {prog : List Instr} {k : Nat}
    {c : Word} (n : Nat) (hk : k < prog.length) (hcode : CodeAt s.mem base prog)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (halign : s.pc.toNat % 4 = 0) (hok : env.region.ok s.pc 4)
    (hexec : exec env s prog[k] = .halted c s') : run env (n + 1) s = .halted c s' :=
  run_succ_halted n ((step_of_code hk hcode hpc halign hok).trans hexec)

theorem exec_br_taken {env : Env} {s : Machine} {op : BrOp} {rs1 rs2 : Reg} {off : BitVec 12}
    (h : taken op (s.reg rs1) (s.reg rs2) = true) :
    exec env s (.br op rs1 rs2 off) = .running (s.setPc (s.pc + (off ++ 0#1).signExtend 32)) := by
  simp only [exec, h, ↓reduceIte]

theorem exec_br_not {env : Env} {s : Machine} {op : BrOp} {rs1 rs2 : Reg} {off : BitVec 12}
    (h : taken op (s.reg rs1) (s.reg rs2) = false) :
    exec env s (.br op rs1 rs2 off) = .running s.next := by
  simp only [exec, h, Bool.false_eq_true, ↓reduceIte]

end Rv32
