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

LONG = 12       # an `on` at least this long is a flash or a glow, not a blink


def holds(binary, *args):
    out = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, check=True).stdout.split()
    return [(h[0] == "+", int(h[1:])) for h in out]


def read(seq):
    """Decode one round as a person counting would."""
    ons = [(i, n) for i, (on, n) in enumerate(seq) if on]
    first = ons[0][1]
    if first == 1:
        kind, k = "fault", None
        body = [(i, n) for i, n in ons if n > 1]
    elif first >= 30:
        kind, k = "pass", None
        body = ons[1:]
    else:
        flashes = [n for _, n in ons if n >= LONG]
        kind, k = "fail", len(flashes)
        body = [(i, n) for i, n in ons if n < LONG]
    # Blinks after the prefix; a dark gap of 10 or more ends a digit.
    digits, count = [], 0
    for i, _ in body:
        count += 1
        if i + 1 < len(seq) and not seq[i + 1][0] and seq[i + 1][1] >= 10:
            digits.append(0 if count == 10 else count)
            count = 0
    return kind, k, int("".join(map(str, digits)))


def main():
    binary = sys.argv[1]
    bad = 0
    cases = [(("report", 0, 108), ("pass", None, 108)),
             (("report", 0, 105), ("pass", None, 105)),
             (("report", 0, 1000), ("pass", None, 1000)),
             (("report", 3, 2), ("fail", 3, 2)),
             (("report", 6, 110), ("fail", 6, 110)),
             (("report", 1, 0), ("fail", 1, 0)),
             (("fault", 2), ("fault", None, 2)),
             (("fault", 5), ("fault", None, 5))]
    for args, want in cases:
        got = read(holds(binary, *args))
        if got != want:
            print(f"FAIL  {args} reads back as {got}, not {want}")
            bad = 1
    if not bad:
        print(f"PASS  every round reads back as what was blinked: {len(cases)} cases, pass, fail and fault")
    pas = holds(binary, "report", 0, 108)
    print("      PASS 108 is   " + " ".join(f"{'+' if on else '-'}{n}" for on, n in pas))
    return bad


if __name__ == "__main__":
    sys.exit(main())
