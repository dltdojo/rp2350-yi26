/-
SPDX-License-Identifier: Apache-2.0

# exp206 — an MSS verify kernel: WOTS under a Merkle tree of height 4, proved

The kernel and its proof are `lean/Rv32/Mss.lean`, in the shared library since
exp213, whose key generator and signer, and the theorem joining all three
binaries, need them. This file prints what they rest on and writes
`kernel.bin`.
-/
import Rv32.Mss

open Rv32.Mss

#print axioms bytes_words
#print axioms code_of_image
#print axioms chain_iter
#print axioms chain_loop
#print axioms to_tree
#print axioms level_iter
#print axioms level_loop
#print axioms root_iff
#print axioms halt
#print axioms verifies
#print axioms exactly
#print axioms from_boot
#print axioms wots_complete
#print axioms path_climbs
#print axioms accepts_signed
#print axioms signed_halts_with_zero

/-- `lean --run Mss.lean OUT` writes `image` to OUT — that is `kernel.bin` —
and prints the listing: offset, word, instruction. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Rv32.Mss.image
  | _ => pure ()
  for (i, k) in Rv32.Mss.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
