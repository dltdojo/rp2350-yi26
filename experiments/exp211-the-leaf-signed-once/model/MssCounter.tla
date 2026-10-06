----------------------------- MODULE MssCounter -----------------------------
(* SPDX-License-Identifier: Apache-2.0

   An MSS signer's leaf counter in NOR flash, against somebody who holds the
   board. Each boot reads the counter, signs one leaf, and moves the counter
   on; the question is whether any leaf is ever signed twice.

   NOR flash, as the model has it: an erase sets every bit of a sector to 1;
   a program can only clear bits to 0. A power cut in the middle of either
   leaves an arbitrary subset of the bits it was changing changed. That is
   the whole assumption about the chip, and it is the datasheet's, not a
   measurement.

     Design  "unary"       exp211: one word per leaf, all ones when unused.
                           Claim first — program the leaf's word to 0 — and
                           only then sign. Never erased after formatting.
                           A word with any bit cleared counts as used.
             "sign_first"  the same words, but sign, then claim: the order
                           exp197 found its PIN counter had
             "number"      claim first, but the counter is one number,
                           rewritten by erasing its sector and programming
                           the next value
             "in_image"    "unary", but the sector lies inside the firmware
                           image, so flashing the firmware again erases it

     Attacker "power"      cuts the power between any two steps, or in the
                           middle of an erase or a program
              "reflash"    that, and flashes the same firmware again
              "eraser"     that, and erases the whole flash through BOOTSEL
                           (picotool erase -a, exp141): a person holding the
                           board, which this design does not stop

   Leaves is 3 rather than 16, and a word has Bits bits rather than 32: every
   argument here is per word, and the search must end. *)
EXTENDS Naturals, FiniteSets

CONSTANTS Design, Attacker, Leaves, Bits

AllBits == 1..Bits
Slots == 0..(Leaves - 1)

VARIABLES magic,    \* bits cleared in the format marker; formatted iff all of them
          claim,    \* per leaf, the bits cleared in its word ("unary" designs)
          num,      \* the "number" design's counter: a value, Erased, or Garbage
          pc,       \* where this boot is
          k,        \* the leaf this boot read
          signed    \* how many times each leaf has been signed

vars == <<magic, claim, num, pc, k, signed>>

Unary == Design \in {"unary", "sign_first", "in_image"}

\* The "number" design's word when it is all ones, and when it is neither all
\* ones nor a value it wrote (a program cut short).
Erased == 100
Garbage == 101

Init == /\ magic = {} /\ claim = [i \in Slots |-> {}] /\ num = Erased
        /\ pc = "boot" /\ k = 0 /\ signed = [i \in Slots |-> 0]

\* How many leaves the counter says are used: the unused words must be a
\* suffix, else the boot refuses. NoneUnused: every leaf used.
UsedCount == CHOOSE n \in 0..Leaves : (\A i \in Slots : (i < n) <=> (claim[i] # {}))
Consistent == \E n \in 0..Leaves : \A i \in Slots : (i < n) <=> (claim[i] # {})

NumValue == IF num = Erased THEN 0 ELSE num

----------------------------------------------------------------------------
(* One boot. *)

\* Format when the marker is not whole: erase, then write the marker last.
Format == /\ pc = "boot" /\ Unary /\ magic # AllBits
          /\ claim' = [i \in Slots |-> {}] /\ magic' = AllBits
          /\ pc' = "read"
          /\ UNCHANGED <<num, k, signed>>

Read == /\ pc = "boot"
        /\ IF Unary
             THEN /\ magic = AllBits
                  /\ IF Consistent /\ UsedCount < Leaves
                       THEN /\ pc' = (IF Design = "sign_first" THEN "sign" ELSE "claim")
                            /\ k' = UsedCount
                       ELSE pc' = "refused" /\ UNCHANGED k
             ELSE /\ IF num # Garbage /\ NumValue < Leaves
                       THEN pc' = "claim" /\ k' = NumValue
                       ELSE pc' = "refused" /\ UNCHANGED k
        /\ UNCHANGED <<magic, claim, num, signed>>

\* Claim leaf k, whole.
Claim == /\ pc = "claim"
         /\ IF Unary THEN claim' = [claim EXCEPT ![k] = AllBits] /\ UNCHANGED num
                     ELSE num' = k + 1 /\ UNCHANGED claim
         /\ pc' = (IF Design = "sign_first" THEN "halt" ELSE "sign")
         /\ UNCHANGED <<magic, k, signed>>

Sign == /\ pc = "sign"
        /\ signed' = [signed EXCEPT ![k] = @ + 1]
        /\ pc' = (IF Design = "sign_first" THEN "claim" ELSE "halt")
        /\ UNCHANGED <<magic, claim, num, k>>

Boot == Format \/ Read \/ Claim \/ Sign

----------------------------------------------------------------------------
(* The attacker. Every action ends this boot; the next one starts over. *)

Cut == /\ pc # "boot"
       /\ pc' = "boot"
       /\ UNCHANGED <<magic, claim, num, k, signed>>

\* The power goes in the middle of formatting: the erase got as far as it got
\* (some bits of each word back to 1), and the marker is partly written.
TornFormat == /\ pc = "boot" /\ Unary /\ magic # AllBits
              /\ \E m \in SUBSET AllBits, keep \in [Slots -> SUBSET AllBits] :
                    /\ m # AllBits
                    /\ magic' = m
                    /\ claim' = [i \in Slots |-> claim[i] \cap keep[i]]
              /\ UNCHANGED <<num, pc, k, signed>>

\* In the middle of the claim's program, or the number's erase or program.
TornClaim == /\ pc = "claim"
             /\ IF Unary
                  THEN \E s \in SUBSET AllBits :
                          s # AllBits /\ claim' = [claim EXCEPT ![k] = @ \cup s] /\ UNCHANGED num
                  ELSE \E v \in {Erased, Garbage} \cup (0..Leaves) :
                          num' = v /\ UNCHANGED claim
             /\ pc' = "boot"
             /\ UNCHANGED <<magic, k, signed>>

Reflash == /\ Attacker \in {"reflash", "eraser"}
           /\ pc' = "boot"
           /\ IF Design = "in_image"
                THEN magic' = {} /\ claim' = [i \in Slots |-> {}]
                ELSE UNCHANGED <<magic, claim>>
           /\ UNCHANGED <<num, k, signed>>

EraseAll == /\ Attacker = "eraser"
            /\ pc' = "boot"
            /\ magic' = {} /\ claim' = [i \in Slots |-> {}] /\ num' = Erased
            /\ UNCHANGED <<k, signed>>

Attack == Cut \/ TornFormat \/ TornClaim \/ Reflash \/ EraseAll

\* Keep the search finite: once a leaf has been signed twice the question is
\* answered, and nothing more is signed after that.
Next == (Boot /\ \A i \in Slots : signed[i] <= 1) \/ Attack
Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* An MSS leaf is a one-time key: signing two messages under it gives away
   enough of its chains to forge. So no leaf, ever, twice. *)
NoLeafTwice == \A i \in Slots : signed[i] <= 1
=============================================================================
