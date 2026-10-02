/-
SPDX-License-Identifier: Apache-2.0

# exp201 — one word, one reading

The two theorems are in the shared library, `lean/Rv32/Isa.lean`, because every
experiment after this one stands on them. This file is what exp201 claims about
them, and the one thing it shows on top: why there are two.

- `Rv32.decode_encode` — every instruction survives a round trip:
  `decode (encode i) = some i`.
- `Rv32.encode_decode` — the decoder accepts no word that is not exactly the
  encoding of what it returns: `decode w = some i → encode i = w`.

The first is the one anybody writes down. It is not enough, and
`a_round_trip_allows_a_second_reading` below is the decoder that proves it:
it passes the first theorem for every instruction and still reads a word that
is no instruction's encoding — the reserved `slli` with bit 30 set — as one.
A kernel's bytes are what the chip executes; if two different words could
decode to the same instruction, a theorem about the instruction would be about
two binaries, and only one of them is the one that was hashed.
-/
import Rv32.Isa

namespace Exp201
open Rv32

/-- `decode_encode`, quoted: every instruction survives a round trip. -/
theorem round_trip (i : Instr) : decode (encode i) = some i := decode_encode i

/-- `encode_decode`, quoted: no alias, no ignored bit. -/
theorem no_alias {w : BitVec 32} {i : Instr} (h : decode w = some i) : encode i = w :=
  encode_decode h

/-- Two instructions never share a word. -/
theorem encode_injective {i j : Instr} (h : encode i = encode j) : i = j := by
  have := round_trip i
  rw [h, round_trip] at this
  exact (Option.some.inj this).symm

/-- **One word, one reading**: two words that decode to the same instruction
are the same word. This is the sentence the kernel's hash check leans on. -/
theorem one_reading {w v : BitVec 32} {i : Instr} (hw : decode w = some i)
    (hv : decode v = some i) : w = v := by
  rw [← no_alias hw, ← no_alias hv]

/-- A decoder that also accepts `0x40001013` — `slli x0, x0, 0` with bit 30
set, which the specification reserves — as `slli x0, x0, 0`. -/
def sloppyDecode (w : BitVec 32) : Option Instr :=
  match decode w with
  | some i => some i
  | none => if w = 0x40001013#32 then some (.sh .slli 0 0 0) else none

/-- The first theorem cannot tell it from the real one... -/
theorem sloppy_round_trips (i : Instr) : sloppyDecode (encode i) = some i := by
  simp [sloppyDecode, round_trip]

/-- ...and it has two words for one instruction. `encode_decode` is what
rules this decoder out; without it, a round trip is all one could say. -/
theorem a_round_trip_allows_a_second_reading :
    sloppyDecode 0x40001013#32 = some (.sh .slli 0 0 0) ∧
      encode (.sh .slli 0 0 0) ≠ 0x40001013#32 := by
  constructor
  · rfl
  · decide

end Exp201

#print axioms Exp201.round_trip
#print axioms Exp201.no_alias
#print axioms Exp201.encode_injective
#print axioms Exp201.one_reading
#print axioms Exp201.sloppy_round_trips
#print axioms Exp201.a_round_trip_allows_a_second_reading
