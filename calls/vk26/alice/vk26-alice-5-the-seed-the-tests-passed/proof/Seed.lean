/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-5 — the seed the tests passed

SP 800-90A Rev. 1's Hash_DRBG Instantiate (§10.1.1.2) with SHA-256, seedlen =
440 bits, no personalization beyond what the seed material carries:

  V = Hash_df(seed_material, 440),  C = Hash_df(0x00 ‖ V, 440),  counter = 1

where Hash_df (§10.3.1) is, for 440 bits, two hashes:
Hash(0x01 ‖ 0x000001b8 ‖ input) ‖ Hash(0x02 ‖ 0x000001b8 ‖ input), cut to 55
bytes. This kernel runs after vk26-alice-2's (`Alice.Trust`), on the region
that one leaves: its digest of the tested window is at 0x2400, and the seed
material is that digest, the nonce after it, and any personalization string
after that. It lays the state out where vk26-alice-4's Generate
(`Alice.Drbg`) keeps it. Offsets from `base`:

  0x23fb  Hash_df's counter byte and 00 00 01 b8, then the seed material at 0x2400
  0x2480  m, the interval (words), and the seed material's length S
  0x43a   Hash_df's prefix for C: counter, 00 00 01 b8, 00, then V at 0x440
  out:    m, the interval and the counter 1 at 0x400; 0x03 at 0x43f; V at
          0x440; C at 0x480; 23 and 51 zeros at 0x500 and 0x540; the number
          1 at 0x580 — what `Drbg.generate_run` asks of a region

   0-2     s0 = base, s1 = base + 0x2000
   3-6     00 00 01 b8 to 0x23fc; s2 = 5 + S
   7-20    V: HASHB(0x23fb, 5 + S) to 0x440 with counter 1, to 0x460 with 2
   21-41   C: the prefix; HASHB(0x43a, 61) to 0x480 with 1, to 0x4a0 with 2
   42-43   0x03 to 0x43f
   44-49   46 words of zeros from 0x500
   50-51   1 to 0x5b6
   52-57   m, the interval, and 1 to 0x400
   58-60   HALT 0
-/
import Alice.Trust
import Alice.Drbg

set_option maxRecDepth 20000

namespace Seed
open Rv32 Rv32.Health

/-- `HASHB(a0 = rs + off, a1 = len, a2 = s0 + dst)` with Hash_df's counter `k`
stored first at `rs + off`. -/
def dfHash (k : Nat) (rs : Reg) (off : BitVec 12) (len : Reg) (lenImm : BitVec 12) (dst : BitVec 12) : List Instr :=
  [ .opi .addi T1 0 (BitVec.ofNat 12 k), .st .sb rs T1 off,
    .opi .addi A0 rs off, .opi .addi A1 len lenImm, .opi .addi A2 S0 dst, .opi .addi T0 0 2, .ecall ]

def kernel : List Instr :=
  [ .auipc S0 0, .lui T0 2, .op .add S1 S0 T0,
    .lui T1 0xb8010, .st .sw S1 T1 0x3fc, .ld .lw S2 S1 0x488, .opi .addi S2 S2 5 ]
  ++ dfHash 1 S1 0x3fb S2 0 0x440 ++ dfHash 2 S1 0x3fb S2 0 0x460
  ++ [ .st .sb S0 0 0x43b, .st .sb S0 0 0x43c, .opi .addi T1 0 1, .st .sb S0 T1 0x43d,
       .opi .addi T1 0 0xb8, .st .sb S0 T1 0x43e, .st .sb S0 0 0x43f ]
  ++ dfHash 1 S0 0x43a 0 61 0x480 ++ dfHash 2 S0 0x43a 0 61 0x4a0
  ++ [ .opi .addi T1 0 3, .st .sb S0 T1 0x43f,
       .opi .addi A0 S0 0x500, .opi .addi T2 0 46,
       .st .sw A0 0 0, .opi .addi A0 A0 4, .opi .addi T2 T2 0xfff, .br .bne T2 0 (BitVec.ofInt 12 (2 * (46 - 49 : Int))),
       .opi .addi T1 0 1, .st .sb S0 T1 0x5b6,
       .ld .lw T1 S1 0x480, .st .sw S0 T1 0x400, .ld .lw T1 S1 0x484, .st .sw S0 T1 0x404,
       .opi .addi T1 0 1, .st .sw S0 T1 0x408,
       .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

theorem kernel_length : kernel.length = 61 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

end Seed

/-- `main OUT [TRUST DRBG]`: kernel.bin, and the two kernels it runs between,
as alice's package has them. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Seed.image
  | [out, trust, drbg] =>
    IO.FS.writeBinFile out Seed.image
    IO.FS.writeBinFile trust Trust.image
    IO.FS.writeBinFile drbg Drbg.image
  | _ => pure ()
  for (i, k) in Seed.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
