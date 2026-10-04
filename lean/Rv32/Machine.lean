/-
SPDX-License-Identifier: Apache-2.0

# What one RV32IM instruction does, in User mode, inside one region

The model the kernel's proofs are about. It is deliberately smaller than the
machine: one hart, User mode only, no interrupts, no CSRs, and one region of
memory that the kernel may fetch from, load from and store to. Everything
outside that region is a fault, which is what the shell's PMP setting makes
it on the chip; misaligned accesses are a fault, which is what Hazard3 does
with them.

`ecall` is the only way out, and it is the sig.golf interface:

| `t0` | arguments | effect |
| --- | --- | --- |
| 0 | `a0` input, `a1` length, `a2` output | `HASH`: 32 bytes of `env.hash` of the input written at `a2`, `pc + 4` |
| 1 | `a0` result code | `HALT`: stop, with `a0` |

`env.hash` is a parameter. The proofs never look inside it, which is the
same relationship a zkVM has with a precompile: the theorem is "given a
function that returns 32 bytes", and whether the chip's SHA-256 block is that
function is measured, not proved.

Where the specification leaves a choice to the implementation, this model makes
the one Hazard3 makes, and says so at the site. Where the model is stricter than
the chip — a jump to an address that is 2 mod 4 is legal on a core with the C
extension and a fault here — it is stricter on purpose: a kernel the theorems
are about never does it, and a model that refuses it cannot be wrong about it.
-/
import Rv32.Isa

namespace Rv32

abbrev Word := BitVec 32
abbrev Byte := BitVec 8

structure Machine where
  pc   : Word
  regs : Reg → Word
  mem  : Word → Byte

/-- Where the kernel may go: `[lo, hi)`, as numbers, so nothing here wraps. -/
structure Region where
  lo : Nat
  hi : Nat

def Region.ok (r : Region) (a : Word) (n : Nat) : Prop := r.lo ≤ a.toNat ∧ a.toNat + n ≤ r.hi

instance (r : Region) (a : Word) (n : Nat) : Decidable (r.ok a n) := by
  unfold Region.ok; infer_instance

/-- The world outside the kernel: its region, and the function `HASH` stands for. -/
structure Env where
  region : Region
  hash   : List Byte → Fin 32 → Byte

inductive Fault
  | fetchMisaligned | fetchAccess | illegal (w : Word)
  | loadMisaligned | loadAccess | storeMisaligned | storeAccess
  | hashArgs | unknownCall
  deriving DecidableEq, Repr

inductive Outcome
  | running (s : Machine)
  | halted (code : Word) (s : Machine)
  | fault (f : Fault) (s : Machine)

/-! ## Registers and memory -/

/-- `x0` reads as zero, whatever is stored for it. -/
def Machine.reg (s : Machine) (r : Reg) : Word := if r = 0 then 0 else s.regs r

/-- A write to `x0` is dropped. -/
def Machine.setReg (s : Machine) (r : Reg) (v : Word) : Machine :=
  if r = 0 then s else { s with regs := fun x => if x = r then v else s.regs x }

def Machine.setPc (s : Machine) (pc : Word) : Machine := { s with pc := pc }

def Machine.next (s : Machine) : Machine := s.setPc (s.pc + 4)

/-- Little-endian: `n` bytes from `a`, as a number. -/
def readLE (m : Word → Byte) (a : Word) : Nat → Nat
  | 0 => 0
  | n + 1 => (m a).toNat + 256 * readLE m (a + 1) n

def writeByte (m : Word → Byte) (a : Word) (v : Byte) : Word → Byte :=
  fun x => if x = a then v else m x

/-- Little-endian: the low `n` bytes of `v` from `a`. -/
def writeLE (m : Word → Byte) (a : Word) (v : Nat) : Nat → (Word → Byte)
  | 0 => m
  | n + 1 => writeLE (writeByte m a (BitVec.ofNat 8 v)) (a + 1) (v / 256) n

def readBytes (m : Word → Byte) (a : Word) : Nat → List Byte
  | 0 => []
  | n + 1 => m a :: readBytes m (a + 1) n

