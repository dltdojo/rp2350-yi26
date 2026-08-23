#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Ask the device itself which signature algorithms it offers.

    python3 algorithms.py > algorithms.json

`fido2-token -I` prints this device's third algorithm as `unknown`, and a
comparison that ruled on `unknown` would be ruling on libfido2's table of names
rather than on the device. `authenticatorGetInfo` field `0x0a` carries the COSE
algorithm identifiers as numbers, so this asks for them directly, over the same
CTAPHID transport exp168 built — using exp173's client, unmodified, because the
point is that a third-party device answers the client this repository already
had.

The CBOR is read with **exp178's** reader rather than exp173's. Both host-side
readers this repository already had refuse a real authenticator's `getInfo`, and
for different reasons: exp169's (copied into exp170 to exp172) rejects text map
keys, and exp173's has no major type 7, so the first `true` in an options map
stops it. Neither device they were written against ever sent either. exp178's
reader is the one that handles both, and it is canonical-only, so if pico-fido's
bytes are sloppy this fails rather than normalising them.

Two things this had to learn about somebody else's firmware:

- **It sends `CTAPHID_KEEPALIVE` (`0x3b`) while it thinks.** exp174 measured
  what that packet is for on this repository's own board; here it arrives
  unbidden from a device nobody here wrote, and a reader that treats the first
  reply as the answer reads `0x01` — PROCESSING — as a CTAP status byte and
  reports an error the device never sent.
- **A stale keepalive outlives the exchange that caused it**, so the link is
  drained before `CTAPHID_INIT` as well as after.
"""

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CTAPHID = os.path.join(HERE, "..", "exp173-a-client-that-is-not-ours", "ctaphid.py")
READER = os.path.join(HERE, "..", "exp178-the-shape-of-the-contract", "closes.py")

# COSE algorithm identifiers, from the IANA registry. Only the ones a FIDO2
# authenticator plausibly advertises are named; anything else is reported as a
# number, which is more useful than the word "unknown".
COSE = {-7: "ES256", -8: "EdDSA", -35: "ES384", -36: "ES512",
        -37: "PS256", -47: "ES256K", -257: "RS256"}

KEEPALIVE = 0x3B


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def drain(link):
    while link.read_packet(timeout=0.2):
        pass


def get_info(m, link):
    drain(link)
    for _ in range(5):
        r = m.init(link)
        if r and "new_cid" in r:
            break
        drain(link)
    else:
        raise SystemExit("the device never answered CTAPHID_INIT")

    cid = bytes.fromhex(r["new_cid"])
    drain(link)
    link.send_message(cid, m.CTAPHID_CBOR, b"\x04")

    keepalives = 0
    while True:
        resp = link.read_message(timeout=5.0)
        if resp is None:
            raise SystemExit("the device stopped answering")
        if resp["cmd"] == KEEPALIVE:
            keepalives += 1
            continue
        break
    body = link.last
    if body[0] != 0:
        raise SystemExit("getInfo returned status 0x%02x" % body[0])
    reader = load("exp178_reader", READER)
    info, at = reader.decode(body[1:])
    if at != len(body) - 1:
        raise SystemExit("%d bytes left over after the map" % (len(body) - 1 - at))
    return info, keepalives, r


def main():
    m = load("ctaphid", CTAPHID)
    link = m.Link()
    info, keepalives, init = get_info(m, link)

    algs = []
    for entry in info.get(10, []):
        alg = entry.get("alg") if isinstance(entry, dict) else None
        algs.append({"cose": alg, "name": COSE.get(alg, "unrecognised"),
                     "type": entry.get("type") if isinstance(entry, dict) else None})

    aaguid = info.get(3)
    out = {"device": link.path,
           "capabilities": "0x%02x" % init["capabilities"],
           "keepalives_before_the_answer": keepalives,
           "versions": info.get(1),
           "aaguid": aaguid.hex() if isinstance(aaguid, (bytes, bytearray)) else aaguid,
           "algorithms": algs,
           "max_msg_size": info.get(5),
           "pin_protocols": info.get(6)}
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
