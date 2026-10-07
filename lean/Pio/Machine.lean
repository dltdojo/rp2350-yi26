/-
SPDX-License-Identifier: Apache-2.0

# One PIO state machine, an instruction at a time

What `Pio.Isa`'s instructions *do*: one state machine of one PIO block,
stepped one instruction at a time. A step either completes an instruction,
waits on it (a FIFO empty or full, a pin or flag not yet at its level — the
state is unchanged, so the same instruction is tried again), or counts down
the delay the last instruction asked for. Time is not modelled beyond that:
a theorem here says what a program does, not how fast.

From the RP2350 datasheet's §11.4. What is modelled:

- the scratch registers X and Y; the shift registers ISR and OSR with their
  shift counters, in either direction, with the push and pull thresholds;
- the TX and RX FIFOs, four words each, front first;
- this machine's outputs: pin values and directions, written through the
  OUT and SET mappings; the pins it reads are the pads, which are what it
  drives where its direction is out and an external input elsewhere;
- the block's eight IRQ flags, as this machine sees them (`rel` is relative
  to machine 0);
- `mov` from STATUS (the TX level below N); `mov`/`out` to EXEC and to PC;
- the RP2350's `mov pindirs` and `wait jmppin`.

What is not, and is answered `none` rather than guessed: the IRQ index modes
`prev` and `next` (they name other PIO blocks), and `mov` to or from the RX
FIFO (it needs the FIFO joined in a mode this model does not have).
Autopush, autopull, side-set and the clock divider are not here either; a
program that needs them is outside every theorem about this model.

Which of these the hardware agrees with is not a theorem's to say.
`experiments/exp217` holds the model, step by step, against two emulators
written by others, on what each of them implements.
-/
import Pio.Isa

namespace Pio

abbrev W := BitVec 32

/-- A state machine's configuration, fixed while it runs. Counts are pins;
thresholds are bits, 1 to 32. -/
structure Config where
  wrapBottom : Nat := 0
  wrapTop : Nat := 31
  inBase : Nat := 0
  outBase : Nat := 0
  outCount : Nat := 0
  setBase : Nat := 0
  setCount : Nat := 5
  jmpPin : Nat := 0
  inRight : Bool := true
  outRight : Bool := true
  pushThresh : Nat := 32
  pullThresh : Nat := 32
  statusN : Nat := 0
  deriving Repr

/-- The state of one machine. `osrCount = 32` is an empty OSR. -/
structure Sm where
  pc : Nat
  x : W
  y : W
  isr : W
  osr : W
  isrCount : Nat
  osrCount : Nat
  tx : List W
  rx : List W
  pins : W
  dirs : W
  irq : BitVec 8
  delay : Nat
  exec : Option Instr
  irqWait : Bool
  deriving Repr

def FIFO_DEPTH : Nat := 4

/-- Writing `count` pins from `base`, wrapping at 32: bit `i` of `v` to pin
`base + i`. -/
def writePins (cur : W) (base count : Nat) (v : W) : W :=
  (List.range count).foldl (fun acc i =>
    let m : W := 1#32 <<< ((base + i) % 32)
    if v.getLsbD i then acc ||| m else acc &&& ~~~m) cur

/-- What the pads read: this machine's outputs where it drives, the outside
elsewhere. -/
def pads (s : Sm) (ext : W) : W := (s.pins &&& s.dirs) ||| (ext &&& ~~~s.dirs)

def mask (n : Nat) : W := BitVec.ofNat 32 (2 ^ n - 1)

/-- `n` bits of `v` shifted into ISR, in its direction. -/
def shiftIn (cfg : Config) (isr v : W) (n : Nat) : W :=
  if cfg.inRight then (isr >>> n) ||| ((v &&& mask n) <<< (32 - n))
  else (isr <<< n) ||| (v &&& mask n)

