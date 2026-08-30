#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""CTAP2 requests and WebAuthn checking, by hand, for the CTAP-HID client.

    from webauthn import make_credential_request, check_credential

# Why this is here

`ctaphid.py` beside this file is the transport. This is the layer above it: the
CBOR a `makeCredential` or `getAssertion` request is made of, and the off-board
checking that says whether what came back is a real WebAuthn credential.

Five experiments carried a copy — exp170 through exp174, accreting as the road
went — and comparing them found **no divergence at all**. Every one of these
thirteen functions is byte-identical in every experiment that has it:

```
             head cbor_* make_cred cbor_decode check_cred get_assert check_assert register
    exp170     x     x       x
    exp171     x     x       x         x           x
    exp172     x     x       x         x           x          x           x          x
    exp173     x     x       x         x           x          x           x          x
    exp174     x     x       x         x           x          x           x          x
```

A pure copy chain, monotonically accreting, with nothing to reconcile — which
makes moving it the one extraction in this repository that **cannot** change
behaviour. That is worth saying out loud, because it is not the normal case:
`ctaphid.py`'s own extraction found exp174 carrying a fix six others lacked, and
`crates/ctap-hid`'s found exp189 carrying two defects.

Nothing here talks to a device. The transport does that, and keeping the two
apart is what lets this be checked by reading rather than by flashing.

# What it does not do

