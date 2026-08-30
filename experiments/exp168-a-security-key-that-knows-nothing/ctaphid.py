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
    unknown        a command this device does not implement
    stray-cont     a continuation packet for a transaction nobody started

Prints one JSON object per exchange. Nothing here parses CBOR, because there
is no CBOR: this device knows nothing.
"""

import json
import struct
import sys
from pathlib import Path

# **The transport is `tools/ctaphid/`, not a copy of it here.**
#
# This file wrote the first one, and six experiments after it each derived their
# own: seven copies between 238 and 689 lines. Comparing them found exactly one
# substantive difference, and it was a *fix* that had never propagated —
# exp174's `Link.drain()`, which throws away keepalive packets left in the
# kernel's buffer by a previous run. Six clients did not have it, including this
# one. That is the argument for there being one, made by the copies themselves.
#
# What stays here is this experiment's own cases, which is what it was ever
# about.
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
        r = link.init()
        cid = bytes.fromhex(r["new_cid"])
        link.send_message(cid, CTAPHID_CBOR, b"\x04")   # authenticatorGetInfo
        out["reply"] = link.read_message()

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
