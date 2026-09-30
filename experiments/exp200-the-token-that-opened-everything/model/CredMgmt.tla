---------------------------- MODULE CredMgmt ----------------------------
(* SPDX-License-Identifier: Apache-2.0

   CTAP 2.1 authenticatorCredentialManagement (0x0A): who may delete a
   discoverable credential. Three switches select the design; the attacker is
   a fourth. The property is fixed.

     RejectsBadParam    does a pinUvAuthParam that fails to verify stop the
                        request?  exp188/exp189: no, once any token exists
                        ("For testing flexibility in credMgmt")
     BindsParams        does the MAC cover subCommand || subCommandParams, or
                        only the subCommand byte?  exp188/exp189: only the byte
     ChecksPermissions  must the token carry the cm permission?  exp188/exp189:
                        no, and getPinToken's token has only mc and ga

     Attacker  "malware"   software on the host with no token and no PIN
               "observer"  sees the requests on the wire but holds no token —
                           a USB relay, or a process between the platform and
                           the device. It can resend a pinUvAuthParam it saw.
               "browser"   holds a token of its own, from getPinToken: the
                           default mc and ga permissions a login needs

   One token exists at a time: issuing a new one invalidates the last
   (CTAP 2.1: "all existing pinUvAuthTokens are invalidated"). The owner knows
   the PIN and deletes on purpose; nobody else should delete anything. *)
EXTENDS Naturals, FiniteSets

CONSTANTS RejectsBadParam, BindsParams, ChecksPermissions, Attacker, Creds, MaxTokens

VARIABLES holder,   \* whose token is current: "none", "owner", "browser"
          perms,    \* its permissions: "mcga" or "cm"
          epoch,    \* how many tokens have been issued; a MAC is for one token
          seen,     \* <<credential, epoch>>: deleteCredential params on the wire
          deletedBy \* credential -> who deleted it, or "nobody"

vars == <<holder, perms, epoch, seen, deletedBy>>

Init == /\ holder = "none" /\ perms = "mcga" /\ epoch = 0 /\ seen = {}
        /\ deletedBy = [c \in Creds |-> "nobody"]

Present(c) == deletedBy[c] = "nobody"

(* The device's decision, for a request whose MAC does or does not verify
   against the current token. *)
Accepts(macOk) ==
    /\ IF RejectsBadParam THEN macOk ELSE (macOk \/ holder # "none")
    /\ (ChecksPermissions => perms = "cm")

Delete(c, who) == /\ deletedBy' = [deletedBy EXCEPT ![c] = who]

(* The owner asks for a token to manage credentials with. Without the
   permission system the only way is getPinToken, whose token is mc|ga. *)
OwnerGetsToken == /\ epoch < MaxTokens
                  /\ holder' = "owner"
                  /\ perms' = IF ChecksPermissions THEN "cm" ELSE "mcga"
                  /\ epoch' = epoch + 1
                  /\ UNCHANGED <<seen, deletedBy>>

(* A site logs in through the browser: getPinToken, mc|ga. *)
BrowserGetsToken == /\ Attacker = "browser" /\ epoch < MaxTokens
                    /\ holder' = "browser" /\ perms' = "mcga" /\ epoch' = epoch + 1
                    /\ UNCHANGED <<seen, deletedBy>>

OwnerDeletes(c) == /\ holder = "owner" /\ Present(c) /\ Accepts(TRUE)
                   /\ Delete(c, "owner")
                   /\ seen' = seen \cup {<<c, epoch>>}
                   /\ UNCHANGED <<holder, perms, epoch>>

(* No token: whatever it sends does not verify. *)
MalwareDeletes(c) == /\ Attacker = "malware" /\ Present(c) /\ Accepts(FALSE)
                     /\ Delete(c, "malware")
                     /\ UNCHANGED <<holder, perms, epoch, seen>>

(* Resends a parameter it saw for the current token, naming any credential.
   It verifies if the MAC never covered which credential it was for. *)
ObserverDeletes(c) == /\ Attacker = "observer" /\ Present(c)
                      /\ \E s \in seen : /\ s[2] = epoch
                                         /\ Accepts(IF BindsParams THEN s[1] = c ELSE TRUE)
                      /\ Delete(c, "observer")
                      /\ UNCHANGED <<holder, perms, epoch, seen>>

(* Uses its own token, which verifies, for something it was not issued for. *)
BrowserDeletes(c) == /\ holder = "browser" /\ Present(c) /\ Accepts(TRUE)
                     /\ Delete(c, "browser")
                     /\ UNCHANGED <<holder, perms, epoch, seen>>

Next == \/ OwnerGetsToken \/ BrowserGetsToken
        \/ \E c \in Creds : OwnerDeletes(c) \/ MalwareDeletes(c)
                            \/ ObserverDeletes(c) \/ BrowserDeletes(c)
Spec == Init /\ [][Next]_vars

(* "The authenticator verifies that the pinUvAuthToken has the cm permission"
   and "calls verify(pinUvAuthToken, deleteCredential (0x06) ||
   subCommandParams, pinUvAuthParam)": a credential is deleted by the owner
   who asked for a cm token, or by nobody. *)
OnlyTheOwnerDeletes == \A c \in Creds : deletedBy[c] \in {"nobody", "owner"}
=============================================================================
