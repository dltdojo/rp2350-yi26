------------------------------- MODULE UsbLog -------------------------------
(* SPDX-License-Identifier: Apache-2.0

   The blind half of exp195: written, and committed with its predictions,
   BEFORE TLC was ever run on it. See ../PREDICTIONS.md.

   What is modelled is `line()` in crates/usb-log/src/board.rs under the
   default policy (DropNewest), with two producers and the writer task:

     board.rs:115  admit(POLICY, QUEUE.is_full(), ..)   -> Drop | Enqueue
     board.rs:124  Admission::Drop => DROPPED += 1; return
     board.rs:161  let lost = claim(POLICY, &DROPPED)     (swap to 0)
     board.rs:222  if QUEUE.try_send(line).is_err()
     board.rs:223      refund(POLICY, &DROPPED, lost)     (+= lost + 1)

   The one thing that is a choice rather than a translation is the
   scheduler. `Preemptive = FALSE` is embassy's executor: `line()` never
   awaits, so no other task runs inside it. `Preemptive = TRUE` is what the
   crate's own documentation invites: senders "on a different core or
   inside an interrupt". *)
EXTENDS Naturals, Sequences

CONSTANTS Preemptive,  \* see above
          Depth,       \* QUEUE_DEPTH, scaled down
          Lines        \* how many lines each producer logs

Producers == {"p1", "p2"}

VARIABLES queue,      \* the queued lines, each as the loss count it carries
          dropped,    \* DROPPED
          pc,         \* where each producer is inside line()
          held,       \* a count a producer has claimed and not yet placed
          left,       \* lines each producer has still to log
          lostTotal,  \* ghost: lines that really were lost
          reported,   \* ghost: the sum of every marker that reached the queue
          gap,        \* ghost: a line was lost, and none has entered the queue since
          misplaced   \* ghost: a line entered the queue after a gap, unmarked

vars == <<queue, dropped, pc, held, left, lostTotal, reported, gap, misplaced>>

Init == /\ queue = << >> /\ dropped = 0
        /\ pc = [p \in Producers |-> "idle"]
        /\ held = [p \in Producers |-> 0]
        /\ left = [p \in Producers |-> Lines]
        /\ lostTotal = 0 /\ reported = 0 /\ gap = FALSE /\ misplaced = FALSE

Full == Len(queue) >= Depth

(* board.rs:124 — refused, counted, nothing formatted. *)
Refuse(p) == /\ dropped' = dropped + 1
             /\ lostTotal' = lostTotal + 1
             /\ gap' = TRUE
             /\ left' = [left EXCEPT ![p] = @ - 1]
             /\ UNCHANGED <<queue, pc, held, reported, misplaced>>

(* board.rs:222-223 — try_send with the line carrying `lost`. `d` is DROPPED
   as it stands at this moment. *)
Send(p, lost, d) ==
  IF Full
  THEN /\ dropped' = d + lost + 1                 \* refund: the count and the line
       /\ lostTotal' = lostTotal + 1
       /\ gap' = TRUE
       /\ UNCHANGED <<queue, reported, misplaced>>
  ELSE /\ queue' = Append(queue, lost)
       /\ dropped' = d
       /\ reported' = reported + lost
       /\ misplaced' = (misplaced \/ (gap /\ lost = 0))
       /\ gap' = FALSE
       /\ UNCHANGED lostTotal

\* --- cooperative: the whole of line() is one step ----------------------------
Log(p) == /\ left[p] > 0
          /\ IF Full
               THEN Refuse(p)
               ELSE /\ Send(p, dropped, 0)          \* claim swaps DROPPED to 0
                    /\ left' = [left EXCEPT ![p] = @ - 1]
                    /\ UNCHANGED <<pc, held>>

\* --- preemptive: line() as its three atomic steps -----------------------------
Admit(p) == /\ pc[p] = "idle" /\ left[p] > 0
            /\ IF Full
                 THEN Refuse(p)
                 ELSE /\ pc' = [pc EXCEPT ![p] = "admitted"]
                      /\ UNCHANGED <<queue, dropped, held, left, lostTotal, reported, gap, misplaced>>

Claim(p) == /\ pc[p] = "admitted"
            /\ held' = [held EXCEPT ![p] = dropped]
            /\ dropped' = 0
            /\ pc' = [pc EXCEPT ![p] = "claimed"]
            /\ UNCHANGED <<queue, left, lostTotal, reported, gap, misplaced>>

TrySend(p) == /\ pc[p] = "claimed"
              /\ Send(p, held[p], dropped)
              /\ held' = [held EXCEPT ![p] = 0]
              /\ pc' = [pc EXCEPT ![p] = "idle"]
              /\ left' = [left EXCEPT ![p] = @ - 1]

\* --- the writer task: board.rs `run`, QUEUE.receive() -------------------------
Receive == /\ Len(queue) > 0
           /\ queue' = Tail(queue)
           /\ UNCHANGED <<dropped, pc, held, left, lostTotal, reported, gap, misplaced>>

Next == \/ Receive
        \/ \E p \in Producers :
             IF Preemptive THEN Admit(p) \/ Claim(p) \/ TrySend(p) ELSE Log(p)

Spec == Init /\ [][Next]_vars

(* "Losing data is survivable; not knowing you lost it is not."
   Every lost line is either reported by a marker that reached the queue,
   still counted in DROPPED, or held by a producer about to place it. *)
EveryLossIsCounted ==
  reported + dropped + held["p1"] + held["p2"] = lostTotal

(* "The count is attached to the first line that survives after the gap, so
   the loss is marked exactly where it happened." *)
TheMarkIsWhereTheGapIs == ~misplaced
=============================================================================
