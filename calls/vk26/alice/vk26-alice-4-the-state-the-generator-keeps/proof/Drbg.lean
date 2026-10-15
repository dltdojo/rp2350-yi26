/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-4 — the proof, from alice's package

The kernel, its specification and its proof are calls/vk26/alice/lean/Alice/Drbg.lean,
where vk26-alice-5, the second to need them, imports them from. This file is
what this experiment checks and runs: the theorems it rests on, and kernel.bin.
-/
import Alice.Drbg

/-! ## Why lean/Rv32/Ct.lean cannot be asked about this kernel

Ct's checker accepts a program only if `transfer` accepts every instruction
a run reaches. From any abstract state it refuses (`none`) a `jal`, a
`jalr`, and an `ecall` unless t0 is HASH's 0 or HALT's 1. The kernel calls
ADD with `jal`, returns with `jalr`, and its HASHB is an `ecall` with
t0 = 2, the first of them at the start of the GEN loop. -/

namespace Drbg
open Rv32

theorem ct_refuses_jal (len : Nat) (P : List (Nat × Nat)) (k : Nat) (A : Ct.AState) (rd : Reg)
    (off : BitVec 20) : Ct.transfer len P k A (.jal rd off) = none := rfl

theorem ct_refuses_jalr (len : Nat) (P : List (Nat × Nat)) (k : Nat) (A : Ct.AState) (rd r1 : Reg)
    (imm : BitVec 12) : Ct.transfer len P k A (.jalr rd r1 imm) = none := rfl

theorem ct_refuses_ecall (len : Nat) (P : List (Nat × Nat)) (k : Nat) (A : Ct.AState)
    (h0 : Ct.get A 5 ≠ .num 0 0) (h1 : Ct.get A 5 ≠ .num 1 1) : Ct.transfer len P k A .ecall = none := by
  simp only [Ct.transfer]

/-- Where they are: the `jal`s at 22, 33, 36 and 46, the `jalr` at 69, and
HASHB's `ecall` with t0 = 2 just before it at 19 and 30. -/
theorem kernel_calls :
    (List.range kernel.length).filter (fun k => match kernel[k]? with | some (.jal ..) => true | _ => false)
      = [22, 33, 36, 46] ∧
    (List.range kernel.length).filter (fun k => match kernel[k]? with | some (.jalr ..) => true | _ => false)
      = [69] ∧
    kernel[18]? = some (.opi .addi T0 0 2) ∧ kernel[19]? = some .ecall ∧
    kernel[29]? = some (.opi .addi T0 0 2) ∧ kernel[30]? = some .ecall := by decide


end Drbg

#print axioms Drbg.from_boot
#print axioms Drbg.reseed_boot
#print axioms Drbg.generate_twice
#print axioms Drbg.after_out
#print axioms Drbg.ct_refuses_jal
#print axioms Drbg.ct_refuses_jalr
#print axioms Drbg.ct_refuses_ecall
#print axioms Drbg.kernel_calls

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Drbg.image
  | _ => pure ()
  for (i, k) in Drbg.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
