/-
SPDX-License-Identifier: Apache-2.0

# PIO: the instructions, their 16-bit encodings, and the way back

The RP2350's PIO instruction set, the nine kinds of the RP2350 datasheet's
§11.4 and the RP2350's additions to them — `mov` to and from the RX FIFO,
`wait jmppin`, `mov pindirs`, and the IRQ index modes `prev`, `rel` and
`next` — with the delay field taken whole as five bits of delay. Side-set,
which takes some of those five bits when a program configures it, is not
here: what those bits mean is a property of the program, not of the word.

Every word is three fields — the opcode (bits 15:13), the delay (12:8) and
eight bits the opcode gives a layout to — so `encode` is a sum and `decode`
reads them back by division. The two theorems at the bottom say the two
agree in both directions: every instruction survives a round trip, and
`decode` accepts no word that is not exactly the encoding of what it
returns. So a word of a PIO program has one reading.

`decode` refuses what the datasheet calls reserved, and also the few words
whose extra bits the hardware is said to ignore but which no assembler
writes — `irq clear` with the wait bit set, `mov rxfifo[y]` with an index
beside it. Refusing them costs nothing and keeps "one reading" literal.

Whether these are the encodings the *datasheet* gives is not something a
theorem here can say. `experiments/exp215` answers it against Raspberry
Pi's `pioasm`, over all 65536 words.
-/

namespace Pio

/-- JMP's condition, bits 7:5. -/
inductive Cond | always | notX | xDec | notY | yDec | xNeY | pin | notOsre
  deriving DecidableEq, Repr

/-- How an IRQ index names a flag: bits 4:3 of WAIT IRQ's and IRQ's index. -/
inductive IrqIdx | this | prev | rel | next
  deriving DecidableEq, Repr

/-- WAIT's source, bits 6:5, and its index, bits 4:0. `jmppin`'s offset is
0 to 3; the datasheet reserves the rest. -/
inductive WaitSrc
  | gpio (n : BitVec 5)
  | pin (n : BitVec 5)
  | irq (m : IrqIdx) (n : BitVec 3)
  | jmppin (n : BitVec 2)
  deriving DecidableEq, Repr

/-- IN's source, bits 7:5; 4 and 5 are reserved. -/
inductive InSrc | pins | x | y | null | isr | osr
  deriving DecidableEq, Repr

/-- OUT's destination, bits 7:5. -/
inductive OutDst | pins | x | y | null | pindirs | pc | isr | exec
  deriving DecidableEq, Repr

/-- MOV's destination, bits 7:5. -/
inductive MovDst | pins | x | y | pindirs | exec | pc | isr | osr
  deriving DecidableEq, Repr

/-- MOV's operation, bits 4:3; 3 is reserved. Not `none`: inside this type's
namespace that name would shadow `Option.none`. -/
inductive MovOp | plain | invert | reverse
  deriving DecidableEq, Repr

/-- MOV's source, bits 2:0; 4 is reserved. -/
inductive MovSrc | pins | x | y | null | status | isr | osr
  deriving DecidableEq, Repr

/-- IRQ's clear and wait bits, 6 and 5. Clear with wait has no syntax. -/
inductive IrqOp | set | wait | clear
  deriving DecidableEq, Repr

/-- SET's destination, bits 7:5; 3, 5, 6 and 7 are reserved. -/
inductive SetDst | pins | x | y | pindirs
  deriving DecidableEq, Repr

/-- What an instruction does, everything but its delay. `inp` is IN (`in` is
a keyword). The counts of IN and OUT are as encoded: 0 means 32. A
`movToRx`/`movFromRx` index of `none` is `rxfifo[y]`. -/
inductive Op
  | jmp (c : Cond) (addr : BitVec 5)
  | wait (pol : Bool) (src : WaitSrc)
  | inp (src : InSrc) (count : BitVec 5)
  | out (dst : OutDst) (count : BitVec 5)
  | push (ifFull block : Bool)
  | pull (ifEmpty block : Bool)
  | movToRx (idx : Option (BitVec 3))
  | movFromRx (idx : Option (BitVec 3))
  | mov (dst : MovDst) (op : MovOp) (src : MovSrc)
  | irq (op : IrqOp) (m : IrqIdx) (n : BitVec 3)
  | set (dst : SetDst) (data : BitVec 5)
  deriving DecidableEq, Repr

