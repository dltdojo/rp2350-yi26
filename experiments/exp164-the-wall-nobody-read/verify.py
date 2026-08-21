#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Re-derive exp164's finding from a pasted log, off the board.

    python3 verify.py < capture.txt
    yi26 log --seconds 60 | python3 verify.py

The board prints two things that have to agree and are produced by different
means: **eight SAU region descriptors**, read out of the unit a register at a
time, and **fourteen TT responses**, which are the hardware's own answer to
"what is this address". This file derives the second from the first and says so
out loud when they disagree.

What it checks, and it is careful about which rules it is allowed to use:

1. **A disabled region attributes nothing.** If all eight regions read
   `enabled=false`, then no TT response may name a SAU region. That is the
   SAU's own definition and needs no reference manual.
2. **Secure and Non-secure-readable are exclusive.** A line reporting `S=yes`
   and `nsr=yes` at once is a contradiction in the printed map, whatever the
   attribution rules are.
3. **The controls held.** Candidate 1 read the address `cortex-m` publishes,
   not one this firmware invented; candidate 2 compared the SAU across
   `embassy_rp::init()`; candidate 4 shut an ACCESSCTRL bank and required the
   TT answer to be unmoved; candidate 5 required the demoted core to be refused
   by ACCESSCTRL, which is what makes it a demoted core rather than a claim.
4. **The finding, and it is not asserted here either.** Candidate 5's two
   readings are compared: what core 1 saw of the Secure SAU against what core 0
   saw of it. The conclusion printed at the end follows those numbers.

Deliberately NOT used: the Armv8-M rule for combining SAU and IDAU
attribution. This file has no copy of the architecture reference manual and
will not pretend to. Everything above is either a definition or a comparison.

Exit line, machine-readable, always the last line printed:

    OK          controls held, the map follows the registers, the two agree
    BAD         a control did not hold
    DISAGREE    the map and the region descriptors say different things
    INCOMPLETE  fewer than six candidates in the capture

