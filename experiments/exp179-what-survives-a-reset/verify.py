#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reads one of this experiment's transcripts and rules on what it shows.

    python3 verify.py --cold capture-cold-boot.txt
    python3 verify.py --after-flash capture-after-flash.txt

The two transcripts are the experiment. One is what the board says after a
watchdog reset and a flash — power never gone — and the other is what it says
after somebody pulled the cable out. The rules below are written **in both
directions on purpose**, the way exp173's are: a cold transcript that shows the
marker is a transcript where power never actually went away, and it fails here
rather than being read as a result.
"""

import re
import sys

# The band the earlier work's own criteria call healthy for SRAM startup noise.
HEALTHY = (45.0, 55.0)
BLOCKS = 130
WINDOWS = ("uninit", "prior", "bank8")

BOOT = re.compile(r"boot #(\d+),")
ONES = re.compile(r"(\.uninit \(ours\)|0x2007c000 [^:]*|0x20080000 [^:]*): (\d+) of (\d+) one-bits \(([\d.]+)%\)")
VERDICT = re.compile(r"^\s+\[.*?\]\s+(ALL ZERO|ALL ONES|OUR MARKER|SOMETHING ELSE)")
ZEROMAP = re.compile(r"zero map: (\d+) of (\d+) 4 KB blocks")


def parse(path):
    """Transcript to a list of boots, each a dict of what that boot reported."""
    boots, current = [], None
    for line in open(path):
        if line.lstrip().startswith("#"):
            continue
        m = BOOT.search(line)
        if m:
            current = {"boot": int(m.group(1)), "windows": [], "zero_blocks": None}
            boots.append(current)
            continue
        if current is None:
            continue
        m = ONES.search(line)
        if m:
            current["windows"].append({"name": m.group(1).strip(), "ones": int(m.group(2)),
                                       "bits": int(m.group(3)), "percent": float(m.group(4)),
                                       "verdict": None})
            continue
        m = re.search(r"(ALL ZERO|ALL ONES|OUR MARKER|SOMETHING ELSE)", line)
        if m and current["windows"]:
            current["windows"][-1]["verdict"] = m.group(1)
            continue
        m = ZEROMAP.search(line)
        if m:
            current["zero_blocks"] = (int(m.group(1)), int(m.group(2)))
    return boots


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("--cold", "--after-flash"):
        raise SystemExit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    boots = parse(path)
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    check(len(boots) >= 2, f"{path} carries at least two boots (found {len(boots)})")
    if not boots:
        sys.exit(1)
    first = boots[0]
    check(first["boot"] == 1, "the first boot in it is boot #1")
    check(len(first["windows"]) == 3, "boot #1 reports all three windows")

    if mode == "--cold":
        for w in first["windows"]:
            lo, hi = HEALTHY
            check(lo <= w["percent"] <= hi,
                  "%s: %.1f%% one-bits, inside the %g–%g%% band the earlier work's own "
                  "criteria call healthy" % (w["name"], w["percent"], lo, hi))
            # The direction that matters most: if the marker is still there, the
            # power did not really go, and this transcript proves nothing.
            check(w["verdict"] == "SOMETHING ELSE",
                  "%s is neither zeroed nor our marker — which is what a real power "
                  "cycle has to look like" % w["name"])
        check(first["zero_blocks"] == (0, BLOCKS),
              "not one of the %d 4 KB blocks is entirely zero after power returned" % BLOCKS)
        later = [b for b in boots if b["boot"] > 1]
        check(any(w["verdict"] == "OUR MARKER" for b in later for w in b["windows"]),
              "and the warm boots after it do show the marker — the control that says "
              "the firmware can see one when it is there")

    else:
        for w in first["windows"]:
            check(w["verdict"] == "ALL ZERO" and w["ones"] == 0,
                  "%s: zero one-bits on the boot straight after flashing" % w["name"])
        zeroed, total = first["zero_blocks"]
        check(zeroed >= 120 and total == BLOCKS,
              "%d of %d 4 KB blocks are entirely zero — the flashing path clears SRAM "
              "wholesale, which is the reading the earlier work took" % (zeroed, total))
        later = [b for b in boots if b["boot"] > 1]
        marker = [w for b in later for w in b["windows"] if w["verdict"] == "OUR MARKER"]
        check(len(marker) >= 2,
              "after a watchdog reset the marker is still in .uninit and in bank 8 — "
              "so a reset that keeps the power clears nothing")
        prior_after = [w for b in later for w in b["windows"]
                       if w["name"].startswith("0x2007c000")]
        check(all(w["verdict"] == "ALL ZERO" for w in prior_after),
              "and 0x2007c000 stays zero, because nothing writes there — not because "
              "anything clears it a second time")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
