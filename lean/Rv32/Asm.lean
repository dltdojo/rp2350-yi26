/-
SPDX-License-Identifier: Apache-2.0

# Instructions as text, in the form LLVM reads and writes

`Instr.toAsm` prints an instruction the way `llvm-mc` accepts it and
`llvm-mc --disassemble -M numeric -M no-aliases` prints it back: registers as
`x0`..`x31`, every immediate as the signed (or, for `lui` and `auipc`, the
unsigned) number the specification says the field holds, and branch and jump
offsets in bytes. It exists so that an encoding chosen here can be held against
an assembler written by somebody else; nothing in a proof depends on it.
-/
import Rv32.Isa

namespace Rv32

def regName (r : Reg) : String := s!"x{r.toNat}"

def BrOp.name : BrOp → String
  | .beq => "beq" | .bne => "bne" | .blt => "blt" | .bge => "bge"
  | .bltu => "bltu" | .bgeu => "bgeu"

def LdOp.name : LdOp → String
  | .lb => "lb" | .lh => "lh" | .lw => "lw" | .lbu => "lbu" | .lhu => "lhu"

def StOp.name : StOp → String
  | .sb => "sb" | .sh => "sh" | .sw => "sw"

def IOp.name : IOp → String
  | .addi => "addi" | .slti => "slti" | .sltiu => "sltiu" | .xori => "xori"
  | .ori => "ori" | .andi => "andi"

def ShOp.name : ShOp → String
  | .slli => "slli" | .srli => "srli" | .srai => "srai"

def ROp.name : ROp → String
  | .add => "add" | .sub => "sub" | .sll => "sll" | .slt => "slt" | .sltu => "sltu"
  | .xor => "xor" | .srl => "srl" | .sra => "sra" | .or => "or" | .and => "and"
  | .mul => "mul" | .mulh => "mulh" | .mulhsu => "mulhsu" | .mulhu => "mulhu"
  | .div => "div" | .divu => "divu" | .rem => "rem" | .remu => "remu"

def Instr.toAsm : Instr → String
  | .lui rd imm => s!"lui {regName rd}, {imm.toNat}"
  | .auipc rd imm => s!"auipc {regName rd}, {imm.toNat}"
  | .jal rd off => s!"jal {regName rd}, {(off ++ 0#1).toInt}"
  | .jalr rd rs1 imm => s!"jalr {regName rd}, {imm.toInt}({regName rs1})"
  | .br o rs1 rs2 off => s!"{o.name} {regName rs1}, {regName rs2}, {(off ++ 0#1).toInt}"
  | .ld o rd rs1 imm => s!"{o.name} {regName rd}, {imm.toInt}({regName rs1})"
  | .st o rs1 rs2 imm => s!"{o.name} {regName rs2}, {imm.toInt}({regName rs1})"
  | .opi o rd rs1 imm => s!"{o.name} {regName rd}, {regName rs1}, {imm.toInt}"
  | .sh o rd rs1 sa => s!"{o.name} {regName rd}, {regName rs1}, {sa.toNat}"
  | .op o rd rs1 rs2 => s!"{o.name} {regName rd}, {regName rs1}, {regName rs2}"
  | .ecall => "ecall"

def hex8 (n : Nat) : String :=
  let s := String.ofList (Nat.toDigits 16 n)
  "".pushn '0' (8 - s.length) ++ s

end Rv32
