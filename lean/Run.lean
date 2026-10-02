/-
SPDX-License-Identifier: Apache-2.0

# rv32run — the Lean model, as a program

    rv32run IMAGE BASE SIZE FUEL [DUMP_BYTES DUMP_FILE]

Loads IMAGE at BASE (`Rv32.boot`), runs `Rv32.step` until it halts, faults or
FUEL instructions have run, and prints one line in the same form as
`tools/hazard3/sim.sh`:

    halt code=<hex> count=<n>
    fault <what> pc=<hex> count=<n>
    timeout count=<n>

`count` is every instruction `step` was asked to execute, the one that halted
or faulted included. With DUMP_BYTES, the region's first DUMP_BYTES bytes
afterwards go to DUMP_FILE as one little-endian word per line in hex — the
testbench's `--sigfile` format — so the two can be compared with `cmp`.

This is the model the theorems are about, run: the same `step`, compiled. It
is never an argument in a proof; it is how the model is held against things
that are not it.

HASH is not available here yet (exp204 brings it), and is reported as a fault
rather than given some value, so that nothing can pass by calling it.
-/
import Rv32.Load
import Rv32.Asm

open Rv32

def hexWord (n : Nat) : String := hex8 n

def faultName : Fault → String
  | .fetchMisaligned => "fetch-misaligned" | .fetchAccess => "fetch-access"
  | .illegal w => s!"illegal({hexWord w.toNat})"
  | .loadMisaligned => "load-misaligned" | .loadAccess => "load-access"
  | .storeMisaligned => "store-misaligned" | .storeAccess => "store-access"
  | .hashArgs => "hash-args" | .unknownCall => "unknown-call"

def asksForHash (env : Env) (s : Machine) : Bool :=
  match fetch env s with
  | .ok .ecall => s.reg T0 == 0
  | _ => false

partial def loop (env : Env) (fuel : Nat) (s : Machine) (k : Nat) : String × Machine :=
  if k ≥ fuel then (s!"timeout count={k}", s)
  else if asksForHash env s then (s!"fault hash-not-available pc={hexWord s.pc.toNat} count={k + 1}", s)
  else match step env s with
    | .running s' => loop env fuel s' (k + 1)
    | .halted code s' => (s!"halt code={hexWord code.toNat} count={k + 1}", s')
    | .fault f s' => (s!"fault {faultName f} pc={hexWord s'.pc.toNat} count={k + 1}", s')

def parseHex (s : String) : Nat :=
  (s.toList.drop (if s.startsWith "0x" then 2 else 0)).foldl (fun n c =>
    n * 16 + (if c.isDigit then c.toNat - '0'.toNat
      else if 'a' ≤ c ∧ c ≤ 'f' then c.toNat - 'a'.toNat + 10
      else if 'A' ≤ c ∧ c ≤ 'F' then c.toNat - 'A'.toNat + 10 else 0)) 0

def main (args : List String) : IO UInt32 := do
  match args with
  | img :: base :: size :: fuel :: rest =>
    let bytes ← IO.FS.readBinFile img
    let lo := parseHex base
    let r : Region := { lo := lo, hi := lo + parseHex size }
    let env : Env := { region := r, hash := fun _ _ => 0 }
    let (line, s) := loop env fuel.toNat! (boot r bytes) 0
    IO.println line
    match rest with
    | [n, file] =>
      let words := (List.range (n.toNat! / 4)).map fun i =>
        hexWord (readLE s.mem (BitVec.ofNat 32 (lo + 4 * i)) 4)
      IO.FS.writeFile file (String.intercalate "\n" words ++ "\n")
    | _ => pure ()
    return 0
  | _ =>
    IO.eprintln "usage: rv32run IMAGE BASE SIZE FUEL [DUMP_BYTES DUMP_FILE]"
    return 2
