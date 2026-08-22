#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Re-check exp174's browser half from the file it left behind.

    python3 verify.py [browser-ab.json]

`browser-ab.json` holds two arms of one experiment: the same source, the same
board, the same browser, differing in whether the firmware sends
`CTAPHID_KEEPALIVE` while it waits for a person. The board's own clock decides
when the answer leaves, so both arms answer at the same moment and the only
variable left is the packet.

This file states the claim as an implication in both directions, the way
exp173's does:

    the device was silent past the ceiling  <->  the browser refused the credential

A transcript showing a silent arm accepted, or a keepalive arm refused, fails —
because either would mean the packet was not what made the difference and this
experiment's conclusion is wrong.

It also does the cryptography again, on the arm that succeeded, from the bytes
the browser handed the page: the self attestation is checked against the public
key inside the attestation object, and the user-presence bit is required to be
set. A credential that verifies but claims nobody was there is not a pass.
"""
import base64
import hashlib
import json
import sys

FAILURES = []


def check(ok, claim, detail=""):
    print("  %-4s %s%s" % ("ok" if ok else "FAIL", claim, ("  — " + detail) if detail else ""))
    if not ok:
        FAILURES.append(claim)
    return ok


def ub64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def cbor(b, i=0):
    """Enough CBOR for an attestation object, and no more."""
    m, a = b[i] >> 5, b[i] & 0x1F
    i += 1
    if a < 24:
        v = a
    elif a == 24:
        v, i = b[i], i + 1
    elif a == 25:
        v, i = int.from_bytes(b[i:i + 2], "big"), i + 2
    elif a == 26:
        v, i = int.from_bytes(b[i:i + 4], "big"), i + 4
    else:
        raise ValueError("length form %d" % a)
    if m == 0:
        return v, i
    if m == 1:
        return -1 - v, i
    if m == 2:
        return b[i:i + v], i + v
    if m == 3:
        return b[i:i + v].decode(), i + v
    if m == 4:
        out = []
        for _ in range(v):
            x, i = cbor(b, i)
            out.append(x)
        return out, i
    if m == 5:
        out = {}
        for _ in range(v):
            k, i = cbor(b, i)
            x, i = cbor(b, i)
            out[k] = x
        return out, i
    raise ValueError("major %d" % m)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "browser-ab.json"
    doc = json.load(open(path))
    arms = {a["board"]["arm"]: a for a in doc.get("arms", [])}

    print("exp174 — the two arms")
    # `.get` everywhere below, not `[]`. exp173's verify.py crashed with a
    # KeyError on a transcript that was missing a field, which is a check that
    # stops checking the moment it finds something wrong.
    if not check(set(arms) == {"silent", "keepalive"},
                 "the file holds both arms", "found: " + ", ".join(sorted(arms)) or "none"):
        return 1

    silent, keep = arms["silent"], arms["keepalive"]

    print("\nthe two arms differ by one thing")
    check(silent["board"].get("hold_ms") == keep["board"].get("hold_ms"),
          "both answered on the same floor",
          "%s ms and %s ms" % (silent["board"].get("hold_ms"), keep["board"].get("hold_ms")))
    check(silent["board"].get("keepalives") == 0,
          "the silent arm sent no keepalives",
          "%s" % silent["board"].get("keepalives"))
    check((keep["board"].get("keepalives") or 0) > 0,
          "the keepalive arm sent some",
          "%s" % keep["board"].get("keepalives"))
    # The floor is the point: a difference in *when* the answer left would be a
    # second variable, and there would be nothing to attribute the result to.
    a, b = silent["board"].get("answered_at_ms"), keep["board"].get("answered_at_ms")
    check(a is not None and b is not None and abs(a - b) < 500,
          "and answered within half a second of each other",
          "%s ms and %s ms" % (a, b))

    print("\nboth boards did the work; only one client was still there")
    check(silent["board"].get("credential_made") is True,
          "the silent arm built a credential too", "it was not a refusal")
    check(keep["board"].get("credential_made") is True, "so did the keepalive arm")

    print("\nthe implication, in both directions")
    s_ok = silent["browser"].get("ok")
    k_ok = keep["browser"].get("ok")
    check(s_ok is False, "silent past the ceiling -> the browser refused",
          str(silent["browser"].get("error")))
    check(k_ok is True, "keepalive past the ceiling -> the browser accepted",
          "%s ms" % keep["browser"].get("ms"))

    print("\nand the credential the browser accepted, checked again here")
    att_b64 = keep["browser"].get("attestationObject")
    cdj_b64 = keep["browser"].get("clientDataJSON")
    if not check(bool(att_b64 and cdj_b64), "the attestation object is in the file"):
        return 1 if FAILURES else 0

    att, _ = cbor(ub64(att_b64))
    ad = att.get("authData", b"")
    check(att.get("fmt") == "packed", "fmt is packed", str(att.get("fmt")))
    rp = json.loads(ub64(cdj_b64)).get("origin", "")
    host = rp.split("//", 1)[-1].split(":")[0]
    check(ad[:32] == hashlib.sha256(host.encode()).digest(),
          "the rpIdHash is this origin's", host)
    flags = ad[32] if len(ad) > 32 else 0
    check(bool(flags & 0x01), "the user-presence bit is set", "flags %#04x" % flags)
    check(bool(flags & 0x40), "attested credential data is present", "flags %#04x" % flags)

    n = int.from_bytes(ad[53:55], "big")
    cose, _ = cbor(ad[55 + n:])
    msg = ad + hashlib.sha256(ub64(cdj_b64)).digest()
    sig = att.get("attStmt", {}).get("sig", b"")
    try:
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives import hashes
        from cryptography.exceptions import InvalidSignature
        key = ec.EllipticCurvePublicNumbers(
            int.from_bytes(cose[-2], "big"), int.from_bytes(cose[-3], "big"),
            ec.SECP256R1()).public_key()
        try:
            key.verify(sig, msg, ec.ECDSA(hashes.SHA256()))
            check(True, "the self attestation verifies", "%d byte signature" % len(sig))
        except InvalidSignature:
            check(False, "the self attestation verifies")
        # exp159's rule: a check that has never failed has not been shown to
        # work. One flipped bit must break it.
        bad = bytearray(msg)
        bad[-1] ^= 1
        try:
            key.verify(sig, bytes(bad), ec.ECDSA(hashes.SHA256()))
            check(False, "and one flipped bit breaks it")
        except InvalidSignature:
            check(True, "and one flipped bit breaks it")
    except ImportError:
        check(False, "python3-cryptography is installed to check the signature")

    print()
    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("every check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
