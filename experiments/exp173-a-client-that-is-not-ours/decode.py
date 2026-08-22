#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read what libfido2's tools print, and say what is in it.

`fido2-cred` and `fido2-assert` emit base64 blobs, and the authenticator data
comes out **wrapped in its CBOR byte-string header** rather than raw — which
cost this experiment one wrong decode before it was noticed, and is exactly the
sort of thing a host format does that a specification does not mention.
"""

import base64
import hashlib
import sys


def unwrap(b64):
    b = base64.b64decode(b64)
    if b and b[0] == 0x58:          # byte string, one-byte length
        return b[2:], b[:2].hex()
    if b and b[0] == 0x59:          # byte string, two-byte length
        return b[3:], b[:3].hex()
    return b, "(raw)"


def flags(f):
    return (f"flags={f:#04x} UP={bool(f & 1)} UV={bool(f & 4)} "
            f"AT={bool(f & 0x40)} ED={bool(f & 0x80)}")


def cose_xy(auth):
    n = int.from_bytes(auth[53:55], "big")
    blob = auth[55 + n:]
    # A five-entry COSE_Key: kty, alg, crv, x, y. Only the coordinates matter
    # here and they are the last two 32-byte strings.
    x = blob[blob.index(b"\x21\x58\x20") + 3:][:32]
    y = blob[blob.index(b"\x22\x58\x20") + 3:][:32]
    return x, y, auth[55:55 + n]


def main():
    what = sys.argv[1]
    if what == "credential":
        lines = sys.stdin.read().split("\n")
        auth, hdr = unwrap(lines[3])
        print(f"fmt={lines[2]} authData={len(auth)}B (cbor header {hdr})")
        print(flags(auth[32]))
        print(f"rpIdHash matches example.test: "
              f"{auth[:32] == hashlib.sha256(b'example.test').digest()}")
        print(f"aaguid all zero: {auth[37:53] == bytes(16)}  "
              f"credential id: {int.from_bytes(auth[53:55], 'big')}B")
        return
    if what == "assertion":
        lines = sys.stdin.read().split("\n")
        auth, hdr = unwrap(lines[2])
        print(f"authData={len(auth)}B (cbor header {hdr})")
        print(flags(auth[32]))
        print(f"signCount={int.from_bytes(auth[33:37], 'big')}")
        return
    if what == "check":
        from cryptography.hazmat.primitives import hashes as _h
        from cryptography.hazmat.primitives.asymmetric import ec as _ec
        from cryptography.exceptions import InvalidSignature

        cred = open(sys.argv[2]).read().split("\n")
        asrt = open(sys.argv[3]).read().split("\n")
        cauth, _ = unwrap(cred[3])
        x, y, cred_id = cose_xy(cauth)
        aauth, _ = unwrap(asrt[2])
        sig = base64.b64decode(asrt[3])
        cdh = base64.b64decode(asrt[0])
        pub = _ec.EllipticCurvePublicNumbers(
            int.from_bytes(x, "big"), int.from_bytes(y, "big"), _ec.SECP256R1()
        ).public_key()
        try:
            pub.verify(sig, aauth + cdh, _ec.ECDSA(_h.SHA256()))
            ok = True
        except InvalidSignature:
            ok = False
        broken = bytearray(aauth + cdh)
        broken[5] ^= 1
        try:
            pub.verify(sig, bytes(broken), _ec.ECDSA(_h.SHA256()))
            tamper = False
        except InvalidSignature:
            tamper = True
        print(f"credential echoed: {base64.b64decode(asrt[2]) is not None}")
        print(f"signature verifies against the registered key: {ok}")
        print(f"a flipped bit is rejected: {tamper}")
        return
    raise SystemExit(f"unknown: {what}")


if __name__ == "__main__":
    main()
