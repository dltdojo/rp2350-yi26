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

It is not a CTAP client. It sends the subcommands exp186-exp189 implement and
reports the status byte they answer with, so that a verdict can be about the
authenticator rather than about this code.

exp200 added the other half of a token: asking for one with permissions
(0x09), and using one for authenticatorCredentialManagement, where the MAC
covers `subCommand || subCommandParams` — exactly the bytes sent.
"""

import hashlib
import hmac

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from webauthn import cbor_bytes, cbor_decode, cbor_map, cbor_nint, cbor_text, cbor_uint

CTAPHID_CBOR = 0x10
AUTHENTICATOR_CLIENT_PIN = 0x06

GET_PIN_RETRIES = 0x01
GET_KEY_AGREEMENT = 0x02
SET_PIN = 0x03
CHANGE_PIN = 0x04
GET_PIN_TOKEN = 0x05
GET_PIN_UV_AUTH_TOKEN_USING_PIN_WITH_PERMISSIONS = 0x09

AUTHENTICATOR_CREDENTIAL_MANAGEMENT = 0x0A
GET_CREDS_METADATA = 0x01
DELETE_CREDENTIAL = 0x06

# What a token may be used for, CTAP 2.1 §6.5.5.7.
PERMISSION_MC = 0x01
PERMISSION_GA = 0x02
PERMISSION_CM = 0x04

# CTAP 2.1's status table. exp186-exp189 had three of these wrong; see
# crates/client-pin.
STATUS = {
    0x00: "CTAP2_OK",
    0x02: "CTAP1_ERR_INVALID_PARAMETER",
    0x14: "CTAP2_ERR_MISSING_PARAMETER",
    0x2B: "CTAP2_ERR_UNSUPPORTED_OPTION",
    0x2E: "CTAP2_ERR_NO_CREDENTIALS",
    0x31: "CTAP2_ERR_PIN_INVALID",
    0x32: "CTAP2_ERR_PIN_BLOCKED",
    0x33: "CTAP2_ERR_PIN_AUTH_INVALID",
    0x34: "CTAP2_ERR_PIN_AUTH_BLOCKED",
    0x35: "CTAP2_ERR_PIN_NOT_SET",
    0x36: "CTAP2_ERR_PUAT_REQUIRED",
    0x40: "CTAP2_ERR_UNAUTHORIZED_PERMISSION",
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
        return self.command(AUTHENTICATOR_CLIENT_PIN, cbor_map(pairs))

    def command(self, ctap_cmd, body):
        """Send one CTAP2 command and return (status, decoded map or None)."""
        self.link.send_message(self.cid, CTAPHID_CBOR, bytes([ctap_cmd]) + body)
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

    def mac(self, data, key=None):
        """LEFT(HMAC-SHA-256, 16): under the shared secret, or under a token."""
        return hmac.new(key or self.shared, data, hashlib.sha256).digest()[:16]

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

    def get_pin_token_with_permissions(self, pin, permissions, rp_id=None):
        """getPinUvAuthTokenUsingPinWithPermissions (0x09) -> (status, token or None)."""
        if self.shared is None and self.agree() != 0:
            return None, None
        extra = [
            (cbor_uint(3), self.platform_key),
            (cbor_uint(6), cbor_bytes(self.seal(self.pin_hash(pin)))),
            (cbor_uint(9), cbor_uint(permissions)),
        ]
        if rp_id is not None:
            extra.append((cbor_uint(10), cbor_text(rp_id)))
        status, got = self.request(GET_PIN_UV_AUTH_TOKEN_USING_PIN_WITH_PERMISSIONS, extra)
        token = self.unseal(got[2]) if status == 0 and got and 2 in got else None
        return status, token

    # -- authenticatorCredentialManagement ------------------------------------
    def cred_mgmt(self, sub, params=b"", token=None, auth=None):
        """Send credential management subcommand `sub` and return its status.

        `params` is subCommandParams already CBOR-encoded, and the MAC is over
        `sub || params`, the same bytes that are sent. Pass `auth` to send a
        chosen pinUvAuthParam instead of the right one, or neither to send none.
        """
        if auth is None and token is not None:
            auth = self.mac(bytes([sub]) + params, key=token)
        pairs = [(cbor_uint(1), cbor_uint(sub))]
        if params:
            pairs.append((cbor_uint(2), params))
        pairs.append((cbor_uint(3), cbor_uint(1)))
        if auth is not None:
            pairs.append((cbor_uint(4), cbor_bytes(auth)))
        status, _ = self.command(AUTHENTICATOR_CREDENTIAL_MANAGEMENT, cbor_map(pairs))
        return status
