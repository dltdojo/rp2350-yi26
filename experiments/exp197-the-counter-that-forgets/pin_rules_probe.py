#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp197's board half: ask a freshly flashed authenticator the questions
exp186's probe never asked, and print one JSON object.

Needs a board running a firmware built on crates/client-pin (exp186-exp189),
freshly flashed so no PIN is set, and nobody: no PIN operation here waits for
a person.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "ctaphid"))

from ctaphid import Link  # noqa: E402
from clientpin import ClientPin, status_name  # noqa: E402

OWNER = "123456"
INTRUDER = "999999"
GUESS = "000000"


def ask_the_board():
    link = Link()
    pin = ClientPin(link, link.open_channel())
    out = {"retries_before": pin.retries(), "set_owner": pin.set_pin(OWNER)}

    # P1: "If a PIN has already been set, authenticator returns
    # CTAP2_ERR_PIN_AUTH_INVALID error."
    out["set_intruder"] = pin.set_pin(INTRUDER)
    # P3 and P5: three wrong in a row, then the owner's PIN too.
    out["three_wrong"] = [pin.get_pin_token(GUESS)[0] for _ in range(3)]
    out["retries_after_three"] = pin.retries()
    out["owner_after_three"] = pin.get_pin_token(OWNER)[0]

    checks = {
        "a second setPIN is refused with PIN_AUTH_INVALID (0x33)": out["set_intruder"] == 0x33,
        "three wrong PINs answer INVALID, INVALID, AUTH_BLOCKED (0x31 0x31 0x34)": out["three_wrong"] == [0x31, 0x31, 0x34],
        "and five attempts are left for the owner": out["retries_after_three"] == 5,
        "and even the owner's PIN waits for a power cycle (0x34)": out["owner_after_three"] == 0x34,
    }
    out["names"] = {k: status_name(v) for k, v in out.items() if isinstance(v, int) and not isinstance(v, bool) and k.startswith(("set", "owner"))}
    out["checks"] = checks
    out["verdict"] = "spec" if out["set_owner"] == 0 and all(checks.values()) else "DIFF"
    return out


if __name__ == "__main__":
    print(json.dumps(ask_the_board()))
