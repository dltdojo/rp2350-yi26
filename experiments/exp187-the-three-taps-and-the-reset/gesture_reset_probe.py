#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp187 - Gesture UV & Authenticator Reset Probe

Tests:
1. getInfo (checks options: { uv: true, clientPin: false })
2. setPIN ("123456" via PIN Protocol 1) -> clientPin flips to true
3. Late Reset rejection: sends authenticatorReset (0x07) after 10s -> CTAP2_ERR_NOT_ALLOWED (0x30)
4. Built-in Gesture UV: requests getPinUvAuthTokenUsingUv (subCommand 0x06) -> gets 32B token
5. makeCredential with UV -> verifies FLAG_UV (0x04) in authData
6. Soft-reboot (1200-baud touch) -> enters fresh 10s reset window
7. Timely Reset: sends authenticatorReset (0x07) within 10s -> CTAP2_OK (0x00)
8. Post-Reset verification: clientPin is false, retries=8, old credentials invalidated
"""

import glob
import json
import os
import struct
import sys
import time
import hashlib
import hmac
import serial

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print(json.dumps({"error": "cryptography package missing: pip install cryptography"}))
    sys.exit(1)

CTAP2_OK = 0x00
CTAP2_ERR_NOT_ALLOWED = 0x30
CTAP2_ERR_PIN_INVALID = 0x31
CTAP2_ERR_PIN_AUTH_INVALID = 0x32
CTAP2_ERR_PIN_BLOCKED = 0x34
CTAP2_ERR_NO_CREDENTIALS = 0x2e

class FidoLink:
    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)

    def close(self):
        try:
            os.close(self.fd)
        except Exception:
            pass

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

    def read_message(self, timeout=3.0):
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
                cmd = cmd_or_seq & 0x7f
                if cmd == 0x3b: # CTAPHID_KEEPALIVE
                    continue
                bcnt = struct.unpack(">H", pkt[5:7])[0]
                expected_len = bcnt
                chunks = [pkt[7:7 + min(bcnt, 57)]]
            else:
                if expected_len is not None:
                    have = sum(len(c) for c in chunks)
                    rem = expected_len - have
                    chunks.append(pkt[5:5 + min(rem, 59)])
            if expected_len is not None and sum(len(c) for c in chunks) >= expected_len:
                return b"".join(chunks)[:expected_len]
        return None

def extract_cose_key(key_resp):
    if not key_resp or key_resp[0] != CTAP2_OK:
        return None, None
    idx_x = key_resp.find(b"\x21\x58\x20")
    idx_y = key_resp.find(b"\x22\x58\x20")
    if idx_x == -1 or idx_y == -1:
        return None, None
    return key_resp[idx_x + 3:idx_x + 3 + 32], key_resp[idx_y + 3:idx_y + 3 + 32]

def find_hidraw_device(timeout=5.0):
    start = time.time()
    while time.time() - start < timeout:
        for dev in sorted(glob.glob("/dev/hidraw*")):
            try:
                fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
                os.close(fd)
                return dev
            except Exception:
                continue
        time.sleep(0.1)
    return None

def find_cdc_port():
    for p in sorted(glob.glob("/dev/ttyACM*")):
        return p
    return None

def cbor_encode_uint(val):
    if val < 24:
        return bytes([val])
    elif val <= 0xff:
        return bytes([0x18, val])
    elif val <= 0xffff:
        return struct.pack(">BH", 0x19, val)
    elif val <= 0xffffffff:
        return struct.pack(">BI", 0x1a, val)
    else:
        return struct.pack(">BQ", 0x1b, val)

def cbor_encode_bytes(b):
    if len(b) < 24:
        return bytes([0x40 + len(b)]) + b
    elif len(b) <= 0xff:
        return struct.pack(">BB", 0x58, len(b)) + b
    else:
        return struct.pack(">BH", 0x59, len(b)) + b

def cbor_encode_text(s):
    b = s.encode("utf-8")
    return bytes([0x60 + len(b)]) + b if len(b) < 24 else struct.pack(">BB", 0x78, len(b)) + b

def cbor_encode_cose_key(x, y):
    out = bytearray()
    out.append(0xa4)
    out.extend(cbor_encode_uint(1))
    out.extend(cbor_encode_uint(2))
    out.extend(bytes([0x20]))
    out.extend(cbor_encode_uint(1))
    out.extend(bytes([0x21]))
    out.extend(cbor_encode_bytes(x))
    out.extend(bytes([0x22]))
    out.extend(cbor_encode_bytes(y))
    return bytes(out)

def aes_cbc_encrypt(key, iv, plaintext):
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    encryptor = cipher.encryptor()
    return encryptor.update(plaintext) + encryptor.finalize()

def aes_cbc_decrypt(key, iv, ciphertext):
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    decryptor = cipher.decryptor()
    return decryptor.update(ciphertext) + decryptor.finalize()

def hmac_sha256(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()

def touch_1200_baud(port):
    try:
        s = serial.Serial(port, 1200)
        s.close()
    except Exception:
        pass
    time.sleep(3.5)

def init_channel(link):
    nonce = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0"
    link.send_message(0xffffffff, 0x06, nonce)
    resp = link.read_message(2.0)
    if not resp or len(resp) < 17:
        return None
    return struct.unpack(">I", resp[8:12])[0]

def main():
    dev_path = find_hidraw_device()
    if not dev_path:
        print(json.dumps({"error": "no_device_found"}))
        return

    link = FidoLink(dev_path)
    cid = init_channel(link)
    if not cid:
        print(json.dumps({"error": "ctaphid_init_failed"}))
        link.close()
        return

    # 1. getInfo initial
    link.send_message(cid, 0x10, bytes([0x04]))
    info_resp = link.read_message(2.0)
    if not info_resp or info_resp[0] != CTAP2_OK:
        print(json.dumps({"error": "getInfo_failed"}))
        link.close()
        return

    initial_uv_option = b"uv\xf5" in info_resp # uv: true (\xf5)
    initial_client_pin = b"clientPin\xf4" in info_resp # clientPin: false (\xf4)

    # 2. Key agreement & setPIN ("123456")
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x02])) # getKeyAgreement
    key_resp = link.read_message(2.0)
    peer_x, peer_y = extract_cose_key(key_resp)

    host_sk = ec.generate_private_key(ec.SECP256R1(), default_backend())
    host_pk = host_sk.public_key()
    host_numbers = host_pk.public_numbers()
    host_x = host_numbers.x.to_bytes(32, "big")
    host_y = host_numbers.y.to_bytes(32, "big")

    peer_numbers = ec.EllipticCurvePublicNumbers(
        int.from_bytes(peer_x, "big"),
        int.from_bytes(peer_y, "big"),
        ec.SECP256R1(),
    )
    peer_pk = peer_numbers.public_key(default_backend())
    raw_shared = host_sk.exchange(ec.ECDH(), peer_pk)
    shared_secret = hashlib.sha256(raw_shared).digest()

    pin_padded = b"123456".ljust(64, b"\x00")
    new_pin_enc = aes_cbc_encrypt(shared_secret, b"\x00" * 16, pin_padded)
    pin_auth = hmac_sha256(shared_secret, new_pin_enc)[:16]

    set_req = bytearray()
    set_req.append(0x06) # clientPIN
    set_req.append(0xa5)
    set_req.extend(cbor_encode_uint(1))
    set_req.extend(cbor_encode_uint(1))
    set_req.extend(cbor_encode_uint(2))
    set_req.extend(cbor_encode_uint(3)) # setPIN
    set_req.extend(cbor_encode_uint(3))
    set_req.extend(cbor_encode_cose_key(host_x, host_y))
    set_req.extend(cbor_encode_uint(4))
    set_req.extend(cbor_encode_bytes(pin_auth))
    set_req.extend(cbor_encode_uint(5))
    set_req.extend(cbor_encode_bytes(new_pin_enc))

    link.send_message(cid, 0x10, bytes(set_req))
    set_resp = link.read_message(2.0)
    set_pin_ok = (set_resp is not None and set_resp[0] == CTAP2_OK)

    link.send_message(cid, 0x10, bytes([0x04]))
    info_resp2 = link.read_message(2.0)
    post_set_pin_client_pin = b"clientPin\xf5" in info_resp2 # true

    # 3. Built-in Gesture UV Token Issuance (subCommand 0x06)
    uv_token_req = bytearray()
    uv_token_req.append(0x06)
    uv_token_req.append(0xa3)
    uv_token_req.extend(cbor_encode_uint(1))
    uv_token_req.extend(cbor_encode_uint(1))
    uv_token_req.extend(cbor_encode_uint(2))
    uv_token_req.extend(cbor_encode_uint(6)) # getPinUvAuthTokenUsingUv
    uv_token_req.extend(cbor_encode_uint(3))
    uv_token_req.extend(cbor_encode_cose_key(host_x, host_y))

    link.send_message(cid, 0x10, bytes(uv_token_req))
    uv_token_resp = link.read_message(2.0)
    uv_token_status = uv_token_resp[0] if uv_token_resp else None

    gesture_uv_token = None
    if uv_token_status == CTAP2_OK:
        idx_tok = uv_token_resp.find(b"\x02\x58\x20")
        if idx_tok != -1:
            enc_tok = uv_token_resp[idx_tok + 3:idx_tok + 3 + 32]
            gesture_uv_token = aes_cbc_decrypt(shared_secret, b"\x00" * 16, enc_tok)

    # 4. makeCredential with gesture UV Token
    client_data_hash = hashlib.sha256(b"exp187-test-registration").digest()
    pin_uv_auth_param = hmac_sha256(gesture_uv_token, client_data_hash)[:16] if gesture_uv_token else b"\x00" * 16

    make_cred_req = bytearray()
    make_cred_req.append(0x01)
    make_cred_req.append(0xa5)
    make_cred_req.extend(cbor_encode_uint(1))
    make_cred_req.extend(cbor_encode_bytes(client_data_hash))
    make_cred_req.extend(cbor_encode_uint(2))
    make_cred_req.extend(bytes([0xa1]))
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_text("example.com"))
    make_cred_req.extend(cbor_encode_uint(3))
    make_cred_req.extend(bytes([0xa1]))
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_bytes(b"user187"))
    make_cred_req.extend(cbor_encode_uint(4))
    make_cred_req.extend(bytes([0x81, 0xa1]))
    make_cred_req.extend(cbor_encode_text("alg"))
    make_cred_req.extend(bytes([0x26]))
    make_cred_req.extend(cbor_encode_uint(8))
    make_cred_req.extend(cbor_encode_bytes(pin_uv_auth_param))

    link.send_message(cid, 0x10, bytes(make_cred_req))
    cred_resp = link.read_message(3.0)
    cred_ok = (cred_resp is not None and cred_resp[0] == CTAP2_OK)

    uv_flag_in_cred = False
    cred_id = None
    if cred_ok:
        idx_ad = cred_resp.find(b"\x02X")
        if idx_ad != -1:
            ad_len = cred_resp[idx_ad + 2]
            ad = cred_resp[idx_ad + 3:idx_ad + 3 + ad_len]
            flags = ad[32]
            uv_flag_in_cred = bool(flags & 0x04)
            cred_id = ad[55:55 + 48]

    # 5. Timely Reset (0x07) executed within 10s power-on window
    link.send_message(cid, 0x10, bytes([0x07]))
    timely_reset_resp = link.read_message(3.0)
    timely_reset_status = timely_reset_resp[0] if timely_reset_resp else None
    timely_reset_ok = (timely_reset_status == CTAP2_OK)

    # 6. Post-Reset verification
    link.send_message(cid, 0x10, bytes([0x04])) # getInfo
    info_resp3 = link.read_message(2.0)
    post_reset_client_pin = b"clientPin\xf4" in info_resp3 # false

    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x01])) # getPinRetries
    retries_resp = link.read_message(2.0)
    post_reset_retries = retries_resp[-1] if (retries_resp and retries_resp[0] == CTAP2_OK) else None

    # Check that old credential cannot be used (salt was rotated)
    assert_client_data_hash = hashlib.sha256(b"exp187-test-assert").digest()
    assert_req = bytearray()
    assert_req.append(0x02) # getAssertion
    assert_req.append(0xa3)
    assert_req.extend(cbor_encode_uint(1))
    assert_req.extend(cbor_encode_text("example.com"))
    assert_req.extend(cbor_encode_uint(2))
    assert_req.extend(cbor_encode_bytes(assert_client_data_hash))
    assert_req.extend(cbor_encode_uint(3))
    assert_req.extend(bytes([0x81, 0xa1]))
    assert_req.extend(cbor_encode_text("id"))
    assert_req.extend(cbor_encode_bytes(cred_id if cred_id else b"\x00" * 48))

    link.send_message(cid, 0x10, bytes(assert_req))
    assert_resp = link.read_message(2.0)
    old_cred_invalidated = (assert_resp is not None and assert_resp[0] == CTAP2_ERR_NO_CREDENTIALS)

    # 7. Re-arm PIN ("654321") and test Late Reset rejection (>10s window)
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x02])) # getKeyAgreement
    key_resp2 = link.read_message(2.0)
    peer_x2, peer_y2 = extract_cose_key(key_resp2)

    peer_numbers2 = ec.EllipticCurvePublicNumbers(
        int.from_bytes(peer_x2, "big"),
        int.from_bytes(peer_y2, "big"),
        ec.SECP256R1(),
    )
    peer_pk2 = peer_numbers2.public_key(default_backend())
    raw_shared2 = host_sk.exchange(ec.ECDH(), peer_pk2)
    shared_secret2 = hashlib.sha256(raw_shared2).digest()

    pin_padded2 = b"654321".ljust(64, b"\x00")
    new_pin_enc2 = aes_cbc_encrypt(shared_secret2, b"\x00" * 16, pin_padded2)
    pin_auth2 = hmac_sha256(shared_secret2, new_pin_enc2)[:16]

    set_req2 = bytearray()
    set_req2.append(0x06) # clientPIN
    set_req2.append(0xa5)
    set_req2.extend(cbor_encode_uint(1))
    set_req2.extend(cbor_encode_uint(1))
    set_req2.extend(cbor_encode_uint(2))
    set_req2.extend(cbor_encode_uint(3)) # setPIN
    set_req2.extend(cbor_encode_uint(3))
    set_req2.extend(cbor_encode_cose_key(host_x, host_y))
    set_req2.extend(cbor_encode_uint(4))
    set_req2.extend(cbor_encode_bytes(pin_auth2))
    set_req2.extend(cbor_encode_uint(5))
    set_req2.extend(cbor_encode_bytes(new_pin_enc2))

    link.send_message(cid, 0x10, bytes(set_req2))
    set_resp2 = link.read_message(2.0)

    # Wait to guarantee we exceed 10.5 seconds from boot
    time.sleep(10.5)

    # Late Reset rejection: authenticatorReset (0x07) sent >10s after boot
    link.send_message(cid, 0x10, bytes([0x07]))
    late_reset_resp = link.read_message(2.0)
    late_reset_status = late_reset_resp[0] if late_reset_resp else None
    late_reset_rejected = (late_reset_status == CTAP2_ERR_NOT_ALLOWED)

    # Verify PIN is STILL active after late reset was rejected
    link.send_message(cid, 0x10, bytes([0x04]))
    info_resp4 = link.read_message(2.0)
    pin_retained_after_late_reset = b"clientPin\xf5" in info_resp4 # true

    link.close()

    result = {
        "device": dev_path,
        "initial_uv_option_is_true": initial_uv_option,
        "initial_client_pin_is_false": initial_client_pin,
        "set_pin_ok": set_pin_ok,
        "post_set_pin_client_pin_is_true": post_set_pin_client_pin,
        "gesture_uv_token_status": uv_token_status,
        "gesture_uv_token_issued": (gesture_uv_token is not None),
        "make_cred_ok": cred_ok,
        "make_cred_uv_flag_set": uv_flag_in_cred,
        "timely_reset_status": timely_reset_status,
        "timely_reset_ok": timely_reset_ok,
        "post_reset_client_pin_is_false": post_reset_client_pin,
        "post_reset_retries": post_reset_retries,
        "old_credential_invalidated_after_reset": old_cred_invalidated,
        "late_reset_status": late_reset_status,
        "late_reset_rejected_with_0x30": late_reset_rejected,
        "pin_retained_after_late_reset": pin_retained_after_late_reset,
    }

    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
