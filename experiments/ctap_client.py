#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""A CTAPHID and CTAP2 client, by hand, for the experiments after exp190.

`libfido2` is the right client when the point is that **somebody else's tool
accepts this board** — exp173 is that experiment and exp189 uses it on purpose.
This is for the other half: a chain with no external dependency, so that running
it in five years needs python3 and `cryptography` and nothing else. A tool that
talks to a network service is somebody else's product with somebody else's
release schedule, and no pin fixes that.

It is shared for the same reason `crates/ctap` is shared on the firmware side:
by exp189 this road had fifteen firmwares and 24,507 lines, each begun as a copy
of the last, and three of one round's four defects lived in code that existed
twelve to fifteen times over. The host side was going the same way — exp185,
exp186, exp187 and exp188 each carry their own copy of the PIN-protocol-1 key
agreement below.

**Forward, not back.** Those four keep theirs: they are verified work whose
scripts are part of what they demonstrate, which is the ruling `cbor.py` already
records for the host-side CBOR readers. Nothing before exp191 imports this.

# What is here

The transport (`FidoLink`), enough CBOR to build a request by hand, PIN protocol
1's ECDH key agreement, and the `hmac-secret` extension — which is the one this
was written for, because it is the only way to get a **key** out of an
authenticator rather than a signature.
"""

import glob
import hashlib
import hmac
import os
import struct
import time

from cryptography.hazmat.primitives import hashes, hmac as crypto_hmac
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

CTAPHID_INIT = 0x06
CTAPHID_CBOR = 0x10
CTAP2_OK = 0x00

AUTHENTICATOR_MAKE_CREDENTIAL = 0x01
AUTHENTICATOR_GET_ASSERTION = 0x02
AUTHENTICATOR_GET_INFO = 0x04
AUTHENTICATOR_CLIENT_PIN = 0x06


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
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    encryptor = cipher.encryptor()
    return encryptor.update(plaintext) + encryptor.finalize()

def aes_cbc_decrypt(key, iv, ciphertext):
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
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


def get_key_agreement(link, cid):
    """The authenticator's ephemeral P-256 public key, and a shared secret.

    `clientPIN` subcommand 0x02. It is called `clientPIN` and has nothing to do
    with a PIN here: `hmac-secret` rides the same tunnel, which is why a device
    with no PIN at all still has to answer this.

    Returns `(shared_secret, platform_cose_key)` or `(None, None)`.
    """
    req = bytes([AUTHENTICATOR_CLIENT_PIN]) + b"\xa2\x01\x01\x02\x02"
    link.send_message(cid, CTAPHID_CBOR, req)
    resp = link.read_message()
    peer_x, peer_y = extract_cose_key(resp)
    if peer_x is None:
        return None, None

    private = ec.generate_private_key(ec.SECP256R1())
    peer = ec.EllipticCurvePublicNumbers(
        int.from_bytes(peer_x, "big"), int.from_bytes(peer_y, "big"), ec.SECP256R1()
    ).public_key()
    z = private.exchange(ec.ECDH(), peer)

    # PIN protocol 1: the shared secret is SHA-256 of the x coordinate only.
    digest = hashes.Hash(hashes.SHA256())
    digest.update(z)
    shared = digest.finalize()

    nums = private.public_key().public_numbers()
    platform = cbor_encode_cose_key(
        nums.x.to_bytes(32, "big"), nums.y.to_bytes(32, "big")
    )
    return shared, platform


def hmac_secret_extension(shared, platform_key, salt):
    """The `hmac-secret` map a `getAssertion` carries.

    ```text
    "hmac-secret": { 01: keyAgreement, 02: saltEnc, 03: saltAuth }
    ```

    `saltEnc` is AES-256-CBC with a zero IV and `saltAuth` is the first sixteen
    bytes of HMAC-SHA256 over it — the truncation is protocol 1's, and a device
    that checked all thirty-two would refuse every real client.
    """
    if len(salt) not in (32, 64):
        raise ValueError("a salt is 32 or 64 bytes")
    salt_enc = aes_cbc_encrypt(shared, b"\x00" * 16, salt)
    salt_auth = hmac_sha256(shared, salt_enc)[:16]
    return (
        b"\xa1"
        + cbor_encode_text("hmac-secret")
        + b"\xa3"
        + b"\x01" + platform_key
        + b"\x02" + cbor_encode_bytes(salt_enc)
        + b"\x03" + cbor_encode_bytes(salt_auth)
    )


def get_assertion_with_hmac_secret(link, cid, rp_id, cred_id, salt, shared, platform_key):
    """Ask for an assertion **and** the thirty-two bytes behind the salt.

    Returns the decrypted output, or `None`. The board waits for a press before
    it computes anything, so this blocks until somebody presses or the device
    gives up — which is the entire point of the experiment that uses it.
    """
    client_data_hash = os.urandom(32)
    req = (
        bytes([AUTHENTICATOR_GET_ASSERTION])
        + b"\xa4"
        + b"\x01" + cbor_encode_text(rp_id)
        + b"\x02" + cbor_encode_bytes(client_data_hash)
        + b"\x03" + b"\x81\xa2"
        + cbor_encode_text("id") + cbor_encode_bytes(cred_id)
        + cbor_encode_text("type") + cbor_encode_text("public-key")
        + b"\x04" + hmac_secret_extension(shared, platform_key, salt)
    )
    link.send_message(cid, CTAPHID_CBOR, req)
    resp = link.read_message(timeout=40.0)
    if not resp or resp[0] != CTAP2_OK:
        return None

    # The output rides back in authData's extension block, encrypted under the
    # same shared secret. authData is the response map's key 0x02; the extension
    # data follows the 37-byte header when the ED flag is set.
    idx = resp.find(b"\x02\x58")
    if idx == -1:
        idx = resp.find(b"\x02\x59")
    if idx == -1:
        return None
    if resp[idx + 1] == 0x58:
        alen = resp[idx + 2]
        auth = resp[idx + 3:idx + 3 + alen]
    else:
        alen = struct.unpack(">H", resp[idx + 2:idx + 4])[0]
        auth = resp[idx + 4:idx + 4 + alen]
    if len(auth) < 37 or not auth[32] & 0x80:
        return None  # no extension data
    ext = auth[37:]
    j = ext.find(b"hmac-secret")
    if j == -1:
        return None
    tail = ext[j + len("hmac-secret"):]
    if tail[0] == 0x58:
        n = tail[1]
        enc = tail[2:2 + n]
    elif tail[0] == 0x59:
        n = struct.unpack(">H", tail[1:3])[0]
        enc = tail[3:3 + n]
    else:
        return None
    return aes_cbc_decrypt(shared, b"\x00" * 16, enc)


def _selftest():
    """Exercise every pure function here, so a missing import cannot ship.

    This module was extracted out of exp188's probe and reached a board twice
    with an import left behind — `default_backend`, then `hmac` — each time
    failing in 0.3 s while a retry loop above it reported "nobody pressed" and
    asked somebody to press again. **An extraction is not finished until
    something runs it**, and the transport half cannot be run without a board,
    so this runs everything else.
    """
    ok = True

    def check(good, what):
        nonlocal ok
        print(("PASS  " + what) if good else ("FAIL  " + what))
        ok = ok and good

    key = b"k" * 32
    zero = b"\x00" * 16
    check(aes_cbc_decrypt(key, zero, aes_cbc_encrypt(key, zero, b"S" * 32)) == b"S" * 32,
          "AES-256-CBC round trips at the zero IV protocol 1 uses")
    check(len(hmac_sha256(key, b"x")) == 32, "HMAC-SHA256 answers 32 bytes")
    check(hmac_sha256(key, b"x") != hmac_sha256(key, b"y"), "and different data gives a different tag")

    check(cbor_encode_uint(0) == b"\x00" and cbor_encode_uint(23) == b"\x17",
          "small unsigned integers encode inline")
    check(cbor_encode_uint(24) == b"\x18\x18", "and 24 takes the one-byte form canonical CBOR requires")
    check(cbor_encode_bytes(b"ab") == b"\x42ab", "short byte strings encode inline")
    check(cbor_encode_bytes(b"a" * 32)[:2] == b"\x58\x20", "and 32 bytes take the one-byte length")
    check(cbor_encode_text("id") == b"\x62id", "text strings encode inline")

    cose = cbor_encode_cose_key(b"x" * 32, b"y" * 32)
    check(b"\x21\x58\x20" in cose and b"\x22\x58\x20" in cose,
          "a COSE key carries x at label -2 and y at label -3")
    check(extract_cose_key(bytes([CTAP2_OK]) + cose) == (b"x" * 32, b"y" * 32),
          "and reading it back gives the point that went in")

    ext = hmac_secret_extension(key, cose, b"S" * 32)
    check(ext[0] == 0xa1 and b"hmac-secret" in ext, "the extension is a map of one, named hmac-secret")
    check(b"\x03\x50" in ext, "and saltAuth is sixteen bytes — protocol 1 truncates the tag")
    try:
        hmac_secret_extension(key, cose, b"S" * 31)
        check(False, "a salt that is not 32 or 64 bytes is refused")
    except ValueError:
        check(True, "a salt that is not 32 or 64 bytes is refused")

    return ok


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(0 if _selftest() else 1)
    print("usage: ctap_client.py --selftest", file=sys.stderr)
    sys.exit(2)