**It is not a WebAuthn library.** It encodes exactly the requests these
experiments send and checks exactly the fields they claim, by hand, because
[exp128](../../experiments/exp128-reassemble-by-hand/) is this repository's
reason for doing that once. A real client sends more and checks more.
"""

import hashlib
import struct

import ctaphid

# CTAP2 command bytes. Only the two these experiments send.
AUTHENTICATOR_MAKE_CREDENTIAL = 0x01
AUTHENTICATOR_GET_ASSERTION = 0x02

# `cryptography` is imported inside the two functions that verify a signature,
# not here, and that is deliberate: the request-building half of this module has
# no such dependency, and an experiment that only sends should not fail to start
# because a checking library is missing. Kept as the five copies had it.


def head(mt, arg, force_width=None):
    """A major type and an argument. `force_width` writes it wider than it
    needs to be, which is legal CBOR and is not canonical CBOR — the thing a
    permissive parser accepts and this device must not."""
    w = force_width
    if w is None:
        w = 0 if arg < 24 else 1 if arg < 0x100 else 2 if arg < 0x10000 else 4
    if w == 0:
        return bytes([(mt << 5) | arg])
    ai = {1: 24, 2: 25, 4: 26, 8: 27}[w]
    return bytes([(mt << 5) | ai]) + arg.to_bytes(w, "big")


def cbor_uint(v, w=None):
    return head(0, v, w)


def cbor_nint(v):
    return head(1, -1 - v)


def cbor_bytes(b, claim=None):
    """`claim` writes a length other than the real one — the hostile case."""
    return head(2, len(b) if claim is None else claim) + b


def cbor_text(s):
    b = s.encode()
    return head(3, len(b)) + b


def cbor_array(items):
    return head(4, len(items)) + b"".join(items)


def cbor_map(pairs):
    return head(5, len(pairs)) + b"".join(k + v for k, v in pairs)


def make_credential_request(**kw):
    """A well-formed authenticatorMakeCredential, and the knobs each case turns.

    The defaults are what a browser sends: a 32-byte client data hash, a
    relying party, a user, and ES256 first in the list of algorithms.
    """
    cdh = kw.get("cdh", bytes(range(32)))
    rp_id = kw.get("rp_id", "example.test")
    user_id = kw.get("user_id", b"\x01\x02\x03\x04")
    algs = kw.get("algs", [-7])
    pairs = []
    if not kw.get("drop_cdh"):
        pairs.append((cbor_uint(1), cbor_bytes(cdh, claim=kw.get("claim_cdh"))))
    pairs.append((cbor_uint(2), cbor_map([(cbor_text("id"), cbor_text(rp_id)),
                                          (cbor_text("name"), cbor_text("Example"))])))
    pairs.append((cbor_uint(3), cbor_map([(cbor_text("id"), cbor_bytes(user_id)),
                                          (cbor_text("name"), cbor_text("nobody"))])))
    if not kw.get("drop_params"):
        entries = [cbor_map([(cbor_text("alg"), cbor_nint(a) if a < 0 else cbor_uint(a)),
                             (cbor_text("type"), cbor_text("public-key"))]) for a in algs]
        pairs.append((cbor_uint(4), cbor_array(entries)))
    body = cbor_map(pairs)
    if kw.get("noncanonical"):
        # Rewrite the outer map header wider than it needs to be.
        body = head(5, len(pairs), force_width=1) + body[1:]
    if kw.get("trailing"):
        body += b"\x00"
    return body


def cbor_decode(b, at=0):
    """Just enough to read a makeCredential response, and strict about it."""
    ib = b[at]
    mt, ai = ib >> 5, ib & 0x1F
    at += 1
    if ai < 24:
        arg = ai
    elif ai == 24:
        arg, at = b[at], at + 1
    elif ai == 25:
        arg, at = int.from_bytes(b[at:at + 2], "big"), at + 2
    elif ai == 26:
        arg, at = int.from_bytes(b[at:at + 4], "big"), at + 4
    else:
        raise ValueError(f"additional information {ai}")
    if mt == 0:
        return arg, at
    if mt == 1:
        return -1 - arg, at
    if mt == 2:
        return bytes(b[at:at + arg]), at + arg
    if mt == 3:
        return b[at:at + arg].decode(), at + arg
    if mt == 4:
        out = []
        for _ in range(arg):
            v, at = cbor_decode(b, at)
            out.append(v)
        return out, at
    if mt == 5:
        out = {}
        for _ in range(arg):
            k, at = cbor_decode(b, at)
            v, at = cbor_decode(b, at)
            out[k] = v
        return out, at
    raise ValueError(f"major type {mt}")


def check_credential(response, rp_id, client_data_hash):
    """Do what a relying party does with a makeCredential response.

    Every field is derived from the bytes rather than from anything the board
    said about them.
    """
    from cryptography.hazmat.primitives import hashes as _h
    from cryptography.hazmat.primitives.asymmetric import ec as _ec
    from cryptography.exceptions import InvalidSignature

    att, end = cbor_decode(response)
    out = {"fmt": att.get(1), "trailing": len(response) - end}
    auth = att[2]
    stmt = att[3]

    rp_hash, flags, count = auth[:32], auth[32], int.from_bytes(auth[33:37], "big")
    out["rp_id_hash_matches"] = rp_hash == hashlib.sha256(rp_id.encode()).digest()
    out["flags"] = flags
    out["user_present"] = bool(flags & 0x01)
    out["user_verified"] = bool(flags & 0x04)
    out["attested_data"] = bool(flags & 0x40)
    out["sign_count"] = count

    out["aaguid_all_zero"] = auth[37:53] == bytes(16)
    cred_len = int.from_bytes(auth[53:55], "big")
    out["credential_id_len"] = cred_len
    cose, _ = cbor_decode(auth[55 + cred_len:])
    out["cose_kty"], out["cose_alg"], out["cose_crv"] = cose.get(1), cose.get(3), cose.get(-1)
    x, y = cose[-2], cose[-3]
    out["coordinate_bytes"] = [len(x), len(y)]

    pub = _ec.EllipticCurvePublicNumbers(
        int.from_bytes(x, "big"), int.from_bytes(y, "big"), _ec.SECP256R1()
    ).public_key()
    signed = auth + client_data_hash
    out["att_alg"] = stmt.get("alg")
    out["att_has_x5c"] = "x5c" in stmt
    try:
        pub.verify(stmt["sig"], signed, _ec.ECDSA(_h.SHA256()))
        out["signature_valid"] = True
    except InvalidSignature:
        out["signature_valid"] = False

    # **The control.** A signature that verifies proves nothing until the same
    # check has been seen to fail. One bit of the authenticator data.
    broken = bytearray(signed)
    broken[40] ^= 0x01
    try:
        pub.verify(stmt["sig"], bytes(broken), _ec.ECDSA(_h.SHA256()))
        out["tamper_rejected"] = False
    except InvalidSignature:
        out["tamper_rejected"] = True
    return out


def get_assertion_request(rp_id="example.test", cdh=None, allow=None, no_allow=False):
    """A well-formed authenticatorGetAssertion, and the knobs each case turns."""
    cdh = bytes(range(32, 64)) if cdh is None else cdh
    pairs = [
        (cbor_uint(1), cbor_text(rp_id)),
        (cbor_uint(2), cbor_bytes(cdh)),
    ]
    if not no_allow:
        entries = [
            cbor_map([(cbor_text("id"), cbor_bytes(c)),
                      (cbor_text("type"), cbor_text("public-key"))])
            for c in (allow or [])
        ]
        pairs.append((cbor_uint(3), cbor_array(entries)))
    return cbor_map(pairs), cdh


def check_assertion(response, rp_id, client_data_hash, x, y, expect_cred_id):
    """Verify an assertion against the public key from **registration**.

    This is the whole round trip: the board derived a key once to register, kept
    nothing, and derived it again to sign. If these two signatures come from
    different keys, the second verification fails and there is nowhere to hide.
    """
    from cryptography.hazmat.primitives import hashes as _h
    from cryptography.hazmat.primitives.asymmetric import ec as _ec
    from cryptography.exceptions import InvalidSignature

    att, end = cbor_decode(response)
    out = {"trailing": len(response) - end}
    cred, auth, sig = att[1], att[2], att[3]
    out["credential_id_echoed"] = cred.get("id") == expect_cred_id
    out["credential_type"] = cred.get("type")
    out["auth_data_len"] = len(auth)
    flags = auth[32]
    out["flags"] = flags
    out["user_present"] = bool(flags & 0x01)
    # Attested credential data belongs to registration and must not be here.
    out["attested_data"] = bool(flags & 0x40)
    out["rp_id_hash_matches"] = auth[:32] == hashlib.sha256(rp_id.encode()).digest()
    out["sign_count"] = int.from_bytes(auth[33:37], "big")

    pub = _ec.EllipticCurvePublicNumbers(
        int.from_bytes(x, "big"), int.from_bytes(y, "big"), _ec.SECP256R1()
    ).public_key()
    signed = auth + client_data_hash
    try:
        pub.verify(sig, signed, _ec.ECDSA(_h.SHA256()))
        out["signature_valid"] = True
    except InvalidSignature:
        out["signature_valid"] = False
    broken = bytearray(signed)
    broken[10] ^= 0x01
    try:
        pub.verify(sig, bytes(broken), _ec.ECDSA(_h.SHA256()))
        out["tamper_rejected"] = False
    except InvalidSignature:
        out["tamper_rejected"] = True
    return out


def register(link, rp_id="example.test"):
    """Make a credential and return what a relying party would have stored.

    The one function here that touches the transport. `link` is a
    [`ctaphid.Link`](./ctaphid.py); the five copies this came from called a free
    `init(link)` where the shared client has it as a method.
    """
    r = link.init()
    cid = bytes.fromhex(r["new_cid"])
    cdh = bytes(range(32))
    link.send_message(cid, ctaphid.CTAPHID_CBOR,
                      bytes([AUTHENTICATOR_MAKE_CREDENTIAL]) + make_credential_request(rp_id=rp_id))
    reply = link.read_message(timeout=15.0)
    data = link.last
    if not reply or data[0] != 0:
        raise SystemExit(f"registration failed: {reply}")
    att, _ = cbor_decode(data[1:])
    auth = att[2]
    cred_len = int.from_bytes(auth[53:55], "big")
    cred_id = auth[55:55 + cred_len]
    cose, _ = cbor_decode(auth[55 + cred_len:])
    return cred_id, cose[-2], cose[-3]