/-- One instruction: what it does, and how many cycles it waits after. -/
structure Instr where
  op : Op
  delay : BitVec 5
  deriving DecidableEq, Repr

/-! ## Codes, one table each, and back -/

def Cond.code : Cond → Nat
  | .always => 0 | .notX => 1 | .xDec => 2 | .notY => 3 | .yDec => 4 | .xNeY => 5
  | .pin => 6 | .notOsre => 7
def Cond.ofCode : Nat → Option Cond
  | 0 => some .always | 1 => some .notX | 2 => some .xDec | 3 => some .notY
  | 4 => some .yDec | 5 => some .xNeY | 6 => some .pin | 7 => some .notOsre | _ => none

def IrqIdx.code : IrqIdx → Nat
  | .this => 0 | .prev => 1 | .rel => 2 | .next => 3
def IrqIdx.ofCode : Nat → Option IrqIdx
  | 0 => some .this | 1 => some .prev | 2 => some .rel | 3 => some .next | _ => none

def InSrc.code : InSrc → Nat
  | .pins => 0 | .x => 1 | .y => 2 | .null => 3 | .isr => 6 | .osr => 7
def InSrc.ofCode : Nat → Option InSrc
  | 0 => some .pins | 1 => some .x | 2 => some .y | 3 => some .null
  | 6 => some .isr | 7 => some .osr | _ => none

def OutDst.code : OutDst → Nat
  | .pins => 0 | .x => 1 | .y => 2 | .null => 3 | .pindirs => 4 | .pc => 5
  | .isr => 6 | .exec => 7
def OutDst.ofCode : Nat → Option OutDst
  | 0 => some .pins | 1 => some .x | 2 => some .y | 3 => some .null
  | 4 => some .pindirs | 5 => some .pc | 6 => some .isr | 7 => some .exec | _ => none

def MovDst.code : MovDst → Nat
  | .pins => 0 | .x => 1 | .y => 2 | .pindirs => 3 | .exec => 4 | .pc => 5
  | .isr => 6 | .osr => 7
def MovDst.ofCode : Nat → Option MovDst
  | 0 => some .pins | 1 => some .x | 2 => some .y | 3 => some .pindirs
  | 4 => some .exec | 5 => some .pc | 6 => some .isr | 7 => some .osr | _ => none

def MovOp.code : MovOp → Nat
  | .plain => 0 | .invert => 1 | .reverse => 2
def MovOp.ofCode : Nat → Option MovOp
  | 0 => some .plain | 1 => some .invert | 2 => some .reverse | _ => none

def MovSrc.code : MovSrc → Nat
  | .pins => 0 | .x => 1 | .y => 2 | .null => 3 | .status => 5 | .isr => 6 | .osr => 7
def MovSrc.ofCode : Nat → Option MovSrc
  | 0 => some .pins | 1 => some .x | 2 => some .y | 3 => some .null
  | 5 => some .status | 6 => some .isr | 7 => some .osr | _ => none

/-- Bits 6:5 of IRQ, clear then wait. -/
def IrqOp.code : IrqOp → Nat
  | .set => 0 | .wait => 1 | .clear => 2
def IrqOp.ofCode : Nat → Option IrqOp
  | 0 => some .set | 1 => some .wait | 2 => some .clear | _ => none

def SetDst.code : SetDst → Nat
  | .pins => 0 | .x => 1 | .y => 2 | .pindirs => 4
def SetDst.ofCode : Nat → Option SetDst
  | 0 => some .pins | 1 => some .x | 2 => some .y | 4 => some .pindirs | _ => none

theorem Cond.ofCode_code (c : Cond) : Cond.ofCode c.code = some c := by cases c <;> rfl
theorem IrqIdx.ofCode_code (c : IrqIdx) : IrqIdx.ofCode c.code = some c := by cases c <;> rfl
theorem InSrc.ofCode_code (c : InSrc) : InSrc.ofCode c.code = some c := by cases c <;> rfl
theorem OutDst.ofCode_code (c : OutDst) : OutDst.ofCode c.code = some c := by cases c <;> rfl
theorem MovDst.ofCode_code (c : MovDst) : MovDst.ofCode c.code = some c := by cases c <;> rfl
theorem MovOp.ofCode_code (c : MovOp) : MovOp.ofCode c.code = some c := by cases c <;> rfl
theorem MovSrc.ofCode_code (c : MovSrc) : MovSrc.ofCode c.code = some c := by cases c <;> rfl
theorem IrqOp.ofCode_code (c : IrqOp) : IrqOp.ofCode c.code = some c := by cases c <;> rfl
theorem SetDst.ofCode_code (c : SetDst) : SetDst.ofCode c.code = some c := by cases c <;> rfl

