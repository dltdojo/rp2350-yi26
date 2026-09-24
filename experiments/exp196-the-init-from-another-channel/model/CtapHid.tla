------------------------------ MODULE CtapHid ------------------------------
(* SPDX-License-Identifier: Apache-2.0

   crates/ctap-hid's Transaction::feed and expire, and the board loop that
   drives them, with two clients on one device. Line numbers are to the code
   after exp196's fix; model/cited.txt holds them and check.sh re-reads them.

     lib.rs:269   feed: "Time first" — expire() before judging the packet
     lib.rs:275   ... and remember a stale channel that is not this packet's
     lib.rs:307   an INIT is answered (Action::Init) ...
     lib.rs:312   ... aborting only a transaction on its own channel
     lib.rs:320   any other command on another channel: ERR_CHANNEL_BUSY
     lib.rs:339   a continuation with no transaction: ignored in silence
     lib.rs:342   a continuation from another channel: ignored in silence
     lib.rs:357   the last packet: Complete, and the channel is free
     board.rs:111 the timer arm of the select, which calls expire()
     board.rs:124 after every feed: take_expired(), and ERR_MSG_TIMEOUT

   Two constants select the code. The property is fixed.

     InitPolicy "clears"   before exp196: an INIT from anyone clears the buffer
                "answers"  exp196: answered, only its own channel reset
                "busy"     §11.2.5.1 read literally: refused while busy
     FixH1      FALSE      before exp196: a stale channel tripped by another
                           channel's packet is dropped
                TRUE       exp196: take_expired() hands it to the caller     *)
EXTENDS Naturals

CONSTANTS InitPolicy, FixH1,
          T,       \* TRANSACTION_TIMEOUT, in ticks
          MaxT     \* how far time runs

A == 1   B == 2   BCAST == 255
Owner(cid) == IF cid = A THEN "A" ELSE "B"   \* B also owns the broadcast channel
INIT == "INIT"  CBOR == "CBOR"  PING == "PING"

VARIABLES active, cur, want, have, started,   \* the Transaction struct
          now,                                 \* the clock
          st,                                  \* each client: idle | midway | sent
          told,                                \* what each client was answered
          bKind                                \* ghost: what B sent

vars == <<active, cur, want, have, started, now, st, told, bKind>>

Init == /\ active = FALSE /\ cur = 0 /\ want = 0 /\ have = 0 /\ started = 0
        /\ now = 0
        /\ st = [c \in {"A", "B"} |-> "idle"]
        /\ told = [c \in {"A", "B"} |-> "none"]
        /\ bKind = "none"

Stale == active /\ now - started >= T

(* The judging half of feed(), after expiry. (a, c): the device as it stands
   after expiry — a transaction active on channel c, or not. t0: what the
   clients have been told so far. *)
Judge(a, c, pcid, isInit, cmd, w, t0) ==
  IF isInit THEN
    IF cmd = INIT THEN
      CASE InitPolicy = "clears" ->                          \* clear(), then a 1-packet message
             /\ told' = [t0 EXCEPT ![Owner(pcid)] = "complete"]
             /\ active' = FALSE /\ cur' = pcid /\ want' = 1 /\ have' = 1 /\ started' = now
        [] InitPolicy = "busy" /\ a /\ c # pcid ->           \* refused like any other command
             /\ told' = [t0 EXCEPT ![Owner(pcid)] = "error"]
             /\ active' = a /\ cur' = c /\ UNCHANGED <<want, have, started>>
        [] OTHER ->                                          \* answered; own channel reset
             /\ told' = [t0 EXCEPT ![Owner(pcid)] = "complete"]
             /\ active' = (a /\ c # pcid) /\ cur' = c /\ UNCHANGED <<want, have, started>>
    ELSE IF a /\ c # pcid THEN                               \* ERR_CHANNEL_BUSY
      /\ told' = [t0 EXCEPT ![Owner(pcid)] = "error"]
      /\ active' = a /\ cur' = c /\ UNCHANGED <<want, have, started>>
    ELSE IF 1 >= w THEN                                      \* whole in one packet
      /\ told' = [t0 EXCEPT ![Owner(pcid)] = "complete"]
      /\ active' = FALSE /\ cur' = pcid /\ want' = w /\ have' = 1 /\ started' = now
    ELSE
      /\ told' = t0
      /\ active' = TRUE /\ cur' = pcid /\ want' = w /\ have' = 1 /\ started' = now
  ELSE  \* a continuation packet
    IF ~a \/ pcid # c THEN                                   \* ignored in silence
      /\ told' = t0 /\ active' = a /\ cur' = c /\ UNCHANGED <<want, have, started>>
    ELSE IF have + 1 >= want THEN
      /\ told' = [t0 EXCEPT ![Owner(pcid)] = "complete"]
      /\ active' = FALSE /\ cur' = c /\ have' = have + 1 /\ UNCHANGED <<want, started>>
    ELSE
      /\ told' = t0 /\ active' = a /\ cur' = c /\ have' = have + 1 /\ UNCHANGED <<want, started>>

