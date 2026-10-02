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

HASH is SHA-256 of the input, from `Sha256.lean` — a library no proof
imports. The theorems hold for every `env.hash`; this is the one value the
runs use, so that they can be held byte for byte against the RTL, whose harness
hashes in C, and against vectors Python's `hashlib` signed.
-/
import Rv32.Load
import Rv32.Asm
import Sha256

open Rv32

def hexWord (n : Nat) : String := hex8 n

def faultName : Fault → String
  | .fetchMisaligned => "fetch-misaligned" | .fetchAccess => "fetch-access"
  | .illegal w => s!"illegal({hexWord w.toNat})"
  | .loadMisaligned => "load-misaligned" | .loadAccess => "load-access"
  | .storeMisaligned => "store-misaligned" | .storeAccess => "store-access"
  | .hashArgs => "hash-args" | .unknownCall => "unknown-call"

/-- `env.hash` for the runs: SHA-256 of the bytes. -/
def sha256 (input : List Byte) (d : Fin 32) : Byte :=
  BitVec.ofNat 8 (Sha256.digest ⟨(input.map fun b => b.toNat.toUInt8).toArray⟩)[d.val]!.toNat

/-! ## Keeping a long run fast

`Machine.regs` and `Machine.mem` are functions, and every write wraps one in
another closure. After sixteen thousand instructions a register read walks
sixteen thousand closures, and a loop of 5000 stores took seven minutes.

So the runner keeps the region in a `ByteArray` and the registers in an
`Array`, and after each step rebuilds the machine's two functions from them —
functions one closure deep. What goes into the arrays is read back from the
machine `step` returned, never computed here: after a step, the registers are
read from it, and so are the bytes the instruction could have written. In
`Rv32.exec` only two things write memory, a store (its `size` bytes at
`rs1 + imm`) and HASH (32 bytes at `a2`); those bytes are copied, and every
other byte of the region is left as it was, which is what `exec` does with it.
Outside the region nothing is ever written — both writes fault there first —
so a read there goes to the memory the run began with.

`step` is untouched, and no proof sees any of this. If the runner ever copied
the wrong bytes, the run would stop being the model's — and the comparison of
the whole region with the RTL, which every kernel's `compare.sh` makes, is
what would show it. -/

/-- The bytes an instruction can write: `(address, count)`. -/
def writes (env : Env) (s : Machine) : Option (Word × Nat) :=
  match fetch env s with
  | .ok (.st op rs1 _ imm) => some (s.reg rs1 + imm.signExtend 32, op.size)
  | .ok .ecall => if s.reg T0 = 0 then some (s.reg A2, 32) else none
  | _ => none

def regsOf (s : Machine) : Array Word := (Array.range 32).map fun i => s.regs (BitVec.ofNat 5 i)

def rebuild (r : Region) (outside : Word → Byte) (regs : Array Word) (region : ByteArray)
    (s : Machine) : Machine :=
  { s with
    regs := fun x => regs[x.toNat]!
    mem := fun a =>
      let i := a.toNat - r.lo
      if r.lo ≤ a.toNat ∧ i < region.size then BitVec.ofNat 8 region[i]!.toNat else outside a }

partial def loop (env : Env) (outside : Word → Byte) (fuel : Nat) (s : Machine) (region : ByteArray)
    (k : Nat) : String × Machine :=
  if k ≥ fuel then (s!"timeout count={k}", s)
  else
    let w := writes env s
    match step env s with
    | .running s' =>
      let region' := match w with
        | some (a, n) => (List.range n).foldl (fun acc j =>
            let x := a + BitVec.ofNat 32 j
            let i := x.toNat - env.region.lo
            if env.region.lo ≤ x.toNat ∧ i < acc.size then acc.set! i (s'.mem x).toNat.toUInt8 else acc)
            region
        | none => region
      loop env outside fuel (rebuild env.region outside (regsOf s') region' s') region' (k + 1)
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
    let env : Env := { region := r, hash := sha256 }
    let s0 := boot r bytes
    let region : ByteArray := ⟨(Array.range (r.hi - r.lo)).map fun i =>
      (s0.mem (BitVec.ofNat 32 (r.lo + i))).toNat.toUInt8⟩
    let (line, s) := loop env s0.mem fuel.toNat! s0 region 0
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
