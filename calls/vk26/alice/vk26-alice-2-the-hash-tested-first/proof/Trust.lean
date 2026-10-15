/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-2 — the proof, from alice's package

The kernel, its specification and its proof are calls/vk26/alice/lean/Alice/Trust.lean,
where vk26-alice-5, the second to need them, imports them from. This file is
what this experiment checks and runs: the theorems it rests on, and kernel.bin.
-/
import Alice.Trust

#print axioms Trust.compare_iff
#print axioms Trust.kat_run
#print axioms Trust.halts
#print axioms Trust.window_step
#print axioms Trust.output_run
#print axioms Trust.from_boot
#print axioms Trust.trusts_after_kat

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Trust.image
  | _ => pure ()
  for (i, k) in Trust.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
