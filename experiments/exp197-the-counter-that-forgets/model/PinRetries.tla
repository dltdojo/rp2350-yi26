---------------------------- MODULE PinRetries ----------------------------
(* SPDX-License-Identifier: Apache-2.0

   CTAP 2.1 clientPIN's retry counter, against somebody who wants the owner's
   PIN. Four switches select the design; the attacker and the properties are
   fixed.

     Storage     "ram"    the PIN and its counter vanish with the power
                          (every firmware here: `let mut pin_state = PinState::new()`)
                 "flash"  they survive it; the consecutive count does not
     Order       "compare_first"    exp186-exp189: compare, and only on a
                                    mismatch, decrement
                 "decrement_first"  CTAP 2.1, and crates/client-pin:
                                    begin() decrements (lib.rs:223) before
                                    judge() can compare (lib.rs:267)
     SetChecks   does setPIN refuse a device that has a PIN?     (lib.rs:194)
     Consecutive do three mismatches in a row stop everything?   (lib.rs:220)

   The attacker never knows the PIN, so every guess is wrong.

     Attacker    "malware"   software on the host: sends commands, no hands
                 "physical"  holds the board: can also cut the power at any
                             instant, including in the middle of an attempt

   One assumption, stated because the result turns on it: under compare_first
   the attacker learns a guess was wrong at the moment of the compare — from
   timing, or from the device starting to write its counter — and not only
   from the reply. Power analysis of exactly this is the classic attack on
   retry counters, and it is why the specification puts the decrement first. *)
EXTENDS Naturals

CONSTANTS Storage, Order, SetChecks, Consecutive, Attacker, Max, MaxInARow

VARIABLES pinSet,       \* is there a PIN
          owner,        \* whose PIN it is: "user", "attacker", or "none"
          retries,      \* pinRetries
          inARow,       \* consecutive mismatches (RAM, always)
          phase,        \* inside an attempt: "idle", "paid", "compared"
          learned       \* wrong guesses at the OWNER's PIN the attacker has learned

vars == <<pinSet, owner, retries, inARow, phase, learned>>

Init == /\ pinSet = TRUE /\ owner = "user" /\ retries = Max
        /\ inARow = 0 /\ phase = "idle" /\ learned = 0

AgainstOwner == owner = "user"
Stopped == retries = 0 \/ (Consecutive /\ inARow >= MaxInARow)

(* setPIN. With SetChecks a set PIN refuses it: PIN_AUTH_INVALID. *)
SetPin == /\ phase = "idle"
          /\ (~pinSet \/ ~SetChecks)
          /\ pinSet' = TRUE /\ owner' = "attacker" /\ retries' = Max /\ inARow' = 0
          /\ UNCHANGED <<phase, learned>>

(* getPinToken with a wrong guess, in two halves so the power can go between. *)
Begin == /\ phase = "idle" /\ pinSet /\ ~Stopped
         /\ learned <= Max                              \* keep the search finite
         /\ IF Order = "decrement_first"
              THEN /\ retries' = retries - 1 /\ phase' = "paid"
                   /\ UNCHANGED <<inARow, learned>>
              ELSE /\ phase' = "compared" /\ inARow' = inARow + 1
                   /\ learned' = IF AgainstOwner THEN learned + 1 ELSE learned
                   /\ UNCHANGED retries
         /\ UNCHANGED <<pinSet, owner>>

Finish == /\ \/ /\ phase = "paid"                        \* decrement_first: now compare
                /\ inARow' = inARow + 1
                /\ learned' = IF AgainstOwner THEN learned + 1 ELSE learned
                /\ UNCHANGED retries
             \/ /\ phase = "compared"                    \* compare_first: now decrement
                /\ retries' = retries - 1
                /\ UNCHANGED <<inARow, learned>>
          /\ phase' = "idle"
          /\ UNCHANGED <<pinSet, owner>>

(* The power goes — between any two steps — and comes back. *)
PowerCycle == /\ Attacker = "physical"
              /\ phase' = "idle" /\ inARow' = 0 /\ UNCHANGED learned
              /\ IF Storage = "ram"
                   THEN pinSet' = FALSE /\ owner' = "none" /\ retries' = Max
                   ELSE UNCHANGED <<pinSet, owner, retries>>

Next == SetPin \/ Begin \/ Finish \/ PowerCycle
Spec == Init /\ [][Next]_vars

(* "If a PIN has already been set, authenticator returns
   CTAP2_ERR_PIN_AUTH_INVALID error." — the owner's PIN is not replaced by
   someone who does not know it. *)
ThePinCannotBeReplaced == owner # "attacker"

(* "Once the pinRetries counter reaches 0 … can only be enabled if
   authenticator is reset." — nobody learns the answer to more than Max
   guesses at the owner's PIN. *)
GuessesAreBounded == learned <= Max

(* "This is done so that malware running on the platform should not be able
   to block the device without user interaction." *)
MalwareCannotBlock == ~(AgainstOwner /\ retries = 0)
=============================================================================
