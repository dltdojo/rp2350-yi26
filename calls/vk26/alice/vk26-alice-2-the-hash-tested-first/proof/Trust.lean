/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-2 — the hash tested first

Before a kernel trusts `HASH` with its samples, it asks `HASH` for the digest
of 64 bytes whose digest it already has, and stops if the answer differs.
Then SP 800-90B's start-up test (§4.3 item 4: the continuous tests over at
least 1024 consecutive samples), whose samples are discarded, and one more
window, the repetition count carried across the edge, whose digest is the
output.

   0       s0 = base
   1-6     HASH of the 64 bytes at 0x300, to 0x360 (the KAT's scratch)
   7-38    the 32 bytes at 0x360 against the 32 at 0x340, eight words, no
           early exit (`Blocks.compare_words`); s6 = 0 iff all equal
   39      bne s6 → KAT FAIL
   40-42   s1 = base + 0x400, s4 = 2 (no sample yet), s5 = 0
   43-66   window 0, the start-up test (`Alice.Window.win`)
   67      bne s6 → START FAIL
   68-91   window 1
   92      bne s6 → FAIL
   93-99   HASH of window 1's 4096 bytes, to base + 0x2400
   100     HALT 0
   103     START FAIL: HALT 1
   106     KAT FAIL: HALT 2
   109     FAIL: HALT 3
-/
import Alice.Window
import Alice.Addr
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm
import Rv32.Flow

set_option maxRecDepth 20000

namespace Trust
open Rv32 Rv32.Health Alice.Window Alice.Addr

def katSet : List Instr := [
  .opi .addi A0 S0 0x300, .opi .addi A1 0 64, .opi .addi A2 S0 0x360, .opi .addi T0 0 0, .opi .addi S6 0 0 ]

def katCmp : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T1 A2 (BitVec.ofNat 12 (4 * j)), .ld .lw T2 S0 (BitVec.ofNat 12 (0x340 + 4 * j)),
     .op .xor T1 T1 T2, .op .or S6 S6 T1]

def healthSet : List Instr := [ .opi .addi S1 S0 0x400, .opi .addi S4 0 2, .opi .addi S5 0 0 ]

/-- `a0` = the window just tested, `a1` = 4096, `a2` = where it ends, `t0` = HASH. -/
def outSet : List Instr := [
  .opi .addi A0 S1 0x800, .opi .addi A0 A0 0x800, .opi .addi A1 0 1, .sh .slli A1 A1 12,
  .opi .addi A2 S1 0, .opi .addi T0 0 0 ]

def halt (c : Nat) : List Instr := [ .opi .addi A0 0 (BitVec.ofNat 12 c), .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  [.auipc S0 0] ++ katSet ++ [.ecall] ++ katCmp ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (106 - 39)))]
  ++ healthSet ++ win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (103 - 67)))]
  ++ win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (109 - 92)))]
  ++ outSet ++ [.ecall] ++ halt 0 ++ halt 1 ++ halt 2 ++ halt 3

theorem kernel_length : kernel.length = 112 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

end Trust

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Trust.image
  | _ => pure ()
  for (i, k) in Trust.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
