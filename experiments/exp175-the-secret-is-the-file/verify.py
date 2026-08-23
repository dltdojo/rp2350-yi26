#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Confirm a forged assertion is real, and that the device would accept it.

    python3 verify.py firmware.uf2 forged.json

forge.py claims it built a working assertion from the firmware image alone.
This checks the claim without trusting a byte of forge.py's output structure:
it lifts the secret out of the .uf2 itself, and from that plus the forged
credential id re-derives everything the real device would have.

Three things have to hold, and each is a separate sentence:

  1. **the assertion verifies** against the public key — it is a real ES256
     signature over authenticatorData || SHA256(clientDataJSON);

  2. **the device would accept this credential** — the credential id's tag is
     HMAC(secret, "id" || nonce || rpIdHash)[..16], so the real board's
     `credential_is_ours` returns true for bytes the board never issued;

  3. **the public key is the one the device would derive** — same nonce, same
     rpIdHash, same rejection loop, same key. The forger did not choose the
     keypair; the secret did.

exp159's rule closes it: one flipped bit in the signed message must break check
1, or the check has not been shown to work.

Every value is recomputed here from the .uf2 and the credential id. If forge.py
and verify.py agree, it is because the secret determines all of it — which is
the finding.
"""
import base64
import hashlib
import hmac
import json
import sys

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes
    from cryptography.exceptions import InvalidSignature
except ImportError:
    raise SystemExit("needs python3-cryptography")

from unpack import load

SECRET_NEEDLE = b"not a secret. this is a test key"
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
FAILURES = []


def check(ok, claim, detail=""):
    print("  %-4s %s%s" % ("ok" if ok else "FAIL", claim,
                           ("  — " + detail) if detail else ""))
    if not ok:
        FAILURES.append(claim)
    return ok


def ub64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def mac(secret, *parts):
    m = hmac.new(secret, digestmod=hashlib.sha256)
    for p in parts:
        m.update(p)
    return m.digest()


def derive_key(secret, nonce, rp_id_hash):
    for counter in range(256):
        k = mac(secret, b"key", bytes([counter]), nonce, rp_id_hash)
        v = int.from_bytes(k, "big")
        if 1 <= v < N:
            return ec.derive_private_key(v, ec.SECP256R1())
    return None


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    uf2_path, forged_path = sys.argv[1], sys.argv[2]

    base, img = load(uf2_path)
    si = img.find(SECRET_NEEDLE)
    if not check(si >= 0, "the secret is in the firmware image",
                 "%#x" % (base + si) if si >= 0 else "absent"):
        return 1
    secret = img[si:si + 32]

    f = json.load(open(forged_path))
    rp_id = f.get("rp_id", "")
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    cred_id = ub64(f["credential_id"])
    nonce, tag = cred_id[:32], cred_id[32:]

    print("\n1 — the device would accept this credential id")
    want = mac(secret, b"id", nonce, rp_id_hash)[:16]
    check(len(cred_id) == 48, "the credential id is 48 bytes", "%d" % len(cred_id))
    check(hmac.compare_digest(tag, want),
          "its tag is HMAC(secret, 'id'..)[..16] — credential_is_ours() says yes",
          "the board would sign for bytes it never issued")

    print("\n2 — the public key is the one the device derives, not the forger's")
    key = derive_key(secret, nonce, rp_id_hash)
    if not check(key is not None, "a valid scalar derives from the secret"):
        return 1
    pn = key.public_key().public_numbers()
    fx = int.from_bytes(ub64(f["public_key"]["x"]), "big")
    fy = int.from_bytes(ub64(f["public_key"]["y"]), "big")
    check(pn.x == fx and pn.y == fy,
          "the re-derived public key matches the forged one exactly")

    print("\n3 — the assertion is a real signature, presence and all")
    auth = ub64(f["authenticator_data"])
    cdj = ub64(f["client_data_json"])
    sig = ub64(f["signature"])
    flags = auth[32]
    check(bool(flags & 0x01),
          "the user-presence bit is set in a signature nobody was present for",
          "flags %#04x" % flags)
    check(auth[:32] == rp_id_hash, "the rpIdHash is this relying party's", rp_id)
    signed = auth + hashlib.sha256(cdj).digest()
    pub = key.public_key()
    try:
        pub.verify(sig, signed, ec.ECDSA(hashes.SHA256()))
        check(True, "the assertion verifies against the derived key",
              "%d byte signature" % len(sig))
    except InvalidSignature:
        check(False, "the assertion verifies against the derived key")

    # exp159's rule.
    bad = bytearray(signed)
    bad[-1] ^= 1
    try:
        pub.verify(sig, bytes(bad), ec.ECDSA(hashes.SHA256()))
        check(False, "and one flipped bit breaks it")
    except InvalidSignature:
        check(True, "and one flipped bit breaks it")

    print()
    if FAILURES:
        print("%d check(s) failed" % len(FAILURES))
        return 1
    print("every check passed — the file was enough to be the device")
    return 0


if __name__ == "__main__":
    sys.exit(main())
