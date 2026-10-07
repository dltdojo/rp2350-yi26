/-
SPDX-License-Identifier: Apache-2.0

# PIO instructions as text, the way pioasm reads them

For holding `Pio.Isa`'s encodings against `pioasm`: every instruction printed
in the RP2350's syntax (`.pio_version 1`), so that assembling the text must
give back the word `encode` makes. No theorem uses this; a wrong printer can
make the comparison fail, never make it pass for a wrong encoding, because the
words are compared, not the text.
-/
import Pio.Isa

namespace Pio

def Cond.toAsm : Cond → String
  | .always => "" | .notX => "!x, " | .xDec => "x--, " | .notY => "!y, " | .yDec => "y--, "
  | .xNeY => "x!=y, " | .pin => "pin, " | .notOsre => "!osre, "

def InSrc.toAsm : InSrc → String
  | .pins => "pins" | .x => "x" | .y => "y" | .null => "null" | .isr => "isr" | .osr => "osr"

def OutDst.toAsm : OutDst → String
  | .pins => "pins" | .x => "x" | .y => "y" | .null => "null" | .pindirs => "pindirs"
  | .pc => "pc" | .isr => "isr" | .exec => "exec"

def MovDst.toAsm : MovDst → String
  | .pins => "pins" | .x => "x" | .y => "y" | .pindirs => "pindirs" | .exec => "exec"
  | .pc => "pc" | .isr => "isr" | .osr => "osr"

def MovOp.toAsm : MovOp → String
  | .plain => "" | .invert => "~" | .reverse => "::"

def MovSrc.toAsm : MovSrc → String
  | .pins => "pins" | .x => "x" | .y => "y" | .null => "null" | .status => "status"
  | .isr => "isr" | .osr => "osr"

def SetDst.toAsm : SetDst → String
  | .pins => "pins" | .x => "x" | .y => "y" | .pindirs => "pindirs"

def IrqOp.toAsm : IrqOp → String
  | .set => "set" | .wait => "wait" | .clear => "clear"

def count (n : BitVec 5) : Nat := if n.toNat = 0 then 32 else n.toNat

def rxIdxAsm : Option (BitVec 3) → String
  | none => "y"
  | some k => s!"{k.toNat}"

def Op.toAsm : Op → String
  | .jmp c a => s!"jmp {c.toAsm}{a.toNat}"
  | .wait p s =>
    let pol := if p then 1 else 0
    match s with
    | .gpio n => s!"wait {pol} gpio {n.toNat}"
    | .pin n => s!"wait {pol} pin {n.toNat}"
    | .irq m n =>
      match m with
      | .prev => s!"wait {pol} irq prev {n.toNat}"
      | .next => s!"wait {pol} irq next {n.toNat}"
      | .rel => s!"wait {pol} irq {n.toNat} rel"
      | .this => s!"wait {pol} irq {n.toNat}"
    | .jmppin n => s!"wait {pol} jmppin + {n.toNat}"
  | .inp s n => s!"in {s.toAsm}, {count n}"
  | .out d n => s!"out {d.toAsm}, {count n}"
  | .push f b => s!"push {if f then "iffull " else ""}{if b then "block" else "noblock"}"
  | .pull e b => s!"pull {if e then "ifempty " else ""}{if b then "block" else "noblock"}"
  | .movToRx k => s!"mov rxfifo[{rxIdxAsm k}], isr"
  | .movFromRx k => s!"mov osr, rxfifo[{rxIdxAsm k}]"
  | .mov d o s => s!"mov {d.toAsm}, {o.toAsm}{s.toAsm}"
  | .irq o m n =>
    match m with
    | .prev => s!"irq prev {o.toAsm} {n.toNat}"
    | .next => s!"irq next {o.toAsm} {n.toNat}"
    | .rel => s!"irq {o.toAsm} {n.toNat} rel"
    | .this => s!"irq {o.toAsm} {n.toNat}"
  | .set d v => s!"set {d.toAsm}, {v.toNat}"

def Instr.toAsm (i : Instr) : String :=
  if i.delay.toNat = 0 then i.op.toAsm else s!"{i.op.toAsm} [{i.delay.toNat}]"

/-- Whether the instruction needs `.fifo putget`, which also forbids PUSH
and PULL: such instructions are assembled in programs of their own. -/
def Op.needsPutget : Op → Bool
  | .movToRx _ | .movFromRx _ => true
  | _ => false

end Pio
