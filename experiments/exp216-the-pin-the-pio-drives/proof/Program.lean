/-
SPDX-License-Identifier: Apache-2.0

# exp216 — the program, as instructions, and the words the chip runs

The PIO program is written here as `Pio.Instr` values, and its words are
what exp215's `encode` makes of them — the first time a word that goes onto
the chip comes out of the proved encoder rather than out of a hand table.
`lean --run` writes them into `shell/program.h`; check.sh holds that file to
this one, and the words to what pioasm makes of `drive.pio`.

The program waits for a word in the TX FIFO, sets the pin to 0 if it is
zero and to 1 otherwise, and answers with the same word through RX:

  0      set pindirs, 1      the pin is an output — once, before the wrap
  1      pull block          ← wrap target
  2      out x, 32
  3      jmp !x, 6
  4      set pins, 1
  5      jmp 7
  6      set pins, 0
  7      mov isr, x
  8      push block          → wrap
-/
import Pio.Isa
import Pio.Asm

namespace Exp216
open Pio

def program : List Instr := [
  ⟨.set .pindirs 1, 0⟩,
  ⟨.pull false true, 0⟩,
  ⟨.out .x 0, 0⟩,
  ⟨.jmp .notX 6, 0⟩,
  ⟨.set .pins 1, 0⟩,
  ⟨.jmp .always 7, 0⟩,
  ⟨.set .pins 0, 0⟩,
  ⟨.mov .isr .plain .x, 0⟩,
  ⟨.push false true, 0⟩ ]

/-- Where the state machine starts, and the wrap: 1 to 8, so instruction 0
runs once. -/
def wrapBottom : Nat := 1
def wrapTop : Nat := 8

/-- The words, as `encode` makes them — stated, so that a change to the
program or to the encoder shows here first. -/
theorem words :
    program.map encode = [0xe081, 0x80a0, 0x6020, 0x0026, 0xe001, 0x0007, 0xe000, 0xa0c1, 0x8020] := by
  decide

/-- And each word reads back as the instruction it was made from: the
program on the chip is this program, and nothing else. -/
theorem reads_back : (program.map encode).map decode = program.map some := by
  simp only [List.map_map]
  exact List.map_congr_left fun i _ => decode_encode i

/-- Every jump lands inside the program, and the wrap is inside it too. -/
theorem jumps_inside : program.all (fun i => match i.op with
    | .jmp _ a => a.toNat < program.length
    | _ => true) = true ∧ wrapBottom ≤ wrapTop ∧ wrapTop < program.length := by
  decide

end Exp216

#print axioms Exp216.words
#print axioms Exp216.reads_back
#print axioms Exp216.jumps_inside

def hex4 (n : Nat) : String :=
  let d := "0123456789abcdef".toList
  String.ofList ((List.range 4).reverse.map fun k => d.getD (n / 16 ^ k % 16) '0')

/-- `header OUT` writes shell/program.h; with no arguments, the listing. -/
def main (args : List String) : IO Unit := do
  let ws := Exp216.program.map fun i => (Pio.encode i).toNat
  match args with
  | ["header", out] =>
    let body := String.intercalate ", " (ws.map fun w => s!"0x{hex4 w}")
    let notes := String.join ((Exp216.program.zip ws).zipIdx.map fun ((i, w), k) =>
      s!"//   {k}  {hex4 w}  {i.toAsm}\n")
    IO.FS.writeFile out <|
      "// SPDX-License-Identifier: Apache-2.0\n//\n" ++
      "// exp216 — the program's words, written by proof/Program.lean from the\n" ++
      "// instructions there through lean/Pio's proved encode. Do not edit; check.sh\n" ++
      "// holds this file to what Lean writes and the words to what pioasm makes of\n" ++
      "// drive.pio.\n//\n" ++ notes ++
      "#pragma once\n#include <stdint.h>\n\n" ++
      s!"#define PROGRAM_LEN {ws.length}\n" ++
      s!"#define WRAP_BOTTOM {Exp216.wrapBottom}\n#define WRAP_TOP {Exp216.wrapTop}\n" ++
      s!"static const uint16_t PROGRAM[PROGRAM_LEN] = \{{body}};\n" ++
      s!"#define JMP_0 0x{hex4 (Pio.encode ⟨.jmp .always 0, 0⟩).toNat}u\n"
  | _ =>
    for ((i, w), k) in (Exp216.program.zip ws).zipIdx do
      IO.println s!"  {k}  {hex4 w}  {i.toAsm}"