def writeBytes (m : Word → Byte) (a : Word) (f : Fin 32 → Byte) : Word → Byte :=
  fun x =>
    let d := (x - a).toNat
    if h : d < 32 then f ⟨d, h⟩ else m x

/-! ## Arithmetic the M extension defines case by case -/

def intMin : Word := 0x80000000#32

/-- Signed division rounds toward zero; by zero is all ones; the one overflow
case, `intMin / -1`, is `intMin`. RISC-V unprivileged spec, Table 13.1. -/
def divS (a b : Word) : Word :=
  if b = 0 then BitVec.allOnes 32
  else if a = intMin ∧ b = BitVec.allOnes 32 then intMin
  else BitVec.ofInt 32 (a.toInt.tdiv b.toInt)

def divU (a b : Word) : Word :=
  if b = 0 then BitVec.allOnes 32 else BitVec.ofNat 32 (a.toNat / b.toNat)

/-- The remainder has the dividend's sign; by zero is the dividend; the
overflow case is zero. -/
def remS (a b : Word) : Word :=
  if b = 0 then a
  else if a = intMin ∧ b = BitVec.allOnes 32 then 0
  else BitVec.ofInt 32 (a.toInt.tmod b.toInt)

def remU (a b : Word) : Word :=
  if b = 0 then a else BitVec.ofNat 32 (a.toNat % b.toNat)

/-- The high half of a 64-bit product, taken from its two's complement bits so
no rounding convention of `Int` division is involved. -/
def mulHigh (p : Int) : Word := (BitVec.ofInt 64 p).extractLsb' 32 32

def aluR : ROp → Word → Word → Word
  | .add, a, b => a + b
  | .sub, a, b => a - b
  | .sll, a, b => a <<< (b.toNat % 32)
  | .slt, a, b => if a.slt b then 1 else 0
  | .sltu, a, b => if a.ult b then 1 else 0
  | .xor, a, b => a ^^^ b
  | .srl, a, b => a >>> (b.toNat % 32)
  | .sra, a, b => a.sshiftRight (b.toNat % 32)
  | .or, a, b => a ||| b
  | .and, a, b => a &&& b
  | .mul, a, b => a * b
  | .mulh, a, b => mulHigh (a.toInt * b.toInt)
  | .mulhsu, a, b => mulHigh (a.toInt * b.toNat)
  | .mulhu, a, b => mulHigh (a.toNat * b.toNat)
  | .div, a, b => divS a b
  | .divu, a, b => divU a b
  | .rem, a, b => remS a b
  | .remu, a, b => remU a b

def aluI : IOp → Word → Word → Word
  | .addi, a, b => a + b
  | .slti, a, b => if a.slt b then 1 else 0
  | .sltiu, a, b => if a.ult b then 1 else 0
  | .xori, a, b => a ^^^ b
  | .ori, a, b => a ||| b
  | .andi, a, b => a &&& b

def shiftI : ShOp → Word → Nat → Word
  | .slli, a, n => a <<< n
  | .srli, a, n => a >>> n
  | .srai, a, n => a.sshiftRight n

def taken : BrOp → Word → Word → Bool
  | .beq, a, b => a == b
  | .bne, a, b => a != b
  | .blt, a, b => a.slt b
  | .bge, a, b => !(a.slt b)
  | .bltu, a, b => a.ult b
  | .bgeu, a, b => !(a.ult b)

def LdOp.size : LdOp → Nat
  | .lb | .lbu => 1 | .lh | .lhu => 2 | .lw => 4

def StOp.size : StOp → Nat
  | .sb => 1 | .sh => 2 | .sw => 4

/-- What a load of `n` bytes becomes in a register. -/
def LdOp.extend : LdOp → Nat → Word
  | .lb, v => (BitVec.ofNat 8 v).signExtend 32
  | .lh, v => (BitVec.ofNat 16 v).signExtend 32
  | .lw, v => BitVec.ofNat 32 v
  | .lbu, v => BitVec.ofNat 32 v
  | .lhu, v => BitVec.ofNat 32 v

