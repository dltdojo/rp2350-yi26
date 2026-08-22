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
import os
import struct
import sys
import time

PACKET = 64
INIT_HEADER, CONT_HEADER = 7, 5
INIT_PAYLOAD, CONT_PAYLOAD = PACKET - INIT_HEADER, PACKET - CONT_HEADER
BROADCAST = b"\xff\xff\xff\xff"

CTAPHID_PING, CTAPHID_MSG, CTAPHID_INIT, CTAPHID_CBOR, CTAPHID_ERROR = 1, 3, 6, 0x10, 0x3F
ERRORS = {
    0x01: "ERR_INVALID_CMD", 0x02: "ERR_INVALID_PAR", 0x03: "ERR_INVALID_LEN",
    0x04: "ERR_INVALID_SEQ", 0x05: "ERR_MSG_TIMEOUT", 0x06: "ERR_CHANNEL_BUSY",
    0x0B: "ERR_INVALID_CHANNEL", 0x7F: "ERR_OTHER",
}


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
    raise SystemExit("no FIDO hidraw device this user can open — is exp168 flashed?")


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
        r = init(link)
        cid = bytes.fromhex(r["new_cid"])
        link.send_message(cid, CTAPHID_CBOR, b"\x04")   # authenticatorGetInfo
        out["reply"] = link.read_message()

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
