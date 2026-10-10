#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — kernel.bin on the Lean model (rv32run) and on the Hazard3 RTL,
against script.py, over cases.hand() and cases.fuzz().

  differential.py RV32RUN KERNEL [FUZZ]     PASS/FAIL lines; exit 0 = all pass

Every case runs on the model. The RTL's harness has no signature check of its
own — every CHECKSIG there is invalid — so a case whose verdict depends on a
valid signature runs on the model only, with RV32RUN_SIGS naming that one
(key, signature) pair valid; every other case runs on both, and on both every
signature is invalid, as script.py is told.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "shell"))
from expect import model, rtl  # noqa: E402
import cases  # noqa: E402
from script import NAMES, run  # noqa: E402

FUEL = 200000


def code_of(line):
    return int(line.split("code=")[1].split()[0], 16) if line.startswith("halt code=") else None


def differential(rv32run, kernel, nfuzz):
    failed = 0
    sigs = tempfile.NamedTemporaryFile("w", suffix=".sigs", delete=False)
    sig = cases.SIGN()
    sigs.write(f"{cases.KEY.hex()} {sig.hex()}\n")
    sigs.close()
    hand = list(cases.hand().items())
    fz = [(f"fuzz {i}", (s, st, False)) for i, (s, st) in enumerate(cases.fuzz(nfuzz))]
    codes = {}
    for name, (script, stack, signed) in hand + fz:
        img = cases.image(kernel, script, stack)
        if signed:
            want = run(script, stack, sig=cases.valid)
            os.environ["RV32RUN_SIGS"] = sigs.name
            got_model = code_of(model(rv32run, img, FUEL)[0])
            del os.environ["RV32RUN_SIGS"]
            got_rtl = None
        else:
            want = run(script, stack)
            got_model = code_of(model(rv32run, img, FUEL)[0])
            got_rtl = code_of(rtl(img))
        codes[want] = codes.get(want, 0) + 1
        bad = got_model != want or (not signed and got_rtl != want)
        if bad or not name.startswith("fuzz"):
            where = "model" if signed else "model and RTL"
            print(f"{'FAIL' if bad else 'PASS'}  {name}: {NAMES[want]} ({want}) on the {where}"
                  + (f" — model {got_model}, RTL {got_rtl}" if bad else ""))
        failed += bad
    print(f"{'FAIL' if failed else 'PASS'}  {len(fz)} fuzzed scripts, model and RTL against script.py: "
          + ", ".join(f"{NAMES[k]} {v}" for k, v in sorted(codes.items())))
    os.unlink(sigs.name)
    return failed


if __name__ == "__main__":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    sys.exit(1 if differential(sys.argv[1], open(sys.argv[2], "rb").read(), n) else 0)
