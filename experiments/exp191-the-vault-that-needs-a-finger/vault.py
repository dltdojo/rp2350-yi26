#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""Seal and open a directory with a key that is not on this machine.

AES-256-GCM, keyed by the thirty-two bytes
[exp189](../exp189-the-same-salt-twice/) gets out of the board. The salt sits
**in the clear** beside the ciphertext and that is not an oversight: a salt is
not a secret. The client chooses it and sends it; what makes the vault shut is
that `HMAC(CredRandom, salt)` cannot be computed anywhere but inside a board
that somebody has pressed.

`cryptography` is the one dependency, and it is the same one exp185 onward
already needed. It is offline, widely packaged and stable in these primitives —
which is a different kind of dependency from a client that talks to a service,
and the distinction is written up in the README rather than assumed.
"""

import json
import os
import sys
import tarfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def seal(key, plaintext):
    """`nonce ‖ ciphertext`. The nonce is fresh per seal and not secret."""
    nonce = os.urandom(12)
    return nonce + AESGCM(key).encrypt(nonce, plaintext, None)


def open_(key, blob):
    """Raises if the key is wrong, which is the whole point of GCM here.

    A wrong key must **fail** rather than produce plausible rubbish: the vault's
    claim is that without the board it does not open, and a cipher with no tag
    would open it into garbage and let a caller carry on.
    """
    return AESGCM(key).decrypt(blob[:12], blob[12:], None)


def pack_dir(path):
    import io
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(path, arcname=".")
    return buf.getvalue()


def unpack_dir(blob, path):
    import io
    os.makedirs(path, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r") as tar:
        tar.extractall(path, filter="data")


def main():
    if len(sys.argv) < 2:
        print("usage: vault.py {seal|open} ...", file=sys.stderr)
        return 2
    key = bytes.fromhex(os.environ["VAULT_KEY"])
    if len(key) != 32:
        print("VAULT_KEY must be 32 bytes of hex", file=sys.stderr)
        return 2

    if sys.argv[1] == "seal":
        _, _, src, out, salt_b64 = sys.argv
        blob = seal(key, pack_dir(src))
        with open(out, "wb") as f:
            f.write(blob)
        with open(out + ".salt", "w") as f:
            json.dump({"salt": salt_b64, "cipher": "AES-256-GCM"}, f)
        print(f"sealed {len(blob)} bytes")
    elif sys.argv[1] == "open":
        _, _, blob_path, dest = sys.argv
        with open(blob_path, "rb") as f:
            unpack_dir(open_(key, f.read()), dest)
        print(f"opened into {dest}")
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
