#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Decode a credential's attestation, and say what kind of identity it carries.

    fido2-cred -M /dev/hidrawN < input > cred.out
    python3 attest.py --label board cred.out

`getInfo` already shows one device claims a real AAGUID and the other none. This
looks at the attestation *statement*, where the difference becomes concrete.

`fido2-cred -M` prints, one per line: the client data hash, the relying party
id, the attestation **format** (a plain string, e.g. `packed`), the
**authenticator data** (base64, prefixed with its own two-byte length), the
credential id, the signature, and — **only if the device sent one** — an
**x5c certificate** (base64 DER, recognisable by its `30 82` SEQUENCE header).

The board self-attests: `packed`, an all-zero AAGUID, no certificate. A
commercial key adds the certificate, rooting its identity in a CA the FIDO
Metadata Service lists. A self attestation says *these bytes were signed by the
key inside this credential*; a certificate chain says *and a named manufacturer
vouches the key lives in a certified device*. The second is the sentence
[exp175](../exp175-the-secret-is-the-file/) showed this chip cannot back with a
secret it can keep — so the missing certificate is not a missing feature, it is
a missing authority.
"""
import base64
import hashlib
import json
import sys

FLAG_NAMES = [(0x01, "UP"), (0x04, "UV"), (0x40, "AT"), (0x80, "ED")]


def b64(s):
    return base64.b64decode(s + "=" * (-len(s) % 4))


def b64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def cbor(b, i=0):
    """A CBOR reader, enough for a WebAuthn attestation object."""
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
        return b[i:i + v].decode("latin1"), i + v
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


def decode_webauthn(att_obj_b64url, label):
    """Decode a browser's attestationObject — the same finding, the touch-only way.

    This is what navigator.credentials.create() hands a page, captured by the
    exp174 probe page and posted to a file. No PIN typed at a shell, no
    fido2-cred: the browser asks the authenticator the way a website does, and a
    person only touches (and enters a PIN in the browser's own dialog if the key
    insists). With attestation='direct' a commercial key returns its x5c chain
    here just as it would to a real relying party.
    """
    obj, _ = cbor(b64url(att_obj_b64url))
    auth = obj.get("authData", b"")
    aaguid = auth[37:53].hex() if len(auth) >= 53 else ""
    flags = auth[32] if len(auth) > 32 else 0
    stmt = obj.get("attStmt", {})
    x5c = stmt.get("x5c")
    has_cert = bool(x5c)
    return {
        "label": label,
        "source": "browser attestationObject",
        "format": obj.get("fmt"),
        "authenticator_data_bytes": len(auth),
        "flags": "0x%02x" % flags,
        "flags_set": [name for bit, name in FLAG_NAMES if flags & bit],
        "aaguid": aaguid,
        "aaguid_is_zero": aaguid == "0" * 32,
        "attStmt_keys": sorted(str(k) for k in stmt.keys()),
        "has_certificate_chain": has_cert,
        "certificates_in_chain": len(x5c) if isinstance(x5c, list) else 0,
        "identity": ("certificate chain — a manufacturer vouches for the device"
                     if has_cert else
                     "self attestation — the credential vouches only for itself"),
    }


def last_create_attestation(transcript_path):
    """Pull the attestationObject from the last successful create in a transcript."""
    obj = None
    for line in open(transcript_path):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("step") == "create" and e.get("ok") and e.get("attestationObject"):
            obj = e["attestationObject"]
    if obj is None:
        raise SystemExit("no successful create with an attestationObject in %s" % transcript_path)
    return obj


def looks_base64(s):
    return s != "" and all(c.isalnum() or c in "+/=" for c in s)


def cbor_bytes(field):
    """Read a CBOR byte string (major type 2) and return (payload, header_ok)."""
    if not field:
        return b"", False
    major = field[0] >> 5
    info = field[0] & 0x1F
    if major != 2:
        return field, False               # not CBOR-wrapped; take it as-is
    if info < 24:
        n, i = info, 1
    elif info == 24:
        n, i = field[1], 2
    elif info == 25:
        n, i = int.from_bytes(field[1:3], "big"), 3
    else:
        return field[1:], False
    return field[i:i + n], (len(field) - i) == n


def decode(lines, label):
    lines = [ln.strip() for ln in lines if ln.strip()]
    if len(lines) < 6:
        raise SystemExit("expected fido2-cred -M output (>= 6 lines), got %d" % len(lines))

    fmt = lines[2]  # a plain string, not base64

    # authenticator data is printed as a CBOR byte string (major type 2), not
    # raw. This repository has misread that once before (exp173): a header like
    # `58 b4` is "byte string, 180 bytes", not two bytes of data. Decode the
    # header properly rather than skipping a fixed count, so a longer authData
    # with a three-byte header still parses.
    auth_field = b64(lines[3])
    auth, length_ok = cbor_bytes(auth_field)
    flags = auth[32] if len(auth) > 32 else 0
    aaguid = auth[37:53].hex() if len(auth) >= 53 else ""

    # A certificate is any line that base64-decodes to a DER SEQUENCE (0x30 0x82
    # ...), which is what an x5c entry is. Detected by content, not by position,
    # so the seventh-line convention is not relied on.
    has_cert = False
    for ln in lines:
        if looks_base64(ln):
            d = b64(ln)
            if len(d) > 4 and d[0] == 0x30 and d[1] == 0x82:
                has_cert = True
                break

    return {
        "label": label,
        "format": fmt,
        "authenticator_data_bytes": len(auth),
        "authdata_cbor_length_ok": length_ok,
        "flags": "0x%02x" % flags,
        "flags_set": [name for bit, name in FLAG_NAMES if flags & bit],
        "aaguid": aaguid,
        "aaguid_is_zero": aaguid == "0" * 32,
        "has_certificate_chain": has_cert,
        "identity": ("certificate chain — a manufacturer vouches for the device"
                     if has_cert else
                     "self attestation — the credential vouches only for itself"),
    }


def main():
    label = "device"
    mode = "cli"
    args = sys.argv[1:]
    while args and args[0].startswith("--"):
        if args[0] == "--label":
            label, args = args[1], args[2:]
        elif args[0] == "--webauthn":
            mode, args = "webauthn", args[1:]
        else:
            raise SystemExit("unknown option %s" % args[0])
    if mode == "webauthn":
        # Argument is a transcript.json (from the probe page) or a raw
        # base64url attestationObject.
        src = args[0] if args else None
        if src and src.endswith(".json"):
            att = last_create_attestation(src)
        elif src:
            att = open(src).read().strip()
        else:
            att = sys.stdin.read().strip()
        print(json.dumps(decode_webauthn(att, label), indent=2))
        return
    lines = open(args[0]).read().splitlines() if args else sys.stdin.read().splitlines()
    print(json.dumps(decode(lines, label), indent=2))


if __name__ == "__main__":
    main()
