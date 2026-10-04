/-
SPDX-License-Identifier: Apache-2.0

exp201's half of the differential: instructions and words, printed for an
assembler that was not written here to judge.

  E|<asm>|<word>   an instruction, as text, and the word `encode` makes of it
  D|<word>|<asm>   a word, and what `decode` reads it as — or NONE

`differential.py` hands every E line's text to `llvm-mc` and every D line's
word to `llvm-objdump`, and compares. Nothing here is random in the sense of
changing between runs: the generator is a fixed linear congruential sequence,
so a failure names a line that will be there next time too.
-/
import Rv32.Isa
import Rv32.Asm

open Rv32

/-- Numerical Recipes' LCG. Not for anything but choosing test cases. -/
def lcg (x : Nat) : Nat := (1664525 * x + 1013904223) % 2^32

/-- The register numbers worth naming every time, then any. -/
def edgeRegs : List Nat := [0, 1, 2, 15, 16, 30, 31]

/-- Edge immediates for a field `w` bits wide, as bit patterns: zero, one,
all ones, the top bit alone, the top bit clear and the rest set. -/
def edgeImms (w : Nat) : List Nat := [0, 1, 2^w - 1, 2^(w-1), 2^(w-1) - 1]

/-- Every instruction form, with its fields filled from the three sources
given. -/
def forms (r1 r2 r3 : Nat) (i12 i20 i5 : Nat) : List Instr :=
  let a : Reg := .ofNat 5 r1
  let b : Reg := .ofNat 5 r2
  let c : Reg := .ofNat 5 r3
  [ .lui a (.ofNat 20 i20), .auipc a (.ofNat 20 i20), .jal a (.ofNat 20 i20),
    .jalr a b (.ofNat 12 i12) ] ++
  ([.beq, .bne, .blt, .bge, .bltu, .bgeu].map fun o => Instr.br o a b (.ofNat 12 i12)) ++
  ([.lb, .lh, .lw, .lbu, .lhu].map fun o => Instr.ld o a b (.ofNat 12 i12)) ++
  ([.sb, .sh, .sw].map fun o => Instr.st o a b (.ofNat 12 i12)) ++
  ([.addi, .slti, .sltiu, .xori, .ori, .andi].map fun o => Instr.opi o a b (.ofNat 12 i12)) ++
  ([.slli, .srli, .srai].map fun o => Instr.sh o a b (.ofNat 5 i5)) ++
  ([.add, .sub, .sll, .slt, .sltu, .xor, .srl, .sra, .or, .and,
    .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu].map fun o => Instr.op o a b c) ++
  [.ecall]

def encodeLines : List String := Id.run do
  let mut out := []
  -- Every edge register in every position, every edge immediate in every field.
  for r in edgeRegs do
    for (i12, i20, i5) in (edgeImms 12).zip ((edgeImms 20).zip (edgeImms 5)) do
      out := out ++ (forms r (31 - r) ((r + 7) % 32) i12 i20 i5).map fun i =>
        s!"E|{i.toAsm}|{hex8 (encode i).toNat}"
  -- And a fixed pseudo-random sample of everything else.
  let mut x := 201
  for _ in [0:40] do
    x := lcg x; let r1 := x % 32
    x := lcg x; let r2 := x % 32
    x := lcg x; let r3 := x % 32
    x := lcg x; let i12 := x % 2^12
    x := lcg x; let i20 := x % 2^20
    x := lcg x; let i5 := x % 32
    out := out ++ (forms r1 r2 r3 i12 i20 i5).map fun i =>
      s!"E|{i.toAsm}|{hex8 (encode i).toNat}"
  return out

/-- The opcodes a word is drawn with: the ten this model knows, three it
deliberately does not (`fence`, a load-fp, `amo`), and anything at all. -/
def opcodes : List Nat := [0x37, 0x17, 0x6f, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x73,
  0x0f, 0x07, 0x2f]

def decodeLines : List String := Id.run do
  let mut out := []
  let mut x := 2010
  for k in [0:6000] do
    x := lcg x
    let hi := x / 128
    let opc := if k % 14 = 13 then x % 128 else opcodes[k % 13]!
    let w := hi * 128 + opc
    let shown := match decode (.ofNat 32 w) with
      | some i => i.toAsm
      | none => "NONE"
    out := out ++ [s!"D|{hex8 w}|{shown}"]
  return out

def main : IO Unit := do
  for l in encodeLines do IO.println l
  for l in decodeLines do IO.println l
