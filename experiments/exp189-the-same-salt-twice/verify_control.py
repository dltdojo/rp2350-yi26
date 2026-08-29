#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp189 control verification — rules on control.json and control-nopress.json.

The control is somebody else's tool, so what is checked here is different from
what verify.py checks. verify.py compares two recorded runs of *this* firmware
because an hmac-secret output is a key and not evidence. Here there is real
evidence: a file went in, a file came out, and they are either the same bytes or
they are not.

What must not be trusted is the host's own account of why. `age` printing an
error is equally consistent with "the board refused" and "nobody was there", so
every rule that matters is cross-checked against the board's own log — the count
of times the pad actually read low, which control.sh records.
"""

import json
import re
import sys

FAILED = False


def rule(good, yes, no):
    global FAILED
    print(("PASS  " + yes) if good else ("FAIL  " + no))
    if not good:
        FAILED = True


def verify(d):
    rule(d.get("generated"),
         "the plugin registered a credential on this board",
         "the plugin did not get through -g — the transcript is the finding, not this line")

    r = d.get("recipient") or ""
    rule(re.fullmatch(r"age1fido2-hmac1[0-9a-z]+", r) is not None,
         f"the recipient is a fido2-hmac recipient ({len(r)} chars)",
         f"not a plugin recipient: {r!r} — a bare `age1...` means the plugin was not used")

    # The half exp191 is built around: encryption is offline, and only opening
    # the file costs a finger.
    rule(d.get("encrypted_without_board"),
         "a file was encrypted to it with no board attached",
         "encryption needed the board — then the plugin is in -s mode and exp191's shape is wrong")

    opened = d.get("decrypted_with_identity_file") or d.get("decrypted_with_magic_identity")
    rule(opened,
         "and opened again, byte-identical to what went in",
         "the file did not come back — a control that cannot open its own file measures nothing")

    # The host says it succeeded. The board says how many times somebody was
    # actually there. Only the second can tell a press from a device that
    # answered on its own.
    presses = d.get("presses_the_board_saw", 0)
    rule(presses >= 3,
         f"the board's own log counted {presses} presses, so a person was there for each",
         f"the board saw {presses} presses for a run that claims three — the log is the arbiter")

    # What the plugin turned out **not** to need, which is why this board is
    # enough: no PIN, and no discoverable credential.
    mc = d.get("make_credential_line") or ""
    rule("rk=false" in mc and "uv=false" in mc,
         f"the plugin asked for neither a resident key nor user verification",
         f"the plugin asked for more than this board offers: {mc!r}")
    print(f"      what it registered against: {d.get('rp_id_the_plugin_chose')}")
    return not FAILED


def verify_nopress(d):
    n = d.get("attempts", 0)
    rule(n >= 3, f"{n} attempts, which is enough to call a refusal a habit",
         f"{n} attempts is not a habit")
    rule(d.get("opened") == 0,
         f"nobody pressed, {n} times, and the file never opened",
         f"the file opened {d.get('opened')} times with nobody meant to be pressing")

    # A refusal that still wrote the plaintext somewhere is not a refusal. This
    # is exp191's leaky-CLI rule applied to somebody else's tool.
    rule(d.get("wrote_plaintext_anyway") == 0,
         "and nothing was written on the way to refusing",
         f"{d.get('wrote_plaintext_anyway')} refusals still left plaintext behind")

    print(f"      the word for the refusal: {d.get('refusal') or '(nothing recorded)'}")
    rule(bool(d.get("refusal")),
         "the refusal is recorded in the tool's own words",
         "no refusal was recorded — then nothing distinguishes this from the tool not running")

    # The device's own account. An empty line here is the finding: the pad never
    # read low, so this was not a press that arrived too late.
    b = d.get("bootsel_line") or ""
    rule(b == "",
         "and the board never read BOOTSEL low, so this was nobody rather than a slow finger",
         f"the board did read a press: {b} — the run is not a no-press run")
    return not FAILED


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: verify_control.py control.json [control-nopress.json]", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        verify(json.load(f))
    if len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            verify_nopress(json.load(f))
    sys.exit(1 if FAILED else 0)