theorem Cond.code_ofCode {n : Nat} {c : Cond} (h : Cond.ofCode n = some c) : c.code = n := by
  unfold Cond.ofCode at h; split at h <;> cases h <;> rfl
theorem IrqIdx.code_ofCode {n : Nat} {c : IrqIdx} (h : IrqIdx.ofCode n = some c) : c.code = n := by
  unfold IrqIdx.ofCode at h; split at h <;> cases h <;> rfl
theorem InSrc.code_ofCode {n : Nat} {c : InSrc} (h : InSrc.ofCode n = some c) : c.code = n := by
  unfold InSrc.ofCode at h; split at h <;> cases h <;> rfl
theorem OutDst.code_ofCode {n : Nat} {c : OutDst} (h : OutDst.ofCode n = some c) : c.code = n := by
  unfold OutDst.ofCode at h; split at h <;> cases h <;> rfl
theorem MovDst.code_ofCode {n : Nat} {c : MovDst} (h : MovDst.ofCode n = some c) : c.code = n := by
  unfold MovDst.ofCode at h; split at h <;> cases h <;> rfl
theorem MovOp.code_ofCode {n : Nat} {c : MovOp} (h : MovOp.ofCode n = some c) : c.code = n := by
  unfold MovOp.ofCode at h; split at h <;> cases h <;> rfl
theorem MovSrc.code_ofCode {n : Nat} {c : MovSrc} (h : MovSrc.ofCode n = some c) : c.code = n := by
  unfold MovSrc.ofCode at h; split at h <;> cases h <;> rfl
theorem IrqOp.code_ofCode {n : Nat} {c : IrqOp} (h : IrqOp.ofCode n = some c) : c.code = n := by
  unfold IrqOp.ofCode at h; split at h <;> cases h <;> rfl
theorem SetDst.code_ofCode {n : Nat} {c : SetDst} (h : SetDst.ofCode n = some c) : c.code = n := by
  unfold SetDst.ofCode at h; split at h <;> cases h <;> rfl

theorem Cond.code_lt (c : Cond) : c.code < 8 := by cases c <;> decide
theorem IrqIdx.code_lt (c : IrqIdx) : c.code < 4 := by cases c <;> decide
theorem InSrc.code_lt (c : InSrc) : c.code < 8 := by cases c <;> decide
theorem OutDst.code_lt (c : OutDst) : c.code < 8 := by cases c <;> decide
theorem MovDst.code_lt (c : MovDst) : c.code < 8 := by cases c <;> decide
theorem MovOp.code_lt (c : MovOp) : c.code < 4 := by cases c <;> decide
theorem MovSrc.code_lt (c : MovSrc) : c.code < 8 := by cases c <;> decide
theorem IrqOp.code_lt (c : IrqOp) : c.code < 4 := by cases c <;> decide
theorem SetDst.code_lt (c : SetDst) : c.code < 8 := by cases c <;> decide

/-! ## The word -/

/-- WAIT's source and index, bits 6:0. -/
def WaitSrc.bits : WaitSrc → Nat
  | .gpio n => n.toNat
  | .pin n => 32 + n.toNat
  | .irq m n => 64 + m.code * 8 + n.toNat
  | .jmppin n => 96 + n.toNat

/-- The `rxfifo[...]` index, bits 3:0: IdxI, then the index. -/
def rxIdx : Option (BitVec 3) → Nat
  | none => 0
  | some k => 8 + k.toNat

def Op.opcode : Op → Nat
  | .jmp .. => 0 | .wait .. => 1 | .inp .. => 2 | .out .. => 3
  | .push .. | .pull .. | .movToRx .. | .movFromRx .. => 4
  | .mov .. => 5 | .irq .. => 6 | .set .. => 7

/-- Bits 7:0, the opcode's own layout. -/
def Op.low : Op → Nat
  | .jmp c a => c.code * 32 + a.toNat
  | .wait p s => p.toNat * 128 + s.bits
  | .inp s n => s.code * 32 + n.toNat
  | .out d n => d.code * 32 + n.toNat
  | .push f b => f.toNat * 64 + b.toNat * 32
  | .pull e b => 128 + e.toNat * 64 + b.toNat * 32
  | .movToRx k => 16 + rxIdx k
  | .movFromRx k => 128 + 16 + rxIdx k
  | .mov d o s => d.code * 32 + o.code * 8 + s.code
  | .irq o m n => o.code * 32 + m.code * 8 + n.toNat
  | .set d v => d.code * 32 + v.toNat

