#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp185 PIN Protocol 1 test probe.
Verifies:
1. getInfo (FIDO_2_1, pinUvAuthProtocols: [1])
2. getPinRetries (subCommand 0x01 -> { 3: 8 })
3. getKeyAgreement (subCommand 0x02 -> authenticator P-256 COSE_Key)
4. ECDH shared secret derivation (SHA-256 of P-256 x-coordinate)
5. AES-256-CBC encryption & HMAC-SHA256 (16B truncated) pinAuth tunnel verification
6. Negative test: corrupted pinAuth correctly rejected with CTAP2_ERR_PIN_AUTH_INVALID (0x32)
"""

import glob
import hashlib
import hmac
import json
import os
import struct
import sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

CTAPHID_INIT = 0x06
CTAPHID_CBOR = 0x10
CTAPHID_BROADCAST_CID = 0xFFFFFFFF
AUTHENTICATOR_GET_INFO = 0x04
AUTHENTICATOR_CLIENT_PIN = 0x06

CTAP2_OK = 0x00
CTAP2_ERR_PIN_AUTH_INVALID = 0x32

class FidoLink:
    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)

    def close(self):
        os.close(self.fd)

    def send_message(self, cid, cmd, data):
        seq = 0
        total = len(data)
        init_pkt = struct.pack(">IBH", cid, 0x80 | cmd, total) + data[:57]
        init_pkt = init_pkt.ljust(64, b"\x00")
        os.write(self.fd, b"\x00" + init_pkt)
        offset = 57
        while offset < total:
            cont_data = data[offset:offset + 59]
            cont_pkt = struct.pack(">IB", cid, seq) + cont_data
            cont_pkt = cont_pkt.ljust(64, b"\x00")
            os.write(self.fd, b"\x00" + cont_pkt)
            offset += 59
            seq += 1

    def read_message(self, timeout=2.0):
        import time
        start = time.time()
        chunks = []
        expected_len = None
        while time.time() - start < timeout:
            try:
                pkt = os.read(self.fd, 64)
            except BlockingIOError:
                time.sleep(0.005)
                continue
            if len(pkt) < 64:
                continue
            cid, cmd_or_seq = struct.unpack(">IB", pkt[:5])
            if cmd_or_seq & 0x80:
                bcnt = struct.unpack(">H", pkt[5:7])[0]
                expected_len = bcnt
                chunks.append(pkt[7:7 + min(bcnt, 57)])
            else:
                if expected_len is not None:
                    remaining = expected_len - sum(len(c) for c in chunks)
                    chunks.append(pkt[5:5 + min(remaining, 59)])
            if expected_len is not None and sum(len(c) for c in chunks) >= expected_len:
                return b"".join(chunks)[:expected_len]
        return None

def cbor_decode(data, offset=0):
    if offset >= len(data):
        raise ValueError("EOF")
    fb = data[offset]
    major = fb >> 5
    info = fb & 0x1F
    offset += 1

    if info < 24:
        val = info
    elif info == 24:
        val = data[offset]; offset += 1
    elif info == 25:
        val = struct.unpack(">H", data[offset:offset+2])[0]; offset += 2
    elif info == 26:
        val = struct.unpack(">I", data[offset:offset+4])[0]; offset += 4
    elif info == 27:
        val = struct.unpack(">Q", data[offset:offset+8])[0]; offset += 8
    else:
        val = None

    if major == 0:
        return val, offset
    elif major == 1:
        return -1 - val, offset
    elif major == 2:
        res = data[offset:offset+val]
        return res, offset + val
    elif major == 3:
        res = data[offset:offset+val].decode('utf-8', errors='replace')
        return res, offset + val
    elif major == 4:
        arr = []
        for _ in range(val):
            item, offset = cbor_decode(data, offset)
            arr.append(item)
        return arr, offset
    elif major == 5:
        m = {}
        for _ in range(val):
            k, offset = cbor_decode(data, offset)
            v, offset = cbor_decode(data, offset)
            m[k] = v
        return m, offset
    elif major == 7:
        if info == 20: return False, offset
        if info == 21: return True, offset
        if info == 22: return None, offset
        return val, offset
    raise ValueError(f"Unsupported major {major}")

def cbor_encode(val):
    if isinstance(val, int):
        if val >= 0:
            if val < 24: return bytes([val])
            elif val < 0x100: return bytes([24, val])
            elif val < 0x10000: return struct.pack(">BH", 25, val)
            elif val < 0x100000000: return struct.pack(">BI", 26, val)
            else: return struct.pack(">BQ", 27, val)
        else:
            val = -1 - val
            if val < 24: return bytes([0x20 | val])
            elif val < 0x100: return bytes([0x20 | 24, val])
            elif val < 0x10000: return struct.pack(">BH", 0x20 | 25, val)
            else: return struct.pack(">BI", 0x20 | 26, val)
    elif isinstance(val, bytes):
        l = len(val)
        if l < 24: head = bytes([0x40 | l])
        elif l < 0x100: head = bytes([0x40 | 24, l])
        else: head = struct.pack(">BH", 0x40 | 25, l)
        return head + val
    elif isinstance(val, str):
        b = val.encode('utf-8')
        l = len(b)
        if l < 24: head = bytes([0x60 | l])
        elif l < 0x100: head = bytes([0x60 | 24, l])
        else: head = struct.pack(">BH", 0x60 | 25, l)
        return head + b
    elif isinstance(val, list):
        l = len(val)
        if l < 24: head = bytes([0x80 | l])
        elif l < 0x100: head = bytes([0x80 | 24, l])
        else: head = struct.pack(">BH", 0x80 | 25, l)
        return head + b"".join(cbor_encode(x) for x in val)
    elif isinstance(val, dict):
        l = len(val)
        if l < 24: head = bytes([0xA0 | l])
        elif l < 0x100: head = bytes([0xA0 | 24, l])
        else: head = struct.pack(">BH", 0xA0 | 25, l)
        items = b""
        for k, v in val.items():
            items += cbor_encode(k) + cbor_encode(v)
        return head + items
    elif isinstance(val, bool):
        return bytes([0xF5 if val else 0xF4])
    raise ValueError(f"Cannot encode {type(val)}")

def find_fido_device():
    for dev in sorted(glob.glob("/dev/hidraw*")):
        try:
            link = FidoLink(dev)
            nonce = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0"
            link.send_message(CTAPHID_BROADCAST_CID, CTAPHID_INIT, nonce)
            resp = link.read_message(timeout=0.3)
            if resp and len(resp) >= 17 and resp[:8] == nonce:
                cid = struct.unpack(">I", resp[8:12])[0]
                return link, cid
            link.close()
        except Exception:
            continue
    return None, None

def run_test():
    link, cid = find_fido_device()
    if not link:
        print(json.dumps({"error": "no_device_found"}))
        return

    # 1. getInfo
    link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_GET_INFO]))
    info_raw = link.read_message()
    if not info_raw or info_raw[0] != 0x00:
        raise SystemExit(f"getInfo failed: {info_raw}")
    info, _ = cbor_decode(info_raw[1:])

    # 2. getPinRetries (subCommand 0x01)
    link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_CLIENT_PIN, 0xA1, 0x02, 0x01]))
    retries_raw = link.read_message()
    retries_map, _ = cbor_decode(retries_raw[1:]) if retries_raw and retries_raw[0] == 0x00 else ({}, 0)

    # 3. getKeyAgreement (subCommand 0x02)
    link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_CLIENT_PIN, 0xA1, 0x02, 0x02]))
    ag_raw = link.read_message()
    if not ag_raw or ag_raw[0] != 0x00:
        raise SystemExit(f"getKeyAgreement failed: {ag_raw}")
    ag_map, _ = cbor_decode(ag_raw[1:])
    auth_cose_key = ag_map[1]
    auth_x = auth_cose_key[-2]
    auth_y = auth_cose_key[-3]

    # 4. Client generates ephemeral P-256 keypair
    client_sk = ec.generate_private_key(ec.SECP256R1())
    client_pk = client_sk.public_key()
    client_pt = client_pk.public_numbers()
    client_x = client_pt.x.to_bytes(32, 'big')
    client_y = client_pt.y.to_bytes(32, 'big')

    # Construct peer public key object for authenticator
    auth_pk_numbers = ec.EllipticCurvePublicNumbers(
        int.from_bytes(auth_x, 'big'),
        int.from_bytes(auth_y, 'big'),
        ec.SECP256R1()
    )
    auth_pk = auth_pk_numbers.public_key()

    # 5. Compute ECDH Shared Secret: SHA-256(raw x-coordinate)
    shared_ecdh = client_sk.exchange(ec.ECDH(), auth_pk)
    shared_secret = hashlib.sha256(shared_ecdh).digest()

    # 6. Encrypt test PIN (64 bytes) with AES-256-CBC (zero IV)
    test_pin = b"123456".ljust(64, b"\x00")
    cipher = Cipher(algorithms.AES(shared_secret), modes.CBC(b"\x00" * 16))
    encryptor = cipher.encryptor()
    new_pin_enc = encryptor.update(test_pin) + encryptor.finalize()

    # 7. Compute pinAuth: HMAC-SHA256(sharedSecret, newPinEnc)[0..16]
    h = hmac.new(shared_secret, new_pin_enc, hashlib.sha256)
    pin_auth = h.digest()[:16]

    # 8. Send setPIN / test tunnel request (subCommand 0x03)
    client_cose_key = {
        1: 2,   # kty: EC2
        -1: 1,  # crv: P-256
        -2: client_x,
        -3: client_y,
    }
    req_map = {
        1: 1,                 # pinProtocol 1
        2: 3,                 # subCommand 3 (setPIN / test tunnel)
        3: client_cose_key,   # keyAgreement
        4: pin_auth,          # pinAuth
        5: new_pin_enc,       # newPinEnc
    }
    cbor_req = bytes([AUTHENTICATOR_CLIENT_PIN]) + cbor_encode(req_map)
    link.send_message(cid, CTAPHID_CBOR, cbor_req)
    tunnel_resp = link.read_message()
    tunnel_status = tunnel_resp[0] if tunnel_resp else None

    # 9. Negative Test: Corrupted pinAuth
    bad_req_map = dict(req_map)
    bad_req_map[4] = bytes([b ^ 0xFF for b in pin_auth])
    cbor_bad_req = bytes([AUTHENTICATOR_CLIENT_PIN]) + cbor_encode(bad_req_map)
    link.send_message(cid, CTAPHID_CBOR, cbor_bad_req)
    bad_resp = link.read_message()
    bad_status = bad_resp[0] if bad_resp else None

    result = {
        "device": link.path,
        "versions": info.get(1, []),
        "options": info.get(4, {}),
        "pin_protocols": info.get(6, []),
        "pin_retries_status": retries_raw[0] if retries_raw else None,
        "pin_retries_remaining": retries_map.get(3),
        "key_agreement_status": ag_raw[0] if ag_raw else None,
        "ecdh_shared_secret_prefix": shared_secret[:8].hex(),
        "tunnel_verify_status": tunnel_status,
        "tunnel_verify_ok": tunnel_status == CTAP2_OK,
        "bad_auth_status": bad_status,
        "bad_auth_rejected": bad_status == CTAP2_ERR_PIN_AUTH_INVALID,
    }
    print(json.dumps(result, indent=2))
    link.close()

if __name__ == "__main__":
    run_test()

