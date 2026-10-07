/-
SPDX-License-Identifier: Apache-2.0

# exp215 — the word the state machine reads

The two theorems are in the shared library, `lean/Pio/Isa.lean`, where the
next PIO work will stand on them. This file is what exp215 claims about them.

- `Pio.decode_encode` — every instruction survives a round trip:
  `decode (encode i) = some i`.
- `Pio.encode_decode` — the decoder accepts no word that is not exactly the
  encoding of what it returns: `decode w = some i → encode i = w`.

The first is the one anybody writes down, and exp201 showed for RV32IM why
it is not enough: a decoder can pass it and still read a second word as the
same instruction. Here the word that would do it is `irq clear 0` with the
wait bit also set, `0xc060`. The datasheet says the hardware ignores wait
when clear is set, and no assembler writes the word.
`a_round_trip_allows_a_second_reading` is a decoder that accepts it, and
passes the first theorem anyway.
-/
import Pio.Isa

namespace Exp215
open Pio

/-- `decode_encode`, quoted: every instruction survives a round trip. -/
theorem round_trip (i : Instr) : decode (encode i) = some i := decode_encode i

/-- `encode_decode`, quoted: no alias, no ignored bit. -/
theorem no_alias {w : BitVec 16} {i : Instr} (h : decode w = some i) : encode i = w :=
  encode_decode h

/-- **One word, one reading**: two words that decode to the same instruction
are the same word. -/
theorem one_reading {w v : BitVec 16} {i : Instr} (hw : decode w = some i)
    (hv : decode v = some i) : w = v := by
  rw [← no_alias hw, ← no_alias hv]

/-- A decoder that also reads `0xc060` — clear and wait both set, flag 0 —
as `irq clear 0`, the way the hardware is said to. -/
def sloppyDecode (w : BitVec 16) : Option Instr :=
  match decode w with
  | some i => some i
  | none => if w = 0xc060#16 then some ⟨.irq .clear .this 0, 0⟩ else none

/-- The first theorem cannot tell it from the real one... -/
theorem sloppy_round_trips (i : Instr) : sloppyDecode (encode i) = some i := by
  simp [sloppyDecode, round_trip]

/-- ...and it has two words for one instruction. -/
theorem a_round_trip_allows_a_second_reading :
    sloppyDecode 0xc060#16 = some ⟨.irq .clear .this 0, 0⟩ ∧
      encode ⟨.irq .clear .this 0, 0⟩ ≠ 0xc060#16 := by
  constructor
  · rfl
  · decide

end Exp215

#print axioms Exp215.round_trip
#print axioms Exp215.no_alias
#print axioms Pio.encode_injective
#print axioms Exp215.one_reading
#print axioms Exp215.sloppy_round_trips
#print axioms Exp215.a_round_trip_allows_a_second_reading