/-! ## One step -/

def T0 : Reg := 5
def A0 : Reg := 10
def A1 : Reg := 11
def A2 : Reg := 12

/-- The two system calls. -/
def syscall (env : Env) (s : Machine) : Outcome :=
  let t0 := s.reg T0
  if t0 = 0 then
    let src := s.reg A0
    let len := (s.reg A1).toNat
    let dst := s.reg A2
    if len % 64 = 0 ∧ src.toNat % 4 = 0 ∧ dst.toNat % 4 = 0
        ∧ env.region.ok src len ∧ env.region.ok dst 32 then
      .running { s with mem := writeBytes s.mem dst (env.hash (readBytes s.mem src len)) }.next
    else .fault .hashArgs s
  else if t0 = 1 then .halted (s.reg A0) s
  else .fault .unknownCall s

def exec (env : Env) (s : Machine) : Instr → Outcome
  | .lui rd imm => .running (s.setReg rd (imm ++ 0#12)).next
  | .auipc rd imm => .running (s.setReg rd (s.pc + (imm ++ 0#12))).next
  | .jal rd off => .running ((s.setReg rd (s.pc + 4)).setPc (s.pc + (off ++ 0#1).signExtend 32))
  | .jalr rd rs1 imm =>
    let target := (s.reg rs1 + imm.signExtend 32) &&& ~~~1#32
    .running ((s.setReg rd (s.pc + 4)).setPc target)
  | .br op rs1 rs2 off =>
    if taken op (s.reg rs1) (s.reg rs2) then .running (s.setPc (s.pc + (off ++ 0#1).signExtend 32))
    else .running s.next
  | .ld op rd rs1 imm =>
    let a := s.reg rs1 + imm.signExtend 32
    if a.toNat % op.size ≠ 0 then .fault .loadMisaligned s
    else if ¬ env.region.ok a op.size then .fault .loadAccess s
    else .running (s.setReg rd (op.extend (readLE s.mem a op.size))).next
  | .st op rs1 rs2 imm =>
    let a := s.reg rs1 + imm.signExtend 32
    if a.toNat % op.size ≠ 0 then .fault .storeMisaligned s
    else if ¬ env.region.ok a op.size then .fault .storeAccess s
    else .running { s with mem := writeLE s.mem a (s.reg rs2).toNat op.size }.next
  | .opi op rd rs1 imm => .running (s.setReg rd (aluI op (s.reg rs1) (imm.signExtend 32))).next
  | .sh op rd rs1 sa => .running (s.setReg rd (shiftI op (s.reg rs1) sa.toNat)).next
  | .op op rd rs1 rs2 => .running (s.setReg rd (aluR op (s.reg rs1) (s.reg rs2))).next
  | .ecall => syscall env s

def fetch (env : Env) (s : Machine) : Except Fault Instr :=
  if s.pc.toNat % 4 ≠ 0 then .error .fetchMisaligned
  else if ¬ env.region.ok s.pc 4 then .error .fetchAccess
  else
    let w := BitVec.ofNat 32 (readLE s.mem s.pc 4)
    match decode w with
    | some i => .ok i
    | none => .error (.illegal w)

def step (env : Env) (s : Machine) : Outcome :=
  match fetch env s with
  | .ok i => exec env s i
  | .error f => .fault f s

/-- At most `n` instructions. A halt or a fault ends the run early and is kept. -/
def run (env : Env) : Nat → Machine → Outcome
  | 0, s => .running s
  | n + 1, s =>
    match step env s with
    | .running s' => run env n s'
    | o => o

/-- Run until it stops, and count: the number returned is every instruction
`step` was asked to execute, the one that halted or faulted included. -/
def runCount (env : Env) : Nat → Machine → Nat → Outcome × Nat
  | 0, s, k => (.running s, k)
  | n + 1, s, k =>
    match step env s with
    | .running s' => runCount env n s' (k + 1)
    | o => (o, k + 1)

end Rv32
