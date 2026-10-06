/-
SPDX-License-Identifier: Apache-2.0

# exp208 — the hash the kernel computes

The specification, the kernel and what is proved of them are in
`lean/Rv32/Sha.lean`. This file writes the kernel's bytes, `sha.bin`, and
runs the specification on any message, for compare.py to hold against
hashlib.
-/
import Rv32.Sha
import Rv32.Asm

namespace Rv32.Sha

def hexByte (b : Byte) : String :=
  let d := "0123456789abcdef".toList
  String.ofList [d.getD (b.toNat / 16) '0', d.getD (b.toNat % 16) '0']

def unhex (s : String) : List Byte :=
  let v (c : Char) : Nat := if c.isDigit then c.toNat - '0'.toNat else c.toLower.toNat - 'a'.toNat + 10
  let cs := s.toList
  (List.range (cs.length / 2)).map fun i => BitVec.ofNat 8 (16 * v (cs.getD (2 * i) '0') + v (cs.getD (2 * i + 1) '0'))

end Rv32.Sha

/-- `kernel OUT` writes `sha.bin` and prints the listing; `digest HEX` prints
the specification's SHA-256 of the message given in hex. -/
def main (args : List String) : IO Unit := do
  match args with
  | ["kernel", out] =>
    IO.FS.writeBinFile out Rv32.Sha.image
    for (i, k) in Rv32.Sha.kernel.zipIdx do
      IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
  | ["digest", hex] =>
    IO.println (String.join ((Rv32.Sha.sha256 (Rv32.Sha.unhex hex)).map Rv32.Sha.hexByte))
  | _ => IO.eprintln "usage: Sha.lean kernel OUT | digest HEX"
