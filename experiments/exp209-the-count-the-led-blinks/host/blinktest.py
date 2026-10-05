#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp209 — what an eye counts in shell/blink.c's rounds, checked.

  blinktest.py BINARY      PASS/FAIL lines; exit 0 = every pattern reads back

A person reads the LED by counting, never by timing, so the test decodes each
recorded round the way a person would — long or short, how many in a row,
where the long pauses fall — and requires it to give back exactly what was
put in. It also requires the three kinds of round never to be mistaken for
one another.
"""
import subprocess
import sys

LONG = 12       # an `on` at least this long is a flash, not a blink


def holds(binary, *args):
    out = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, check=True).stdout.split()
    return [(h[0] == "+", int(h[1:])) for h in out]


def digits_of(seq, idx):
    """Short blinks at positions idx in seq, cut into digits at dark gaps of 10 or more."""
    digits, count = [], 0
    for i in idx:
        count += 1
        if i + 1 >= len(seq) or (not seq[i + 1][0] and seq[i + 1][1] >= 10):
            digits.append(0 if count == 10 else count)
            count = 0
    return int("".join(map(str, digits)))


def read(seq):
    """Decode one round as a person counting would: ("fault", step) or
    ("report", [(flashes, number), ...])."""
    ons = [(i, n) for i, (on, n) in enumerate(seq) if on]
    if ons[0][1] == 1:
        return "fault", digits_of(seq, [i for i, n in ons if n > 1])
    out, flashes, short = [], 0, []
    for i, n in ons:
        if n >= LONG:
            if short:
                out.append((flashes, digits_of(seq, short)))
                flashes, short = 0, []
            flashes += 1
        else:
            short.append(i)
    out.append((flashes, digits_of(seq, short)))
    return "report", out


def main():
    binary = sys.argv[1]
    bad = 0
    reports = [[0, 108, 31, 0], [2, 108, 159, 0], [26, 105, 0, 4294967295], [34, 8, 31, 0], [1, 0, 0, 10]]
    for nums in reports:
        got = read(holds(binary, "report", *nums))
        want = ("report", [(i + 1, n) for i, n in enumerate(nums)])
        if got != want:
            print(f"FAIL  report {nums} reads back as {got}")
            bad = 1
    for step in (1, 2, 5):
        got = read(holds(binary, "fault", step))
        if got != ("fault", step):
            print(f"FAIL  fault {step} reads back as {got}")
            bad = 1
    if not bad:
        print(f"PASS  every round reads back as what was blinked, each number after as many long flashes "
              f"as its place: {len(reports)} reports, 3 faults")
    seq = holds(binary, "report", 0, 108, 31, 0)
    print("      0 108 31 0 is   " + " ".join(f"{'+' if on else '-'}{n}" for on, n in seq))
    return bad


if __name__ == "__main__":
    sys.exit(main())
