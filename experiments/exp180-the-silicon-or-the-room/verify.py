#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rules on one of this experiment's transcripts.

    python3 verify.py capture.txt

Three things are checked, and only two of them need a temperature to mean
anything:

1. **The configuration coefficient.** One register field, `FREQ_RANGE`, written
   by firmware, moves the ring oscillator's frequency. If it moves it further
   than the 13.34% the earlier work called device uniqueness, then the base
   frequency is not a property of the silicon until the configuration is fixed.
2. **The counter's resolution.** The earlier work reported LPOSC at 28.00 and
   32.00 kHz across boards and called it a 14.28% spread. At `FC0_INTERVAL = 8`
   the window is about 251 µs, so the resolution at 32 kHz is about 4 kHz and
   those two numbers are one count apart. The same board measured at both
   intervals in the same second settles it.
3. **The temperature coefficient**, when the transcript contains a sweep with
   more than a degree in it. Two transcripts here do not: a board cannot heat
   itself past about 1.5 °C, and a fingertip at 33 °C *cools* a die at 41 °C.
   Both are checked in as what they are.
"""

import re
import sys

# What the earlier work claimed as device spread, and what this compares against.
CLAIMED_DEVICE_SPREAD = 13.34
LPOSC_SHORT_STEP_KHZ = 4.0

#: The measurement noise, from the transcripts: repeated readings of an
#: undisturbed oscillator wander by about this much.
NOISE_PERCENT = 0.05
#: So a sweep is only worth a coefficient when the temperature moved far enough
#: that a plausible drift would clear that band. A degree is not enough, and
#: saying "at least one degree" was this script's own version of the mistake it
#: exists to catch — a threshold picked because it is a round number rather than
#: because it is where the instrument starts to be able to see.
USABLE_DT = 5.0

RANGE = re.compile(r"range (LOW|MEDIUM|HIGH): ([\d.]+) kHz")
LPOSC = re.compile(r"LPOSC at interval (\d+): ([\d.]+) kHz")
CRYSTAL = re.compile(r"crystal \(the control\): ([\d.]+) kHz")
DT = re.compile(r"a change of (-?[\d.]+) C|widest so far: (-?[\d.]+) C")
# The wording of this line changed three times as the instrument was rebuilt;
# all of them are read, because the older transcripts are checked in as the
# record of why it was rebuilt.
PER_DEGREE = re.compile(r"(?:so|which is) ([-+][\d.]+)%(?: per degree|/C)")
SAMPLE = re.compile(r"\+(\d+)s\s+([\d.]+) C\s+ROSC ([\d.]+) kHz")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    text = open(sys.argv[1]).read()
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    # --- 1. what one register field does ---------------------------------
    ranges = {m.group(1): float(m.group(2)) for m in RANGE.finditer(text)}
    check(len(ranges) == 3, "the transcript carries all three usable ROSC ranges")
    if len(ranges) == 3:
        lo, hi = min(ranges.values()), max(ranges.values())
        spread = (hi - lo) / lo * 100
        check(
            spread > CLAIMED_DEVICE_SPREAD,
            "one register field moves ROSC by %.1f%% (%.2f to %.2f kHz) — more than the "
            "%.2f%% the earlier work called device uniqueness"
            % (spread, lo, hi, CLAIMED_DEVICE_SPREAD),
        )

    # --- 2. the counter measuring itself ---------------------------------
    lp = {int(m.group(1)): float(m.group(2)) for m in LPOSC.finditer(text)}
    check(8 in lp and 15 in lp, "LPOSC was measured at both intervals")
    if 8 in lp and 15 in lp:
        step = lp[8] / LPOSC_SHORT_STEP_KHZ
        check(
            abs(step - round(step)) < 1e-6,
            "at interval 8 it reads %.2f kHz, an exact multiple of %.0f kHz — one count"
            % (lp[8], LPOSC_SHORT_STEP_KHZ),
        )
        frac = lp[15] / LPOSC_SHORT_STEP_KHZ
        check(
            abs(frac - round(frac)) > 1e-6,
            "at interval 15 it reads %.2f kHz, which that window could never produce"
            % lp[15],
        )

    # --- the instrument's own control -------------------------------------
    xtal = CRYSTAL.search(text)
    check(xtal is not None and abs(float(xtal.group(1)) - 12000.0) < 1.0,
          "the crystal reads 12000.00 kHz — the counter is not the thing drifting")

    # --- 3. temperature, if this transcript has any ------------------------
    # The widest of them, not the first. The firmware prints a running summary
    # and the early ones are taken before the board has finished warming; taking
    # `search`'s first hit reported 6.72 C where the run reached 6.94.
    spans = [float(a or b) for a, b in DT.findall(text)]
    dt = max(spans, key=abs) if spans else None
    samples = [(int(a), float(b), float(c)) for a, b, c in SAMPLE.findall(text)]
    if dt is None or abs(dt) < USABLE_DT:
        span = 0.0
        if samples:
            temps = [t for _, t, _ in samples]
            span = max(temps) - min(temps)
        moved = dt if dt is not None else span
        print("SKIP  no usable temperature sweep here — %.2f C, against the %.1f C this "
              "instrument needs before a drift would clear its own %.2f%% noise. That is "
              "what this transcript records, not a gap in it."
              % (moved, USABLE_DT, NOISE_PERCENT))
    else:
        coeffs = [abs(float(c)) for c in PER_DEGREE.findall(text)]
        check(bool(coeffs), "a temperature coefficient was computed")
        if coeffs:
            coeff = max(coeffs)
            print("      ROSC moved %.3f%% per degree over %.2f C" % (coeff, dt))
            # The finding, asserted rather than printed. If a board ever comes
            # back where twenty degrees covers the spread that was called device
            # uniqueness, this experiment's conclusion is the other one and
            # somebody should have to notice before writing it down.
            check(
                coeff * 20 < CLAIMED_DEVICE_SPREAD,
                "twenty degrees of that is %.2f%%, which is %.0f times smaller than the "
                "%.2f%% called device uniqueness — temperature is real here and does not "
                "explain that spread"
                % (coeff * 20, CLAIMED_DEVICE_SPREAD / (coeff * 20), CLAIMED_DEVICE_SPREAD),
            )

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
