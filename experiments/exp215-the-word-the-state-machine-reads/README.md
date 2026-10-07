# exp215 — the word the state machine reads

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A Lean encoder and decoder for the RP2350's PIO instructions: all nine
kinds, with the RP2350's additions (`mov` to and from the RX FIFO, `wait
jmppin`, `mov pindirs`, and the IRQ index modes `prev`, `rel` and `next`),
the delay field taken whole. Two theorems say the encoder and decoder agree
in both directions, so a PIO word has one reading. Raspberry Pi's `pioasm`
agrees with all 65,536 words. Each of the 42,304 words Lean decodes,
printed and assembled, comes back as that word. Every instruction `pioasm`
accepts, at every delay, makes a word Lean decodes, and those are exactly
the 42,304. Four wrong encodings pass both theorems and fail against
`pioasm`, which is why the comparison is here.**

exp214 put a PIO program on silicon, and its three words were held to
`pioasm` by comparing them. This is what a proof about a PIO program's bytes
will stand on, as exp201's RV32IM decoder is what every kernel proof here
stands on: a theorem about "the instruction `pull block`" has to be a
theorem about one 16-bit word, and this is where that is earned.

## The scope

| | |
| --- | --- |
| In | JMP, WAIT, IN, OUT, PUSH, PULL, MOV, IRQ, SET: every field, every value the datasheet does not reserve. The RP2350's additions: `mov rxfifo[y\|0–7], isr`, `mov osr, rxfifo[y\|0–7]`, `wait jmppin + 0–3`, `mov pindirs, …`, and IRQ indices under `prev`, `rel` and `next` |
| Out | **Side-set.** When a program configures it, side-set takes some of the five delay bits; what those bits mean is a property of the program, not of the word. Here all five are delay |
| Refused | What the datasheet reserves (IN sources 4 and 5, MOV source 4 and operation 3, SET destinations 3, 5–7, IRQ bit 7, `jmppin` offsets above 3), and the few words whose extra bits the hardware is said to ignore but no assembler writes: `irq clear` with the wait bit set, and `mov rxfifo[y]` with index bits beside it |

The library is [`lean/Pio/Isa.lean`](../../lean/Pio/Isa.lean), and the text
`pioasm` reads is [`lean/Pio/Asm.lean`](../../lean/Pio/Asm.lean). A word is
three fields: the opcode (bits 15:13), the delay (12:8), and eight bits the
opcode lays out. So `encode` is a sum and `decode` reads the fields back by
division, as in `lean/Rv32/Isa.lean`.

## What is proved

| Theorem | Says |
| --- | --- |
| `Pio.decode_encode` | every instruction survives a round trip: `decode (encode i) = some i` |
| `Pio.encode_decode` | `decode` accepts no word that is not exactly the encoding of what it returns: `decode w = some i → encode i = w` |
| `Pio.encode_injective` | two instructions never share a word |
| `one_reading` | two words that decode to the same instruction are the same word |
| `a_round_trip_allows_a_second_reading` | why there are two theorems: a decoder that also reads `0xc060`, `irq clear 0` with the wait bit set, passes the first theorem for every instruction and has two words for one |

[`proof/Roundtrip.lean`](./proof/Roundtrip.lean) quotes the library's
theorems and adds the last two. Everything rests on `propext`,
`Classical.choice` and `Quot.sound`.

Six wrong versions of the library in
[`proof/mutants.txt`](./proof/mutants.txt) are each refused:
- **two by `decode_encode`:** jmp's conditions 6 and 7 read the other way
  round, and pull's IfEmpty and Block bits written in each other's places;
- **four by `encode_decode`:** `wait jmppin` offsets up to 7, `mov
  rxfifo[y]` with any index bits, `irq` with bit 7 set, and `irq clear`
  with the wait bit set.

## The differential

No theorem can say these are the datasheet's encodings, because the
datasheet is prose. [`differential/`](./differential/) asks `pioasm` 2.3.1,
built by [`tools/pioasm`](../../tools/pioasm/) at `.pio_version 1`, and
because a PIO word is 16 bits it asks about every word:

1. **Lean's readings.** [`Gen.lean`](./differential/Gen.lean) prints all
   65,536 words, each with the text Lean reads it as or `NONE`. Lean decodes
   42,304. Each one's text is assembled, in programs of 32 padded with `nop`
   so every jump target is inside, and `mov rxfifo` ones under `.fifo
   putget`, which forbids PUSH and PULL. Every word comes back unchanged.
2. **`pioasm`'s words.** [`differential.py`](./differential/differential.py)
   writes its own grammar of what `pioasm` accepts, from `pioasm`'s syntax
   and not from Lean: 1,322 instructions, each at all 32 delays, 42,304
   texts. Lean decodes every word they make, and the words are exactly the
   42,304 Lean decodes, no more and no fewer. The other 23,232 Lean refuses,
   and `pioasm` made none of them.

Two theorems agreeing with each other cannot catch a mistake made the same
way in both directions. [`differential/mutants.txt`](./differential/mutants.txt)
has four such mistakes. Each passes both theorems, and the differential
refuses each:
- `jmp x--` and `y--` trading codes in both tables;
- MOV's `status` given the reserved code 4 in both;
- the IRQ modes `prev` and `next` trading codes in both;
- SET's `pindirs` given the reserved code 3 in both.

`tools/lean/gap.sh` runs them. exp201 wrote that loop for LLVM; this is its
second caller, so it moved to `tools/lean`.

## What it does not say

- **That the chip executes these words as named.** That a word is `pull
  block` is proved, and that `pioasm` agrees; what `pull block` *does* is a
  model of PIO, which is not here. exp214 ran three of these words on
  silicon.
- **Side-set.** Out of scope, above.
- **That `pioasm` is right.** It is Raspberry Pi's own assembler, and the
  only independent reading available; it is not the datasheet either.

## Running it

```sh
./check.sh               # the proof, its mutants, the differential, the gap
differential/gap.sh --show
./run.sh                 # records capture.txt
```

Needs Lean (`tools/lean/setup.sh`) and pioasm (`tools/pioasm/setup.sh`). No
board. A few minutes, nearly all of it ten mutants rebuilding the library.

## Expected output

CAPTURE
