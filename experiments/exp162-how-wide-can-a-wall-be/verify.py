#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Re-derive exp162's finding from a pasted log, off the board.

    python3 verify.py < capture.txt
    yi26 log --seconds 40 | python3 verify.py

exp159 and exp160 both sent their result to a *different implementation* to be
checked, and said why: a result checked by the thing that produced it proves the
two agree, not that either is right. Neither of those had anything to verify
here — this experiment produces no signature — so what carries over is the
principle rather than the library.

What this checks, and it is not the same thing the firmware checks:

1. The three controls did what a control has to do. Without candidate 1 a
   refusal is not a refusal, it is a core that could not read anything; without
   candidate 2 the wall was never shown to be this firmware's doing.
2. The readings fit **exactly one** of the arrangements below, and that the
   fifteen probes can tell all thirteen apart in the first place — which is the
   property a single survivor depends on, checked here rather than believed.
3. The verdict the board printed is the verdict these readings imply. A
   disagreement is reported as a disagreement rather than resolved.

Be precise about how independent this is. exp159 sent its signature to a
different *implementation of the same standard*, which is a strong check. There
is no second implementation of an SRAM bank map, so what this file gives is
weaker and worth naming: the same arithmetic, written again in another language
from the address rather than from the firmware's table, run somewhere the
firmware's bugs cannot reach. It would catch a transcription error, a wrong
probe address, or a verdict that does not follow from the readings printed above
it. It would not catch both files being wrong about the same idea.

Exit line, machine-readable, always the last line printed:

    OK          controls held, one arrangement fits, board agrees
    BAD         a control did not hold
    NOFIT       the readings match no arrangement this experiment can express
    DISAGREE    the readings fit, and the board named a different one
    INCOMPLETE  fewer than fifteen readings in the capture

