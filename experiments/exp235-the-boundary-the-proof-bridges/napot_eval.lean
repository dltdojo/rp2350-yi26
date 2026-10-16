/-
SPDX-License-Identifier: Apache-2.0

# exp235 — the model, evaluated on test vectors

Reads `pmpaddr addr width` lines (hex, hex, decimal) on stdin and prints, for each,
the `[lo, hi)` that `decodeNapotRange` makes of `pmpaddr`, and whether `pmpCheck`
lets U-mode load `width` bytes at `addr` when entry 0 is NAPOT with RWX and the
other three are OFF. `test_vectors.py` compares that with its own arithmetic.
-/
import Rv32.Priv

open Rv32 Rv32.Priv

def parseHex (s : String) : Nat :=
  (s.toList.foldl (fun acc c => acc * 16 + (if c.isDigit then c.toNat - '0'.toNat
    else (c.toLower.toNat - 'a'.toNat + 10))) 0)

partial def loop (h : IO.FS.Stream) : IO Unit := do
  let line ← h.getLine
  if line.isEmpty then return
  match line.trimAscii.toString.splitOn " " with
  | [p, a, w] =>
    let pmpaddr := BitVec.ofNat 32 (parseHex p)
    let addr := BitVec.ofNat 32 (parseHex a)
    let width := w.toNat!
    let csrs : PrivCSRs := { pmpcfg0 := 0x1F#32, pmpaddr0 := pmpaddr }
    let (lo, hi) := decodeNapotRange pmpaddr
    IO.println s!"{lo} {hi} {pmpCheck csrs .U addr width .Load}"
  | _ => IO.println "bad line"
  loop h

def main : IO Unit := do
  loop (← IO.getStdin)
