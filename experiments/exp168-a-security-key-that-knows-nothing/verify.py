#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check exp168's transcript against the protocol, off the board.

    python3 verify.py < capture.txt

Prints OK, DISAGREE or INCOMPLETE on the last line.

Two voices, on two interfaces: `>>> host:` lines and the JSON under them come
from a CTAPHID client talking to /dev/hidraw, and the `[ ms]` lines come from
the board's own CDC log. Neither is trusted about the other.

The derivation that matters is arithmetic, not agreement. A CTAPHID
initialisation packet carries 57 payload bytes and each continuation packet
carries 59, so the number of packets a message of N bytes takes is

    1 + ceil(max(0, N - 57) / 59)

and that is computed here from N rather than read from the log. A device that
fragmented wrongly but consistently would satisfy every "the host and the board
agree" check and fail this one.

Also derived:

  - every echo came back byte-identical, for every length below the limit;
  - each deliberate mistake drew the error code the specification names, and
    the codes are not interchangeable;
  - a continuation packet for a transaction nobody started drew **silence**,
    which is the one place CTAPHID prescribes no answer;
  - the report descriptor the board printed is 34 bytes and begins with usage
    page 0xF1D0, which is the only reason a host's FIDO tooling looks at it;
  - the capability byte says `nocbor` and `nomsg`, which is this device
    declaring in the protocol's own words that it knows nothing.
"""

import json
import math
import re
import sys

INIT_PAYLOAD, CONT_PAYLOAD = 57, 59

#: What each case must produce. `None` means no reply at all.
EXPECTED = {
    "init": ("reply", 6),
    "ping 8": ("echo", 8),
    "ping 57": ("echo", 57),
    "ping 58": ("echo", 58),
    "ping 200": ("echo", 200),
    "ping 1024": ("echo", 1024),
    "ping 2000": ("error", "ERR_INVALID_LEN"),
    "bad-seq": ("error", "ERR_INVALID_SEQ"),
    "busy": ("error", "ERR_CHANNEL_BUSY"),
    "truncated": ("error", "ERR_MSG_TIMEOUT"),
    "unknown": ("error", "ERR_INVALID_CMD"),
    "stray-cont": ("silence", None),
}

CASE = re.compile(r"^>>> host: case (?P<case>.+?)\s*$")


def packets_for(n):
    """How many packets a message of n bytes must take. The whole of CTAPHID's
    fragmentation, in one line, computed rather than observed."""
    if n <= INIT_PAYLOAD:
        return 1
    return 1 + math.ceil((n - INIT_PAYLOAD) / CONT_PAYLOAD)


def main():
    lines = [l.rstrip("\n") for l in sys.stdin]
    problems, notes = [], []

    seen = {}
    case = None
    for l in lines:
        m = CASE.match(l)
        if m:
            case = m.group("case")
            continue
        stripped = l.strip()
        if case and stripped.startswith("{"):
            try:
                seen[case] = json.loads(stripped)
            except json.JSONDecodeError:
                problems.append(f"{case}: the client's output is not JSON")
            case = None

    missing = [c for c in EXPECTED if c not in seen]
    if missing:
        print(f"cases with no result in this transcript: {', '.join(missing)}")
        print("INCOMPLETE")
        return 1

    for name, (kind, want) in EXPECTED.items():
        d = seen[name]
        r = d.get("reply")
        if kind == "silence":
            if r is not None:
                problems.append(f"{name}: expected no reply, got {r}")
            continue
        if r is None:
            problems.append(f"{name}: no reply at all")
            continue
        if kind == "error":
            if r.get("error_name") != want:
                problems.append(f"{name}: expected {want}, got {r.get('error_name')}")
            continue
        if kind == "reply":
            if r.get("cmd") != want:
                problems.append(f"{name}: expected command {want:#04x}, got {r.get('cmd')}")
            if not d["reply"].get("nonce_echoed", d.get("nonce_echoed")):
                problems.append(f"{name}: the nonce was not echoed")
            continue

        # An echo. Three separate things have to hold, and only the first is
        # what a naive check would look at.
        if r.get("len") != want:
            problems.append(f"{name}: {r.get('len')} bytes back, {want} sent")
        if not d.get("echo_matches"):
            problems.append(f"{name}: the bytes that came back are not the bytes that went out")
        for side, key in (("sent", "sent_packets"), ("received", "packets")):
            got = d.get(key) if key in d else r.get(key)
            need = packets_for(want)
            if got != need:
                problems.append(f"{name}: {got} packets {side}, arithmetic says {need}")

    # ---- channels ---------------------------------------------------------
    cids = [d["reply"]["cid"] for d in seen.values() if d.get("reply")]
    if "00000000" in cids:
        problems.append("a reserved channel identifier was allocated")
    inits = [d for n, d in seen.items() if n == "init"]
    if inits and inits[0]["reply"].get("new_cid") in ("00000000", "ffffffff"):
        problems.append("INIT allocated a reserved or broadcast channel")

    # ---- the board's own voice --------------------------------------------
    board = [l.strip() for l in lines if re.match(r"^\s*\[\s*\d+ ms\]", l)]
    if any("lines lost" in l for l in board):
        problems.append("the board's log has a gap: usb-log dropped lines")
    desc = "".join(
        re.sub(r"^\[\s*\d+ ms\]\s+", "", l) for l in board if re.search(r"^\[\s*\d+ ms\]\s+[0-9a-f]{20,}$", l)
    )
    if desc:
        if len(desc) != 68:
            problems.append(f"the printed report descriptor is {len(desc) // 2} bytes, not 34")
        if not desc.startswith("06d0f10901"):
            problems.append("the report descriptor does not begin with usage page 0xF1D0")
        notes.append(f"report descriptor: {len(desc) // 2} bytes, usage page 0xF1D0")
    else:
        problems.append("the board never printed its report descriptor")

    caps = next((l for l in lines if "caps:" in l), None)
    if caps is None:
        problems.append("fido2-token -I did not report the device's capabilities")
    else:
        if "nocbor" not in caps or "nomsg" not in caps:
            problems.append(f"the device claims a capability it does not have: {caps.strip()}")
        notes.append(caps.strip())

    listed = next((l for l in lines if "/dev/hidraw" in l and "vendor=" in l), None)
    if listed is None:
        problems.append("fido2-token -L did not list the device")
    else:
        notes.append("listed by the host's own FIDO tooling, unprivileged")

    for n in notes:
        print(f"note: {n}")
    print("OPEN: this device has no cryptography; nothing here says it could be trusted with any")

    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
