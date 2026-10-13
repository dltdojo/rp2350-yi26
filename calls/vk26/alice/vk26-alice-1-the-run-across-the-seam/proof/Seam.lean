/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-1 — the run across the seam

SP 800-90B's repetition count and adaptive proportion tests over four windows
of 1024 samples, the repetition count carried across every window's edge, and
nothing written after the first window that fails.

The samples are at base + 0x400, four windows one after another, one sample
in bit 0 of each word. For each window in turn the kernel runs both tests
(`Alice.Window.win`). If the window passes, it asks `HASH` for the 32 bytes of
its 4096 and writes them at base + 0x4400 + 32w, and goes on to the next. If
it fails, it halts at once with the window's number, 1 to 4. If all four
pass, it halts with 0.

   0-8     s1 = base + 0x400 (the samples), s9 = base + 0x4400 (the digests);
           s4 = 2 (no sample yet), s5 = 0 (the run), s6 = 0 (no failure),
           s2 = 0 (windows passed)
   9 + 33w window w:
     +0    win: the reference, the counts, 1024 samples, the verdict in s6
     +24   bne s6, x0 → FAIL
     +25   HASH of the 4096 bytes just tested, to s9; s9 += 32; s2 += 1
   141     HALT 0
   144     FAIL: HALT s2 + 1
-/
import Alice.Window
import Rv32.Blocks
import Rv32.Line
import Rv32.Asm

set_option maxRecDepth 20000

namespace Seam
open Rv32 Rv32.Health Alice.Window

def S9 : Reg := 25

def init : List Instr := [
  .auipc S0 0, .opi .addi S1 S0 0x400, .lui T1 4, .op .add S9 S0 T1, .opi .addi S9 S9 0x400,
  .opi .addi S4 0 2, .opi .addi S5 0 0, .opi .addi S6 0 0, .opi .addi S2 0 0 ]

/-- After a window passes: HASH of the 4096 bytes before `s1`, to `s9`. -/
def hashLine : List Instr := [
  .opi .addi A0 S1 0x800, .opi .addi A0 A0 0x800, .lui A1 1, .opi .addi A2 S9 0,
  .opi .addi T0 0 0, .ecall, .opi .addi S9 S9 32, .opi .addi S2 S2 1 ]

/-- Window `w`: its tests, the branch to FAIL at 144 from 33 + 33w, its digest. -/
def window (w : Nat) : List Instr :=
  win ++ [.br .bne S6 0 (BitVec.ofNat 12 (2 * (111 - 33 * w)))] ++ hashLine

def passLine : List Instr := [ .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]
def failLine : List Instr := [ .opi .addi A0 S2 1, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  init ++ window 0 ++ window 1 ++ window 2 ++ window 3 ++ passLine ++ failLine

theorem kernel_length : kernel.length = 147 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

end Seam

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Seam.image
  | _ => pure ()
  for (i, k) in Seam.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
