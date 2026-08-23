#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Ask a FIDO2 device to describe itself, in a form two devices can be diffed by.

    python3 probe.py /dev/hidrawN   > device.json

This is `fido2-token -I` — the host's own tool, nothing installed — parsed into a
normalised dict so compare.py can put two devices side by side. It reads only;
it registers nothing and changes no state. The point of the experiment is that
the same question, asked of a five-dollar board and a commercial key, comes back
in the same fields with different answers, and the differences sort into a small
number of kinds.
"""
import json
import subprocess
import sys


def probe(dev):
    out = subprocess.run(["fido2-token", "-I", dev],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("fido2-token -I %s failed: %s" % (dev, out.stderr.strip()))
    info = {"device": dev, "raw": out.stdout}
    lists = {"version strings": "versions",
             "extension strings": "extensions",
             "transport strings": "transports",
             "algorithms": "algorithms"}
    scalars = {"aaguid": "aaguid", "maxmsgsiz": "max_msg_size",
               "maxcredcntlst": "max_cred_count_list",
               "maxcredlen": "max_cred_len",
               "pin protocols": "pin_protocols",
               "pin retries": "pin_retries"}
    for _, name in lists.items():
        info[name] = []
    info["options"] = []
    for _, name in scalars.items():
        info.setdefault(name, None)
    for line in out.stdout.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if key in lists:
            info[lists[key]] = [v.strip().split(" ")[0] for v in val.split(",") if v.strip()]
        elif key == "options":
            info["options"] = [v.strip() for v in val.split(",") if v.strip()]
        elif key in scalars:
            info[scalars[key]] = val
    # The AAGUID is the identity axis: all-zero is "I claim no model identity",
    # which self-attestation requires; anything else names a certified model.
    info["aaguid_is_zero"] = info.get("aaguid", "") == "0" * 32
    return info


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    print(json.dumps(probe(sys.argv[1]), indent=2))


if __name__ == "__main__":
    main()
