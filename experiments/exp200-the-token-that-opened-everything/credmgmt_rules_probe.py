#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp200's board half: ask a freshly flashed authenticator who may manage its
credentials, and print one JSON object.

Needs a board running exp189 (or exp188), freshly flashed so no PIN is set,
and nobody. No question needs a credential to exist: whether a deletion was
*authorized* shows in the answer to deleting one that is not there —
NO_CREDENTIALS (0x2E) means the device let the request through, and
PIN_AUTH_INVALID (0x33) means it did not.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "ctaphid"))

from ctaphid import Link  # noqa: E402
from clientpin import (  # noqa: E402
    DELETE_CREDENTIAL,
    GET_CREDS_METADATA,
    PERMISSION_CM,
    ClientPin,
    status_name,
)
from webauthn import cbor_bytes, cbor_map, cbor_text, cbor_uint  # noqa: E402

OWNER = "123456"


def delete_params(cred_id):
    """subCommandParams for deleteCredential: {2: {"id": ..., "type": "public-key"}}."""
    descriptor = cbor_map([(cbor_text("id"), cbor_bytes(cred_id)), (cbor_text("type"), cbor_text("public-key"))])
    return cbor_map([(cbor_uint(2), descriptor)])


def put_the_questions():
    link = Link()
    pin = ClientPin(link, link.open_channel())
    out = {"set_owner": pin.set_pin(OWNER)}
    mine, other = delete_params(b"\x01" * 48), delete_params(b"\x02" * 48)

    # C3 first, because it needs the login token: getPinToken grants mc and
    # ga, "Other pinUvAuthToken permissions can only be acquired by providing
    # the permissions parameter".
    status, login = pin.get_pin_token(OWNER)
    out["login_token"] = status
    out["login_token_metadata"] = pin.cred_mgmt(GET_CREDS_METADATA, token=login)

    status, cm = pin.get_pin_token_with_permissions(OWNER, PERMISSION_CM)
    out["cm_token"] = status
    out["cm_token_metadata"] = pin.cred_mgmt(GET_CREDS_METADATA, token=cm)

    # C1: with the owner's cm token current, a parameter that does not verify,
    # and none at all.
    out["wrong_param_metadata"] = pin.cred_mgmt(GET_CREDS_METADATA, auth=b"\x00" * 16)
    out["no_param_metadata"] = pin.cred_mgmt(GET_CREDS_METADATA)

    # C2: the owner's parameter for one credential, sent naming another; and
    # the old message, the subcommand byte alone.
    out["delete_own_param"] = pin.cred_mgmt(DELETE_CREDENTIAL, mine, token=cm)
    out["delete_someone_elses_param"] = pin.cred_mgmt(DELETE_CREDENTIAL, other, auth=pin.mac(bytes([DELETE_CREDENTIAL]) + mine, key=cm))
    out["delete_byte_only_param"] = pin.cred_mgmt(DELETE_CREDENTIAL, mine, auth=pin.mac(bytes([DELETE_CREDENTIAL]), key=cm))

    checks = {
        "C3: getPinToken's mc|ga token cannot read metadata (0x33)": out["login_token_metadata"] == 0x33,
        "C3: a token asked for with cm can (0x00)": out["cm_token"] == 0 and out["cm_token_metadata"] == 0,
        "C1: a parameter that does not verify is refused with a token current (0x33)": out["wrong_param_metadata"] == 0x33,
        "C1: no parameter is PUAT_REQUIRED (0x36)": out["no_param_metadata"] == 0x36,
        "C2: the owner's own deletion is let through (0x2E, nothing to delete)": out["delete_own_param"] == 0x2E,
        "C2: its parameter does not delete a different credential (0x33)": out["delete_someone_elses_param"] == 0x33,
        "C2: a MAC over the subcommand byte alone is refused (0x33)": out["delete_byte_only_param"] == 0x33,
    }
    out["names"] = {k: status_name(v) for k, v in out.items() if isinstance(v, int) and not isinstance(v, bool)}
    out["checks"] = checks
    out["verdict"] = "spec" if out["set_owner"] == 0 and out["login_token"] == 0 and all(checks.values()) else "DIFF"
    return out


if __name__ == "__main__":
    print(json.dumps(put_the_questions()))
