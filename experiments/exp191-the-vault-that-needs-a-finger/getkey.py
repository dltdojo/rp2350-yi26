#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Ask the board for the vault key. Prints 32 bytes of hex, or nothing.

The client is **this repository's own** — `experiments/ctap_client.py` — and not
`libfido2`, on purpose. exp189 uses libfido2 because the point there is that
somebody else's tool accepts the board. The point here is the opposite: a chain
that still runs in five years, which means no tool that talks to a service and
no format somebody else may change.

    getkey.py <credential-id-b64> <salt-b64>

Blocks until somebody presses BOOTSEL. That is the experiment.
"""

import base64
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ctap_client as ctap  # noqa: E402


def main():
    if len(sys.argv) != 3:
        print("usage: getkey.py <credential-id-b64> <salt-b64>", file=sys.stderr)
        return 2
    cred_id = base64.b64decode(sys.argv[1])
    salt = base64.b64decode(sys.argv[2])

    dev = ctap.find_hidraw_device()
    if not dev:
        print("no FIDO device", file=sys.stderr)
        return 1
    link = ctap.FidoLink(dev)
    try:
        cid = ctap.init_channel(link)
        if cid is None:
            print("no channel", file=sys.stderr)
            return 1
        shared, platform = ctap.get_key_agreement(link, cid)
        if shared is None:
            print("no key agreement — does this board advertise hmac-secret?", file=sys.stderr)
            return 1
        out = ctap.get_assertion_with_hmac_secret(
            link, cid, "example.test", cred_id, salt, shared, platform
        )
        if not out or len(out) != 32:
            print("no key came back", file=sys.stderr)
            return 1
        print(out.hex())
        return 0
    finally:
        link.close()


if __name__ == "__main__":
    sys.exit(main())
