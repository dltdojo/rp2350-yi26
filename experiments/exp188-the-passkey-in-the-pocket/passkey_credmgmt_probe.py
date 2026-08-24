#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp188 - Discoverable Credentials (Passkey rk) & Credential Management (credMgmt) Probe

Tests:
1. getInfo: verifies rk: true, credMgmt: true, uv: true
2. setPIN ("123456") & getPinToken -> derives 32B pinUvAuthToken
3. credMgmt getCredsMetadata (0x01) -> existing: 0, remaining: 16
4. makeCredential with options: { rk: true } -> registers Alice's resident passkey
5. credMgmt getCredsMetadata -> existing: 1, remaining: 15
6. 1-Click Passkey assertion (getAssertion with empty allow: []) -> returns Alice's user entity & valid signature
7. credMgmt enumerateRPsBegin (0x02) -> returns example.com
8. credMgmt enumerateCredentialsBegin (0x04) -> returns Alice's passkey
9. credMgmt deleteCredential (0x06) -> deletes Alice's passkey
10. Post-deletion: getCredsMetadata returns existing: 0, empty assertion fails with 0x2E
"""

import glob
import json
import os
import struct
import sys
import time
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

    rk_option = b"rk\xf5" in info_resp # rk: true
    cred_mgmt_option = b"credMgmt\xf5" in info_resp # credMgmt: true
    uv_option = b"uv\xf5" in info_resp # uv: true

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

    # 3. getPinToken ("123456") to get pinUvAuthToken
    good_pin_hash = hashlib.sha256(b"123456").digest()[:16]
    good_pin_enc = aes_cbc_encrypt(shared_secret, b"\x00" * 16, good_pin_hash)

    token_req = bytearray()
    token_req.append(0x06)
    token_req.append(0xa4)
    token_req.extend(cbor_encode_uint(1))
    token_req.extend(cbor_encode_uint(1))
    token_req.extend(cbor_encode_uint(2))
    token_req.extend(cbor_encode_uint(5)) # getPinToken
    token_req.extend(cbor_encode_uint(3))
    token_req.extend(cbor_encode_cose_key(host_x, host_y))
    token_req.extend(cbor_encode_uint(6))
    token_req.extend(cbor_encode_bytes(good_pin_enc))

    link.send_message(cid, 0x10, bytes(token_req))
    token_resp = link.read_message(2.0)
    pin_uv_auth_token = None
    if token_resp and token_resp[0] == CTAP2_OK:
        idx_tok = token_resp.find(b"\x02\x58\x20")
        if idx_tok != -1:
            enc_tok = token_resp[idx_tok + 3:idx_tok + 3 + 32]
            pin_uv_auth_token = aes_cbc_decrypt(shared_secret, b"\x00" * 16, enc_tok)

    # 4. credMgmt: getCredsMetadata (0x01) initial -> should be existing: 0, remaining: 16
    mgmt_req_1 = bytearray()
    mgmt_req_1.append(0x0a) # authenticatorCredentialManagement
    mgmt_req_1.append(0xa3)
    mgmt_req_1.extend(cbor_encode_uint(1))
    mgmt_req_1.extend(cbor_encode_uint(1)) # subCommand: getCredsMetadata
    mgmt_req_1.extend(cbor_encode_uint(3))
    mgmt_req_1.extend(cbor_encode_uint(1)) # pinUvAuthProtocol: 1
    mgmt_req_1.extend(cbor_encode_uint(4))
    mgmt_auth_1 = hmac_sha256(pin_uv_auth_token, bytes([1]))[:16] if pin_uv_auth_token else b"\x00" * 16
    mgmt_req_1.extend(cbor_encode_bytes(mgmt_auth_1))

    link.send_message(cid, 0x10, bytes(mgmt_req_1))
    mgmt_resp_1 = link.read_message(2.0)
    meta_1_ok = (mgmt_resp_1 is not None and mgmt_resp_1[0] == CTAP2_OK)
    initial_existing = None
    initial_remaining = None
    if meta_1_ok:
        idx_e = mgmt_resp_1.find(b"\x01")
        idx_r = mgmt_resp_1.find(b"\x02")
        if idx_e != -1 and idx_r != -1:
            initial_existing = mgmt_resp_1[idx_e + 1]
            initial_remaining = mgmt_resp_1[idx_r + 1]

    # 5. makeCredential with options: { "rk": true } (Passkey registration for Alice)
    client_data_hash = hashlib.sha256(b"exp188-passkey-reg-alice").digest()
    pin_uv_auth_param = hmac_sha256(pin_uv_auth_token, client_data_hash)[:16] if pin_uv_auth_token else b"\x00" * 16

    make_cred_req = bytearray()
    make_cred_req.append(0x01)
    make_cred_req.append(0xa6)
    make_cred_req.extend(cbor_encode_uint(1))
    make_cred_req.extend(cbor_encode_bytes(client_data_hash))
    make_cred_req.extend(cbor_encode_uint(2))
    make_cred_req.extend(bytes([0xa1]))
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_text("example.com"))
    make_cred_req.extend(cbor_encode_uint(3))
    make_cred_req.extend(bytes([0xa3]))
    make_cred_req.extend(cbor_encode_text("id"))
    make_cred_req.extend(cbor_encode_bytes(b"alice_user_id_188"))
    make_cred_req.extend(cbor_encode_text("name"))
    make_cred_req.extend(cbor_encode_text("alice"))
    make_cred_req.extend(cbor_encode_text("displayName"))
    make_cred_req.extend(cbor_encode_text("Alice Smith"))
    make_cred_req.extend(cbor_encode_uint(4))
    make_cred_req.extend(bytes([0x81, 0xa1]))
    make_cred_req.extend(cbor_encode_text("alg"))
    make_cred_req.extend(bytes([0x26]))
    make_cred_req.extend(cbor_encode_uint(7)) # options map
    make_cred_req.extend(bytes([0xa1]))
    make_cred_req.extend(cbor_encode_text("rk"))
    make_cred_req.extend(bytes([0xf5])) # rk: true
    make_cred_req.extend(cbor_encode_uint(8))
    make_cred_req.extend(cbor_encode_bytes(pin_uv_auth_param))

    link.send_message(cid, 0x10, bytes(make_cred_req))
    cred_resp = link.read_message(3.0)
    passkey_registered = (cred_resp is not None and cred_resp[0] == CTAP2_OK)

    alice_cred_id = None
    if passkey_registered:
        idx_ad = cred_resp.find(b"\x02X")
        if idx_ad != -1:
            ad_len = cred_resp[idx_ad + 2]
            ad = cred_resp[idx_ad + 3:idx_ad + 3 + ad_len]
            alice_cred_id = ad[55:55 + 48]

    # 6. credMgmt: getCredsMetadata after registration -> should be existing: 1, remaining: 15
    link.send_message(cid, 0x10, bytes(mgmt_req_1))
    mgmt_resp_2 = link.read_message(2.0)
    post_reg_existing = None
    post_reg_remaining = None
    if mgmt_resp_2 and mgmt_resp_2[0] == CTAP2_OK:
        idx_e = mgmt_resp_2.find(b"\x01")
        idx_r = mgmt_resp_2.find(b"\x02")
        if idx_e != -1 and idx_r != -1:
            post_reg_existing = mgmt_resp_2[idx_e + 1]
            post_reg_remaining = mgmt_resp_2[idx_r + 1]

    # 7. 1-Click Passkey Assertion: getAssertion with EMPTY allowList (allow: [])
    assert_client_data_hash = hashlib.sha256(b"exp188-passkey-1click-assert").digest()
    assert_uv_param = hmac_sha256(pin_uv_auth_token, assert_client_data_hash)[:16] if pin_uv_auth_token else b"\x00" * 16

    assert_req = bytearray()
    assert_req.append(0x02) # authenticatorGetAssertion
    assert_req.append(0xa3)
    assert_req.extend(cbor_encode_uint(1))
    assert_req.extend(cbor_encode_text("example.com"))
    assert_req.extend(cbor_encode_uint(2))
    assert_req.extend(cbor_encode_bytes(assert_client_data_hash))
    assert_req.extend(cbor_encode_uint(7))
    assert_req.extend(cbor_encode_bytes(assert_uv_param))
    # NOTE: NO key 0x03 (allowList) -> empty allowList 1-click Passkey discovery!

    link.send_message(cid, 0x10, bytes(assert_req))
    assert_resp = link.read_message(3.0)
    one_click_assert_ok = (assert_resp is not None and assert_resp[0] == CTAP2_OK)

    returned_user_alice = False
    returned_cred_id_matches = False
    if one_click_assert_ok:
        returned_user_alice = b"alice" in assert_resp and b"Alice Smith" in assert_resp
        if alice_cred_id and alice_cred_id in assert_resp:
            returned_cred_id_matches = True

    # 8. credMgmt: enumerateRPsBegin (0x02)
    mgmt_req_enum_rp = bytearray()
    mgmt_req_enum_rp.append(0x0a)
    mgmt_req_enum_rp.append(0xa3)
    mgmt_req_enum_rp.extend(cbor_encode_uint(1))
    mgmt_req_enum_rp.extend(cbor_encode_uint(2)) # subCommand: 2 (enumerateRPsBegin)
    mgmt_req_enum_rp.extend(cbor_encode_uint(3))
    mgmt_req_enum_rp.extend(cbor_encode_uint(1))
    mgmt_req_enum_rp.extend(cbor_encode_uint(4))
    mgmt_auth_2 = hmac_sha256(pin_uv_auth_token, bytes([2]))[:16] if pin_uv_auth_token else b"\x00" * 16
    mgmt_req_enum_rp.extend(cbor_encode_bytes(mgmt_auth_2))

    link.send_message(cid, 0x10, bytes(mgmt_req_enum_rp))
    enum_rp_resp = link.read_message(2.0)
    enum_rp_ok = (enum_rp_resp is not None and enum_rp_resp[0] == CTAP2_OK and b"example.com" in enum_rp_resp)

    # 9. credMgmt: enumerateCredentialsBegin (0x04)
    rp_hash = hashlib.sha256(b"example.com").digest()
    mgmt_req_enum_cred = bytearray()
    mgmt_req_enum_cred.append(0x0a)
    mgmt_req_enum_cred.append(0xa4)
    mgmt_req_enum_cred.extend(cbor_encode_uint(1))
    mgmt_req_enum_cred.extend(cbor_encode_uint(4)) # subCommand: 4 (enumerateCredentialsBegin)
    mgmt_req_enum_cred.extend(cbor_encode_uint(2)) # subCommandParams map
    mgmt_req_enum_cred.extend(bytes([0xa1]))
    mgmt_req_enum_cred.extend(cbor_encode_uint(1)) # 0x01: rpIDHash
    mgmt_req_enum_cred.extend(cbor_encode_bytes(rp_hash))
    mgmt_req_enum_cred.extend(cbor_encode_uint(3))
    mgmt_req_enum_cred.extend(cbor_encode_uint(1))
    mgmt_req_enum_cred.extend(cbor_encode_uint(4))
    mgmt_auth_4 = hmac_sha256(pin_uv_auth_token, bytes([4]))[:16] if pin_uv_auth_token else b"\x00" * 16
    mgmt_req_enum_cred.extend(cbor_encode_bytes(mgmt_auth_4))

    link.send_message(cid, 0x10, bytes(mgmt_req_enum_cred))
    enum_cred_resp = link.read_message(2.0)
    enum_cred_ok = (enum_cred_resp is not None and enum_cred_resp[0] == CTAP2_OK and b"alice" in enum_cred_resp)

    # 10. credMgmt: deleteCredential (0x06)
    mgmt_req_del = bytearray()
    mgmt_req_del.append(0x0a)
    mgmt_req_del.append(0xa4)
    mgmt_req_del.extend(cbor_encode_uint(1))
    mgmt_req_del.extend(cbor_encode_uint(6)) # subCommand: 6 (deleteCredential)
    mgmt_req_del.extend(cbor_encode_uint(2)) # subCommandParams map
    mgmt_req_del.extend(bytes([0xa1]))
    mgmt_req_del.extend(cbor_encode_uint(2)) # 0x02: credentialId map
    mgmt_req_del.extend(bytes([0xa2]))
    mgmt_req_del.extend(cbor_encode_text("id"))
    mgmt_req_del.extend(cbor_encode_bytes(alice_cred_id if alice_cred_id else b"\x00" * 48))
    mgmt_req_del.extend(cbor_encode_text("type"))
    mgmt_req_del.extend(cbor_encode_text("public-key"))
    mgmt_req_del.extend(cbor_encode_uint(3))
    mgmt_req_del.extend(cbor_encode_uint(1))
    mgmt_req_del.extend(cbor_encode_uint(4))
    mgmt_auth_6 = hmac_sha256(pin_uv_auth_token, bytes([6]))[:16] if pin_uv_auth_token else b"\x00" * 16
    mgmt_req_del.extend(cbor_encode_bytes(mgmt_auth_6))

    link.send_message(cid, 0x10, bytes(mgmt_req_del))
    del_resp = link.read_message(2.0)
    delete_ok = (del_resp is not None and del_resp[0] == CTAP2_OK)

    # 11. Post-deletion: getCredsMetadata -> existing: 0, and 1-Click assertion returns CTAP2_ERR_NO_CREDENTIALS (0x2E)
    link.send_message(cid, 0x10, bytes(mgmt_req_1))
    mgmt_resp_3 = link.read_message(2.0)
    post_del_existing = None
    if mgmt_resp_3 and mgmt_resp_3[0] == CTAP2_OK:
        idx_e = mgmt_resp_3.find(b"\x01")
        if idx_e != -1:
            post_del_existing = mgmt_resp_3[idx_e + 1]

    link.send_message(cid, 0x10, bytes(assert_req))
    assert_resp_2 = link.read_message(2.0)
    post_del_assert_no_creds = (assert_resp_2 is not None and assert_resp_2[0] == CTAP2_ERR_NO_CREDENTIALS)

    link.close()

    result = {
        "device": dev_path,
        "rk_option_is_true": rk_option,
        "cred_mgmt_option_is_true": cred_mgmt_option,
        "uv_option_is_true": uv_option,
        "set_pin_ok": set_pin_ok,
        "pin_uv_auth_token_derived": (pin_uv_auth_token is not None),
        "initial_metadata_existing_count": initial_existing,
        "initial_metadata_remaining_count": initial_remaining,
        "passkey_registration_ok": passkey_registered,
        "post_registration_existing_count": post_reg_existing,
        "post_registration_remaining_count": post_reg_remaining,
        "one_click_passkey_assertion_ok": one_click_assert_ok,
        "one_click_returned_user_alice": returned_user_alice,
        "one_click_returned_matching_cred_id": returned_cred_id_matches,
        "enumerate_rps_ok": enum_rp_ok,
        "enumerate_credentials_ok": enum_cred_ok,
        "delete_credential_ok": delete_ok,
        "post_deletion_existing_count": post_del_existing,
        "post_deletion_assertion_rejected_no_creds": post_del_assert_no_creds,
    }

    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()

