----------------------------- MODULE Breadcrumb -----------------------------
(* SPDX-License-Identifier: Apache-2.0

   WATCHDOG.SCRATCH0 across boots, deaths and reflashes, as four crates use it
   together. No one of them is modelled alone, because no one of them is wrong
   alone: the bug this model finds is in their composition.

   Facts, each measured or read, none assumed:
   - SCRATCH0-3 survive the 1200-baud reflash                (ecf659e, measured)
   - a power cycle (BOOTSEL held while plugging in) clears them
                                                             (the datasheet; not measured here)
   - lifeline::begin reads the note, then arms               (lifeline/src/board.rs:44, :71)
     and alive() only feeds, so a running lifeline firmware
     holds its own token for as long as it runs              (lifeline/src/board.rs:82-86)
   - read() believes a note only if SCRATCH0 is the token    (breadcrumb/src/lib.rs:335 interpret,
     — before ecf659e `before.s0 != MAGIC`, after is_ours     :141 is_ours)
   - a firmware without the crate never touches SCRATCH0
   - every firmware here reflashes through crates/usb-reboot (Cargo.toml of each)
     whose 1200-baud path now clears SCRATCH0 first          (usb-reboot/src/lib.rs:169)
*)
EXTENDS Naturals

CONSTANTS Tagged,   \* FALSE: breadcrumb before ecf659e, one MAGIC word for everyone
          FixFlash  \* TRUE: usb-reboot withdraws the token before entering the bootrom

\* exp190a and exp190b are two builds of one experiment: same tag, different code.
Firmware == {"exp190a", "exp190b", "exp174", "exp157"}
UsesCrate(f)    == f \in {"exp190a", "exp190b", "exp157"}
HoldsWhileUp(f) == f \in {"exp190a", "exp190b"}           \* the lifeline users
Tag(f)          == IF f \in {"exp190a", "exp190b"} THEN 190 ELSE 157
\* SCRATCH0: "none" when clear, otherwise the token that was written
Token(f)        == IF ~Tagged THEN "MAGIC"
                   ELSE IF Tag(f) = 190 THEN "MAGIC|190" ELSE "MAGIC|157"
IsOurs(s, f)    == s = Token(f)

VARIABLES fw,        \* what is running; "blank" before the first flash
          s0,        \* SCRATCH0
          writer,    \* ghost: which firmware wrote what SCRATCH0 holds
          flashed,   \* ghost: this boot is the first since a flash
          died,      \* ghost: this boot follows a death of the same firmware
          believed   \* ghost: whose note this boot believed, or "none"

vars == <<fw, s0, writer, flashed, died, believed>>

Init == /\ fw = "blank" /\ s0 = "none" /\ writer = "none"
        /\ flashed = FALSE /\ died = FALSE /\ believed = "none"

(* A boot of `f`, finding SCRATCH0 = `found`, written by `by`. *)
Boot(f, found, by) ==
  /\ fw' = f
  /\ IF UsesCrate(f)
       THEN /\ believed' = IF IsOurs(found, f) THEN by ELSE "none"   \* read()
            /\ IF HoldsWhileUp(f)
                 THEN s0' = Token(f) /\ writer' = f                   \* arm(), and kept
                 ELSE s0' = "none"   /\ writer' = "none"              \* read() zeroes it
       ELSE /\ believed' = "none"                                     \* never touches it
            /\ s0' = found /\ writer' = by

(* `yi26 flash`: the running firmware hears 1200 baud (usb-reboot) and enters
   the bootrom; the new image boots from there. *)
Reflash1200(f) ==
  /\ fw # "blank"
  /\ flashed' = TRUE /\ died' = FALSE
  /\ IF FixFlash THEN Boot(f, "none", "none") ELSE Boot(f, s0, writer)

(* BOOTSEL held while plugging in: power goes, and SCRATCH0 with it. *)
BootselFlash(f) ==
  /\ flashed' = TRUE /\ died' = FALSE
  /\ Boot(f, "none", "none")

(* A lifeline firmware hangs or faults; the watchdog brings the same image back. *)
Die ==
  /\ HoldsWhileUp(fw)
  /\ flashed' = FALSE /\ died' = TRUE
  /\ Boot(fw, s0, writer)

Next == \/ \E f \in Firmware : Reflash1200(f) \/ BootselFlash(f)
        \/ Die

Spec == Init /\ [][Next]_vars

(* What ecf659e set out to guarantee: "A note from another build now reads as
   Cause::Fresh, which is what it always should have been." Stated as it was
   meant — another experiment's note. *)
NeverAnotherExperimentsNote ==
  believed # "none" => Tag(believed) = Tag(fw)

(* What interpret()'s own doc comment promises: "a fresh flash must find
   nothing to believe". *)
AFreshFlashBelievesNothing ==
  flashed => believed = "none"

(* And the reason the crate exists at all, which a fix must not break: after a
   death, the next boot believes the note the dead boot left. *)
ADeathIsStillReported ==
  died => believed = fw
=============================================================================
