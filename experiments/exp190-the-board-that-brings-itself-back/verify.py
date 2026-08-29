#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""exp190 verification — rules on a capture.txt written by drop.sh.

The claim is that a board brings itself back, so every rule here is about what
the board did **while nobody was touching it**. The one that matters most is
not that the escape fires: it is that it does *not* fire for `late`, because a
net that catches everything has caught nothing.
"""

import re
import sys


def section(text, name):
    m = re.search(rf"^-- {name} --$(.*?)(?=^-- |\Z)", text, re.S | re.M)
    return m.group(1) if m else ""


def verify(text):
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    # --- the control, without which nothing below means anything -------------
    never = section(text, "never")
    rule("boot " in never,
         "the control came up and said which boot it was",
         "the control never reported — nothing below this line is a measurement")
    rule("0 death(s) in a row" in never,
         "and it reports no deaths behind it",
         "the control claims deaths it did not have")
    m = re.search(r"state after 10 s: (\w+)", never)
    rule(m and m.group(1) == "running",
         "it was still running ten seconds later",
         f"the control did not stay up: {m.group(1) if m else 'no state recorded'}")

    # --- the expensive direction ---------------------------------------------
    late = section(text, "late")
    after = section(text, "late, after it came back")
    rule("dying on purpose" in late,
         "the `late` arm reached its own death, so the weight was really dropped",
         "the `late` arm never got as far as dying — it tested nothing")
    before = set(re.findall(r"boot (\d+),", late))
    later = set(re.findall(r"boot (\d+),", after))
    rule(later and later != before,
         f"and it came back by itself — boot {', '.join(sorted(before))} died, boot "
         f"{', '.join(sorted(later))} is answering",
         "it died once and never returned, which is the failure this crate exists to stop")
    rule("0 death(s) in a row" in after,
         "and the boot after it counts no deaths, because the one that died had got up first",
         "the boot after a post-`alive` death is counted towards the escape, which would "
         "eventually hand over a board that was never unreachable")
    m = re.search(r"state after 30 s: (\w+)", after)
    rule(m and m.group(1) == "running",
         "**and it was NOT handed to the bootloader** — a board that got up is one a host can still reboot",
         f"a death after the board was up escalated to the bootloader ({m.group(1) if m else 'unknown'}): "
         "the escape fires at everything, which makes it worthless")

    # --- the two that must escape ---------------------------------------------
    for arm, what in [("early", "a fault before USB"), ("hang", "a hang no fault handler catches")]:
        s = section(text, arm)
        m = re.search(r"reached bootsel after: (\w+) s", s)
        got = m.group(1) if m else "never"
        if got == "never":
            rule(False, "",
                 f"`{arm}` ({what}) never reached the bootloader — this is the walk to a bench, "
                 "unavoided")
        else:
            rule(True,
                 f"`{arm}` ({what}) put itself in the bootloader after {got} s, with nobody touching it",
                 "")
            rule("drive present: yes" in s,
                 f"and the {arm} board presents its drive, so a host can reflash it",
                 f"`{arm}` reports bootsel but no drive — a host cannot reflash that")

    # --- and it is not a one-way trip ----------------------------------------
    restored = section(text, "restored")
    rule("boot " in restored,
         "a working firmware flashed afterwards runs — the escape is one-shot, not a state",
         "the board would not run a working firmware afterwards: the escape is a trap, "
         "not a net")
    m = re.search(r"final state: (\w+)", restored)
    rule(m and m.group(1) == "running",
         "and the board is left running, not in a bootloader",
         f"the run left the board in {m.group(1) if m else 'an unknown state'}")

    return ok


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: verify.py capture.txt", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        sys.exit(0 if verify(f.read()) else 1)
