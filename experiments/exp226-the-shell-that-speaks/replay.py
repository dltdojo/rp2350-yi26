#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp226 — what the board said, checked here, as many times as anyone likes.

  replay.py LOG...

LOG is what tools/pages/log.html's Copy button gave, pasted into a file under
board/. Every line the shell prints is checked against what it should be:

  LIFE round minstret gen1 gen256 centre-column
      round r is the r-th life from exp225's seed, each seeded by the last
      generation of the one before — rule30.py's, Rule 30 cell by cell — and
      minstret is 3082, the RTL's count for any seed
  exp226 usb=… setups=… … usb_khz=… sys_khz=… ref_khz=… sof_khz=… lives=… minstret=…
      the port is open (usb=6) and the counts parse
  FAIL check got
      a failed check: always a FAIL here

A file that is inspect.html's report instead (it has a "config 1" tree) is
held against the device usbdev.c describes: 1209:0001, the product and serial,
EF/02/01, and the interfaces and endpoints, line for line.

and the clock registers and sys_khz the board reported are printed, since
those are what nobody had measured before.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "exp225-the-life-every-beat-proved"))
from rule30 import SEED0, history  # noqa: E402

STATUS = re.compile(r"exp226 usb=(\d+) setups=(\d+) stalls=(\d+) dropped=(\d+) errors=(\d+) ref=([0-9a-f]{8}) "
                    r"sys=([0-9a-f]{8}) xosc=([0-9a-f]{8}) pll=([0-9a-f]{8}) usb_khz=(\d+) sys_khz=(\d+) sys48_khz=(\d+) "
                    r"ref_khz=(\d+) sof_khz=(\d+) lives=(\d+) minstret=(\d+)$")
LIFE = re.compile(r"LIFE ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8}) ([0-9a-f]{8})$")


INSPECT_WANT = [
    ("interface", 0, 0x02, 0x02, 0x00), ("endpoint", 0x81, "IN", "interrupt", 8),
    ("interface", 1, 0x0a, 0x00, 0x00), ("endpoint", 0x01, "OUT", "bulk", 64), ("endpoint", 0x82, "IN", "bulk", 64),
]


def inspect_tree(text):
    """inspect.html's report: the device line, its strings and class, and the tree under config 1."""
    dev = re.search(r"device\s+0x([0-9a-f]+):0x([0-9a-f]+)", text)
    strings = {k: (re.search(rf"^\s*{k}\s+(.+?)\s*$", text, re.M) or [None, None])[1]
               for k in ("manufacturer", "product", "serial")}
    head = text.split("config 1", 1)[0]
    cls = [int(re.search(rf"^\s*{k}\s+0x([0-9a-f]+)", head, re.M).group(1), 16) for k in ("class", "subclass", "protocol")]
    tree, cur = [], None
    for line in text.split("config 1", 1)[1].splitlines():
        m = re.match(r"\s+interface (\d+)\s+alt", line)
        if m:
            cur = ["interface", int(m.group(1))]
            tree.append(cur)
        m = re.match(r"\s+(class|subclass|protocol)\s+0x([0-9a-f]+)", line)
        if m and cur is not None and len(cur) < 5:
            cur.append(int(m.group(2), 16))
        m = re.match(r"\s+endpoint (0x[0-9a-f]+)\s+(IN|OUT)\s+(\w+)\s+(\d+) bytes", line)
        if m:
            tree.append(("endpoint", int(m.group(1), 16), m.group(2), m.group(3), int(m.group(4))))
    return (int(dev.group(1), 16), int(dev.group(2), 16)), strings, cls, [tuple(x) for x in tree]


def inspect_report(path, text):
    ids, strings, cls, tree = inspect_tree(text)
    ok = (ids == (0x1209, 0x0001) and strings == {"manufacturer": "rp2350-yi26",
          "product": "exp226 the shell that speaks", "serial": "226"} and cls == [0xef, 0x02, 0x01]
          and tree == INSPECT_WANT)
    print(("PASS  " if ok else "FAIL  ") + f"{os.path.basename(path)}: inspect.html on a phone saw the device usbdev.c "
          f"describes — 1209:0001, {strings['product']}, serial {strings['serial']}, EF/02/01, "
          f"0x81 interrupt 8, 0x01 and 0x82 bulk 64" + ("" if ok else f" — got {ids} {strings} {cls} {tree}"))
    return 0 if ok else 1


def lives(n):
    out, seed = [], SEED0
    for _ in range(n):
        h = history(seed)
        out.append((h[0], h[-1], sum(((h[g] >> 16) & 1) << g for g in range(32))))
        seed = h[-1]
    return out


def replay(paths):
    failed, seen = 0, {"LIFE": 0, "exp226": 0, "FAIL": 0}
    for path in paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        if "config 1" in text:
            failed += inspect_report(path, text)
            seen["inspect"] = seen.get("inspect", 0) + 1
            continue
        want = lives(64)
        nstatus, last = 0, None
        for raw in text.splitlines():
            ln = raw.strip()
            m = LIFE.search(ln)
            if m:
                r, instret, g1, g256, col = (int(x, 16) for x in m.groups())
                seen["LIFE"] += 1
                if r >= len(want) or (g1, g256, col) != want[r] or instret != 3082:
                    failed += 1
                    print(f"FAIL  {os.path.basename(path)}: {ln} — rule30.py says life {r} is "
                          f"{' '.join(f'{x:08x}' for x in want[r]) if r < len(want) else '?'}, minstret 3082")
                continue
            m = STATUS.search(ln)
            if m:
                seen["exp226"] += 1
                nstatus += 1
                last = m
                continue
            if "FAIL" in ln and ln.startswith("FAIL"):
                seen["FAIL"] += 1
                failed += 1
                print(f"FAIL  {os.path.basename(path)}: the board reported {ln}")
        if nstatus:
            (usb, setups, stalls, dropped, errors, ref, sys_, xosc, pll, usb_khz, sys_khz, sys48_khz, ref_khz,
             sof_khz, nl, mi) = last.groups()
            print(f"PASS  {os.path.basename(path)}: {nstatus} status lines, the last: usb={usb} setups={setups} "
                  f"stalls={stalls} dropped={dropped} errors={errors} lives={nl} minstret={mi}")
            print(f"      the bootrom left clk_ref_ctrl={ref} clk_sys_ctrl={sys_} xosc_status={xosc} pll_usb_cs={pll}")
            print(f"      against the crystal: clk_usb {usb_khz} kHz, clk_sys {sys_khz} kHz as left and {sys48_khz} kHz "
                  f"moved, clk_ref {ref_khz} kHz; "
                  f"clk_sys against the host's frames {sof_khz} kHz")
            if usb != "6" or (mi != "0" and mi != "3082"):
                failed += 1
                print(f"FAIL  {os.path.basename(path)}: the last status should say usb=6 and minstret=3082")
    if seen["LIFE"] and not failed:
        print(f"PASS  every LIFE line ({seen['LIFE']}) is rule30.py's life, minstret 3082")
    if not seen["LIFE"] and not seen["exp226"] and not seen.get("inspect"):
        failed += 1
        print("FAIL  no line the shell prints was found")
    return failed


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(1 if replay(sys.argv[1:]) else 0)
