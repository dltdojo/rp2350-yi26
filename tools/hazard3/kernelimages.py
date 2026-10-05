# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3 — the command line every kernel's images.py has.

A kernel experiment builds images (kernel.bin plus its data, one per case) and
then checks a region dump against what the case should leave. Which cases and
what the image holds are the experiment's own; this is the rest, which exp203,
exp204 and exp205 each wrote out again until the third copy.

  images.py build DIR        write DIR/<name>.bin for each case, and print the
                             name with whatever `describe` says of the case
  images.py verify NAME SIG  check a region dump (the testbench's --sigfile
                             format): every byte outside [lo, hi) — and
                             outside the ranges in `also`, for a kernel that
                             writes in more than one place — is what the image
                             held, and `check`, if given, accepts what is
                             inside
"""
import os
import sys

from sigfile import read_sig


def changed_outside(before, after, lo, hi, also=()):
    """Offsets of bytes outside [lo, hi) and the ranges in `also` that differ
    between an image and a dump of the region it was loaded into; past the
    image, the region held zeros."""
    ranges = [(lo, hi), *also]

    def inside(a):
        return any(l <= a < h for l, h in ranges)
    out = [a for a in range(len(before)) if after[a] != before[a] and not inside(a)]
    out += [a for a in range(len(before), len(after)) if after[a] != 0 and not inside(a)]
    return out


def command(doc, every, image, lo, hi, describe=lambda case: (), check=None, also=()):
    """`every` maps a name to a case; `image(case)` is its bytes. Returns the
    exit status."""
    argv = sys.argv[1:]
    if argv[:1] == ["build"] and len(argv) == 2:
        os.makedirs(argv[1], exist_ok=True)
        for name, case in every.items():
            with open(os.path.join(argv[1], name + ".bin"), "wb") as f:
                f.write(image(case))
            print(name, *describe(case))
        return 0
    if argv[:1] == ["verify"] and len(argv) == 3:
        case = every[argv[1]]
        after = read_sig(argv[2])
        changed = changed_outside(image(case), after, lo, hi, also)
        if changed:
            print(f"{len(changed)} bytes outside [{lo:#x}, {hi:#x}) changed, first at {changed[0]:#x}")
            return 1
        problem = check(case, after) if check else None
        if problem:
            print(problem)
            return 1
        print("ok")
        return 0
    print(doc)
    return 2
