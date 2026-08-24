#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp186 - CTAP 2.1 PIN Lifecycle Probe

Tests the full PIN State Machine over CTAPHID / /dev/hidraw:
1. getInfo (checks initial clientPin: false)
2. getPinRetries (confirms 8 retries)
3. setPIN ("123456" via PIN Protocol 1)
4. getInfo (confirms clientPin: true)
5. getPinToken ("wrong_pin") -> verifies CTAP2_ERR_PIN_INVALID (0x31) & retries=7
6. getPinToken ("123456") -> receives and decrypts 32B pinUvAuthToken & retries=8
7. makeCredential with pinUvAuthParam -> verifies FLAG_UV (0x04) in authData
8. getAssertion with pinUvAuthParam -> verifies FLAG_UV (0x04) in authData
"""

import os
import glob
import json
import struct
import sys
import hashlib
import hmac

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print(json.dumps({"error": "cryptography package missing: pip install cryptography"}))
    sys.exit(1)

CTAP2_OK = 0x00
CTAP2_ERR_PIN_INVALID = 0x31
CTAP2_ERR_PIN_AUTH_INVALID = 0x32
CTAP2_ERR_PIN_BLOCKED = 0x34

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

    def read_message(self, timeout=3.0):
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
                    have = sum(len(c) for c in chunks)
                    rem = expected_len - have
                    chunks.append(pkt[5:5 + min(rem, 59)])
            if expected_len is not None and sum(len(c) for c in chunks) >= expected_len:
                return b"".join(chunks)[:expected_len]
        return None

def find_hidraw_device():
    for dev in sorted(glob.glob("/dev/hidraw*")):
        try:
            fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
            os.close(fd)
            return dev
        except Exception:
            continue
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
    out.append(0xa4) # map(4)
    out.extend(cbor_encode_uint(1))
    out.extend(cbor_encode_uint(2)) # kty: EC2
    out.extend(bytes([0x20])) # -1 (crv)
    out.extend(cbor_encode_uint(1)) # P-256
    out.extend(bytes([0x21])) # -2 (x)
    out.extend(cbor_encode_bytes(x))
    out.extend(bytes([0x22])) # -3 (y)
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

def main():
    dev_path = find_hidraw_device()
    if not dev_path:
        print(json.dumps({"error": "no_device_found"}))
        return

    link = FidoLink(dev_path)
    nonce = b"\x12\x34\x56\x78\x9a\xbc\xde\xf0"
    link.send_message(0xffffffff, 0x06, nonce)
    resp = link.read_message(2.0)
    if not resp or len(resp) < 17:
        print(json.dumps({"error": "ctaphid_init_failed"}))
        link.close()
        return

    cid = struct.unpack(">I", resp[8:12])[0]

    # 1. getInfo
    link.send_message(cid, 0x10, bytes([0x04]))
    info_resp = link.read_message(2.0)
    if not info_resp or info_resp[0] != CTAP2_OK:
        print(json.dumps({"error": "getInfo_failed"}))
        link.close()
        return

    # Check clientPin in getInfo
    initial_client_pin = b"clientPin\xf4" in info_resp # false is \xf4 in CBOR

    # 2. getPinRetries
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x01])) # { 0x02: 0x01 }
    retries_resp = link.read_message(2.0)
    retries_initial = retries_resp[-1] if (retries_resp and retries_resp[0] == CTAP2_OK) else None

    # 3. getKeyAgreement
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x02])) # { 0x02: 0x02 }
    key_resp = link.read_message(2.0)
    if not key_resp or key_resp[0] != CTAP2_OK:
        print(json.dumps({"error": "getKeyAgreement_failed"}))
        link.close()
        return

    # Extract peer public key coordinates (x: 32 bytes, y: 32 bytes)
    idx_x = key_resp.find(b"\x21X ") + 3
    peer_x = key_resp[idx_x:idx_x + 32]
    idx_y = key_resp.find(b"\x22X ") + 3
    peer_y = key_resp[idx_y:idx_y + 32]

    # Host generates P-256 ephemeral keypair and performs ECDH
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

    # 4. setPIN ("123456")
    pin_str = b"123456"
    pin_padded = pin_str.ljust(64, b"\x00")
    new_pin_enc = aes_cbc_encrypt(shared_secret, b"\x00" * 16, pin_padded)
    pin_auth = hmac_sha256(shared_secret, new_pin_enc)[:16]

    # Build CBOR setPIN request: { 1: 1, 2: 3, 3: COSE_Key(host), 4: pinAuth, 5: newPinEnc }
    set_req = bytearray()
    set_req.append(0x06) # clientPIN
    set_req.append(0xa5) # map(5)
    set_req.extend(cbor_encode_uint(1))
    set_req.extend(cbor_encode_uint(1)) # proto: 1
    set_req.extend(cbor_encode_uint(2))
    set_req.extend(cbor_encode_uint(3)) # subCommand: 3 (setPIN)
    set_req.extend(cbor_encode_uint(3))
    set_req.extend(cbor_encode_cose_key(host_x, host_y))
    set_req.extend(cbor_encode_uint(4))
    set_req.extend(cbor_encode_bytes(pin_auth))
    set_req.extend(cbor_encode_uint(5))
    set_req.extend(cbor_encode_bytes(new_pin_enc))

    link.send_message(cid, 0x10, bytes(set_req))
    set_resp = link.read_message(2.0)
    set_pin_ok = (set_resp is not None and set_resp[0] == CTAP2_OK)

    # Check getInfo again to verify clientPin flipped to true
    link.send_message(cid, 0x10, bytes([0x04]))
    info_resp2 = link.read_message(2.0)
    post_client_pin = b"clientPin\xf5" in info_resp2 # true is \xf5 in CBOR

    # 5. Negative test: getPinToken with wrong PIN ("999999")
    wrong_pin_hash = hashlib.sha256(b"999999").digest()[:16]
    wrong_pin_enc = aes_cbc_encrypt(shared_secret, b"\x00" * 16, wrong_pin_hash)

    token_req_bad = bytearray()
    token_req_bad.append(0x06)
    token_req_bad.append(0xa4)
    token_req_bad.extend(cbor_encode_uint(1))
    token_req_bad.extend(cbor_encode_uint(1))
    token_req_bad.extend(cbor_encode_uint(2))
    token_req_bad.extend(cbor_encode_uint(5)) # subCommand: 5 (getPinToken)
    token_req_bad.extend(cbor_encode_uint(3))
    token_req_bad.extend(cbor_encode_cose_key(host_x, host_y))
    token_req_bad.extend(cbor_encode_uint(6))
    token_req_bad.extend(cbor_encode_bytes(wrong_pin_enc))

    link.send_message(cid, 0x10, bytes(token_req_bad))
    bad_token_resp = link.read_message(2.0)
    bad_token_status = bad_token_resp[0] if bad_token_resp else None

    # Check retries after bad PIN (should be 7)
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x01]))
    retries_resp2 = link.read_message(2.0)
    retries_after_bad = retries_resp2[-1] if (retries_resp2 and retries_resp2[0] == CTAP2_OK) else None

    # 6. Positive test: getPinToken with correct PIN ("123456")
    good_pin_hash = hashlib.sha256(b"123456").digest()[:16]
    good_pin_enc = aes_cbc_encrypt(shared_secret, b"\x00" * 16, good_pin_hash)

    token_req_good = bytearray()
    token_req_good.append(0x06)
    token_req_good.append(0xa4)
    token_req_good.extend(cbor_encode_uint(1))
    token_req_good.extend(cbor_encode_uint(1))
    token_req_good.extend(cbor_encode_uint(2))
    token_req_good.extend(cbor_encode_uint(5)) # subCommand: 5 (getPinToken)
    token_req_good.extend(cbor_encode_uint(3))
    token_req_good.extend(cbor_encode_cose_key(host_x, host_y))
    token_req_good.extend(cbor_encode_uint(6))
    token_req_good.extend(cbor_encode_bytes(good_pin_enc))

    link.send_message(cid, 0x10, bytes(token_req_good))
    good_token_resp = link.read_message(2.0)
    good_token_status = good_token_resp[0] if good_token_resp else None

    pin_uv_auth_token = None
    if good_token_status == CTAP2_OK:
        # Extract pinUvAuthToken (32 bytes ciphertext at key 0x02)
        idx_tok = good_token_resp.find(b"\x02\x58\x20")
        if idx_tok != -1:
            enc_tok = good_token_resp[idx_tok + 3:idx_tok + 3 + 32]
            pin_uv_auth_token = aes_cbc_decrypt(shared_secret, b"\x00" * 16, enc_tok)

    # Check retries reset back to 8
    link.send_message(cid, 0x10, bytes([0x06, 0xa1, 0x02, 0x01]))
    retries_resp3 = link.read_message(2.0)
    retries_after_good = retries_resp3[-1] if (retries_resp3 and retries_resp3[0] == CTAP2_OK) else None

    # 7. makeCredential with pinUvAuthParam
    client_data_hash = hashlib.sha256(b"exp186-test-registration").digest()
    pin_uv_auth_param = hmac_sha256(pin_uv_auth_token, client_data_hash)[:16]

    make_cred_req = bytearray()
    make_cred_req.append(0x01) # makeCredential
    make_cred_req.append(0xa5) # map(5)
    make_cred_req.extend(cbor_encode_uint(1))
    make_cred_req.extend(cbor_encode_bytes(client_data_hash))
    make_cred_req.extend(cbor_encode_uint(2))
    make_cred_req.extend(bytes([0xa1])) # rp: { "id": "webauthn.io" }
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_text("webauthn.io"))
    make_cred_req.extend(cbor_encode_uint(3))
    make_cred_req.extend(bytes([0xa1])) # user: { "id": "user123" }
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_bytes(b"user123"))
    make_cred_req.extend(cbor_encode_uint(4))
    make_cred_req.extend(bytes([0x81, 0xa1])) # pubKeyCredParams: [{ "alg": -7 }]
    make_cred_req.extend(cbor_encode_text("alg"))
    make_cred_req.extend(bytes([0x26])) # -7
    make_cred_req.extend(cbor_encode_uint(8)) # pinUvAuthParam (key 8)
    make_cred_req.extend(cbor_encode_bytes(pin_uv_auth_param))

    link.send_message(cid, 0x10, bytes(make_cred_req))
    cred_resp = link.read_message(3.0)
    cred_ok = (cred_resp is not None and cred_resp[0] == CTAP2_OK)

    uv_flag_in_cred = False
    cred_id = None
    if cred_ok:
        # Extract authData (key 0x02)
        idx_ad = cred_resp.find(b"\x02X")
        if idx_ad != -1:
            ad_len = cred_resp[idx_ad + 2]
            ad = cred_resp[idx_ad + 3:idx_ad + 3 + ad_len]
            flags = ad[32]
            uv_flag_in_cred = bool(flags & 0x04) # FLAG_UV is bit 2 (0x04)
            cred_id = ad[55:55 + 48]

    # 8. getAssertion with pinUvAuthParam
    assert_client_data_hash = hashlib.sha256(b"exp186-test-authentication").digest()
    assert_pin_param = hmac_sha256(pin_uv_auth_token, assert_client_data_hash)[:16]

    assert_req = bytearray()
    assert_req.append(0x02) # getAssertion
    assert_req.append(0xa4) # map(4)
    assert_req.extend(cbor_encode_uint(1))
    assert_req.extend(cbor_encode_text("webauthn.io"))
    assert_req.extend(cbor_encode_uint(2))
    assert_req.extend(cbor_encode_bytes(assert_client_data_hash))
    assert_req.extend(cbor_encode_uint(3))
    assert_req.extend(bytes([0x81, 0xa1])) # allowList: [{ "id": cred_id }]
    assert_req.extend(cbor_encode_text("id"))
    assert_req.extend(cbor_encode_bytes(cred_id if cred_id else b"\x00" * 48))
    assert_req.extend(cbor_encode_uint(7)) # pinUvAuthParam (key 7)
    assert_req.extend(cbor_encode_bytes(assert_pin_param))

    link.send_message(cid, 0x10, bytes(assert_req))
    assert_resp = link.read_message(3.0)
    assert_ok = (assert_resp is not None and assert_resp[0] == CTAP2_OK)

    uv_flag_in_assert = False
    if assert_ok:
        idx_ad = assert_resp.find(b"\x02X%")
        if idx_ad != -1:
            flags = assert_resp[idx_ad + 3 + 32]
            uv_flag_in_assert = bool(flags & 0x04)

    link.close()

    result = {
        "device": dev_path,
        "initial_client_pin_is_false": initial_client_pin,
        "initial_retries": retries_initial,
        "set_pin_ok": set_pin_ok,
        "post_client_pin_is_true": post_client_pin,
        "bad_pin_status": bad_token_status,
        "bad_pin_decremented_retries": (retries_after_bad == 7),
        "good_pin_status": good_token_status,
        "good_pin_reset_retries": (retries_after_good == 8),
        "token_derived_prefix": pin_uv_auth_token.hex()[:16] if pin_uv_auth_token else None,
        "make_cred_ok": cred_ok,
        "make_cred_uv_flag_set": uv_flag_in_cred,
        "get_assert_ok": assert_ok,
        "get_assert_uv_flag_set": uv_flag_in_assert,
    }

    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