/-- `n` bits out of OSR, in its direction: the bits, and what OSR keeps. -/
def shiftOut (cfg : Config) (osr : W) (n : Nat) : W × W :=
  if cfg.outRight then (osr &&& mask n, osr >>> n)
  else (osr >>> (32 - n), osr <<< n)

def bitCount (n : BitVec 5) : Nat := if n.toNat = 0 then 32 else n.toNat

def reverse32 (v : W) : W := BitVec.ofNat 32 ((List.range 32).foldl
  (fun acc i => if v.getLsbD i then acc + 2 ^ (31 - i) else acc) 0)

/-- The flag an IRQ index names, for machine 0; `none` for `prev`/`next`. -/
def irqFlag (m : IrqIdx) (n : BitVec 3) : Option Nat :=
  match m with
  | .this | .rel => some n.toNat
  | .prev | .next => none

/-- What an instruction leaves. -/
inductive Res
  | next (s : Sm)
  | jump (s : Sm) (pc : Nat)
  | stall (s : Sm)
  | unsupported

def exe (cfg : Config) (ext : W) (s : Sm) : Op → Res
  | .jmp c a =>
    let go := fun (s : Sm) (b : Bool) => if b then Res.jump s a.toNat else Res.next s
    match c with
    | .always => go s true
    | .notX => go s (s.x = 0)
    | .xDec => go { s with x := s.x - 1 } (s.x ≠ 0)
    | .notY => go s (s.y = 0)
    | .yDec => go { s with y := s.y - 1 } (s.y ≠ 0)
    | .xNeY => go s (s.x ≠ s.y)
    | .pin => go s ((pads s ext).getLsbD (cfg.jmpPin % 32))
    | .notOsre => go s (s.osrCount < cfg.pullThresh)
  | .wait p src =>
    let level := fun (k : Nat) => (pads s ext).getLsbD (k % 32)
    match src with
    | .gpio n => if level n.toNat = p then .next s else .stall s
    | .pin n => if level (cfg.inBase + n.toNat) = p then .next s else .stall s
    | .jmppin n => if level (cfg.jmpPin + n.toNat) = p then .next s else .stall s
    | .irq m n =>
      match irqFlag m n with
      | none => .unsupported
      | some k =>
        if s.irq.getLsbD k = p then
          .next (if p then { s with irq := s.irq &&& ~~~(1#8 <<< k) } else s)
        else .stall s
  | .inp src n =>
    let b := bitCount n
    let v : W := match src with
      | .pins => (pads s ext).rotateRight (cfg.inBase % 32)
      | .x => s.x | .y => s.y | .null => 0 | .isr => s.isr | .osr => s.osr
    .next { s with isr := shiftIn cfg s.isr v b, isrCount := min 32 (s.isrCount + b) }
  | .out dst n =>
    let b := bitCount n
    let (v, osr) := shiftOut cfg s.osr b
    let s := { s with osr := osr, osrCount := min 32 (s.osrCount + b) }
    match dst with
    | .pins => .next { s with pins := writePins s.pins cfg.outBase cfg.outCount v }
    | .pindirs => .next { s with dirs := writePins s.dirs cfg.outBase cfg.outCount v }
    | .x => .next { s with x := v }
    | .y => .next { s with y := v }
    | .null => .next s
    | .pc => .jump s (v.toNat % 32)
    | .isr => .next { s with isr := v, isrCount := b }
    | .exec => .next { s with exec := decode (v.setWidth 16) }
  | .push ifFull block =>
    if ifFull ∧ s.isrCount < cfg.pushThresh then .next s
    else if s.rx.length < FIFO_DEPTH then .next { s with rx := s.rx ++ [s.isr], isr := 0, isrCount := 0 }
    else if block then .stall s
    else .next { s with isr := 0, isrCount := 0 }
  | .pull ifEmpty block =>
    if ifEmpty ∧ s.osrCount < cfg.pullThresh then .next s
    else match s.tx with
      | w :: rest => .next { s with osr := w, osrCount := 0, tx := rest }
      | [] => if block then .stall s else .next { s with osr := s.x, osrCount := 0 }
  | .movToRx _ | .movFromRx _ => .unsupported
  | .mov dst op src =>
    let v : W := match src with
      | .pins => (pads s ext).rotateRight (cfg.inBase % 32)
      | .x => s.x | .y => s.y | .null => 0
      | .status => if s.tx.length < cfg.statusN then BitVec.allOnes 32 else 0
      | .isr => s.isr | .osr => s.osr
    let v := match op with | .plain => v | .invert => ~~~v | .reverse => reverse32 v
    match dst with
    | .pins => .next { s with pins := writePins s.pins cfg.outBase cfg.outCount v }
    | .pindirs => .next { s with dirs := writePins s.dirs cfg.outBase cfg.outCount v }
    | .x => .next { s with x := v }
    | .y => .next { s with y := v }
    | .exec => .next { s with exec := decode (v.setWidth 16) }
    | .pc => .jump s (v.toNat % 32)
    | .isr => .next { s with isr := v, isrCount := 0 }
    | .osr => .next { s with osr := v, osrCount := 0 }
  | .irq op m n =>
    match irqFlag m n with
    | none => .unsupported
    | some k =>
      let bit : BitVec 8 := 1#8 <<< k
      match op with
      | .set => .next { s with irq := s.irq ||| bit }
      | .clear => .next { s with irq := s.irq &&& ~~~bit }
      | .wait =>
        if s.irqWait then
          if s.irq.getLsbD k then .stall s else .next { s with irqWait := false }
        else .stall { s with irq := s.irq ||| bit, irqWait := true }
  | .set dst v =>
    let v : W := v.setWidth 32
    match dst with
    | .pins => .next { s with pins := writePins s.pins cfg.setBase cfg.setCount v }
    | .pindirs => .next { s with dirs := writePins s.dirs cfg.setBase cfg.setCount v }
    | .x => .next { s with x := v }
    | .y => .next { s with y := v }

def advance (cfg : Config) (pc : Nat) : Nat :=
  if pc = cfg.wrapTop then cfg.wrapBottom else (pc + 1) % 32

/-- One step: count down a delay, or try one instruction — the EXEC slot's if
one is waiting there, otherwise the one at `pc`. An instruction run from the
EXEC slot does not move `pc` unless it jumps. `none`: an undecodable word,
or an instruction this model does not have. -/
def step (cfg : Config) (prog : List (BitVec 16)) (ext : W) (s : Sm) : Option Sm :=
  if s.delay > 0 then some { s with delay := s.delay - 1 } else
  let fromExec := s.exec.isSome
  match s.exec.orElse (fun _ => decode (prog.getD s.pc 0)) with
  | none => none
  | some i =>
    match exe cfg ext { s with exec := none } i.op with
    | .unsupported => none
    | .stall s' => some { s' with exec := s.exec }
    | .next s' => some { s' with pc := if fromExec then s.pc else advance cfg s.pc, delay := i.delay.toNat }
    | .jump s' a => some { s' with pc := a, delay := i.delay.toNat }

/-- `n` steps, or `none` as soon as one is. -/
def run (cfg : Config) (prog : List (BitVec 16)) (ext : W) : Nat → Sm → Option Sm
  | 0, s => some s
  | n + 1, s => (step cfg prog ext s).bind (run cfg prog ext n)

theorem run_add (cfg : Config) (prog : List (BitVec 16)) (ext : W) (a b : Nat) (s : Sm) :
    run cfg prog ext (a + b) s = (run cfg prog ext a s).bind (run cfg prog ext b) := by
  induction a generalizing s with
  | zero => simp [run]
  | succ a ih =>
    rw [show a + 1 + b = (a + b) + 1 by omega]
    simp only [run]
    cases step cfg prog ext s <;> simp [ih]

end Pio
