#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check a libfido2 round trip against itself, off the board.

    python3 verify.py < capture.txt

Prints OK, DISAGREE or INCOMPLETE on the last line.

Everything before this experiment was driven by a CTAPHID client written for
this repository, which means every message the board saw was one this repository
also wrote. This transcript is somebody else's: `fido2-token`, `fido2-cred` and
`fido2-assert`, with their own CBOR and their own idea of what an authenticator
owes a caller.

**The derivation that matters is one implication**, and it is the finding:

    the user-presence bit is 0  <->  fido2-cred -V refuses the credential

If a transcript shows `UP=False` and a verification that passed, or `UP=True`
and one that was refused, then the refusal was never about user presence and
everything this experiment concluded is wrong. Nothing else in here is as
important as that one `if`.

Also derived: the device's declared `options` agree with the flags it actually
produced, an assertion carries no attested credential data, and the assertion
verifies against the key the credential handed over — that last by a library
that did not sign it, with a bit flipped first.
"""

import re
import sys

FLAGS = re.compile(
    r"flags=(?P<hex>0x[0-9a-f]{2}) UP=(?P<up>True|False) UV=(?P<uv>True|False) "
    r"AT=(?P<at>True|False) ED=(?P<ed>True|False)"
)


def main():
    lines = [l.rstrip("\n") for l in sys.stdin]
    text = "\n".join(lines)
    problems, notes = [], []

    if "fido2-cred -M" not in text:
        print("this transcript does not contain a libfido2 round trip")
        print("INCOMPLETE")
        return 1

    # ---- what the device said about itself --------------------------------
    if "version strings: FIDO_2_0" not in text:
        problems.append("the device does not claim FIDO_2_0, which its commands now earn")
    opts = next((l for l in lines if "options:" in l), None)
    if opts is None:
        problems.append("fido2-token -I reported no options map")
        opts = ""
    else:
        notes.append(opts.strip())
    declares_up = "noup" not in opts

    flags = FLAGS.findall(text)
    if len(flags) < 2:
        print(f"only {len(flags)} authenticator-data flag lines; a round trip has two")
        print("INCOMPLETE")
        return 1
    cred_flags, assert_flags = flags[0], flags[1]
    cred_up = cred_flags[1] == "True"
    assert_up = assert_flags[1] == "True"

    # ---- the implication this experiment exists for -----------------------
    verified = "verified, and wrote the public key out" in text
    refused = "fido_cred_verify_self: FIDO_ERR_INVALID_PARAM" in text
    if verified == refused:
        problems.append("the transcript neither verifies nor refuses the credential, or does both")
    elif cred_up and not verified:
        problems.append(
            "the credential says a user was present and libfido2 still refused it — "
            "then the refusal is not about presence and this experiment's conclusion is wrong"
        )
    elif not cred_up and not refused:
        problems.append(
            "a credential with no user present was accepted — then the rule this "
            "experiment measured is not the rule libfido2 enforces"
        )
    else:
        notes.append(
            f"UP={cred_up} and fido2-cred -V {'verified' if verified else 'refused'}: the implication holds"
        )

    # ---- the device's declaration and its behaviour have to agree ---------
    if declares_up != cred_up:
        problems.append(
            f"options say the device {'can' if declares_up else 'cannot'} ask a user, "
            f"and the credential says it {'did' if cred_up else 'did not'}"
        )
    if cred_up != assert_up:
        problems.append("one half of the round trip had a user present and the other did not")

    # ---- shapes -----------------------------------------------------------
    if cred_flags[3] != "True":
        problems.append("the credential has no attested credential data")
    if assert_flags[3] != "False":
        problems.append("the assertion carries attested credential data, which belongs to registration")
    if any(f[2] == "True" for f in flags):
        problems.append("a UV bit is set and this device cannot verify anybody")
    if "aaguid all zero: True" not in text:
        problems.append("the AAGUID is not zero, and this is self attestation")
    if "authData=180B" not in text:
        problems.append("the credential's authenticator data is not 180 bytes")
    if "authData=37B" not in text:
        problems.append("the assertion's authenticator data is not 37 bytes")
    if "rpIdHash matches example.test: True" not in text:
        problems.append("rpIdHash is not SHA-256 of the relying party asked for")

    # ---- the assertion, checked by a library that did not sign it ---------
    if "signature verifies against the registered key: True" not in text:
        problems.append("the assertion does not verify against the key the credential gave out")
    if "a flipped bit is rejected: True" not in text:
        problems.append("a flipped bit still verified — the check proves nothing")

    # A host-format detail worth keeping in the record: libfido2 prints the
    # authenticator data wrapped in its CBOR byte-string header, and a reader
    # that assumes raw bytes is two bytes off and reads the wrong flags.
    hdr = re.search(r"cbor header ([0-9a-f]+)", text)
    if hdr:
        notes.append(f"libfido2 prints authData CBOR-wrapped, header {hdr.group(1)}")
    else:
        problems.append("no CBOR header recorded, so nothing says how libfido2 framed the bytes")

    for n in notes:
        print(f"note: {n}")
    print(
        "OPEN: no browser has driven this device; libfido2 is a real client and is not one"
    )
    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
