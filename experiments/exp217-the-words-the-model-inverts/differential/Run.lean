/-
SPDX-License-Identifier: Apache-2.0

exp217's model side of the differential: `lean/Pio/Machine.lean`, run on
each case `cases.py` writes, one per line on stdin:

  <config> | <program words> | <state> | <tx words> | <ext> | <steps>

  config  wrapBottom wrapTop inBase outBase outCount setBase setCount jmpPin
          inRight outRight pushThresh pullThresh statusN   (Bools as 0/1)
  state   pc x y isr isrCount osr osrCount

and for each, one line per step — the state after it, in the format all
three runners print (trace.py reads them) — or `NONE` where the model
refuses an instruction.
-/
import Pio.Machine

open Pio

def nums (s : String) : List Nat := (s.splitOn " ").filterMap fun t => if t.isEmpty then none else t.toNat?

def showState (s : Sm) : String :=
  let l := fun (xs : List W) => ",".intercalate (xs.map fun w => toString w.toNat)
  s!"{s.pc} {s.x.toNat} {s.y.toNat} {s.isr.toNat} {s.isrCount} {s.osr.toNat} {s.osrCount} " ++
  s!"{s.pins.toNat} {s.dirs.toNat} {s.irq.toNat} [{l s.tx}] [{l s.rx}]"

def runCase (line : String) : List String := Id.run do
  let parts := line.splitOn "|"
  let c := nums (parts.getD 0 "")
  let prog := (nums (parts.getD 1 "")).map (BitVec.ofNat 16)
  let st := nums (parts.getD 2 "")
  let tx := (nums (parts.getD 3 "")).map (BitVec.ofNat 32)
  let ext : W := .ofNat 32 ((nums (parts.getD 4 "")).getD 0 0)
  let steps := (nums (parts.getD 5 "")).getD 0 0
  let cfg : Config := {
    wrapBottom := c.getD 0 0, wrapTop := c.getD 1 31, inBase := c.getD 2 0, outBase := c.getD 3 0,
    outCount := c.getD 4 0, setBase := c.getD 5 0, setCount := c.getD 6 5, jmpPin := c.getD 7 0,
    inRight := c.getD 8 1 = 1, outRight := c.getD 9 1 = 1, pushThresh := c.getD 10 32,
    pullThresh := c.getD 11 32, statusN := c.getD 12 0 }
  let mut s : Sm := {
    pc := st.getD 0 0, x := .ofNat 32 (st.getD 1 0), y := .ofNat 32 (st.getD 2 0),
    isr := .ofNat 32 (st.getD 3 0), isrCount := st.getD 4 0, osr := .ofNat 32 (st.getD 5 0),
    osrCount := st.getD 6 32, tx := tx, rx := [], pins := 0, dirs := 0, irq := 0, delay := 0,
    exec := none, irqWait := false }
  let mut out := []
  for _ in [0:steps] do
    match step cfg prog ext s with
    | none => return out ++ ["NONE"]
    | some s' => s := s'; out := out ++ [showState s]
  return out

def main : IO Unit := do
  let stdin ← IO.getStdin
  let mut n := 0
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    IO.println s!"case {n}"
    for l in runCase (line.replace "\n" "") do IO.println l
    n := n + 1
