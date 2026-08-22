#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A CTAPHID client, by hand, over /dev/hidraw.

    python3 ctaphid.py <case> [...]

`fido2-token` proves the descriptor: it finds authenticators by usage page
0xF1D0, so being listed by it means the hand-written 34 bytes are right. It
will not send a PING, and PING is what this experiment is about — so the
transport is driven here instead, one packet at a time, with the framing
written out rather than borrowed.

Cases, and every one can come out the other way:

    init           allocate a channel: 8 bytes of nonce out, 17 back
    ping N         echo N bytes. N > 57 needs continuation packets, which is
                   the whole point; N > 1024 must be refused, not truncated
    bad-seq        a continuation packet with the wrong sequence number
    busy           a second channel interrupting a transaction in progress
    truncated      a byte count that promises more than is ever sent
    unknown        CTAPHID_MSG, which the capability byte says is not supported
    stray-cont     a continuation packet for a transaction nobody started
    getinfo        authenticatorGetInfo: the one CTAP2 command here, and the
                   only one that asks a device to describe itself
    getinfo-params getInfo with parameters, which it takes none of
    makecred       authenticatorMakeCredential, which FIDO_2_0 is for and this
                   device does not have
    ctap-unknown   a CTAP2 command number nobody has defined
    mc-good        a well-formed makeCredential, which is read and then refused
    mc-lying-length  a byte string whose length runs past the message
    mc-noncanonical  a map header written wider than it needs to be
    mc-trailing    a complete request with a byte after it
    mc-missing-cdh   no clientDataHash
    mc-missing-params  no pubKeyCredParams
    mc-no-es256    RS256 only: understood, and not usable here
    mc-many-algs   more algorithms than the device records
    ga-roundtrip   register, then assert with that credential and verify the
                   assertion against the public key registration handed over
    ga-forged      one byte of the credential ID's tag turned over
    ga-other-rp    the real credential ID, asked for a different relying party
    ga-wrong-length  a credential ID with no tag at all
    ga-empty-allow   an allow list with nothing in it
    ga-no-allow    no allow list, which means "use a resident credential"
    ga-decoys      the real credential behind two that are not

