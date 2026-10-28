/-
SPDX-License-Identifier: Apache-2.0

# privrun — the Tier 2 model, as a program

    privrun SCENARIO RAM_OUT
    privrun --pmp QUERIES

Runs `Rv32.Priv.PrivMachine.step` from the machine SCENARIO describes, for the number of steps it names, and
prints one line per step: what software could read of the machine after it. RAM_OUT gets the RAM afterwards.

This is the model every monitor theorem is about, run: the same `step`, compiled. It is never an argument in a
proof; it is how the model is held against things that are not it (tools/monitor/privdiff.py).

SCENARIO is text, one item a line:

    ram BASE FILE          RAM from BASE, its bytes FILE's; every other byte starts 0
    region LO HI           Tier 1's region, `env.region`: where a load or store may go before the PMP is asked
                           (`[0x80000000, 0xC0000100)`, `monRegion`, the monitor theorems', if not given)
    pc X | mode M|U | halted 0|1
    reg N X                register N, 1 to 31
    csr NAME X             mstatus mtvec mscratch mepc mcause mcountinhibit pmpcfg0 pmpaddr0..3 mcycle minstret,
                           as software would write them (mstatus and mcountinhibit decoded by `writeCSR`'s rule)
    answer K ADDR X        the host's answer to a load from port ADDR once K port words have been stored
    digest K HEX           the 32 bytes the host writes back for the hash asked for by port word K
    steps N

Every number is hex. Each step prints

    S pc mode halted x1..x31 mstatus mtvec mcountinhibit mscratch mepc mcause pmpcfg0 pmpaddr0..3 mcycle minstret

with every CSR as `readCSR` returns it, then `W ADDR BYTE` for each byte the instruction could have written, read
back from the machine `step` returned, and `IO ADDR VAL` for each port word it stored.

## `--pmp`: the RP2350's PMP

With `--pmp`, each line of QUERIES asks `Rv32.PmpChip.chipCheck` one question, and the answer is printed, `1` or
`0`, a line each:

    ORDER CFG0 CFG1 ADDR0 .. ADDR7 CFGM0 MODE ADDR WIDTH ACC

ORDER is `e6` (the chip's bit order) or `std`; the registers are as software last wrote them; MODE is `M` or `U`;
ACC is `F`, `L` or `S`, a fetch, a load or a store. exp257 holds the answers to two Hazard3 cores.

## Keeping a long run fast

As in `Run.lean`: the machine's functions would nest a closure per write, so the runner keeps RAM in a
`ByteArray`, every other byte written in a map, and the registers in an `Array`, and after each step rebuilds
the machine's two functions from them, one closure deep. What goes in is read back from the machine `step`
returned, never computed here. Only two things write memory: a store (its `size` bytes at `rs1 + imm`), and the
host's digest (32 bytes at the output word), when M-mode stores 2 to the request word. Those bytes are copied;
nothing else is.
-/
import Rv32.Priv
import Rv32.PmpChip
import Rv32.Asm
import Std.Data.HashMap

open Rv32 Rv32.Priv

/-- Memory as the runner keeps it: RAM from `base`, and every other byte that has been written. -/
structure Mem where
  base  : Nat
  ram   : ByteArray
  other : Std.HashMap Nat UInt8

def Mem.get (m : Mem) (a : Nat) : Byte :=
  if m.base ≤ a ∧ a - m.base < m.ram.size then BitVec.ofNat 8 m.ram[a - m.base]!.toNat
  else BitVec.ofNat 8 (m.other.getD a 0).toNat

def Mem.set (m : Mem) (a : Nat) (b : Byte) : Mem :=
  if m.base ≤ a ∧ a - m.base < m.ram.size then { m with ram := m.ram.set! (a - m.base) b.toNat.toUInt8 }
  else { m with other := m.other.insert a b.toNat.toUInt8 }

/-- The bytes the step from `s` could write: `(address, count)`. -/
def writes (s : PrivMachine) : List (Word × Nat) :=
  let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
  match decode w with
  | some (.st op rs1 rs2 imm) =>
    let a := s.core.reg rs1 + imm.signExtend 32
    let hash := if s.mode = .M ∧ a = 0xc000001c#32 ∧ s.core.reg rs2 = 2#32 then
      [(BitVec.ofNat 32 (readLE s.core.mem 0xc0000018#32 4), 32)] else []
    (a, op.size) :: hash
  | _ => []

def rebuild (m : Mem) (regs : Array Word) (s : PrivMachine) : PrivMachine :=
  { s with core := { s.core with regs := fun x => regs[x.toNat]!, mem := fun a => m.get a.toNat } }

def regsOf (s : PrivMachine) : Array Word := (Array.range 32).map fun i => s.core.regs (BitVec.ofNat 5 i)

def csrNums : List Word :=
  [0x300, 0x305, 0x320, 0x340, 0x341, 0x342, 0x3A0, 0x3B0, 0x3B1, 0x3B2, 0x3B3, 0xB00, 0xB02]

def line (s : PrivMachine) : String :=
  let regs := (List.range 31).map fun i => hex8 (s.core.reg (BitVec.ofNat 5 (i + 1))).toNat
  let csrs := csrNums.map fun n => hex8 (readCSR s.csrs n).toNat
  " ".intercalate (["S", hex8 s.core.pc.toNat, if s.mode = .M then "M" else "U",
    if s.halted then "1" else "0"] ++ regs ++ csrs)

partial def loop (env : Env) (out : IO.FS.Stream) (n : Nat) (s : PrivMachine) (m : Mem) : IO (PrivMachine × Mem) := do
  if n = 0 then return (s, m)
  let ws := writes s
  let s' := PrivMachine.step env s
  let m' := ws.foldl (fun acc (a, k) => (List.range k).foldl (fun acc j =>
    let x := a + BitVec.ofNat 32 j
    acc.set x.toNat (s'.core.mem x)) acc) m
  out.putStrLn (line s')
  for (a, k) in ws do
    for j in List.range k do
      let x := a + BitVec.ofNat 32 j
      out.putStrLn s!"W {hex8 x.toNat} {hex8 (m'.get x.toNat).toNat}"
  for e in s'.io.drop s.io.length do
    out.putStrLn s!"IO {hex8 e.addr.toNat} {hex8 e.val.toNat}"
  loop env out (n - 1) (rebuild m' (regsOf s') s') m'

/-- The CSRs as software would write them: every field through `writeCSR`, counters last. -/
def csrsOf (l : List (String × Nat)) : PrivCSRs :=
  let num : String → Option Word
    | "mstatus" => some 0x300 | "mtvec" => some 0x305 | "mcountinhibit" => some 0x320
    | "mscratch" => some 0x340 | "mepc" => some 0x341 | "mcause" => some 0x342
    | "pmpaddr0" => some 0x3B0 | "pmpaddr1" => some 0x3B1 | "pmpaddr2" => some 0x3B2 | "pmpaddr3" => some 0x3B3
    | "mcycle" => some 0xB00 | "minstret" => some 0xB02
    | _ => none
  -- the address registers before the configuration, which may lock them
  let c := l.foldl (fun c (k, v) => match num k with
    | some n => writeCSR c n (BitVec.ofNat 32 v) | none => c) {}
  match l.find? (·.1 == "pmpcfg0") with
  | some (_, v) => { c with pmpcfg0 := BitVec.ofNat 32 v }
  | none => c

/-- One `--pmp` query, answered: `none` if the line is not one. -/
def pmpQuery (l : List String) : Option Bool :=
  match l with
  | [o, c0, c1, a0, a1, a2, a3, a4, a5, a6, a7, m0, md, a, w, acc] =>
    let addrs := [a0, a1, a2, a3, a4, a5, a6, a7].map fun x => (BitVec.ofNat 32 (parseHex x) : Word)
    let word (x : String) : Word := BitVec.ofNat 32 (parseHex x)
    let p : PmpChip.ChipPmp := ⟨word c0, word c1, fun i => addrs.getD i.val 0, word m0⟩
    let order := if o == "e6" then PmpChip.BitOrder.e6 else .standard
    let mode : PrivMode := if md == "U" then .U else .M
    let kind : AccessType := if acc == "F" then .Fetch else if acc == "L" then .Load else .Store
    some (PmpChip.chipCheck order p mode (BitVec.ofNat 32 (parseHex a)) (parseHex w) kind)
  | _ => none

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--pmp", queries] =>
    let out ← IO.getStdout
    for l in (← IO.FS.readFile queries).splitOn "\n" do
      match pmpQuery ((l.trimAscii.toString.splitOn " ").filter (· ≠ "")) with
      | some b => out.putStrLn (if b then "1" else "0")
      | none => pure ()
    return 0
  | [scenario, ramOut] =>
    let text ← IO.FS.readFile scenario
    let items := (text.splitOn "\n").map fun l => (l.trimAscii.toString.splitOn " ").filter (· ≠ "")
    let mut mem : Mem := ⟨0x80000000, ByteArray.empty, {}⟩
    let mut pc := 0x80000040
    let mut mode : PrivMode := .M
    let mut halted := false
    let mut regs : Array Word := Array.replicate 32 0
    let mut csrs : List (String × Nat) := []
    let mut answers : List (Nat × Nat × Word) := []
    let mut digests : List (Nat × List Byte) := []
    let mut steps := 0
    let mut region : Region := ⟨0x80000000, 0xC0000100⟩
    for it in items do
      match it with
      | ["ram", b, f] => mem := ⟨parseHex b, ← IO.FS.readBinFile f, {}⟩
      | ["pc", x] => pc := parseHex x
      | ["mode", x] => mode := if x == "U" then .U else .M
      | ["halted", x] => halted := x == "1"
      | ["reg", i, x] => regs := regs.set! (parseHex i) (BitVec.ofNat 32 (parseHex x))
      | ["csr", k, x] => csrs := csrs ++ [(k, parseHex x)]
      | ["answer", k, a, x] => answers := answers ++ [(parseHex k, parseHex a, BitVec.ofNat 32 (parseHex x))]
      | ["digest", k, h] => digests := digests ++ [(parseHex k, hexBytes h)]
      | ["steps", n] => steps := parseHex n
      | ["region", lo, hi] => region := ⟨parseHex lo, parseHex hi⟩
      | _ => pure ()
    let answers' := answers
    let digests' := digests
    let s0 : PrivMachine := {
      core := { pc := BitVec.ofNat 32 pc, regs := fun _ => 0, mem := fun _ => 0 }
      mode := mode, halted := halted, csrs := csrsOf csrs
      host := fun io _ a => match answers'.find? (fun (k, b, _) => k == io.length ∧ b == a.toNat) with
        | some (_, _, x) => x | none => 0
      digest := fun io _ d => match digests'.find? (fun (k, _) => k == io.length) with
        | some (_, bs) => bs.getD d.val 0 | none => 0 }
    let regs' := regs.set! 0 0
    let env : Env := { region := region, hash := fun _ _ => 0, sig := fun _ _ => false }
    let out ← IO.getStdout
    let (_, m) ← loop env out steps (rebuild mem regs' s0) mem
    IO.FS.writeBinFile ramOut m.ram
    return 0
  | _ =>
    IO.eprintln "usage: privrun SCENARIO RAM_OUT | privrun --pmp QUERIES"
    return 2
