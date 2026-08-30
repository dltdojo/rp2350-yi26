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

Prints one JSON object per exchange. Nothing here parses CBOR, because there
is no CBOR: this device knows nothing.
"""

import hashlib
import json
import struct
import sys
from pathlib import Path
import time

# **The transport and the WebAuthn layer both live in `tools/ctaphid/`.**
#
# exp168 wrote the first of these clients and six experiments after it each
# derived their own: seven copies between 238 and 689 lines. Comparing them
# found exactly one substantive difference in the transport, and it was a *fix*
# that had never propagated — exp174's `Link.drain()`, which throws away
# keepalive packets a previous run left in the kernel's buffer. Six did not have
# it.
#
# The CBOR and WebAuthn half had no divergence at all: every one of those
# functions was byte-identical in every experiment that had it. Moving that half
# is the one extraction here that cannot change behaviour.
#
# What stays below is this experiment's own cases.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "ctaphid"))

from ctaphid import (  # noqa: E402
    BROADCAST,
    CONT_HEADER,
    CTAPHID_CBOR,
    CTAPHID_ERROR,
    CTAPHID_INIT,
    CTAPHID_MSG,
    CTAPHID_PING,
    ERRORS,
    INIT_HEADER,
    INIT_PAYLOAD,
    PACKET,
    Link,
)

from webauthn import (  # noqa: E402
    cbor_array,
    cbor_bytes,
    cbor_decode,
    cbor_map,
    cbor_nint,
    cbor_text,
    cbor_uint,
    check_credential,
    head,
    make_credential_request,
)


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

# --------------------------------------------------------------------------
# The relying party's half. exp159's rule: the signature is checked by a
# different implementation from the one that made it, and a bit is flipped and
# the check required to fail before the pass is reported.
# --------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    case = sys.argv[1]
    link = Link()
    out = {"case": case, "device": link.path}

    if case == "init":
        out["reply"] = link.init()

    elif case == "ping":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
        r = link.init()
        cid = bytes.fromhex(r["new_cid"])
        payload = bytes((i * 7 + 3) & 0xFF for i in range(n))
        out["sent_bytes"] = n
        out["sent_packets"] = link.send_message(cid, CTAPHID_PING, payload)
        reply = link.read_message()
        out["reply"] = reply
        if reply and "data_head" in reply:
            out["echo_matches"] = getattr(link, "last", b"") == payload

    elif case == "bad-seq":
        r = link.init()
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
        a = bytes.fromhex(link.init()["new_cid"])
        b = bytes.fromhex(link.init(nonce=b"\x11" * 8)["new_cid"])
        pkt = bytearray(PACKET)
        pkt[0:4], pkt[4] = a, 0x80 | CTAPHID_PING
        pkt[5:7] = struct.pack(">H", 200)
        link.send_packet(bytes(pkt))          # channel A, unfinished
        link.send_message(b, CTAPHID_PING, b"\x00" * 8)   # channel B interrupts
        out["cid_a"], out["cid_b"] = a.hex(), b.hex()
        out["reply"] = link.read_message()

    elif case == "truncated":
        r = link.init()
        cid = bytes.fromhex(r["new_cid"])
        out["cid"] = cid.hex()
        link.send_message(cid, CTAPHID_PING, b"\xaa" * 200, hold_back=100)
        out["reply"] = link.read_message(timeout=3.0)

    elif case == "unknown":
        # CTAPHID_MSG, which is CTAP1/U2F. The capability byte says `nomsg`, so
        # this is not merely an unimplemented command — it is the device being
        # checked against its own declaration. exp168 used CTAPHID_CBOR here;
        # this experiment implements that, which is the point.
        r = link.init()
        cid = bytes.fromhex(r["new_cid"])
        link.send_message(cid, CTAPHID_MSG, b"\x00\x01\x03\x00")
        out["reply"] = link.read_message()

    elif case.startswith("mc-"):
        r = link.init()
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
        r = link.init()
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
        r = link.init()
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
