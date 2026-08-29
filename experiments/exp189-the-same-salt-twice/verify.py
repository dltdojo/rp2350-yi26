#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp189 verification — rules on a roundtrip.json recorded by roundtrip.sh.

Nothing in this file can check that thirty-two bytes are the *right* thirty-two
bytes, because nothing can: an hmac-secret output is not evidence, it is a key.
So every rule below is a comparison between two recorded runs rather than a
validation of one, and that is the whole reason this experiment is built out of
pairs.
"""

import base64
import json
import sys

# The PIN family. exp173 spent an entire experiment on one number meaning two
# things, and exp182 had to give a second refusal its own code for the same
# reason, so "nobody pressed" must not arrive wearing any of these.
PIN_CODES = {
    "FIDO_ERR_PIN_INVALID",
    "FIDO_ERR_PIN_AUTH_INVALID",
    "FIDO_ERR_PIN_BLOCKED",
    "FIDO_ERR_PIN_REQUIRED",
    "CTAP2_ERR_PIN_INVALID",
    "CTAP2_ERR_PIN_BLOCKED",
    "CTAP2_ERR_PIN_AUTH_INVALID",
    "CTAP2_ERR_PIN_AUTH_BLOCKED",
    "CTAP2_ERR_PIN_NOT_SET",
    "CTAP2_ERR_PIN_REQUIRED",
    "CTAP2_ERR_PIN_POLICY_VIOLATION",
}
# Both spellings: the board would say CTAP2_ERR_*, libfido2 says FIDO_ERR_*
# for the same byte, and roundtrip.sh records whichever source actually had it.
PRESENCE_CODES = {
    "CTAP2_ERR_USER_ACTION_TIMEOUT",
    "CTAP2_ERR_OPERATION_DENIED",
    "FIDO_ERR_USER_ACTION_TIMEOUT",
    "FIDO_ERR_OPERATION_DENIED",
}


def key(data, field):
    """A recorded hmac-secret output, or None if that case did not produce one."""
    raw = data.get(field) or ""
    if not raw:
        return None
    try:
        b = base64.b64decode(raw, validate=True)
    except Exception:
        return None
    return b if len(b) == 32 else None


def hamming(a, b):
    return sum(bin(x ^ y).count("1") for x, y in zip(a, b))


def verify(data):
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    src = data.get("key_source") or "unrecorded"
    print(f"      arm: {src}")
    rule(bool(data.get("key_source")),
         "the transcript says which arm produced it",
         "the transcript does not say which arm produced it — it is not evidence")

    rule(data.get("cred_a_made") and data.get("cred_b_made"),
         "two credentials made, self attestation verified, hmac-secret bit signed",
         f"a credential is missing: A={data.get('cred_a_made')} B={data.get('cred_b_made')}")

    k1 = key(data, "ga_salt1")
    k1b = key(data, "ga_salt1_again")
    k2 = key(data, "ga_salt2")
    kb = key(data, "ga_credB_salt1")

    rule(k1 is not None and k1b is not None,
         "salt one produced thirty-two bytes, twice",
         "salt one did not produce thirty-two bytes on both runs")

    # 1. The whole experiment. Reproducibility is the only observable form of
    #    correctness a symmetric key has.
    if k1 and k1b:
        rule(k1 == k1b,
             "the same salt twice gave the same thirty-two bytes, bit for bit",
             f"the same salt gave different bytes — {hamming(k1, k1b)} bits apart")

    # 2. A different salt is a different key. The distance is reported and not
    #    asserted to be 128: this is one sample of one HMAC, and a number that
    #    lands near half is what "unrelated" looks like, not a property being
    #    measured. What is asserted is that it is nowhere near zero, because a
    #    salt that barely moves the answer is a bug and not a coincidence.
    if k1 and k2:
        d = hamming(k1, k2)
        print(f"      salt one vs salt two: {d} of 256 bits differ")
        rule(k1 != k2, "a different salt gave a different key", "a different salt gave the same key")
        rule(d >= 64, "the two are unrelated, as far as one sample can say",
             f"only {d} of 256 bits moved — the salt is barely reaching the HMAC")

    # 3. The key is bound to the credential, which is what makes exp190's vault
    #    openable by one credential and not by any credential this board makes.
    if k1 and kb:
        d = hamming(k1, kb)
        print(f"      credential A vs credential B, same salt: {d} of 256 bits differ")
        rule(k1 != kb, "a different credential gave a different key",
             "two credentials produced the same key — CredRandom is not bound to the credential")
        rule(d >= 64, "the two credentials are unrelated, as far as one sample can say",
             f"only {d} of 256 bits moved between credentials")

    # 4. The extension must not have broken the road it was added to.
    rule(data.get("ga_plain_ok"),
         "an assertion with no extension still works, unchanged from exp173",
         "adding hmac-secret broke the ordinary assertion path")

    return ok


def verify_nopress(data):
    """The half that needs nobody, and that must never ask anybody for anything.

    It lives in its own file because it lives in its own script: the LED is the
    only channel reaching a person at the board, so a solid LED has to mean
    press, always. A case that lights it and must not be answered is a trap, and
    it caught two runs before it was moved out.
    """
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    n = data.get("attempts") or 0
    answered = data.get("answered")
    bootsel = (data.get("bootsel_line") or "").strip()

    rule(n >= 3, f"{n} attempts, which is enough to call a refusal a habit",
         f"{n} attempts is one anecdote — the failure this catches is intermittent")

    if answered == 0:
        rule(True, f"nobody pressed, {n} times, and no key came out", "")
    elif bootsel:
        rule(False, "",
             f"a key came out {answered}/{n} times, and the board says its pad read "
             f"low ({bootsel}). Something pressed the button. This is not a "
             "measurement of the firmware and the run must be repeated with the "
             "board left alone.")
    else:
        rule(False, "",
             f"a key came out {answered}/{n} times and the board never saw its pad "
             "go low — the presence bit was set without the button. This is the "
             "experiment failing, not a detail.")

    code = (data.get("refusal_code") or "").strip().upper()
    print(f"      the word for the refusal: {code or '(nothing recorded)'}")
    rule(code != "" and code not in PIN_CODES,
         "the refusal has a code of its own, and it is not one the PIN family uses",
         "the refusal is unrecorded or shares a number with a PIN failure — exp173's mistake")
    if code and code not in PIN_CODES:
        rule(code in PRESENCE_CODES,
             "and it is a code that means a person, rather than a generic denial",
             f"{code} is not one of {sorted(PRESENCE_CODES)} — say what it means in the README first")

    # 5. Nobody pressed, so nothing came out.
    return ok


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: verify.py roundtrip.json [nopress.json]", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        good = verify(json.load(f))
    if len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            good = verify_nopress(json.load(f)) and good
    sys.exit(0 if good else 1)