Prints one JSON object per exchange. Nothing here parses CBOR, because there
is no CBOR: this device knows nothing.
"""

import hashlib
import json
import os
import struct
import sys
import time

PACKET = 64
INIT_HEADER, CONT_HEADER = 7, 5
INIT_PAYLOAD, CONT_PAYLOAD = PACKET - INIT_HEADER, PACKET - CONT_HEADER
BROADCAST = b"\xff\xff\xff\xff"

CTAPHID_PING, CTAPHID_MSG, CTAPHID_INIT, CTAPHID_CBOR, CTAPHID_ERROR = 1, 3, 6, 0x10, 0x3F
AUTHENTICATOR_MAKE_CREDENTIAL, AUTHENTICATOR_GET_ASSERTION, AUTHENTICATOR_GET_INFO = 1, 2, 4
CTAP2_STATUS = {
    0x00: "CTAP2_OK", 0x01: "CTAP1_ERR_INVALID_COMMAND",
    0x02: "CTAP1_ERR_INVALID_PARAMETER", 0x03: "CTAP1_ERR_INVALID_LENGTH",
    0x7F: "CTAP1_ERR_OTHER",
    0x12: "CTAP2_ERR_INVALID_CBOR", 0x14: "CTAP2_ERR_MISSING_PARAMETER",
    0x26: "CTAP2_ERR_UNSUPPORTED_ALGORITHM", 0x27: "CTAP2_ERR_OPERATION_DENIED",
    0x2E: "CTAP2_ERR_NO_CREDENTIALS",
}
ERRORS = {
    0x01: "ERR_INVALID_CMD", 0x02: "ERR_INVALID_PAR", 0x03: "ERR_INVALID_LEN",
    0x04: "ERR_INVALID_SEQ", 0x05: "ERR_MSG_TIMEOUT", 0x06: "ERR_CHANNEL_BUSY",
    0x0B: "ERR_INVALID_CHANNEL", 0x7F: "ERR_OTHER",
}


# --------------------------------------------------------------------------
# Building CBOR, by hand, including the shapes a well-behaved client never
# sends. A library would refuse to produce most of these, which is exactly why
# there is not one here.
# --------------------------------------------------------------------------

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


# --------------------------------------------------------------------------
# The relying party's half. exp159's rule: the signature is checked by a
# different implementation from the one that made it, and a bit is flipped and
# the check required to fail before the pass is reported.
# --------------------------------------------------------------------------

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
    """Make a credential and return what a relying party would have stored."""
    r = init(link)
    cid = bytes.fromhex(r["new_cid"])
    cdh = bytes(range(32))
    link.send_message(cid, CTAPHID_CBOR,
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


def find_device():
    """The device this experiment is running on, found the way libfido2 finds
    one: by asking every hidraw node what its report descriptor says."""
    for name in sorted(os.listdir("/dev")):
        if not name.startswith("hidraw"):
            continue
        path = f"/dev/{name}"
        try:
            desc = open(f"/sys/class/hidraw/{name}/device/report_descriptor", "rb").read()
        except OSError:
            continue
        # Usage Page (0xF1D0), Usage (0x01) — the two items that make a device
        # a FIDO authenticator to every host tool there is.
        if desc.startswith(b"\x06\xd0\xf1\x09\x01"):
            try:
                fd = os.open(path, os.O_RDWR)
            except PermissionError:
                continue
            return path, fd
    raise SystemExit("no FIDO hidraw device this user can open — is this experiment flashed?")


class Link:
    def __init__(self):
        self.path, self.fd = find_device()

    def send_packet(self, pkt):
        assert len(pkt) == PACKET
        # Linux hidraw wants the report number first. This device uses no
        # numbered reports, so it is zero — and leaving it out is a write that
        # succeeds and delivers 63 bytes of the wrong thing.
        os.write(self.fd, b"\x00" + pkt)

    def read_packet(self, timeout=1.5):
        end = time.time() + timeout
        os.set_blocking(self.fd, False)
        while time.time() < end:
            try:
                d = os.read(self.fd, PACKET)
                if d:
                    return d
            except BlockingIOError:
                time.sleep(0.002)
        return None

    def send_message(self, cid, cmd, data, hold_back=0):
        """Fragment and send. `hold_back` stops short of the byte count the
        header promised, which is how a truncated transaction is built."""
        pkt = bytearray(PACKET)
        pkt[0:4] = cid
        pkt[4] = 0x80 | cmd
        pkt[5:7] = struct.pack(">H", len(data))
        n = min(len(data), INIT_PAYLOAD)
        pkt[INIT_HEADER:INIT_HEADER + n] = data[:n]
        self.send_packet(bytes(pkt))
        sent, seq, packets = n, 0, 1
        while sent < len(data) - hold_back:
            pkt = bytearray(PACKET)
            pkt[0:4] = cid
            pkt[4] = seq
            n = min(len(data) - hold_back - sent, CONT_PAYLOAD)
            pkt[CONT_HEADER:CONT_HEADER + n] = data[sent:sent + n]
            self.send_packet(bytes(pkt))
            sent += n
            seq += 1
            packets += 1
        return packets

    def read_message(self, timeout=1.5):
        first = self.read_packet(timeout)
        if first is None:
            return None
        cid, cmd = first[0:4], first[4]
        if not cmd & 0x80:
            return {"error": "first packet back was a continuation packet"}
        cmd &= 0x7F
        want = struct.unpack(">H", first[5:7])[0]
        data = bytearray(first[INIT_HEADER:INIT_HEADER + min(want, INIT_PAYLOAD)])
        packets, seq = 1, 0
        while len(data) < want:
            nxt = self.read_packet(timeout)
            if nxt is None:
                return {"error": f"message stopped at {len(data)}/{want} bytes"}
            packets += 1
            if nxt[4] != seq:
                return {"error": f"sequence {nxt[4]} where {seq} was due"}
            seq += 1
            data += nxt[CONT_HEADER:CONT_HEADER + min(want - len(data), CONT_PAYLOAD)]
        out = {"cid": cid.hex(), "cmd": cmd, "len": want, "packets": packets}
        if cmd == CTAPHID_ERROR:
            out["error_code"] = data[0]
            out["error_name"] = ERRORS.get(data[0], "unknown")
        else:
            # Truncated on purpose. A 1024-byte PING echoes 2 KB of hex, and a
            # transcript nobody will read is a transcript nobody checks —
            # `echo_matches` below is the claim, and it is computed from all of
            # it. The first 16 bytes are here so a reader can see it is the
            # pattern that was sent and not zeroes.
            out["data_head"] = bytes(data[:16]).hex()
            out["data_sha_len"] = len(data)
            self.last = bytes(data)
        return out


def init(link, cid=BROADCAST, nonce=b"\x01\x02\x03\x04\x05\x06\x07\x08"):
    link.send_message(cid, CTAPHID_INIT, nonce)
    r = link.read_message()
    if r and r.get("cmd") == CTAPHID_INIT:
        d = link.last
        r["nonce_echoed"] = d[:8] == nonce
        r["new_cid"] = d[8:12].hex()
        r["protocol"] = d[12]
        r["capabilities"] = d[16]
    return r


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    case = sys.argv[1]
    link = Link()
    out = {"case": case, "device": link.path}

    if case == "init":
        out["reply"] = init(link)

    elif case == "ping":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        payload = bytes((i * 7 + 3) & 0xFF for i in range(n))
        out["sent_bytes"] = n
        out["sent_packets"] = link.send_message(cid, CTAPHID_PING, payload)
        reply = link.read_message()
        out["reply"] = reply
        if reply and "data_head" in reply:
            out["echo_matches"] = getattr(link, "last", b"") == payload

    elif case == "bad-seq":
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        pkt = bytearray(PACKET)
        pkt[0:4], pkt[4] = cid, 0x80 | CTAPHID_PING
        pkt[5:7] = struct.pack(">H", 200)
        pkt[INIT_HEADER:] = bytes(INIT_PAYLOAD)
        link.send_packet(bytes(pkt))
        pkt = bytearray(PACKET)
        pkt[0:4], pkt[4] = cid, 3       # 0 was due
        link.send_packet(bytes(pkt))
        out["reply"] = link.read_message()

    elif case == "busy":
        a = bytes.fromhex(init(link)["new_cid"])
        b = bytes.fromhex(init(link, nonce=b"\x11" * 8)["new_cid"])
        pkt = bytearray(PACKET)
        pkt[0:4], pkt[4] = a, 0x80 | CTAPHID_PING
        pkt[5:7] = struct.pack(">H", 200)
        link.send_packet(bytes(pkt))          # channel A, unfinished
        link.send_message(b, CTAPHID_PING, b"\x00" * 8)   # channel B interrupts
        out["cid_a"], out["cid_b"] = a.hex(), b.hex()
        out["reply"] = link.read_message()

    elif case == "truncated":
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        out["cid"] = cid.hex()
        link.send_message(cid, CTAPHID_PING, b"\xaa" * 200, hold_back=100)
        out["reply"] = link.read_message(timeout=3.0)

    elif case == "unknown":
        # CTAPHID_MSG, which is CTAP1/U2F. The capability byte says `nomsg`, so
        # this is not merely an unimplemented command — it is the device being
        # checked against its own declaration. exp168 used CTAPHID_CBOR here;
        # this experiment implements that, which is the point.
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        link.send_message(cid, CTAPHID_MSG, b"\x00\x01\x03\x00")
        out["reply"] = link.read_message()

    elif case.startswith("ga-"):
        rp_id = "example.test"
        cred_id, x, y = register(link, rp_id)
        out["registered_credential_id"] = cred_id.hex()
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])

        forged = bytearray(cred_id)
        forged[40] ^= 0xFF                     # one byte of the tag
        short = cred_id[:32]                   # nonce only, no tag
        kw = {
            "ga-roundtrip": dict(allow=[cred_id]),
            "ga-forged": dict(allow=[bytes(forged)]),
            "ga-other-rp": dict(rp_id="other.test", allow=[cred_id]),
            "ga-wrong-length": dict(allow=[short]),
            "ga-empty-allow": dict(allow=[]),
            "ga-no-allow": dict(no_allow=True),
            # A real credential behind two decoys: the device has to walk past
            # both without deriving anything for them.
            "ga-decoys": dict(allow=[bytes(forged), short, cred_id]),
        }[case]
        ask_rp = kw.pop("rp_id", rp_id)
        body_cbor, cdh = get_assertion_request(rp_id=ask_rp, **kw)
        out["asked_rp"] = ask_rp
        link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_GET_ASSERTION]) + body_cbor)
        reply = link.read_message(timeout=15.0)
        out["reply"] = reply
        if reply and "data_head" in reply:
            data = link.last
            out["status"] = data[0]
            out["status_name"] = CTAP2_STATUS.get(data[0], f"unknown ({data[0]:#04x})")
            if data[0] == 0x00:
                out["assertion"] = check_assertion(data[1:], ask_rp, cdh, x, y, cred_id)
            else:
                out["cbor"] = data[1:].hex()

    elif case.startswith("mc-"):
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        kw = {
            "mc-good": {},
            # A byte string that says it is 200 bytes long inside a message that
            # is not. A reader that trusts the length reads whatever is next.
            "mc-lying-length": {"claim_cdh": 200},
            "mc-noncanonical": {"noncanonical": True},
            "mc-trailing": {"trailing": True},
            "mc-missing-cdh": {"drop_cdh": True},
            "mc-missing-params": {"drop_params": True},
            # RS256 only: understood, and not something this device would use.
            "mc-no-es256": {"algs": [-257]},
            "mc-many-algs": {"algs": [-7, -35, -36, -257, -258, -259, -37, -38, -39, -8]},
        }[case]
        cdh = bytes(range(32))
        rp_id = "example.test"
        body = bytes([AUTHENTICATOR_MAKE_CREDENTIAL]) + make_credential_request(**kw)
        out["request_bytes"] = len(body)
        link.send_message(cid, CTAPHID_CBOR, body)
        reply = link.read_message(timeout=15.0)
        out["reply"] = reply
        if reply and "data_head" in reply:
            data = link.last
            out["status"] = data[0]
            out["status_name"] = CTAP2_STATUS.get(data[0], f"unknown ({data[0]:#04x})")
            out["response_bytes"] = len(data) - 1
            if data[0] == 0x00:
                out["credential"] = check_credential(data[1:], rp_id, cdh)
            else:
                out["cbor"] = data[1:].hex()

    elif case in ("getinfo", "getinfo-params", "makecred", "ctap-unknown"):
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        body = {
            "getinfo": bytes([AUTHENTICATOR_GET_INFO]),
            # getInfo takes no parameters, so anything after the command byte
            # is a length error rather than something to ignore.
            "getinfo-params": bytes([AUTHENTICATOR_GET_INFO, 0xA0]),
            "makecred": bytes([AUTHENTICATOR_MAKE_CREDENTIAL]),
            "ctap-unknown": bytes([0xEE]),
        }[case]
        link.send_message(cid, CTAPHID_CBOR, body)
        reply = link.read_message()
        out["reply"] = reply
        if reply and "data_head" in reply:
            data = link.last
            out["status"] = data[0]
            out["status_name"] = CTAP2_STATUS.get(data[0], f"unknown ({data[0]:#04x})")
            out["cbor"] = data[1:].hex()

    elif case == "stray-cont":
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        pkt = bytearray(PACKET)
        pkt[0:4], pkt[4] = cid, 0
        link.send_packet(bytes(pkt))
        out["reply"] = link.read_message(timeout=0.8)
        out["silence_expected"] = True

    else:
        raise SystemExit(f"unknown case: {case}")

    print(json.dumps(out))


if __name__ == "__main__":
    main()