def encodeNat (i : Instr) : Nat := i.op.opcode * 2^13 + i.delay.toNat * 2^8 + i.op.low

def encode (i : Instr) : BitVec 16 := .ofNat 16 (encodeNat i)

def decodeWait (l : Nat) : Option WaitSrc :=
  let i := l % 32
  match l / 32 % 4 with
  | 0 => some (.gpio (.ofNat 5 i))
  | 1 => some (.pin (.ofNat 5 i))
  | 2 => (IrqIdx.ofCode (i / 8)).map fun m => .irq m (.ofNat 3 (i % 8))
  | _ => if i < 4 then some (.jmppin (.ofNat 2 i)) else none

def decodeRxIdx (l : Nat) : Option (Option (BitVec 3)) :=
  if l / 8 % 2 = 1 then some (some (.ofNat 3 (l % 8)))
  else if l % 8 = 0 then some none
  else none

/-- Opcode 4: PUSH, PULL, and the RP2350's MOV to and from the RX FIFO. -/
def decode4 (l : Nat) : Option Op :=
  if l % 32 = 0 then
    if l / 128 = 0 then some (.push (l / 64 % 2 = 1) (l / 32 % 2 = 1))
    else some (.pull (l / 64 % 2 = 1) (l / 32 % 2 = 1))
  else if l / 32 % 4 = 0 ∧ l / 16 % 2 = 1 then
    if l / 128 = 0 then (decodeRxIdx l).map .movToRx else (decodeRxIdx l).map .movFromRx
  else none

def decodeOp (opc l : Nat) : Option Op :=
  match opc with
  | 0 => (Cond.ofCode (l / 32)).map fun c => .jmp c (.ofNat 5 (l % 32))
  | 1 => (decodeWait l).map fun s => .wait (l / 128 = 1) s
  | 2 => (InSrc.ofCode (l / 32)).map fun s => .inp s (.ofNat 5 (l % 32))
  | 3 => (OutDst.ofCode (l / 32)).map fun d => .out d (.ofNat 5 (l % 32))
  | 4 => decode4 l
  | 5 =>
    match MovDst.ofCode (l / 32), MovOp.ofCode (l / 8 % 4), MovSrc.ofCode (l % 8) with
    | some d, some o, some s => some (.mov d o s)
    | _, _, _ => none
  | 6 =>
    if l / 128 = 0 then
      match IrqOp.ofCode (l / 32 % 4), IrqIdx.ofCode (l / 8 % 4) with
      | some o, some m => some (.irq o m (.ofNat 3 (l % 8)))
      | _, _ => none
    else none
  | _ => (SetDst.ofCode (l / 32)).map fun d => .set d (.ofNat 5 (l % 32))

def decodeNat (n : Nat) : Option Instr :=
  (decodeOp (n / 2^13) (n % 256)).map fun o => ⟨o, .ofNat 5 (n / 2^8 % 32)⟩

def decode (w : BitVec 16) : Option Instr := decodeNat w.toNat

/-! ## Every instruction survives a round trip -/

theorem ifT {α : Type} {c : Prop} [Decidable c] {a b : α} (h : c) : (if c then a else b) = a := by
  simp [h]
theorem ifF {α : Type} {c : Prop} [Decidable c] {a b : α} (h : ¬ c) : (if c then a else b) = b := by
  simp [h]

theorem rxIdx_lt (k : Option (BitVec 3)) : rxIdx k < 16 := by
  cases k with
  | none => decide
  | some k => have := k.isLt; simp only [rxIdx]; omega

theorem WaitSrc.bits_lt (s : WaitSrc) : s.bits < 128 := by
  cases s with
  | gpio n => have := n.isLt; simp only [WaitSrc.bits]; omega
  | pin n => have := n.isLt; simp only [WaitSrc.bits]; omega
  | irq m n => have := n.isLt; have := m.code_lt; simp only [WaitSrc.bits]; omega
  | jmppin n => have := n.isLt; simp only [WaitSrc.bits]; omega

