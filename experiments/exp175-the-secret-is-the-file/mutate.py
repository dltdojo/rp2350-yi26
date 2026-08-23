#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Break one field of a forged.json, so check.sh can require verify.py to notice.

    python3 mutate.py forged.json out.json <field>=<how>

exp159's rule, applied to a conclusion rather than a signature: every sentence
verify.py asserts needs a version of the file that contradicts it, and verify.py
has to refuse each one. A mutation that changed nothing would make the check
pass for the wrong reason, so an unknown field is an error, not a no-op.

Fields, and what each proves verify.py is actually testing:

  signature   flip a byte of the signature      -> the ES256 check is real
  tag         flip a byte of the credential tag -> the acceptance check is real
  pubkey      flip a byte of the public key x   -> the key really is re-derived
  flags       clear the user-presence bit       -> the UP claim is inspected
"""
import base64
import json
import sys


def ub64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def flip_last(b64_field):
    raw = bytearray(ub64(b64_field))
    raw[-1] ^= 1
    return b64u(bytes(raw))


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    src, dst, edit = sys.argv[1], sys.argv[2], sys.argv[3]
    field, _, _how = edit.partition("=")
    f = json.load(open(src))

    if field == "signature":
        f["signature"] = flip_last(f["signature"])
    elif field == "tag":
        cred = bytearray(ub64(f["credential_id"]))
        cred[-1] ^= 1
        f["credential_id"] = b64u(bytes(cred))
    elif field == "pubkey":
        f["public_key"]["x"] = flip_last(f["public_key"]["x"])
    elif field == "flags":
        auth = bytearray(ub64(f["authenticator_data"]))
        auth[32] &= ~0x01
        f["authenticator_data"] = b64u(bytes(auth))
    else:
        raise SystemExit("unknown field: %s" % field)

    json.dump(f, open(dst, "w"), indent=2)


if __name__ == "__main__":
    main()
