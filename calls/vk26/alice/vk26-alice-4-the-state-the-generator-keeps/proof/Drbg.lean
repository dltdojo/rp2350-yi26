/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-4 — the state the generator keeps

SP 800-90A Rev. 1's Hash_DRBG (§10.1.1), with SHA-256 and seedlen = 440 bits
(55 bytes), keeps a state (V, C, reseed_counter). Its Generate, with no
additional input (§10.1.1.4):

1. if reseed_counter > reseed_interval, return "reseed required";
2. returned bits = Hashgen(V): Hash(V), Hash(V + 1), …;
3. H = Hash(0x03 ‖ V);
4. V = (V + H + C + reseed_counter) mod 2^440;
5. reseed_counter = reseed_counter + 1.

This kernel is that Generate, for `m` blocks of 32 bytes, with the hash as
`ecall HASHB`. Everything is a byte offset from `base`:

  0x400  m (a word), 0x404 reseed_interval, 0x408 reseed_counter
  0x43f  the byte 0x03, then V at 0x440 (55 bytes, big-endian)
  0x480  C        0x4c0  data, Hashgen's running V + i
  0x500  H, as 55 bytes: 23 zeros, then Hash(0x03 ‖ V) at 0x517
  0x540  reseed_counter, as 55 bytes: 51 zeros, then its 4 bytes at 0x573
  0x580  the number 1, as 55 bytes      0x600  the m blocks returned

   0       s0 = base
   1-3     t1 = interval, s3 = counter; interval <u counter → RESEED
   4-12    COPY: V to data, a byte at a time
   13-14   s1 = m, s2 = the first block's place
   15-25   GEN: HASHB(data, 55) to s2; data += 1 (ADD); s2 += 32; s1 -= 1
   26-30   HASHB(0x03 ‖ V, 56) to 0x517
   31-36   V += H (ADD); V += C (ADD)
   37-43   the counter's 4 bytes, big-endian, to 0x573
   44-46   V += counter (ADD)
   47-51   counter += 1, stored; HALT 0
   52-54   RESEED: HALT 1
   55-69   ADD: the 55 bytes at a0 += the 55 at a1, from the last byte up,
           a carry in a3; back through ra
-/
import Rv32.Asm
import Rv32.Flow
import Rv32.Health

set_option maxRecDepth 20000

namespace Drbg
open Rv32 Rv32.Health

def RA : Reg := 1
def A3 : Reg := 13
def A4 : Reg := 14

/-- Instruction `k`'s branch to instruction `t`. -/
def br (op : BrOp) (a b : Reg) (k t : Int) : Instr := .br op a b (BitVec.ofInt 12 (2 * (t - k)))
def call (k t : Int) : Instr := .jal RA (BitVec.ofInt 20 (2 * (t - k)))

def kernel : List Instr := [
  /- 0 -/ .auipc S0 0,
  /- 1 -/ .ld .lw T1 S0 0x404, .ld .lw S3 S0 0x408, br .bltu T1 S3 3 52,
  /- 4 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x4c0, .opi .addi T2 0 55,
  /- 7 -/ .ld .lbu T1 A0 0, .st .sb A1 T1 0, .opi .addi A0 A0 1, .opi .addi A1 A1 1,
  /- 11 -/ .opi .addi T2 T2 0xfff, br .bne T2 0 12 7,
  /- 13 -/ .ld .lw S1 S0 0x400, .opi .addi S2 S0 0x600,
  /- 15 -/ .opi .addi A0 S0 0x4c0, .opi .addi A1 0 55, .opi .addi A2 S2 0, .opi .addi T0 0 2, .ecall,
  /- 20 -/ .opi .addi A0 S0 0x4c0, .opi .addi A1 S0 0x580, call 22 55,
  /- 23 -/ .opi .addi S2 S2 32, .opi .addi S1 S1 0xfff, br .bne S1 0 25 15,
  /- 26 -/ .opi .addi A0 S0 0x43f, .opi .addi A1 0 56, .opi .addi A2 S0 0x517, .opi .addi T0 0 2, .ecall,
  /- 31 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x500, call 33 55,
  /- 34 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x480, call 36 55,
  /- 37 -/ .sh .srli T1 S3 24, .st .sb S0 T1 0x573, .sh .srli T1 S3 16, .st .sb S0 T1 0x574,
  /- 41 -/ .sh .srli T1 S3 8, .st .sb S0 T1 0x575, .st .sb S0 S3 0x576,
  /- 44 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x540, call 46 55,
  /- 47 -/ .opi .addi S3 S3 1, .st .sw S0 S3 0x408, .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall,
  /- 52 -/ .opi .addi A0 0 1, .opi .addi T0 0 1, .ecall,
  /- 55 -/ .opi .addi A0 A0 54, .opi .addi A1 A1 54, .opi .addi T2 0 55, .opi .addi A3 0 0,
  /- 59 -/ .ld .lbu T1 A0 0, .ld .lbu A4 A1 0, .op .add T1 T1 A4, .op .add T1 T1 A3, .st .sb A0 T1 0,
  /- 64 -/ .sh .srli A3 T1 8, .opi .addi A0 A0 0xfff, .opi .addi A1 A1 0xfff, .opi .addi T2 T2 0xfff,
  /- 68 -/ br .bne T2 0 68 59, .jalr 0 RA 0 ]

theorem kernel_length : kernel.length = 70 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

end Drbg

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Drbg.image
  | _ => pure ()
  for (i, k) in Drbg.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