theorem Op.opcode_lt (o : Op) : o.opcode < 8 := by cases o <;> simp only [Op.opcode] <;> omega

theorem Op.low_lt (o : Op) : o.low < 256 := by
  cases o with
  | jmp c a => have := c.code_lt; have := a.isLt; simp only [Op.low]; omega
  | wait p s => have := s.bits_lt; have := Bool.toNat_le p; simp only [Op.low]; omega
  | inp s n => have := s.code_lt; have := n.isLt; simp only [Op.low]; omega
  | out d n => have := d.code_lt; have := n.isLt; simp only [Op.low]; omega
  | push f b => cases f <;> cases b <;> decide
  | pull e b => cases e <;> cases b <;> decide
  | movToRx k => have := rxIdx_lt k; simp only [Op.low]; omega
  | movFromRx k => have := rxIdx_lt k; simp only [Op.low]; omega
  | mov d o s => have := d.code_lt; have := o.code_lt; have := s.code_lt; simp only [Op.low]; omega
  | irq o m n => have := o.code_lt; have := m.code_lt; have := n.isLt; simp only [Op.low]; omega
  | set d v => have := d.code_lt; have := v.isLt; simp only [Op.low]; omega

theorem decodeWait_bits (s : WaitSrc) (p : Nat) : decodeWait (p * 128 + s.bits) = some s := by
  cases s with
  | gpio n =>
    have := n.isLt
    simp only [decodeWait, WaitSrc.bits]
    simp only [show (p * 128 + n.toNat) / 32 % 4 = 0 by omega, show (p * 128 + n.toNat) % 32 = n.toNat by omega]
    simp
  | pin n =>
    have := n.isLt
    simp only [decodeWait, WaitSrc.bits]
    simp only [show (p * 128 + (32 + n.toNat)) / 32 % 4 = 1 by omega,
      show (p * 128 + (32 + n.toNat)) % 32 = n.toNat by omega]
    simp
  | irq m n =>
    have := n.isLt; have := m.code_lt
    simp only [decodeWait, WaitSrc.bits]
    simp only [show (p * 128 + (64 + m.code * 8 + n.toNat)) / 32 % 4 = 2 by omega,
      show (p * 128 + (64 + m.code * 8 + n.toNat)) % 32 / 8 = m.code by omega,
      show (p * 128 + (64 + m.code * 8 + n.toNat)) % 32 % 8 = n.toNat by omega, IrqIdx.ofCode_code]
    simp
  | jmppin n =>
    have := n.isLt
    simp only [decodeWait, WaitSrc.bits]
    simp only [show (p * 128 + (96 + n.toNat)) / 32 % 4 = 3 by omega,
      show (p * 128 + (96 + n.toNat)) % 32 = n.toNat by omega]
    simp [show n.toNat < 4 by omega]

theorem decodeRxIdx_rxIdx (k : Option (BitVec 3)) (hi : Nat) :
    decodeRxIdx (hi * 32 + 16 + rxIdx k) = some k := by
  cases k with
  | none =>
    simp only [decodeRxIdx, rxIdx]
    simp only [show (hi * 32 + 16 + 0) / 8 % 2 = 0 by omega, show (hi * 32 + 16 + 0) % 8 = 0 by omega]
    simp
  | some k =>
    have := k.isLt
    simp only [decodeRxIdx, rxIdx]
    simp only [show (hi * 32 + 16 + (8 + k.toNat)) / 8 % 2 = 1 by omega,
      show (hi * 32 + 16 + (8 + k.toNat)) % 8 = k.toNat by omega]
    simp

