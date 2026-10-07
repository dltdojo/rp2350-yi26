/-
SPDX-License-Identifier: Apache-2.0

exp215's half of the differential: every one of the 65536 words, and what
`Pio.decode` reads it as.

  <word>|<asm>|<putget>   a word Lean decodes: its text, and 1 if it must be
                          assembled under `.fifo putget`
  <word>|NONE|0           a word Lean refuses

`differential.py` assembles every text with pioasm and compares the words.
-/
import Pio.Isa
import Pio.Asm

open Pio

def hex4 (n : Nat) : String :=
  let d := "0123456789abcdef".toList
  String.ofList ((List.range 4).reverse.map fun k => d.getD (n / 16 ^ k % 16) '0')

def main : IO Unit := do
  for w in List.range 65536 do
    match decode (.ofNat 16 w) with
    | some i => IO.println s!"{hex4 w}|{i.toAsm}|{if i.op.needsPutget then 1 else 0}"
    | none => IO.println s!"{hex4 w}|NONE|0"