(* feed(), and the board telling take_expired()'s channel straight after. *)
Feed(pcid, isInit, cmd, w) ==
  IF Stale /\ pcid = cur THEN
      /\ told' = [told EXCEPT ![Owner(cur)] = "error"]        \* ERR_MSG_TIMEOUT
      /\ active' = FALSE /\ UNCHANGED <<cur, want, have, started>>
  ELSE IF Stale THEN
      LET t0 == IF FixH1 THEN [told EXCEPT ![Owner(cur)] = "error"] ELSE told
      IN Judge(FALSE, cur, pcid, isInit, cmd, w, t0)
  ELSE Judge(active, cur, pcid, isInit, cmd, w, told)

\* Client A sends a CBOR request that needs two packets.
ASendInit == /\ st["A"] = "idle" /\ st' = [st EXCEPT !["A"] = "midway"]
             /\ Feed(A, TRUE, CBOR, 2) /\ UNCHANGED <<now, bKind>>
ASendCont == /\ st["A"] = "midway" /\ st' = [st EXCEPT !["A"] = "sent"]
             /\ Feed(A, FALSE, CBOR, 2) /\ UNCHANGED <<now, bKind>>
\* Client B is another program: it enumerates, or it pings its own channel.
BBcastInit == /\ st["B"] = "idle" /\ st' = [st EXCEPT !["B"] = "sent"] /\ bKind' = "init"
              /\ Feed(BCAST, TRUE, INIT, 1) /\ UNCHANGED now
BPing      == /\ st["B"] = "idle" /\ st' = [st EXCEPT !["B"] = "sent"] /\ bKind' = "ping"
              /\ Feed(B, TRUE, PING, 1) /\ UNCHANGED now

\* board.rs:111 — the timer arm.
TimerFires == /\ Stale
              /\ told' = [told EXCEPT ![Owner(cur)] = "error"]
              /\ active' = FALSE
              /\ UNCHANGED <<cur, want, have, started, now, st, bKind>>

Tick == /\ now < MaxT /\ now' = now + 1
        /\ UNCHANGED <<active, cur, want, have, started, st, told, bKind>>

Next == ASendInit \/ ASendCont \/ BBcastInit \/ BPing \/ TimerFires \/ Tick
Spec == Init /\ [][Next]_vars

(* From the crate's own contract — an Action is More, Complete, or an Error
   sent on a channel, and expire() "returns the channel to send
   ERR_MSG_TIMEOUT on" — and from §11.2.5.3, which aborts only a transaction
   with the same channel id. Nothing in either lets a message vanish: a client
   with a message outstanding is still being assembled, or has been answered. *)
NoSilentLoss ==
  \A c \in {"A", "B"} :
    (st[c] \in {"midway", "sent"} /\ told[c] = "none")
      => (active /\ Owner(cur) = c /\ cur # BCAST)

(* exp194's busy-recovers, which this repository chose over §11.2.5.1's
   literal reading: a broadcast INIT is answered whatever else is going on. *)
AnInitIsAnswered ==
  (bKind = "init" /\ st["B"] = "sent") => told["B"] = "complete"
=============================================================================