theorem decodeOp_low (o : Op) : decodeOp o.opcode o.low = some o := by
  cases o with
  | jmp c a =>
    have := c.code_lt; have := a.isLt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [show (c.code * 32 + a.toNat) / 32 = c.code by omega,
      show (c.code * 32 + a.toNat) % 32 = a.toNat by omega, Cond.ofCode_code]
    simp
  | wait p s =>
    have := s.bits_lt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [decodeWait_bits s p.toNat]
    cases p <;> simp [Bool.toNat] <;> omega
  | inp s n =>
    have := s.code_lt; have := n.isLt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [show (s.code * 32 + n.toNat) / 32 = s.code by omega,
      show (s.code * 32 + n.toNat) % 32 = n.toNat by omega, InSrc.ofCode_code]
    simp
  | out d n =>
    have := d.code_lt; have := n.isLt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [show (d.code * 32 + n.toNat) / 32 = d.code by omega,
      show (d.code * 32 + n.toNat) % 32 = n.toNat by omega, OutDst.ofCode_code]
    simp
  | push f b => cases f <;> cases b <;> rfl
  | pull e b => cases e <;> cases b <;> rfl
  | movToRx k =>
    have := rxIdx_lt k
    simp only [Op.opcode, Op.low, decodeOp, decode4]
    have e := decodeRxIdx_rxIdx k 0
    rw [show 0 * 32 + 16 + rxIdx k = 16 + rxIdx k by omega] at e
    have h1 : (16 + rxIdx k) % 32 ≠ 0 := by omega
    have h2 : (16 + rxIdx k) / 32 % 4 = 0 := by omega
    have h4 : (16 + rxIdx k) / 128 = 0 := by omega
    have h5 : rxIdx k / 16 = 0 := by omega
    simp [h1, h2, h4, h5, e]
  | movFromRx k =>
    have := rxIdx_lt k
    simp only [Op.opcode, Op.low, decodeOp, decode4]
    have e := decodeRxIdx_rxIdx k 4
    rw [show 4 * 32 + 16 + rxIdx k = 128 + 16 + rxIdx k by omega] at e
    have h1 : (128 + 16 + rxIdx k) % 32 ≠ 0 := by omega
    have h2 : (128 + 16 + rxIdx k) / 32 % 4 = 0 := by omega
    have h3 : (128 + 16 + rxIdx k) / 16 % 2 = 1 := by omega
    have h4 : (128 + 16 + rxIdx k) / 128 ≠ 0 := by omega
    simp [h1, h2, h3, h4, e]
  | mov d o s =>
    have := d.code_lt; have := o.code_lt; have := s.code_lt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [show (d.code * 32 + o.code * 8 + s.code) / 32 = d.code by omega,
      show (d.code * 32 + o.code * 8 + s.code) / 8 % 4 = o.code by omega,
      show (d.code * 32 + o.code * 8 + s.code) % 8 = s.code by omega,
      MovDst.ofCode_code, MovOp.ofCode_code, MovSrc.ofCode_code]
  | irq o m n =>
    have := o.code_lt; have := m.code_lt; have := n.isLt
    simp only [Op.opcode, Op.low, decodeOp]
    have h0 : (o.code * 32 + m.code * 8 + n.toNat) / 128 = 0 := by omega
    simp only [h0, ↓reduceIte]
    rw [show (o.code * 32 + m.code * 8 + n.toNat) / 32 % 4 = o.code by omega,
      show (o.code * 32 + m.code * 8 + n.toNat) / 8 % 4 = m.code by omega,
      show (o.code * 32 + m.code * 8 + n.toNat) % 8 = n.toNat by omega,
      IrqOp.ofCode_code, IrqIdx.ofCode_code]
    simp
  | set d v =>
    have := d.code_lt; have := v.isLt
    simp only [Op.opcode, Op.low, decodeOp]
    rw [show (d.code * 32 + v.toNat) / 32 = d.code by omega,
      show (d.code * 32 + v.toNat) % 32 = v.toNat by omega, SetDst.ofCode_code]
    simp

theorem encodeNat_lt (i : Instr) : encodeNat i < 2^16 := by
  have := i.op.opcode_lt; have := i.op.low_lt; have := i.delay.isLt
  simp only [encodeNat]; omega

theorem toNat_encode (i : Instr) : (encode i).toNat = encodeNat i := by
  simp only [encode, BitVec.toNat_ofNat]; exact Nat.mod_eq_of_lt (encodeNat_lt i)

/-- **Every instruction survives a round trip.** -/
theorem decode_encode (i : Instr) : decode (encode i) = some i := by
  have := i.op.opcode_lt; have := i.op.low_lt; have := i.delay.isLt
  simp only [decode, toNat_encode, decodeNat, encodeNat]
  rw [show (i.op.opcode * 2^13 + i.delay.toNat * 2^8 + i.op.low) / 2^13 = i.op.opcode by omega,
    show (i.op.opcode * 2^13 + i.delay.toNat * 2^8 + i.op.low) % 256 = i.op.low by omega,
    show (i.op.opcode * 2^13 + i.delay.toNat * 2^8 + i.op.low) / 2^8 % 32 = i.delay.toNat by omega,
    decodeOp_low]
  simp

end Pio