No dependencies, no network, no board.
"""

import re
import sys

CANDIDATES = 6
NAMES = {
    1: "the SAU is implemented and Secure code can read it",
    2: "embassy_rp::init() changes nothing in it",
    3: "the map, address by address",
    4: "shutting a bank moves nothing the SAU can see",
    5: "what a bus-demoted core sees of the Secure SAU",
    6: "demoted before core 1 ever started",
}

STAMP = re.compile(r"^\[\s*\d+ ms\]\s?")
CAND = re.compile(r"^candidate (\d) (.+)$")
OUTCOME = re.compile(r"^candidate (\d) -> (.+)$")
MATRIX = re.compile(r"^\s*(\d) .+ - (.+)$")
REGION = re.compile(
    r"^\s*r(\d) RBAR=(0x[0-9a-f]+) RLAR=(0x[0-9a-f]+) -> "
    r"(0x[0-9a-f]+)\.\.(0x[0-9a-f]+) en=(\d) nsc=(\d)\s*$")
TTLINE = re.compile(
    r"^\s*(0x[0-9a-f]{8}) (.+?)\s+S=(yes|no)\s+nsr=(yes|no)\s+nsrw=(yes|no)\s+"
    r"idau=(-?\d+) sau=(-?\d+)\s*$")
SAULINE = re.compile(
    r"^SAU(?: at entry:| after init:|:)\s+CTRL=(0x[0-9a-f]+) TYPE=(0x[0-9a-f]+) "
    r"SFSR=(0x[0-9a-f]+) SFAR=(0x[0-9a-f]+)\s*$")
CORE1 = re.compile(r"^\s*core 1: up=(\w+) read_done=(\w+) faulted=(\w+) finished=(\w+)")
PAIR = re.compile(r"^\s*(SAU_TYPE|SAU_CTRL)\s+core 0 (0x[0-9a-f]+)\s+core 1 (0x[0-9a-f]+)")
TTPAIR = re.compile(r"^\s*TT of 0x20000000\s+core 0 (0x[0-9a-f]+)\s+core 1 (0x[0-9a-f]+)")
# The same two readings as they come back out of bank 8 in the final report. A
# capture taken after the run is over has this and not the boot that made it,
# which is exactly what `check.sh` is holding when it runs.
BOXFLAGS = re.compile(r"^\s*demoted after :\s+read=(\d) fault=(\d) TYPE=(0x[0-9a-f]+)")
BOXTT = re.compile(r"^\s*TT core1=(0x[0-9a-f]+) core0=(0x[0-9a-f]+)")


def strip(ln):
    return STAMP.sub("", ln).rstrip()


def parse(text):
    regions, tt, sau, outcomes, matrix = {}, {}, [], {}, {}
    cand5, box = {}, {}
    box_next = False
    cur = None
    for raw in text.splitlines():
        ln = strip(raw)

        m = OUTCOME.match(ln)
        if m:
            outcomes[int(m.group(1))] = m.group(2)
            cur = None
            continue
        m = CAND.match(ln)
        if m:
            cur = int(m.group(1))
            continue

        m = REGION.match(ln)
        if m:
            rbar, rlar = int(m.group(2), 16), int(m.group(3), 16)
            # Decoded here from the raw registers, not taken from the board's
            # own decode - and the board's decode is kept alongside so the two
            # can be compared. A bit layout is a claim, and this is the second
            # place it is made.
            regions[int(m.group(1))] = {
                "rbar": rbar,
                "rlar": rlar,
                "base": rbar & ~0x1F,
                "limit": (rlar & ~0x1F) | 0x1F,
                "enabled": bool(rlar & 1),
                "nsc": bool(rlar & 2),
                "board": (int(m.group(4), 16), int(m.group(5), 16),
                          m.group(6) == "1", m.group(7) == "1"),
            }
            continue
        m = TTLINE.match(ln)
        if m:
            # A list, not an assignment. The board prints the map twice - once
            # in candidate 3's boot and once in the final report - and keeping
            # only the last one meant a corrupted first copy was silently
            # overwritten by a clean second one. Both copies are kept, and they
            # have to agree.
            tt.setdefault(int(m.group(1), 16), []).append({
                "what": m.group(2).strip(),
                "secure": m.group(3) == "yes",
                "nsr": m.group(4) == "yes",
                "nsrw": m.group(5) == "yes",
                "idau": int(m.group(6)),
                "sau": int(m.group(7)),
            })
            continue
        m = SAULINE.match(ln)
        if m:
            sau.append(tuple(int(g, 16) for g in m.groups()))
            continue
        if cur == 5:
            m = CORE1.match(ln)
            if m:
                cand5["up"], cand5["read"], cand5["faulted"], cand5["finished"] = (
                    g == "true" for g in m.groups())
            m = PAIR.match(ln)
            if m:
                cand5[m.group(1) + "0"] = int(m.group(2), 16)
                cand5[m.group(1) + "1"] = int(m.group(3), 16)
            m = TTPAIR.match(ln)
            if m:
                cand5["tt0"], cand5["tt1"] = int(m.group(1), 16), int(m.group(2), 16)
        m = BOXFLAGS.match(ln)
        if m:
            box["read"] = m.group(1) == "1"
            box["faulted"] = m.group(2) == "1"
            box["SAU_TYPE1"] = int(m.group(3), 16)
            box_next = True
            continue
        if box_next:
            m = BOXTT.match(ln)
            if m:
                box["tt1"] = int(m.group(1), 16)
                box["tt0"] = int(m.group(2), 16)
            box_next = False

        m = MATRIX.match(ln)
        if m and int(m.group(1)) in NAMES:
            matrix[int(m.group(1))] = m.group(2)
    return regions, tt, sau, outcomes, matrix, cand5, box


def main():
    regions, tt_all, sau, outcomes, matrix, cand5, box = parse(sys.stdin.read())

    # The same address, printed in two different boots, must have the same
    # answer. If it does not, one of the two readings is wrong and this file
    # will not pick a winner.
    disagreeing = {hex(a): v for a, v in tt_all.items() if any(x != v[0] for x in v)}
    if disagreeing:
        for a, v in disagreeing.items():
            print(f"{a} is reported two different ways in this capture: {v}")
        print("DISAGREE")
        return
    tt = {a: v[0] for a, v in tt_all.items()}

    # A capture taken after the run holds bank 8's record of candidate 5 and
    # not the boot that produced it. Fall back to the record, and say so, so
    # that a smaller claim is never made silently.
    full = "up" in cand5
    if not full and box:
        cand5 = dict(box)
        cand5["up"] = True
        cand5["finished"] = False
        cand5["SAU_TYPE0"] = (sau[-1][1] if sau else 0)
        cand5["SAU_CTRL0"] = cand5["SAU_CTRL1"] = (sau[-1][0] if sau else 0)
        print("this capture holds bank 8's record of candidate 5 and not the boot "
              "that made it;")
        print("  SAU_CTRL is compared against the report's own reading rather than "
              "core 1's")

    if len(matrix) < CANDIDATES or not sau:
        print(f"the capture holds {len(matrix)} of {CANDIDATES} candidates "
              f"and {len(sau)} SAU readings")
        print("INCOMPLETE")
        return

    ctrl, type_, sfsr, _sfar = sau[-1]
    sregion = type_ & 0xFF
    print(f"SAU_CTRL={ctrl:#010x} (enable={ctrl & 1}, allns={(ctrl >> 1) & 1}), "
          f"SREGION={sregion}, SFSR={sfsr:#010x}")

    for n in range(1, CANDIDATES + 1):
        print(f"  {n} {NAMES[n]}: {matrix.get(n, '?')}")

    # 1. Every candidate reported something, and none of them said the words
    #    that mean the board disagreed with itself.
    bad = [n for n, v in matrix.items()
           if v.startswith("NOT as expected") or v.startswith("KILLED")
           or v == "not reached"]
    if bad:
        print(f"candidates that did not come out as expected: "
              f"{[(n, matrix[n]) for n in bad]}")
        print("BAD")
        return

    # 2. A disabled region attributes nothing. This is the SAU's own
    #    definition, and it is the whole derivation of the map below.
    if len(regions) != sregion:
        print(f"SREGION says {sregion} regions and the capture holds {len(regions)}")
        print("INCOMPLETE")
        return
    # Does the board's decode of RBAR/RLAR agree with this file's?
    mismatched = [
        i for i, r in regions.items()
        if r["board"] != (r["base"], r["limit"], r["enabled"], r["nsc"])
    ]
    if mismatched:
        for i in mismatched:
            r = regions[i]
            print(f"region {i}: RBAR={r['rbar']:#010x} RLAR={r['rlar']:#010x}; "
                  f"the board decodes {r['board']}, this file decodes "
                  f"{(r['base'], r['limit'], r['enabled'], r['nsc'])}")
        print("DISAGREE")
        return
    print(f"{len(regions)} region descriptors decode the same way twice")

    live = {i: r for i, r in regions.items() if r["enabled"]}
    print(f"{len(regions)} regions read back, {len(live)} of them enabled"
          + (": " + ", ".join(f"{i} at {r['base']:#x}..{r['limit']:#x}"
                              for i, r in live.items()) if live else ""))

    # The derivation, and it goes ONE WAY ONLY.
    #
    # If TT names a SAU region for an address, that region must exist, must be
    # enabled, and must contain the address. Anything else is the map claiming
    # something the descriptors do not say, and it is a disagreement.
    #
    # The converse — an address inside an enabled region must be named — is NOT
    # checked, because it is not true on this part and this file does not know
    # why. `0x00005000` sits inside the one enabled region and TT reports no
    # SAU region for it. Working out whether the IDAU overrides the SAU there,
    # or whether the descriptor means something other than it looks like, needs
    # the Armv8-M reference manual, and guessing at it here would turn an open
    # question into a check. It is reported instead.
    wrong = []
    for a, v in sorted(tt.items()):
        if v["sau"] < 0:
            continue
        r = live.get(v["sau"])
        if r is None or not (r["base"] <= a <= r["limit"]):
            wrong.append((hex(a), v["what"], v["sau"]))
    if wrong:
        for a, what, got in wrong:
            print(f"{a} ({what}): TT names SAU region {got}, which does not cover it")
        print("DISAGREE")
        return
    named = sum(1 for v in tt.values() if v["sau"] >= 0)
    print(f"{len(tt)} addresses in the map; {named} of them named a SAU region, "
          f"and every one that did is inside it")

    unnamed_inside = [(hex(a), v["what"]) for a, v in sorted(tt.items())
                      if v["sau"] < 0
                      and any(r["base"] <= a <= r["limit"] for r in live.values())]
    if unnamed_inside:
        print(f"OPEN: {len(unnamed_inside)} address(es) inside an enabled region that "
              f"TT does not attribute to it:")
        for a, what in unnamed_inside:
            print(f"  {a} ({what})")
        print("  not treated as a disagreement - see the comment in this file")

    # 3. Secure and Non-secure-readable cannot both be true of one address.
    contra = [hex(a) for a, v in tt.items() if v["secure"] and v["nsr"]]
    if contra:
        print(f"addresses reported as Secure and Non-secure-readable at once: {contra}")
        print("DISAGREE")
        return
    print(f"{len(tt)} addresses in the map, none of them both Secure and "
          f"Non-secure-readable")

    # 4. The control that makes candidate 5 a measurement of a demoted core.
    if not (cand5.get("up") and cand5.get("read") and cand5.get("faulted")
            and not cand5.get("finished")):
        print(f"candidate 5's control did not hold: {cand5}")
        print("BAD")
        return
    print("candidate 5: core 1 read the SAU, then was refused by ACCESSCTRL on a "
          "shut bank")

    # 5. The finding follows the two readings; it is not printed over them.
    same_type = cand5.get("SAU_TYPE0") == cand5.get("SAU_TYPE1")
    same_ctrl = cand5.get("SAU_CTRL0") == cand5.get("SAU_CTRL1")
    same_tt = cand5.get("tt0") == cand5.get("tt1")
    print()
    print(f"core 0 / core 1  SAU_TYPE {cand5.get('SAU_TYPE0'):#010x} / "
          f"{cand5.get('SAU_TYPE1'):#010x}")
    print(f"core 0 / core 1  SAU_CTRL {cand5.get('SAU_CTRL0'):#010x} / "
          f"{cand5.get('SAU_CTRL1'):#010x}")
    print(f"core 0 / core 1  TT       {cand5.get('tt0'):#010x} / {cand5.get('tt1'):#010x}")
    if same_type and same_ctrl and same_tt:
        print("the core ACCESSCTRL refuses is the core the SAU answers in full:")
        print("FORCE_CORE_NS marks the bus, not the core.")
    else:
        print("the demoted core got different answers: it is in Non-secure state.")

    if matrix.get(6, "").startswith("as expected: the launch"):
        print("and the other ordering does not exist: demoting before the launch")
        print("leaves spawn_core1 waiting on a FIFO that never answers.")
    print("OK")


if __name__ == "__main__":
    main()
