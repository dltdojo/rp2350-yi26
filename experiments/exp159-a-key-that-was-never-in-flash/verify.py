#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify exp159's signature off the board.

Reads the board's log on stdin, pulls out the public key, the challenge and the
signature, and checks them with `cryptography` — an implementation that is not
the one that produced them. That independence is the whole point: a signature
checked by its own signer proves the two agree, not that either is right.

It then flips one bit of the challenge and requires the verification to FAIL.
A check that cannot fail has not passed, which is what exp140 is named for.

Prints exactly one word, for check.sh:
    OK          verified, and the corrupted variant was rejected
    BAD         the signature did not verify
    CANNOTFAIL  a corrupted message verified too — the check is broken
    MISSING     the log did not carry all five values
    NOPYCA      python-cryptography is not installed
"""
import re
import sys


def last(log, tag):
    m = re.findall(r"\b" + tag + r"\s+([0-9a-f]{64})", log)
    return bytes.fromhex(m[-1]) if m else None


def main() -> None:
    log = sys.stdin.read()
    x, y, msg, r, s = (last(log, t) for t in ("PUBX", "PUBY", "MSG", "SIGR", "SIGS"))
    if not all(v is not None for v in (x, y, msg, r, s)):
        print("MISSING")
        return

    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
    except ImportError:
        print("NOPYCA")
        return

    # 0x04 is the SEC1 tag for an uncompressed point; the board prints X and Y
    # on their own lines because 65 bytes of hex does not fit usb-log's 96-byte
    # line and a truncated public key is a public key nobody can use.
    pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b"\x04" + x + y)
    der = utils.encode_dss_signature(int.from_bytes(r, "big"), int.from_bytes(s, "big"))

    try:
        pub.verify(der, msg, ec.ECDSA(hashes.SHA256()))
    except Exception:
        print("BAD")
        return

    bad = bytearray(msg)
    bad[0] ^= 1
    try:
        pub.verify(der, bytes(bad), ec.ECDSA(hashes.SHA256()))
        print("CANNOTFAIL")
    except Exception:
        print("OK")


if __name__ == "__main__":
    main()
