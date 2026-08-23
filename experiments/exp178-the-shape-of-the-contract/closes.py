#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Checks OpenSK's own answers against exp176's list of what the board lacked.

exp176 asked one question of two devices — this board and a commercial FIDO2
key — and sorted the fourteen differences by kind: **ten were code the board
could write**, three were policy numbers, and one was certification the chip
cannot anchor. That categorisation is a claim, and exp176 wrote it out field by
field so it could be argued with.

This is the argument. OpenSK is that code, written by somebody else, and the
list it has to close is not one written for the occasion: it is read straight
out of `../exp176-the-same-question-of-two-devices/comparison.json`. If exp176's
categorisation changes, this experiment's result changes with it, and check.sh
fails rather than quietly disagreeing with the file it cites.

The CBOR is read with `../cbor.py`, which is exp169's canonical-only reader with
the two rules it did not need: **text map keys, and their ordering**. exp169's
refuses them outright — the device it was written against never emitted one —
and OpenSK's getInfo is full of them, because CTAP 2.1 defines `options` and
`algorithms` with string keys. That reader started life inside this file and was
promoted to a shared one when exp177 needed it the same day; the strictness is
unchanged, and a response that gets the ordering wrong is refused rather than
normalised.
"""

import importlib.util
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "yi26_cbor", os.path.join(_HERE, "..", "cbor.py"))
cbor = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cbor)
decode, NotCanonical = cbor.decode, cbor.NotCanonical


# getInfo's numbered fields, from CTAP 2.1.
VERSIONS, EXTENSIONS, AAGUID, OPTIONS = 1, 2, 3, 4
MAX_MSG_SIZE, PIN_PROTOCOLS, MAX_CREDS_IN_LIST = 5, 6, 7
MAX_CRED_ID_LEN, ALGORITHMS = 8, 10


def closes(capability, info, run):
    """Does OpenSK close this one, and on what evidence?

    Every rule is written out rather than inferred, for the same reason exp176
    wrote its categorisation by hand: a tick nobody can argue with is a tick
    nobody checked. `None` means the rule does not apply to this capability.
    """
    versions = info.get(VERSIONS, [])
    extensions = info.get(EXTENSIONS, [])
    options = info.get(OPTIONS, {})
    algorithms = info.get(ALGORITHMS, [])
    algs = [a.get("alg") for a in algorithms if isinstance(a, dict)]

    rules = {
        "U2F_V2":
            ("U2F_V2" in versions,
             "the CTAP1/U2F path, behind upstream's `ctap1` feature"),
        "FIDO_2_1_PRE":
            (any(v.startswith("FIDO_2_1") for v in versions),
             "and not the preview string: this engine claims %s"
             % ", ".join(v for v in versions if v.startswith("FIDO_2_1"))),
        "credProtect":
            ("credProtect" in extensions, "announced as an extension"),
        "hmac-secret":
            ("hmac-secret" in extensions, "announced as an extension"),
        "rk":
            (options.get("rk") is True and run["rk_status"] == 0,
             "announced, and a resident credential was actually made — "
             "%d bytes of attestation object, status 0"
             % run["rk_response_bytes"]),
        "clientPin":
            ("clientPin" in options,
             "announced; note this is the exact surface the road cut on "
             "purpose, and the one that trips Android's strict parser"),
        "credentialMgmtPreview":
            ("credMgmt" in options or "credentialMgmtPreview" in options,
             "announced as `credMgmt`, the full command rather than the preview"),
        "(no algorithms advertised)":
            (len(algorithms) > 0,
             "field %d is present with %d entry/entries" % (ALGORITHMS, len(algorithms))),
        "eddsa":
            (-8 in algs and run["eddsa_status"] == 0,
             "announced, and an Ed25519 credential was actually made — "
             "%d bytes, status 0" % run["eddsa_response_bytes"]),
        "pin_protocols=1":
            (1 in info.get(PIN_PROTOCOLS, []),
             "field %d offers %s, in that order"
             % (PIN_PROTOCOLS,
                ", ".join(str(p) for p in info.get(PIN_PROTOCOLS, [])))),
    }
    return rules.get(capability)


# The three exp176 called policy are not commands: they are numbers a build
# chooses. Two of them are `Customization` methods — the contract saying out
# loud that they are decisions somebody has to make — and the third is not, and
# saying so is the point of writing this table by hand instead of asserting a
# tidy rule over all three.
POLICY_METHOD = {
    "max_cred_count_list": (
        "max_credential_count_in_list", MAX_CREDS_IN_LIST,
        "one of the twenty-one Customization methods"),
    "max_cred_len": (
        None, MAX_CRED_ID_LEN,
        "not a Customization method: it falls out of how the key store wraps a "
        "credential, so a build changes it by changing the format and not by "
        "setting a number"),
    "pin_retries": (
        "max_pin_retries", None,
        "one of the twenty-one Customization methods; not in getInfo, because "
        "it is answered by clientPIN"),
}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    run = json.load(open(os.path.join(here, "engine.json")))
    exp176 = json.load(open(os.path.join(
        here, "..", "exp176-the-same-question-of-two-devices", "comparison.json")))

    body = bytes.fromhex(run["getinfo_cbor"])
    info, at = decode(body)
    if at != len(body):
        raise NotCanonical(f"{len(body) - at} bytes left over after the map")

    ok = True
    result = {"engine": run["engine"], "closed": [], "open": [], "policy": []}

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    check(True, "OpenSK's getInfo is canonical CBOR by this repository's own "
                "reader, text map keys and their ordering included")

    for entry in exp176["gap"]:
        cap, kind = entry["capability"], entry["kind"]
        if kind == "code":
            rule = closes(cap, info, run)
            if rule is None:
                check(False, f"{cap}: no rule written for it — the list moved "
                             "and this experiment did not")
                continue
            done, why = rule
            (result["closed"] if done else result["open"]).append(
                {"capability": cap, "why": why})
            check(done, f"{cap}: {'closed' if done else 'still open'} — {why}")
        elif kind == "policy":
            key = cap.split("=")[0]
            method, field, note = POLICY_METHOD.get(key, (None, None, None))
            value = info.get(field) if field else None
            result["policy"].append({"capability": cap, "customization": method,
                                     "value_here": value, "note": note})
            # The rule is that every policy number is accounted for, not that
            # every one turns out to be a Customization method. Asserting the
            # tidier thing would have been asserting something false.
            check(note is not None,
                  "%s: %s%s" % (cap, note,
                                "" if value is None else f" — this engine reports {value}"))
        elif kind == "certification":
            aaguid = info.get(AAGUID, b"")
            # The point of the whole road's last three experiments, and the one
            # thing more code does not fix.
            result["certification"] = {
                "capability": cap,
                "aaguid_here": aaguid.hex(),
                "closed": False,
                "why": "this build's AAGUID is sixteen zero bytes, exactly like "
                       "exp174's board. OpenSK offers batch attestation as a "
                       "mechanism — a certificate and a key you supply — and a "
                       "mechanism is not a certification. exp175's gap is "
                       "untouched by any amount of somebody else's code.",
            }
            check(aaguid == bytes(16),
                  "the AAGUID is still all zeroes: the one difference exp176 "
                  "called certification is not closed by code")

    code_total = sum(1 for g in exp176["gap"] if g["kind"] == "code")
    result["counts"] = {"code_in_exp176": code_total,
                        "closed": len(result["closed"]),
                        "open": len(result["open"])}
    check(len(result["closed"]) + len(result["open"]) == code_total,
          f"every one of exp176's {code_total} code differences was ruled on")

    json.dump(result, open(os.path.join(here, "closes.json"), "w"), indent=2)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
