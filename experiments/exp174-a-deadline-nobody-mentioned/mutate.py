#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Break one fact in a browser-ab.json, so check.sh can require the check to notice.

    python3 mutate.py browser-ab.json out.json silent:board:keepalives=7

exp159's rule says a check that has never failed has not been shown to work.
Applied to a conclusion rather than to a signature, that means every sentence
this experiment rests on needs a version of the record that contradicts it, and
`verify.py` has to refuse each one.

The edit is made to the parsed document, not to its text. A string substitution
that matches nothing changes nothing and the mutant passes — which is a test
reporting success for the mutation it failed to apply, and is exactly what the
first version of check.sh's mutation block did.
"""
import json
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    src, dst, edit = sys.argv[1:]
    arm_name, side, assignment = edit.split(":", 2)
    field, value = assignment.split("=", 1)
    if value in ("True", "False"):
        value = value == "True"
    elif value.lstrip("-").isdigit():
        value = int(value)

    doc = json.load(open(src))
    hit = 0
    for arm in doc.get("arms", []):
        if arm.get("board", {}).get("arm") == arm_name:
            if side not in arm:
                raise SystemExit("no %s side in the %s arm" % (side, arm_name))
            if field not in arm[side]:
                raise SystemExit("no field %r in %s:%s" % (field, arm_name, side))
            arm[side][field] = value
            hit += 1
    if hit != 1:
        raise SystemExit("edit matched %d arms, wanted exactly 1: %s" % (hit, edit))
    json.dump(doc, open(dst, "w"), indent=2)


if __name__ == "__main__":
    main()