No dependencies, no network, no board. Somebody who read the log on a phone can
paste it into this and get the same answer.
"""

import re
import sys

BASE = 0x2000_0000
TOTAL = 512 * 1024

# Candidate n -> (banks shut as a bitmask, address read).
#
# This table is written out again rather than parsed out of the log on purpose:
# if the firmware and this file disagree about what candidate 4 even did, that
# is a discrepancy worth catching, and a parser that took the firmware's word
# for it could not catch it.
PROBES = {
    1:  (0b0000_0000, 0x2000_0000),
    2:  (0b0000_0001, 0x2000_0000),
    3:  (0b0000_0001, 0x2001_0000),
    4:  (0b0000_0001, 0x2000_0004),
    5:  (0b0000_0001, 0x2000_0008),
    6:  (0b0000_0001, 0x2000_0010),
    7:  (0b0000_0001, 0x2000_0020),
    8:  (0b0000_0010, 0x2000_0004),
    9:  (0b0000_0100, 0x2000_0008),
    10: (0b0000_1000, 0x2000_000C),
    11: (0b0001_0000, 0x2000_0000),
    12: (0b0000_0001, 0x2004_0000),
    13: (0b0001_0000, 0x2004_0000),
    14: (0b0000_0100, 0x2000_0040),
    15: (0b1111_1111, 0x2007_FFFC),
}

CONTROLS = {1: "allowed", 2: "denied", 15: "denied"}

# Every arrangement the experiment can express: the range is cut into 8 // ways
# equal contiguous chunks, and inside each chunk consecutive `grain`-byte pieces
# go round `ways` banks in turn. ways == 1 is the arrangement everybody assumes.
# The names are byte-for-byte the firmware's, because step 3 below compares the
# two verdicts as text and a near-miss must read as a disagreement.
def _name(ways, grain):
    prefix = {8: "8-way striped", 4: "two halves, 4-way", 2: "four quarters, 2-way"}[ways]
    return f"{prefix}, {grain}-byte grain"


ARRANGEMENTS = [("contiguous 64 KB banks", 1, 4, 65536)] + [
    (_name(w, g), w, g, g) for w in (8, 4, 2) for g in (4, 8, 16, 32)
]


def bank_of(ways, grain, addr):
    off = addr - BASE
    chunk = TOTAL // (8 // ways)
    return ((off // grain) % ways) + (off // chunk) * ways


def distinct_check():
    """The claim the matrix rests on: no two arrangements predict the same run.

    Checked here rather than asserted, because it is the property that makes a
    single surviving arrangement mean anything, and it is cheap.
    """
    seen = {}
    for name, w, g, _ in ARRANGEMENTS:
        sig = tuple(
            1 if (shut >> bank_of(w, g, addr)) & 1 else 0
            for shut, addr in PROBES.values()
        )
        seen.setdefault(sig, []).append(name)
    return [names for names in seen.values() if len(names) > 1]


LINE = re.compile(r"^\s*(\d+)\s+(.+?)\s+-\s+(allowed|DENIED)\s+\((.+?)\)\s*$")


def parse(text):
    """The readings from the most complete report block, and the board's verdict.

    Every boot opens by reprinting the matrix as it stood when that boot
    started, so a capture legitimately contains 'not reached' lines and stale
    partial blocks. Only blocks that follow an 'exp162 done' line count — and of
    those, the fullest one, because a capture that stops mid-block would
    otherwise be read as a run that never finished.
    """
    lines = text.splitlines()
    starts = [i for i, ln in enumerate(lines) if "exp162 done" in ln]
    if not starts:
        return None, None

    best, best_verdict = {}, None
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(lines)
        block = lines[start:end]

        readings, verdict = {}, None
        for ln in block:
            # Strip the "[  1234 ms] " stamp if the capture kept it.
            body = re.sub(r"^\[\s*\d+ ms\]\s?", "", ln)
            m = LINE.match(body)
            if m:
                readings[int(m.group(1))] = m.group(3).lower()
            if "banks 0-7 are" in ln:
                verdict = ln.split("banks 0-7 are", 1)[1].strip().rstrip(".")
            elif "arrangements predict these" in ln:
                verdict = "NO SINGLE ARRANGEMENT"

        # Prefer a block that carries a verdict as well as a full set of
        # readings. Without the tie-break, a capture whose first complete block
        # was cut off before its verdict lines beats the intact one after it,
        # and the run is reported as a disagreement it never had.
        if (len(readings), verdict is not None) > (len(best), best_verdict is not None):
            best, best_verdict = readings, verdict
    return best, best_verdict


def main():
    text = sys.stdin.read()
    readings, board_verdict = parse(text)

    collisions = distinct_check()
    if collisions:
        for names in collisions:
            print(f"these arrangements are indistinguishable on this matrix: {names}")
        print("BAD")
        return

    n_want = len(PROBES)
    if not readings or len(readings) != n_want:
        got = len(readings) if readings else 0
        print(f"only {got} of {n_want} readings found; the capture is a fragment "
              f"or the run is unfinished")
        print("INCOMPLETE")
        return

    for n, ln in sorted(readings.items()):
        shut, addr = PROBES[n]
        print(f"  {n:>2}  shut={shut:#010b} addr={addr:#010x}  ->  {ln}")

    # 1. The controls.
    bad = [n for n, want in CONTROLS.items() if readings[n] != want]
    if bad:
        for n in bad:
            print(f"control {n} says {readings[n]}, and a control that does not hold "
                  f"makes every other line here unreadable")
        print("BAD")
        return
    print("controls 1, 2 and 15 held: the probe reads, the wall refuses, and the "
          "eight registers cover the whole 512 KB")

    # 2. Exactly one arrangement.
    fits = []
    for name, ways, grain, contiguous in ARRANGEMENTS:
        ok = all(
            ("denied" if (PROBES[n][0] >> bank_of(ways, grain, PROBES[n][1])) & 1 else "allowed")
            == reading
            for n, reading in readings.items()
        )
        if ok:
            fits.append((name, ways, contiguous))

    if len(fits) != 1:
        print(f"{len(fits)} of {len(ARRANGEMENTS)} arrangements predict these "
              f"{n_want} readings; this file cannot name the map and must not guess")
        print("NOFIT")
        return

    name, ways, contiguous = fits[0]
    print(f"exactly one arrangement predicts all {n_want} readings: {name}")
    print(f"the longest run of addresses one register gates is {contiguous} bytes")

    if ways == 1:
        print("so two adjacent registers deny a CONTIGUOUS 128 KB to Non-secure code,")
        print("and a secure region larger than one bank does exist on this part.")
    else:
        print(f"so no region larger than {contiguous} bytes can be denied as one piece,")
        print("and exp160's 65,696-byte signing key cannot go behind ACCESSCTRL at all.")

    # 3. Did the board reach the same conclusion?
    if board_verdict is None:
        print("the board printed no verdict line to compare against")
        print("DISAGREE")
        return
    if name.lower() not in board_verdict.lower():
        print(f"the board said '{board_verdict}' and these readings say '{name}'")
        print("DISAGREE")
        return

    print("OK")

if __name__ == "__main__":
    main()
