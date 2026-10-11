#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# exp228 — what a phone gave back, checked line by line.
#
#   board.py build/expect.h board/round1-log.txt ...
#
# Every CASE line must be the case it names, in its place: the exit code
# script.py's verdict, minstret the model's count plus the shell's (expect.h),
# and the signatures checked and found valid the ones script.py asks about. A
# ROUND line must close a round whose every case the log holds, or it says
# so; a log may start or end part way through a round. Every status line must
# have dropped nothing and seen no bus error.

import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cases                     # noqa: E402
from script import script_verdict  # noqa: E402


def expected_cases(expect_h):
    """Name, verdict, minstret, signatures checked and valid, for each hand case."""
    counts = {}
    for line in open(expect_h):
        m = re.match(r'    \{"(.*)", \d+, \d+, \d+, \d+, (\d+), (\d+)\},$', line)
        if m:
            counts[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    rows = []
    for name, (script, stack, _) in cases.hand().items():
        asked = []

        def sig(pk, s):
            asked.append(cases.valid(pk, s))
            return asked[-1]

        want = script_verdict(script, stack, sig=sig, h=lambda b: hashlib.sha256(b).digest())
        if counts.get(name, (None,))[0] != want:
            sys.exit(f"board.py: {name}: expect.h and script.py disagree — rebuild")
        rows.append((name, want, counts[name][1], len(asked), sum(asked)))
    return rows


def check_log(path, rows):
    bad, seen, rounds, statuses = [], {}, [], 0
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if line.startswith("CASE "):
            w = line.split(" ", 8)
            rnd, i, code, want, instret, sigs, valid = (int(x, 16) for x in w[1:8])
            name = w[8] if len(w) > 8 else ""
            if i >= len(rows):
                bad.append(f"line {n}: case {i}, of {len(rows)}")
                continue
            ename, ewant, einstret, esigs, evalid = rows[i]
            got = (name, code, want, instret, sigs, valid)
            if got != (ename, ewant, ewant, einstret, esigs, evalid):
                bad.append(f"line {n}: {got}, not {(ename, ewant, ewant, einstret, esigs, evalid)}")
            seen.setdefault(rnd, set()).add(i)
        elif line.startswith("ROUND "):
            # A round of fewer cases is an older exp228.uf2's: revision 2 ran the first 33.
            rnd, count = (int(x, 16) for x in line.split()[1:3])
            whole = seen.get(rnd, set()) >= set(range(count))
            rounds.append((rnd, whole))
            if count > len(rows):
                bad.append(f"line {n}: ROUND says {count} cases, more than {len(rows)}")
        elif line.startswith("exp228 usb="):
            statuses += 1
            f = dict(kv.split("=", 1) for kv in line.split()[1:])
            if f.get("dropped") != "0" or f.get("errors") != "0":
                bad.append(f"line {n}: dropped={f.get('dropped')} errors={f.get('errors')}")
        elif line.startswith("FAIL"):
            bad.append(f"line {n}: {line}")
    lines = sum(len(s) for s in seen.values())
    whole = [r for r, w in rounds if w]
    if not lines:
        bad.append("no CASE line")
    what = (f"{lines} CASE lines over rounds {min(seen)}–{max(seen)}, each its case's verdict, "
            f"minstret and signatures; {len(rounds)} ROUND lines, "
            f"{len(whole)} closing a round the log holds whole ({', '.join(map(str, whole)) or 'none'}); "
            f"{statuses} status lines, nothing dropped, no bus error") if lines else "nothing"
    if bad:
        print(f"FAIL  {path}: " + "; ".join(bad[:5]))
        return 1
    print(f"PASS  {path}: {what}")
    return 0


if __name__ == "__main__":
    rows = expected_cases(sys.argv[1])
    sys.exit(1 if sum(check_log(p, rows) for p in sys.argv[2:]) else 0)
