#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rules on exp182's transcripts.

    python3 verify.py capture-provisioned.txt
    python3 verify.py capture-unprovisioned.txt
    python3 verify.py capture-roundtrip.txt
    python3 verify.py capture-forge.txt

Four claims, one per transcript, and the implications run in both directions the
way exp173's do — a transcript that shows the device working while claiming to be
unprovisioned fails here rather than being read as a success.
"""

import re
import sys

USED_BITS = 7936
UNIFORMITY = re.compile(r"bank 8 came up ([\d.]+)% one-bits")
CHANGED = re.compile(r"enrolled at ([\d.]+)%, (\d+) of (\d+) cells changed")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    text = open(path).read()
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    if "forge" in path:
        # The falsifiable one: the same attack, the same script, two images.
        check("the test-key secret is not in" in text,
              "exp175's forgery finds nothing in this experiment's image")
        check('"signature"' in text,
              "and mints a working assertion from exp174's, which is the control that "
              "says the attack still works where the secret is in the file")
        check("up_bit_claimed" in text,
              "including a user-presence bit it simply asserts, with no board present")
        sys.exit(0 if ok else 1)

    if "roundtrip" in path:
        for step, what in (
            ("made a credential", "fido2-cred made a credential"),
            ("verified, and wrote the public key out", "fido2-cred verified the self attestation"),
            ("got an assertion", "fido2-assert used the credential"),
            ("VERIFIED", "and the assertion verified against the key the credential handed over"),
        ):
            check(step in text, what)
        check("REFUSED" not in text, "nothing in the round trip was refused")
        sys.exit(0 if ok else 1)

    uni = UNIFORMITY.search(text)
    check(uni is not None, "the transcript says what bank 8 held")
    if uni is None:
        sys.exit(1)
    now = float(uni.group(1))
    changed = CHANGED.search(text)
    check(changed is not None, "and how far that was from the enrolment")
    errors = int(changed.group(2)) if changed else 0
    rate = errors / USED_BITS if changed else 0.0

    if "UNPROVISIONED" in text:
        check(now < 5.0,
              "the window read %.1f%% — cleared, which is what flashing leaves (exp179)" % now)
        check(rate > 0.30,
              "%d of %d cells apart, a %.0f%% error rate no 31-fold repetition can carry"
              % (errors, USED_BITS, rate * 100))
        check("did NOT come back" in text or "refused to enrol" in text,
              "so the device refused rather than signing with the majority vote's output")
        check("FIDO_ERR" in text,
              "and a real client saw the refusal, rather than a credential nobody could check")
        # Both directions: an unprovisioned transcript must not contain a success.
        check("the key came back" not in text,
              "nothing in this transcript claims the key came back")
    else:
        check(40.0 <= now <= 60.0,
              "the window read %.1f%% — a power-on reading" % now)
        check("the key came back" in text, "the key came back")
        check(rate < 0.20,
              "%d of %d cells had changed, a %.2f%% error rate, well inside what the code "
              "carries" % (errors, USED_BITS, rate * 100))
        check(float(changed.group(1)) > 40.0,
              "and the enrolment it was measured against was itself a power-on reading "
              "(%.1f%%)" % float(changed.group(1)))
        check("UNPROVISIONED" not in text,
              "nothing in this transcript claims the board is unprovisioned")

    check("forge.py has nothing to lift" in text,
          "and the firmware says, in its own log, that the image carries no key")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
