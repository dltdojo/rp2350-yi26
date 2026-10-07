/-
SPDX-License-Identifier: Apache-2.0

# exp218 — the cases the chip decides, and what the model says of each

exp217 held `lean/Pio/Machine.lean` against two emulators. Where they parted
from the model, the model followed the datasheet's prose, and nothing here
had asked the chip. Each case below is a short program built to land on one
of those places, or on something no emulator checked (EXEC, STATUS, the IRQ
flags, the RP2350's additions). Its configuration is set, and some words are
put in TX. The program runs until it stops: every case ends waiting, or
jumping to itself, so what the chip holds afterwards does not depend on how
many cycles the shell waited. The shell then stops the state machine, takes
what RX holds, puts the second batch of words in TX, and lets it run until
it stops again.

The model runs the same steps to the same two stopping points, and what it
holds at the second one is what the chip must hold:
- the pc;
- X, Y, ISR and OSR;
- the IRQ flags;
- the pins and directions this machine drives;
- the TX FIFO's level;
- what RX gave up at each stop.

The shift counts are not observable from the CPU, and are not compared.

  lean --run Cases.lean                  each case: its program, and what the model says
  lean --run Cases.lean header OUT       the same, as shell/cases.h
-/
import Pio.Machine
import Pio.Asm

namespace Exp218
open Pio

/-- What a case is: a program at 0, where the state machine starts, its
configuration, and two batches of TX words, before each run. -/
structure Case where
  name : String
  cfg : Config := {}
  prog : List Instr
  start : Nat := 0
  tx1 : List W := []
  tx2 : List W := []

def op (o : Op) : Instr := ⟨o, 0⟩

/-- Every case starts by emptying both shift registers and zeroing X and Y,
so that nothing it ends with depends on what PIO0's reset left. -/
def prologue : List Instr :=
  [op (.mov .isr .plain .null), op (.mov .osr .plain .null), op (.mov .x .plain .null), op (.mov .y .plain .null)]

/-- And every case that ends by waiting ends here: `pull block` with TX empty. -/
def stop : Instr := op (.pull false true)

/-- GPIO2 to GPIO9 are pulled up or down by their pads, and nothing drives
them: 3, 6, 7 and 9 up, 2, 4, 5 and 8 down. The pins any case reads. -/
def EXT : W := .ofNat 32 (2^3 + 2^6 + 2^7 + 2^9)

def cases : List Case := [
  { name := "readout: four words through OSR into X, Y, ISR and OSR, read back"
    tx1 := [0x12345678, 0x9abcdef0, 0x0f1e2d3c, 0xa5a5c3c3]
    prog := prologue ++ [op (.pull false true), op (.mov .x .plain .osr), op (.pull false true),
      op (.mov .y .plain .osr), op (.pull false true), op (.mov .isr .plain .osr), op (.pull false true), stop] },
  { name := "push iffull, 4 bits of 8, no autopush: nothing is pushed (rp2040js pushes)"
    cfg := { pushThresh := 8 }
    prog := prologue ++ [op (.set .x 5), op (.inp .x 4), op (.push true false), stop] },
  { name := "push iffull, 8 bits of 8: pushed"
    cfg := { pushThresh := 8 }
    prog := prologue ++ [op (.set .x 5), op (.inp .x 4), op (.inp .x 4), op (.push true false), stop] },
  { name := "pull ifempty, 4 bits of 8 out: no pull; 8 of 8: pulled (both emulators part)"
    cfg := { pullThresh := 8 }
    tx1 := [0x87654321, 0xcafef00d]
    prog := prologue ++ [op (.pull false true), op (.out .x 4), op (.pull true false), op (.mov .y .plain .osr),
      op (.out .null 4), op (.pull true false), stop] },
  { name := "out x, 32: OSR is shifted by 32 (rp2040js leaves it)"
    tx1 := [0xdeadbeef]
    prog := prologue ++ [op (.pull false true), op (.out .x 0), stop] },
  { name := "mov's bit-reverse and invert (rp2040-pio-emulator copies)"
    tx1 := [0x12345678]
    prog := prologue ++ [op (.pull false true), op (.mov .x .reverse .osr), op (.mov .y .invert .osr), stop] },
  { name := "jmp !osre, 8 bits out of a threshold of 8: not taken (rp2040-pio-emulator takes it)"
    cfg := { pullThresh := 8 }
    tx1 := [0x0000ffff]
    prog := prologue ++ [op (.pull false true), op (.out .null 8), op (.jmp .notOsre 9), op (.set .y 1),
      op (.jmp .always 10), op (.set .y 2), stop] },
  { name := "a wrap from 0 to 0: instruction 0, again and again (rp2040-pio-emulator goes on to 1)"
    cfg := { wrapBottom := 0, wrapTop := 0 }
    start := 2
    prog := [op (.set .y 5), op (.set .y 7)] ++ prologue ++ [op (.jmp .always 0)] },
  { name := "a wrap from 5 to 3, round a jmp x-- loop that shifts X into ISR"
    cfg := { wrapBottom := 3, wrapTop := 5 }
    prog := [op (.set .x 4), op (.mov .isr .plain .null), op (.mov .y .plain .null),
      op (.jmp .notX 6), op (.jmp .xDec 5), op (.inp .x 4), stop] },
  { name := "in pins, 8 from IN_BASE 2: GPIO2..9 (rp2040-pio-emulator reads from GPIO0)"
    cfg := { inBase := 2 }
    prog := prologue ++ [op (.inp .pins 8), stop] },
  { name := "wait pin, jmp pin, wait gpio, wait jmppin: pass where high, wait where low"
    cfg := { inBase := 2, jmpPin := 6 }
    prog := prologue ++ [op (.wait true (.pin 1)), op (.set .y 1), op (.jmp .pin 8), op (.set .y 2),
      op (.wait true (.gpio 7)), op (.wait true (.jmppin 1)), op (.set .x 3), op (.wait true (.pin 0))] },
  { name := "mov pins and mov pindirs through the OUT mapping (rp2040-pio-emulator writes 32 from 0)"
    cfg := { outBase := 4, outCount := 4 }
    prog := prologue ++ [op (.set .x 22), op (.mov .pins .plain .x), op (.mov .pindirs .plain .x), stop] },
  { name := "OUT pins from 31, three of them: they wrap to 0 (both emulators stop at 31)"
    cfg := { outBase := 31, outCount := 3 }
    prog := prologue ++ [op (.set .x 6), op (.mov .pins .plain .x), op (.mov .pindirs .plain .x), stop] },
  { name := "SET pins 30 and 31: the machine drives 32 pins (rp2040js keeps 30)"
    cfg := { setBase := 30, setCount := 2 }
    prog := prologue ++ [op (.set .pins 3), op (.set .pindirs 3), stop] },
  { name := "out exec: a word from TX runs as an instruction"
    tx1 := [(encode (op (.set .y 9))).setWidth 32]
    prog := prologue ++ [op (.pull false true), op (.out .exec 16), stop] },
  { name := "mov exec: X runs as an instruction"
    tx1 := [(encode (op (.mov .y .invert .null))).setWidth 32]
    prog := prologue ++ [op (.pull false true), op (.mov .x .plain .osr), op (.mov .exec .plain .x), stop] },
  { name := "mov from STATUS, TX level against N = 2: 0 at 3 words, all ones at 1"
    cfg := { statusN := 2 }
    tx1 := [1, 2, 3]
    prog := prologue ++ [op (.mov .y .plain .status), op (.pull false true), op (.pull false true),
      op (.mov .x .plain .status), op (.pull false true), stop] },
  { name := "irq set, clear, wait irq clearing its flag, and irq wait: flags 2 and 6 left"
    prog := prologue ++ [op (.irq .set .this 3), op (.irq .clear .this 3), op (.irq .set .this 5),
      op (.wait true (.irq .this 5)), op (.irq .set .this 6), op (.irq .wait .this 2)] },
  { name := "push block on a full RX waits, then pushes when there is room (rp2040js empties ISR)"
    tx2 := [0x600d]
    prog := prologue ++ ((List.range 5).flatMap fun k =>
        [op (.set .x (.ofNat 5 (k + 1))), op (.mov .isr .plain .x), op (.push false true)]) ++
      [op (.pull false true), op (.mov .y .plain .osr), stop] },
  { name := "shifting left both ways, jmp x-- past 0, and pull noblock on an empty TX taking X"
    cfg := { inRight := false, outRight := false }
    tx1 := [0xf0e1d2c3]
    prog := prologue ++ [op (.set .x 3), op (.jmp .xDec 5), op (.pull false true), op (.out .y 8),
      op (.inp .osr 12), op (.pull false false), stop] }
]

/-- The configuration as the three registers the shell writes (rp-pac
7.0.0's fields): EXECCTRL with STATUS_SEL 0, the TX level; SHIFTCTRL with
IN_COUNT 0, all 32; PINCTRL with no side-set. -/
def execctrl (c : Config) : Nat := c.statusN + c.wrapBottom * 2^7 + c.wrapTop * 2^12 + c.jmpPin * 2^24
def shiftctrl (c : Config) : Nat :=
  (if c.inRight then 2^18 else 0) + (if c.outRight then 2^19 else 0) +
    (c.pushThresh % 32) * 2^20 + (c.pullThresh % 32) * 2^25
def pinctrl (c : Config) : Nat :=
  c.outBase + c.setBase * 2^5 + c.inBase * 2^15 + c.outCount * 2^20 + c.setCount * 2^26

def words (c : Case) : List (BitVec 16) := c.prog.map encode

/-- Two states the shell cannot tell apart, nor the next step either. -/
def same (a b : Sm) : Bool :=
  a.pc == b.pc && a.x == b.x && a.y == b.y && a.isr == b.isr && a.osr == b.osr &&
  a.isrCount == b.isrCount && a.osrCount == b.osrCount && a.tx == b.tx && a.rx == b.rx &&
  a.pins == b.pins && a.dirs == b.dirs && a.irq == b.irq && a.delay == b.delay &&
  a.exec == b.exec && a.irqWait == b.irqWait

/-- Steps until a step changes nothing: where the case stops. -/
def settle (c : Case) : Nat → Sm → Except String Sm
  | 0, _ => .error "it never stops"
  | n + 1, s =>
    match step c.cfg (words c) EXT s with
    | none => .error s!"the model refuses the instruction at {s.pc}"
    | some s' => if same s s' then .ok s else settle c n s'

/-- What the shell reads, as the model has it. -/
structure Want where
  pc : Nat
  x : W
  y : W
  isr : W
  osr : W
  irq : BitVec 8
  padout : W
  padoe : W
  txLevel : Nat
  rx1 : List W
  rx2 : List W

def want (c : Case) : Except String Want := do
  if c.prog.length > 32 then throw "more than 32 instructions"
  if c.tx1.length > 4 then throw "more than 4 words in the first batch"
  let s0 : Sm := ⟨c.start, 0, 0, 0, 0, 0, 32, c.tx1, [], 0, 0, 0, 0, none, false⟩
  let s1 ← settle c 1000 s0
  if s1.tx.length + c.tx2.length > 4 then throw "the second batch does not fit"
  let s2 ← settle c 1000 { s1 with rx := [], tx := s1.tx ++ c.tx2 }
  return ⟨s2.pc, s2.x, s2.y, s2.isr, s2.osr, s2.irq, s2.pins, s2.dirs, s2.tx.length, s1.rx, s2.rx⟩

end Exp218

open Exp218 Pio

def hexN (k n : Nat) : String :=
  let d := "0123456789abcdef".toList
  String.ofList ((List.range k).reverse.map fun i => d.getD (n / 16 ^ i % 16) '0')
def h8 (w : W) : String := s!"0x{hexN 8 w.toNat}"
def list8 (ws : List W) : String := "{" ++ ", ".intercalate (ws.map h8) ++ "}"

def describe (k : Nat) (c : Case) (w : Want) : String :=
  let prog := String.join ((c.prog.zip (words c)).zipIdx.map fun ((i, x), a) =>
    s!"      {a}{if a = c.start then " ←" else "  "} {hexN 4 x.toNat}  {i.toAsm}\n")
  s!"case {k + 1}: {c.name}\n" ++
  s!"    EXECCTRL {h8 (.ofNat 32 (execctrl c.cfg))}  SHIFTCTRL {h8 (.ofNat 32 (shiftctrl c.cfg))}  " ++
  s!"PINCTRL {h8 (.ofNat 32 (pinctrl c.cfg))}  TX {list8 c.tx1} then {list8 c.tx2}\n" ++ prog ++
  s!"    the model: pc {w.pc}  X {h8 w.x}  Y {h8 w.y}  ISR {h8 w.isr}  OSR {h8 w.osr}  " ++
  s!"IRQ 0x{hexN 2 w.irq.toNat}\n" ++
  s!"               pins {h8 w.padout}  dirs {h8 w.padoe}  TX level {w.txLevel}  " ++
  s!"RX {list8 w.rx1} then {list8 w.rx2}\n"

def entry (c : Case) (w : Want) : String :=
  let ws := ", ".intercalate ((words c).map fun x => s!"0x{hexN 4 x.toNat}")
  let jmp := encode (op (.jmp .always (.ofNat 5 c.start)))
  s!"    \{ {(words c).length}, \{{ws}}, 0x{hexN 4 jmp.toNat}, " ++
  s!"{h8 (.ofNat 32 (execctrl c.cfg))}, {h8 (.ofNat 32 (shiftctrl c.cfg))}, {h8 (.ofNat 32 (pinctrl c.cfg))},\n" ++
  s!"      {c.tx1.length}, {list8 c.tx1}, {c.tx2.length}, {list8 c.tx2},\n" ++
  s!"      \{ {w.pc}, {h8 w.x}, {h8 w.y}, {h8 w.isr}, {h8 w.osr}, 0x{hexN 2 w.irq.toNat}, " ++
  s!"{h8 w.padout}, {h8 w.padoe}, {w.txLevel},\n" ++
  s!"        {w.rx1.length}, {list8 w.rx1}, {w.rx2.length}, {list8 w.rx2} } },\n"

def main (args : List String) : IO UInt32 := do
  let mut text := ""
  let mut body := ""
  for (c, k) in cases.zipIdx do
    match want c with
    | .error e => IO.eprintln s!"case {k + 1} ({c.name}): {e}"; return 1
    | .ok w =>
      text := text ++ describe k c w
      body := body ++ entry c w
  match args with
  | ["header", out] =>
    let notes := String.join ((text.splitOn "\n").map fun l => if l.isEmpty then "" else s!"// {l}\n")
    IO.FS.writeFile out <|
      "// SPDX-License-Identifier: Apache-2.0\n//\n" ++
      "// exp218 — the cases, written by model/Cases.lean: each program's words through\n" ++
      "// lean/Pio's proved encode, and what lean/Pio/Machine.lean says the chip holds\n" ++
      "// when it stops. Do not edit; check.sh holds this file to what Lean writes.\n//\n" ++
      notes ++ "\n#pragma once\n#include \"case.h\"\n\n" ++
      s!"#define NCASES {cases.length}\n" ++
      s!"#define EXT_PULLED_UP {h8 EXT}u   // GPIO2..9, pulled up where set and down elsewhere\n" ++
      "// What the shell executes on the stopped machine to read it, through encode:\n" ++
      s!"#define I_PUSH        0x{hexN 4 (encode (op (.push false false))).toNat}u   // push noblock\n" ++
      s!"#define I_MOV_ISR_X   0x{hexN 4 (encode (op (.mov .isr .plain .x))).toNat}u   // mov isr, x\n" ++
      s!"#define I_MOV_ISR_Y   0x{hexN 4 (encode (op (.mov .isr .plain .y))).toNat}u   // mov isr, y\n" ++
      s!"#define I_MOV_ISR_OSR 0x{hexN 4 (encode (op (.mov .isr .plain .osr))).toNat}u   // mov isr, osr\n\n" ++
      "static const struct pio_case CASES[NCASES] = {\n" ++ body ++ "};\n"
  | _ => IO.print text
  return 0
