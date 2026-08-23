#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rules on one of this experiment's transcripts.

    python3 verify.py capture-reconstructed.txt
    python3 verify.py capture-refused.txt

Two transcripts, two different claims:

- **the refusal** — on the boot straight after a flash, bank 8 reads 0.0% and
  enrolment does not happen. Enrolling there would store `H = K XOR 0 = K`, the
  key in plain sight, which is [exp175]'s failure reinvented. The guard is
  checked here as something that fired, not as an intention.
- **the reconstruction** — the key came back, on a boot that began from no
  power, and the margin the repetition code had while doing it.

The margin is computed rather than quoted. A cell error rate is only useful
next to the number of flips it would take to break a key bit, and that
arithmetic is here so it can be argued with.
"""

import re
import sys
from math import comb

REPEAT = 31
KEY_BITS = 256
#: A majority of 31 needs this many wrong to invert.
NEED = REPEAT // 2 + 1

UNIFORMITY = re.compile(r"bank 8 now: ([\d.]+)% one-bits")
ENROLLED_AT = re.compile(r"enrolled at ([\d.]+)% one-bits")
CHANGED = re.compile(r"(\d+) of (\d+) cells changed since enrolment")
CAUSE = re.compile(r"boot #(\d+), (.+?)$", re.M)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    text = open(sys.argv[1]).read()
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    uni = UNIFORMITY.search(text)
    check(uni is not None, "the transcript reports what bank 8 held")
    if uni is None:
        sys.exit(1)
    now = float(uni.group(1))

    if "REFUSED to enrol" in text:
        check(now < 5.0,
              "it refused on a window reading %.1f%% — which is a cleared one, not a "
              "power-on one" % now)
        check("exp179" in text,
              "and it names the experiment that measured why the window is cleared")
        check("the key itself is not printed" in text,
              "even a refusal says the key is not printed and not stored")
        print("      This transcript is the guard firing. There is no key in it, which "
              "is the point.")
        sys.exit(0 if ok else 1)

    # --- the reconstruction ------------------------------------------------
    check(40.0 <= now <= 60.0,
          "bank 8 came up at %.1f%% one-bits — a power-on reading, not a cleared one" % now)

    enrolled = ENROLLED_AT.search(text)
    check(enrolled is not None, "the record says what it was enrolled at")
    if enrolled:
        check(abs(float(enrolled.group(1)) - now) < 5.0,
              "and that was %.1f%%, within a few points of this boot — the same kind of "
              "reading, not a different kind" % float(enrolled.group(1)))

    cause = CAUSE.search(text)
    check(cause is not None and "power-on" in cause.group(2),
          "the boot began from no power — exp179 measured that a reset which keeps it "
          "leaves the window untouched, so anything else here would be circular")

    check("the key came back" in text and "did NOT" not in text,
          "the key came back")
    check("every one of the 256 key bits reconstructed" in text,
          "every one of the %d key bits reconstructed, which is what makes the error "
          "count below exact" % KEY_BITS)

    changed = CHANGED.search(text)
    check(changed is not None, "the transcript reports how many cells changed")
    if changed:
        errors, total = int(changed.group(1)), int(changed.group(2))
        p = errors / total
        mean = REPEAT * p
        fail_bit = sum(comb(REPEAT, k) * p**k * (1 - p) ** (REPEAT - k)
                       for k in range(NEED, REPEAT + 1))
        fail_key = 1 - (1 - fail_bit) ** KEY_BITS
        print("      %d of %d cells changed: a %.2f%% error rate, %.2f flips per key bit "
              "of %d, and %d needed to break one" % (errors, total, p * 100, mean, REPEAT, NEED))
        print("      so P(a key bit fails) = %.3g, P(the key fails) = %.3g" % (fail_bit, fail_key))
        check(fail_key < 1e-6,
              "the code had margin: about one reconstruction in %.0f million would fail "
              "**at this error rate**, which is one measurement of it" % (1e-6 / fail_key * 1))
        check(p < 0.20,
              "and the error rate is %.2f%%, well inside what a 31-fold repetition can "
              "carry" % (p * 100))

    check("the key itself is not printed" in text,
          "the key is not in the transcript, and the firmware says so")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
