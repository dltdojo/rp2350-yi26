/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-4 — the proof, from alice's package

The kernel, its specification and its proof are calls/vk26/alice/lean/Alice/Drbg.lean,
where vk26-alice-5, the second to need them, imports them from. This file is
what this experiment checks and runs: the theorems it rests on, and kernel.bin.
-/
import Alice.Drbg

#print axioms Drbg.from_boot
#print axioms Drbg.reseed_boot
#print axioms Drbg.generate_twice
#print axioms Drbg.after_out

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Drbg.image
  | _ => pure ()
  for (i, k) in Drbg.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
