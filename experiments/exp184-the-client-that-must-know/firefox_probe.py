#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Simulate Firefox and strict WebAuthn clients probing CTAP 2.1 clientPIN.

    python3 firefox_probe.py

Proves:
1. getInfo returns FIDO_2_1 and options: { clientPin: false, up: true, rk: false }
2. authenticatorClientPIN (0x06) subCommand 0x01 (getPinRetries) returns 8 retries and OK (0x00)
3. authenticatorClientPIN (0x06) subCommand 0x02 (getKeyAgreement) returns PIN_NOT_SET (0x35)
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

CTAPHID_INIT = 0x06
CTAPHID_CBOR = 0x10
CTAPHID_ERROR = 0x3F

AUTHENTICATOR_MAKE_CREDENTIAL = 0x01
AUTHENTICATOR_GET_ASSERTION = 0x02
AUTHENTICATOR_GET_INFO = 0x04
AUTHENTICATOR_CLIENT_PIN = 0x06

def find_device():
    for name in sorted(os.listdir("/dev")):
        if not name.startswith("hidraw"):
            continue
        path = f"/dev/{name}"
        try:
            desc = open(f"/sys/class/hidraw/{name}/device/report_descriptor", "rb").read()
        except OSError:
            continue
        if desc.startswith(b"\x06\xd0\xf1\x09\x01"):
            try:
                fd = os.open(path, os.O_RDWR)
                return path, fd
            except PermissionError:
                continue
    raise SystemExit("no FIDO hidraw device found or accessible")

class Link:
    def __init__(self):
        self.path, self.fd = find_device()

    def drain(self):
        os.set_blocking(self.fd, False)
        while True:
            try:
                if not os.read(self.fd, PACKET):
                    break
            except (BlockingIOError, OSError):
                break

    def send_packet(self, pkt):
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

    def send_message(self, cid, cmd, data):
        pkt = bytearray(PACKET)
        pkt[0:4] = cid
        pkt[4] = 0x80 | cmd
        pkt[5:7] = struct.pack(">H", len(data))
        n = min(len(data), INIT_PAYLOAD)
        pkt[INIT_HEADER:INIT_HEADER + n] = data[:n]
        self.send_packet(bytes(pkt))
        sent, seq = n, 0
        while sent < len(data):
            pkt = bytearray(PACKET)
            pkt[0:4] = cid
            pkt[4] = seq
            n = min(len(data) - sent, CONT_PAYLOAD)
            pkt[CONT_HEADER:CONT_HEADER + n] = data[sent:sent + n]
            self.send_packet(bytes(pkt))
            sent += n
            seq += 1

    def read_message(self, timeout=1.5):
        first = self.read_packet(timeout)
        if first is None:
            return None
        cid, cmd = first[0:4], first[4] & 0x7F
        want = struct.unpack(">H", first[5:7])[0]
        data = bytearray(first[INIT_HEADER:INIT_HEADER + min(want, INIT_PAYLOAD)])
        seq = 0
        while len(data) < want:
            nxt = self.read_packet(timeout)
            if nxt is None or nxt[4] != seq:
                return None
            seq += 1
            data += nxt[CONT_HEADER:CONT_HEADER + min(want - len(data), CONT_PAYLOAD)]
        return bytes(data)

def cbor_decode(b, at=0):
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
        return b[at:at + arg].decode("utf-8", "replace"), at + arg
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
    if mt == 7:
        if arg == 20:
            return False, at
        if arg == 21:
            return True, at
        return f"simple({arg})", at
    raise ValueError(f"major type {mt}")

def run_probe():
    link = Link()
    link.drain()
    
    # 1. INIT
    nonce = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0"
    link.send_message(BROADCAST, CTAPHID_INIT, nonce)
    init_resp = link.read_message()
    if not init_resp or init_resp[:8] != nonce:
        raise SystemExit("INIT failed")
    cid = init_resp[8:12]
    
    # 2. getInfo (0x04)
    link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_GET_INFO]))
    info_raw = link.read_message()
    if not info_raw or info_raw[0] != 0x00:
        raise SystemExit(f"getInfo failed: {info_raw}")
    info, _ = cbor_decode(info_raw[1:])
    
    # 3. authenticatorClientPIN: subCommand 0x01 (getPinRetries)
    # CBOR: { 0x02: 0x01 } -> a1 02 01
    pin_retries_req = bytes([AUTHENTICATOR_CLIENT_PIN, 0xA1, 0x02, 0x01])
    link.send_message(cid, CTAPHID_CBOR, pin_retries_req)
    retries_raw = link.read_message()
    if not retries_raw or retries_raw[0] != 0x00:
        raise SystemExit(f"getPinRetries failed: {retries_raw}")
    retries_map, _ = cbor_decode(retries_raw[1:])
    
    # 4. authenticatorClientPIN: subCommand 0x02 (getKeyAgreement)
    # CBOR: { 0x02: 0x02 } -> a1 02 02
    key_agreement_req = bytes([AUTHENTICATOR_CLIENT_PIN, 0xA1, 0x02, 0x02])
    link.send_message(cid, CTAPHID_CBOR, key_agreement_req)
    key_ag_raw = link.read_message()
    
    result = {
        "device": link.path,
        "versions": info.get(1, []),
        "options": info.get(4, {}),
        "pin_protocols": info.get(6, []),
        "pin_retries_status": retries_raw[0],
        "pin_retries_map": retries_map,
        "key_agreement_status": key_ag_raw[0] if key_ag_raw else None,
        "fido_2_1_supported": "FIDO_2_1" in info.get(1, []),
        "client_pin_option": info.get(4, {}).get("clientPin"),
        "pin_retries_remaining": retries_map.get(3),
    }
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    run_probe()

