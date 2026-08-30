#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp192 — put the three accounts of one session beside each other.

The page says what it asked for and what came back. The board says what actually
arrived. salt.py says what a browser could plausibly have derived. Only the
board's line can settle the question, and only because it is the device's own
words rather than the client's.

    python3 analyse.py transcript.json board.log > analysis.json
"""

import json
import re
import sys

import salt as salt_mod

# Sixteen bytes a line, because the board's log ring has a fixed line width and
# a 32-byte salt does not fit. The first run of this experiment printed 28 of
# the 32 and the rest was gone — enough to name the salt beyond any doubt, and
# not enough to *be* it.
SALT_CHUNK = re.compile(r"hmac-secret: salt in \[(\d+)\.\.(\d+)\] = ([0-9a-f]+)")
# The one-line form the first capture used, kept so that transcript can still
# be read by this file. A capture ages and is recorded rather than repaired.
SALT_LINE = re.compile(r"hmac-secret: salt in = ([0-9a-f]+)")
FLAGS_LINE = re.compile(r"hmac-secret: (\d+)B salt in, (\d+)B out, UV=(true|false)")


def main(transcript_path, board_path):
    entries = []
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))

    board = open(board_path, errors="replace").read()

    # Chunks first: consecutive pieces starting at offset 0 are one salt.
    salts, current, expect = [], "", 0
    for start, end, hexpart in SALT_CHUNK.findall(board):
        if int(start) == 0:
            if current:
                salts.append(current)
            current, expect = hexpart, int(end)
        elif int(start) == expect:
            current += hexpart
            expect = int(end)
        else:                       # a gap: this reading is not whole
            if current:
                salts.append(current)
            current, expect = "", 0
    if current:
        salts.append(current)
    salts += SALT_LINE.findall(board)
    uv_lines = [(int(a), int(b), c == "true") for a, b, c in FLAGS_LINE.findall(board)]

    prf_input = next((e.get("prfInput") for e in entries if e.get("prfInput")), None)
    creates = [e for e in entries if e.get("step") == "create"]
    gets = [e for e in entries if e.get("step") == "get"]

    out = {
        "prf_input": prf_input,
        "user_agent": next((e.get("userAgent") for e in entries if e.get("userAgent")), None),
        "rp_id": next((e.get("rpId") for e in entries if e.get("rpId")), None),
        "entries": len(entries),
        # What create() gave back. For a security key hmac-secret is not
        # evaluated at registration, so bytes here would be the surprise.
        "create_prf": creates[0].get("prf") if creates else None,
        "create_error": creates[0].get("error") if creates else None,
        "salts_the_board_received": salts,
        "uv_the_board_saw": [u[2] for u in uv_lines],
        "gets": [],
    }

    # Each get(), paired with the salt the board logged for it. The pairing is
    # positional and that is stated rather than hidden: the board's log has no
    # way to name which browser call a salt belonged to, so a run where the
    # counts differ is a run this cannot pair, and says so.
    out["pairable"] = (len(gets) == len(salts))
    for i, g in enumerate(gets):
        observed = salts[i] if i < len(salts) else None
        row = {
            "userVerification": g.get("userVerification"),
            "error": g.get("error"),
            "prf_first_hex": g.get("prfFirstHex"),
            "authdata_flags": g.get("flags"),
            "salt_the_board_received": observed,
            "which_candidate": (
                salt_mod.name_for(observed, prf_input.encode())
                if observed and prf_input else None
            ),
        }
        out["gets"].append(row)

    if prf_input:
        out["candidates"] = {k: v.hex() for k, v in salt_mod.candidates(prf_input.encode()).items()}
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: analyse.py transcript.json board.log", file=sys.stderr)
        raise SystemExit(64)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
