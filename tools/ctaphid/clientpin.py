# SPDX-License-Identifier: Apache-2.0
"""CTAP 2.1 authenticatorClientPIN, PIN/UV auth protocol 1, by hand.

    from clientpin import ClientPin
    pin = ClientPin(link, cid)
    pin.set_pin("123456")            # -> CTAP2 status byte
    pin.get_pin_token("123456")      # -> (status, token or None)

`ctaphid.py` beside this file is the transport and `webauthn.py` the CBOR; this
is the clientPIN layer above them. exp186's `pin_lifecycle_probe.py` wrote the
same steps inline in one `main()`; exp197 needed them a second time, to ask
questions exp186 never asked — a second `setPIN`, three wrong PINs in a row —
and a second copy is the moment to extract.

Protocol 1 exactly as the firmwares here speak it: ECDH on P-256, the shared
secret is SHA-256 of the x coordinate, AES-256-CBC with a zero IV, and
LEFT(HMAC-SHA-256, 16) for pinUvAuthParam.

It is not a CTAP client. It sends the four subcommands exp186-exp189 implement
and reports the status byte they answer with, so that a verdict can be about
the authenticator rather than about this code.
"""

import hashlib
import hmac

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from webauthn import cbor_bytes, cbor_decode, cbor_map, cbor_nint, cbor_uint

CTAPHID_CBOR = 0x10
AUTHENTICATOR_CLIENT_PIN = 0x06

GET_PIN_RETRIES = 0x01
GET_KEY_AGREEMENT = 0x02
SET_PIN = 0x03
CHANGE_PIN = 0x04
GET_PIN_TOKEN = 0x05

# CTAP 2.1's status table. exp186-exp189 had three of these wrong; see
# crates/client-pin.
STATUS = {
    0x00: "CTAP2_OK",
    0x31: "CTAP2_ERR_PIN_INVALID",
    0x32: "CTAP2_ERR_PIN_BLOCKED",
    0x33: "CTAP2_ERR_PIN_AUTH_INVALID",
    0x34: "CTAP2_ERR_PIN_AUTH_BLOCKED",
    0x35: "CTAP2_ERR_PIN_NOT_SET",
    0x36: "CTAP2_ERR_PUAT_REQUIRED",
}


def status_name(code):
    return STATUS.get(code, f"0x{code:02x}") if code is not None else "no answer"


class ClientPin:
    """One key agreement, and the subcommands that use it."""

    def __init__(self, link, cid):
        self.link = link
        self.cid = cid
        self.shared = None
        self.platform_key = None

    # -- the wire ------------------------------------------------------------
    def request(self, sub, extra=()):
        """Send authenticatorClientPIN and return (status, decoded map or None)."""
        pairs = [(cbor_uint(1), cbor_uint(1)), (cbor_uint(2), cbor_uint(sub))] + list(extra)
        self.link.send_message(self.cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_CLIENT_PIN]) + cbor_map(pairs))
        reply = self.link.read_message(timeout=3.0)
        if not reply or reply.get("cmd") != CTAPHID_CBOR:
            return None, None
        body = self.link.last
        status = body[0]
        if status != 0 or len(body) == 1:
            return status, None
        decoded, _ = cbor_decode(body, 1)
        return status, decoded

    # -- protocol 1 ----------------------------------------------------------
    def agree(self):
        """getKeyAgreement, then ECDH. Returns the status."""
        status, got = self.request(GET_KEY_AGREEMENT)
        if status != 0 or not got or 1 not in got:
            return status
        cose = got[1]
        peer = ec.EllipticCurvePublicNumbers(
            int.from_bytes(cose[-2], "big"), int.from_bytes(cose[-3], "big"), ec.SECP256R1()
        ).public_key(default_backend())
        mine = ec.generate_private_key(ec.SECP256R1(), default_backend())
        self.shared = hashlib.sha256(mine.exchange(ec.ECDH(), peer)).digest()
        n = mine.public_key().public_numbers()
        self.platform_key = cbor_map([
            (cbor_uint(1), cbor_uint(2)),                       # kty: EC2
            (cbor_uint(3), cbor_nint(-25)),                     # alg: ECDH-ES+HKDF-256
            (cbor_nint(-1), cbor_uint(1)),                      # crv: P-256
            (cbor_nint(-2), cbor_bytes(n.x.to_bytes(32, "big"))),
            (cbor_nint(-3), cbor_bytes(n.y.to_bytes(32, "big"))),
        ])
        return status

    def seal(self, plain):
        e = Cipher(algorithms.AES(self.shared), modes.CBC(b"\x00" * 16), default_backend()).encryptor()
        return e.update(plain) + e.finalize()

    def unseal(self, sealed):
        d = Cipher(algorithms.AES(self.shared), modes.CBC(b"\x00" * 16), default_backend()).decryptor()
        return d.update(sealed) + d.finalize()

    def mac(self, data):
        return hmac.new(self.shared, data, hashlib.sha256).digest()[:16]

    @staticmethod
    def pin_hash(pin):
        return hashlib.sha256(pin.encode()).digest()[:16]

    # -- the subcommands -----------------------------------------------------
    def retries(self):
        status, got = self.request(GET_PIN_RETRIES)
        return got.get(3) if status == 0 and got else None

    def set_pin(self, pin):
        if self.shared is None and self.agree() != 0:
            return None
        new_enc = self.seal(pin.encode().ljust(64, b"\x00"))
        status, _ = self.request(SET_PIN, [
            (cbor_uint(3), self.platform_key),
            (cbor_uint(4), cbor_bytes(self.mac(new_enc))),
            (cbor_uint(5), cbor_bytes(new_enc)),
        ])
        return status

    def get_pin_token(self, pin):
        if self.shared is None and self.agree() != 0:
            return None, None
        status, got = self.request(GET_PIN_TOKEN, [
            (cbor_uint(3), self.platform_key),
            (cbor_uint(6), cbor_bytes(self.seal(self.pin_hash(pin)))),
        ])
        token = self.unseal(got[2]) if status == 0 and got and 2 in got else None
        return status, token
