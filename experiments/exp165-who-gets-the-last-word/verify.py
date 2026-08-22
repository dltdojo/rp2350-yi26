#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Re-derive exp165's readings from the log, off the board, with nothing installed.

    python3 verify.py < capture.txt

Prints OK, DISAGREE, BAD or INCOMPLETE on the last line.

**What this does that check.sh cannot.** check.sh reads sentences the firmware
printed. This decodes the numbers those sentences are about. Every `TT` line
carries its raw response word next to the fields the board decoded out of it,
so the decode is a claim that can be checked rather than a result to be
believed - exp164 shipped a decode that disagreed with the register it came
from, and only printing both caught it.

**What it deliberately does not know.** The Armv8-M rule for combining SAU and
IDAU attribution. exp164 had no copy of the architecture manual and neither has
this, so nothing here derives what the attribution *should* be. It derives only
what the log must agree with itself about:

  - the fields on a TT line must follow from the raw word on the same line
  - a region's printed base/limit must follow from its raw RBAR/RLAR
  - "MOVED" and "unmoved" must follow from the readings either side
  - the verdict must follow from candidate 3's two readings
  - an address may not be Secure and Non-secure-readable at once

The one thing this experiment found that the manual would be needed to *name*
is printed as OPEN rather than checked.
"""

import re
import sys

# Armv8-M TT response payload. Named here rather than inline because a bit
# position is exactly the kind of thing that is wrong once and then copied.
MREGION = (0, 0xFF)
SREGION = (8, 0xFF)
MRVALID = 16
SRVALID = 17
R = 18
RW = 19
NSR = 20
NSRW = 21
S = 22
IRVALID = 23
IREGION = (24, 0xFF)


def bit(word, n):
    return (word >> n) & 1


def field(word, spec):
    shift, mask = spec
    return (word >> shift) & mask


def decode(word):
    """The fields `cortex-m` would report for this response word.

    `ns_readable()` is documented as `readable() && !secure()` rather than as
    bit 20, and this follows the crate, because the crate is what produced the
    line being checked.
    """
    secure = bool(bit(word, S))
    readable = bool(bit(word, R))
    sau = field(word, SREGION) if bit(word, SRVALID) else -1
    idau = field(word, IREGION) if bit(word, IRVALID) else -1
    return {
        "secure": secure,
        "nsr": readable and not secure,
        "sau": sau,
        "idau": idau,
        "nsr_bit": bool(bit(word, NSR)),
        "rw": bool(bit(word, RW)),
    }


TT = re.compile(
    r"^\s*(?P<what>.+?)\s+(?P<addr>0x[0-9a-f]{8})\s+"
    r"S=(?P<s>yes|no)\s+nsr=(?P<nsr>yes|no)\s+"
    r"sau=(?P<sau>-?\d+)\s+idau=(?P<idau>-?\d+)\s+raw=(?P<raw>0x[0-9a-f]+)\s*$"
)
REGION = re.compile(
    r"^\s*r(?P<n>\d+) RBAR=(?P<rbar>0x[0-9a-f]+) RLAR=(?P<rlar>0x[0-9a-f]+)\s*->\s*"
    r"(?P<base>0x[0-9a-f]+)\.\.(?P<limit>0x[0-9a-f]+) en=(?P<en>\d) nsc=(?P<nsc>\d)\s*$"
)
SWEEP = re.compile(
    r"^\s*(?P<what>.+?)\s+(?P<addr>0x[0-9a-f]{8})\s+S (?P<from>yes|no)\s*->\s*(?P<to>yes|no)\s+"
    r"nsr (?P<nsr>yes|no)\s+sau=(?P<sau>-?\d+)\s+(?P<verdict>MOVED|unmoved)\s+back=(?P<back>ok|NO)\s*$"
)


def strip(line):
    return re.sub(r"^\[\s*\d+ ms\]\s?", "", line.rstrip("\n"))


def main():
    lines = [strip(x) for x in sys.stdin]
    problems = []
    notes = []

    if not any(l.startswith("VERDICT:") for l in lines):
        print("the log does not contain a VERDICT block")
        print("INCOMPLETE")
        return 1

    # A reader that joined mid-run gets the repeated report and nothing before
    # it. That is a legitimate log and it can still be checked — the report
    # carries the three readings its verdict rests on — so the strict pass over
    # candidate 1's eighteen-address map applies only when candidate 1 is in
    # the window. What is checked of a partial log is checked just as hard.
    full_run = any(l.startswith("candidate 1 ") for l in lines)
    if not full_run:
        notes.append("partial log: the run's opening is not in this window")

    # ---- every TT line must decode to the fields printed beside it ---------
    tts = []
    for l in lines:
        m = TT.match(l)
        if not m:
            continue
        raw = int(m.group("raw"), 16)
        got = decode(raw)
        want = {
            "secure": m.group("s") == "yes",
            "nsr": m.group("nsr") == "yes",
            "sau": int(m.group("sau")),
            "idau": int(m.group("idau")),
        }
        for k in want:
            if got[k] != want[k]:
                problems.append(
                    f"{m.group('addr')} {k}: log says {want[k]}, {m.group('raw')} decodes to {got[k]}"
                )
        if want["secure"] and want["nsr"]:
            problems.append(f"{m.group('addr')} is Secure and Non-secure-readable at once")
        if raw == 0:
            problems.append(f"{m.group('addr')} has an all-zero TT response: the instruction did not run")
        tts.append((m.group("what").strip(), m.group("addr"), raw))

    if full_run and len(tts) < 20:
        print(f"only {len(tts)} TT lines in a window that contains candidate 1")
        print("INCOMPLETE")
        return 1
    if len(tts) < 3:
        print(f"only {len(tts)} TT lines; not even the verdict's own evidence is here")
        print("INCOMPLETE")
        return 1

    # ---- every region descriptor must decode the way the board decoded it --
    regions = 0
    for l in lines:
        m = REGION.match(l)
        if not m:
            continue
        regions += 1
        rbar, rlar = int(m.group("rbar"), 16), int(m.group("rlar"), 16)
        if rbar & ~0x1F != int(m.group("base"), 16):
            problems.append(f"r{m.group('n')}: base does not follow from RBAR")
        if (rlar & ~0x1F) | 0x1F != int(m.group("limit"), 16):
            problems.append(f"r{m.group('n')}: limit does not follow from RLAR")
        if rlar & 1 != int(m.group("en")):
            problems.append(f"r{m.group('n')}: en does not follow from RLAR bit 0")
        if (rlar >> 1) & 1 != int(m.group("nsc")):
            problems.append(f"r{m.group('n')}: nsc does not follow from RLAR bit 1")
    if full_run and regions < 8:
        problems.append(f"only {regions} region descriptors printed; the SAU says it has eight")

    # ---- the sweep's own words must follow from its own readings ----------
    moved = unmoved = 0
    for l in lines:
        m = SWEEP.match(l)
        if not m:
            continue
        changed = m.group("verdict") == "MOVED"
        if changed:
            moved += 1
        else:
            unmoved += 1
        # A range whose Secure attribute changed cannot be "unmoved", and one
        # that did not change cannot be "MOVED" - the board computes this from
        # the whole response word, so the S transition is a one-way check.
        if m.group("from") != m.group("to") and not changed:
            problems.append(f"{m.group('addr')}: S changed but the line says unmoved")
        if changed and m.group("sau") == "-1":
            problems.append(f"{m.group('addr')}: MOVED but no SAU region was named")
        if not changed and m.group("sau") != "-1":
            problems.append(f"{m.group('addr')}: unmoved but a SAU region was named")
        if m.group("back") != "ok":
            problems.append(f"{m.group('addr')}: the map was not handed back after probing")

    if full_run and moved + unmoved == 0:
        problems.append("the sweep printed no probe lines at all")

    # ---- the verdict must follow from candidate 3's two readings ----------
    base = next((raw for what, _, raw in tts if what == "bank 9, region off"), None)
    ns = next((raw for what, _, raw in tts if what == "bank 9, ours NS"), None)
    nsc = next((raw for what, _, raw in tts if what == "bank 9, ours NSC"), None)
    if base is None or ns is None:
        problems.append("the verdict's own bank 9 readings are not both in the log")
    else:
        heard = ns != base
        named = decode(ns)["sau"] == 1
        claims_honoured = any("honoured AND reported" in l for l in lines)
        claims_silent = any("named no region" in l for l in lines)
        claims_nothing = any("changed nothing TT can see" in l for l in lines)
        if claims_honoured and not (heard and named):
            problems.append("the verdict claims honoured-and-reported; the readings do not")
        if claims_silent and not (heard and not named):
            problems.append("the verdict claims honoured-but-unnamed; the readings do not")
        if claims_nothing and heard:
            problems.append("the verdict claims nothing moved; the readings say it did")
        if sum([claims_honoured, claims_silent, claims_nothing]) != 1:
            problems.append("the verdict block does not state exactly one of its three outcomes")

    if nsc is not None and ns is not None:
        d_nsc, d_ns = decode(nsc), decode(ns)
        # Not graded, and worth printing: NSC and NS are different attributes
        # and this is what the difference looks like on this part.
        notes.append(
            f"NSC {hex(nsc)} S={d_nsc['secure']} sau={d_nsc['sau']} vs "
            f"NS {hex(ns)} S={d_ns['secure']} sau={d_ns['sau']}"
        )

    # ---- one direction only, and the other direction stays open -----------
    #
    # If TT names a SAU region, that region must exist, be enabled, and contain
    # the address. The converse - that an enabled region containing an address
    # must be named - is exactly what this experiment found is NOT true here,
    # and deriving a rule for it needs the manual neither this nor exp164 has.
    descs = {}
    for l in lines:
        m = REGION.match(l)
        if m:
            descs[int(m.group("n"))] = (
                int(m.group("base"), 16),
                int(m.group("limit"), 16),
                int(m.group("en")),
            )
    for what, addr, raw in tts:
        n = decode(raw)["sau"]
        if n < 0:
            continue
        if n not in descs:
            # r1 is written and switched off again, so its final descriptor is
            # empty by design; the sweep's own `back=ok` covers that case.
            continue
        b, lim, en = descs[n]
        a = int(addr, 16)
        if en and not (b <= a <= lim) and not (b == 0 and lim == 0x1F):
            problems.append(f"{addr} names r{n}, which covers {hex(b)}..{hex(lim)}")

    silent = [(w, a) for w, a, raw in tts if decode(raw)["sau"] == -1]
    notes.append(f"{len(tts) - len(silent)} of {len(tts)} TT lines named a SAU region")

    for n in notes:
        print(f"note: {n}")
    print(f"OPEN: what overrules an enabled SAU region needs the Armv8-M ARM; not derived here")

    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
