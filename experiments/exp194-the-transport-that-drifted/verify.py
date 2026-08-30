#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""exp194 verification — rules on a capture.txt written by drift.sh.

**This does not require the copies to disagree.** The claim is that they were
never checked against each other, and the measurement is what it is: if six
firmwares off one accretion chain all answer the specification, that is a real
answer and this says so. What is graded here is whether the *measurement* is
valid — every subject came up, every case ran, and every verdict is a verdict
rather than a crash.

The assertion with teeth is the last block: exp194's own firmware, built on
`crates/ctap-hid`, must be `spec` in every cell. A crate extracted from fourteen
copies has no excuse to be worse than the best of them.
"""

import json
import re
import sys

# The subject built on the crate. Held to a different standard than the ones it
# was extracted from: they are evidence, it is the product.
CRATE_SUBJECT = "exp194"


def rows(text):
    """(firmware, case, verdict, raw) for every case that ran."""
    for m in re.finditer(r"^-- (\S+) \| (.+?) --$\n(.*?)$", text, re.M):
        fw, case, line = m.group(1), m.group(2), m.group(3).strip()
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            yield fw, case, "did not return JSON", line
            continue
        yield fw, case, d.get("verdict", "no verdict"), line


def subjects(text):
    return [m.group(1) for m in re.finditer(r"^== (\S+) ==$", text, re.M)]


def verify(text):
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    subs = subjects(text)
    table = {}
    for fw, case, verdict, _ in rows(text):
        table.setdefault(fw, {})[case] = verdict

    # --- the measurement is valid -------------------------------------------
    rule(len(subs) >= 2, f"{len(subs)} firmwares were asked", "fewer than two firmwares ran, so there is nothing to compare")

    came_up = [s for s in subs if s in table]
    rule(
        len(came_up) == len(subs),
        f"and every one of them came up and answered ({len(came_up)})",
        f"these never answered: {sorted(set(subs) - set(table))}",
    )

    cases = sorted({c for fw in table for c in table[fw]})
    complete = [fw for fw in table if len(table[fw]) == len(cases)]
    rule(
        len(complete) == len(table),
        f"and every one answered all {len(cases)} cases",
        f"incomplete: {[fw for fw in table if len(table[fw]) != len(cases)]}",
    )

    crashed = [(fw, c) for fw in table for c, v in table[fw].items() if "JSON" in v or v == "no verdict"]
    rule(not crashed, "and every case produced a verdict", f"these produced no verdict: {crashed}")

    # --- the table ----------------------------------------------------------
    print()
    width = max((len(c) for c in cases), default=10)
    order = [s for s in subs]
    print(f"      {'case'.ljust(width)}  " + "  ".join(s.ljust(6) for s in order))
    disagreements = []
    for c in cases:
        marks = []
        for fw in order:
            v = table.get(fw, {}).get(c, "—")
            marks.append(("ok" if v == "spec" else "DIFF").ljust(6))
        line = f"      {c.ljust(width)}  " + "  ".join(marks)
        print(line)
        off = {fw: table[fw][c] for fw in order if table.get(fw, {}).get(c, "spec") != "spec"}
        if off:
            disagreements.append((c, off))
    print()

    # --- what was found, stated either way ----------------------------------
    if disagreements:
        print(f"      {len(disagreements)} of {len(cases)} cases are answered differently by these firmwares:")
        for c, off in disagreements:
            for fw, v in off.items():
                print(f"        {fw} {c}: {v}")
    else:
        print(f"      all {len(subs)} firmwares answered all {len(cases)} cases as the "
              "specification requires — the chain drifted in size, not in behaviour")
    print()

    # --- the product is held to the specification ---------------------------
    crate = [fw for fw in table if fw.startswith(CRATE_SUBJECT)]
    if crate:
        fw = crate[0]
        wrong = {c: v for c, v in table[fw].items() if v != "spec"}
        rule(
            not wrong,
            f"{fw}, built on crates/ctap-hid, answered every case as the specification requires",
            f"{fw} is built on the extracted crate and is wrong at: {wrong}",
        )
    else:
        print(f"SKIP  no {CRATE_SUBJECT} firmware in this capture — the extraction has not been driven yet")

    return ok


if __name__ == "__main__":
    sys.exit(0 if verify(open(sys.argv[1]).read()) else 1)
