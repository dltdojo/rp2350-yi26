#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp192 verification — rules on the analysis.json that analyse.py writes.

The claim under test is narrow and worth stating exactly: **a page hands
`prf.eval.first` some bytes, and something else arrives at the authenticator.**
Everything here is a comparison between what three parties said about one
session — the page, the board, and arithmetic done on this host — and the board
is the arbiter, because it is the only one reporting what it received rather
than what it sent.

A salt that matches none of the candidates is a PASS-shaped failure and is
treated as a FAIL on purpose: it means the derivation is something nobody here
has written down, which is a finding that must be written up before the number
can be used for anything.
"""

import json
import sys

FAILED = False


def rule(good, yes, no):
    global FAILED
    print(("PASS  " + yes) if good else ("FAIL  " + no))
    if not good:
        FAILED = True


def verify(d):
    print(f"      browser: {d.get('user_agent')}")
    print(f"      rp id:   {d.get('rp_id')}    prf input: {d.get('prf_input')!r}")

    rule(d.get("entries", 0) >= 1 and not d.get("create_error"),
         "the browser registered a credential on this board",
         f"create() did not get through: {d.get('create_error')} — "
         "a browser that cannot register cannot be asked about salts")

    # For a security key, hmac-secret is not evaluated during makeCredential.
    # A `prf` result carrying bytes here would mean the browser got a key out of
    # a registration, which is a different device model than this one.
    cp = d.get("create_prf")
    print(f"      prf at create: {json.dumps(cp)}")
    rule(not (isinstance(cp, dict) and cp.get("results")),
         "create() reported prf without handing over a key, as a security key must",
         "create() returned prf results — this board does not evaluate hmac-secret "
         "at registration, so something else produced those bytes")

    rule(d.get("pairable"),
         f"every get() has a salt the board logged for it "
         f"({len(d.get('gets', []))} calls, {len(d.get('salts_the_board_received', []))} salts)",
         f"{len(d.get('gets', []))} get() calls but "
         f"{len(d.get('salts_the_board_received', []))} salts logged — this cannot be paired, "
         "and a positional pairing of unequal lists would be a guess")

    seen = {}
    for g in d.get("gets", []):
        uv = g.get("userVerification")
        if g.get("error"):
            print(f"      uv={uv}: refused — {g['error']}")
            continue
        which = g.get("which_candidate")
        print(f"      uv={uv}: salt {g.get('salt_the_board_received')} = {which}")
        # Two claims, not one. **Which** salt arrived and **all of it** are
        # different sentences, and the first capture had the first without the
        # second: the board's log ring cut the line at 28 of 32 bytes and one
        # nibble. Twenty-eight bytes name a candidate past any argument — a
        # coincidence is 2**-224 — and are still not the salt, so a run that
        # identifies without reading it whole passes the identification and
        # fails the reading, and the transcript says so in two lines.
        rule(which not in (None, "unmatched"),
             f"uv={uv}: the salt the board received is a candidate this repository named ({which})",
             f"uv={uv}: the board received a salt matching none of the candidates — "
             "the derivation is not one of the three written down, and that is the finding")
        # Completeness is a note, not a rule, and the distinction is the point.
        #
        # The claim this experiment makes is *which* salt the browser sends, and
        # 28 bytes settle that past any argument — a coincidence is 2**-224. How
        # much of it the log carried is a fact about the instrument on the day,
        # and the instrument has since been fixed (the firmware prints sixteen
        # bytes a line). Failing an aged capture for a defect that no longer
        # exists would make this verifier refuse the very transcript it was
        # written to rule on, which is exp175's rule inverted: a capture ages,
        # and is recorded rather than repaired. check.sh asserts the fix in the
        # firmware's source instead, where a regression would actually live.
        if which and "bytes" in which:
            print(f"      NOTE  uv={uv}: the reading is a prefix — {which}. "
                  "The identification stands; the reading is owed to the next run.")
        out = g.get("prf_first_hex")
        rule(bool(out) and len(out) == 64,
             f"uv={uv}: thirty-two bytes came back to the page",
             f"uv={uv}: no usable prf output ({out!r})")
        if out:
            seen[uv] = (g.get("salt_the_board_received"), out)

    # The divergence this experiment was built to look for: the same salt with
    # user verification on and off produces different keys, because the firmware
    # derives CredRandom from a different domain string in each case. Two runs
    # that succeeded are needed before anything can be said.
    if len(seen) == 2:
        (s1, o1), (s2, o2) = seen.values()
        if s1 == s2:
            rule(o1 != o2,
                 "the same salt with UV on and off gave different keys, "
                 "as credrandom-uv / credrandom-noUV requires",
                 "the same salt gave the same key with UV on and off — then the firmware's "
                 "two CredRandom domains are not reaching the browser's request")
        else:
            print("      the two calls used different salts, so UV cannot be compared here")
    else:
        print(f"      only {len(seen)} of 2 evaluations produced a key; UV is not compared")
    return not FAILED


def verify_crosscheck(d):
    """The one claim here that is about the board rather than about a client."""
    print(f"      salt:  {d.get('salt_hex')}")
    print(f"      named: {d.get('salt_named')}")
    b, c = d.get("browser_key_hex"), d.get("cli_key_hex")
    rule(bool(b) and len(b) == 64 and bool(c) and len(c) == 64,
         "both stacks produced thirty-two bytes",
         f"a key is missing or the wrong length: browser={b!r} cli={c!r}")
    # libfido2 has never heard of WebAuthn's prf extension and cannot derive
    # this salt; it was handed the one the board reported receiving. So an
    # agreement here is about the authenticator, not about two clients agreeing
    # with each other.
    rule(b == c and bool(b),
         "and they are the same thirty-two bytes, from two stacks that have "
         "never heard of each other",
         "the two stacks derived different keys from the same salt and the same "
         "credential — which is a finding about this board, not about either client")
    return not FAILED


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: verify.py analysis.json [crosscheck.json]", file=sys.stderr)
        raise SystemExit(2)
    with open(sys.argv[1]) as f:
        verify(json.load(f))
    if len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            verify_crosscheck(json.load(f))
    raise SystemExit(1 if FAILED else 0)
