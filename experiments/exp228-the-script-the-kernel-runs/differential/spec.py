#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — proof/Script.lean's specification, run, against script.py.

  spec.py LEAN_SH [FUZZ]     PASS/FAIL; exit 0 = they agree on every case

Every hand case and FUZZ fuzzed scripts (default 3000), with SHA-256 for the
hash and the cases' own signature as the only valid one, through `lean.sh exec
proof/Script.lean spec`, and through script.run.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import cases  # noqa: E402
from script import NAMES, run  # noqa: E402


def h(b):
    return bytes(b).hex() or "-"


def main(lean, n):
    sig = cases.SIGN()
    allc = [(name, s, st, signed) for name, (s, st, signed) in cases.hand().items()]
    allc += [(f"arith {name}", s, [], False) for name, s in cases.arith()]
    allc += [(f"fuzz {i}", s, st, False) for i, (s, st) in enumerate(cases.fuzz(n))]
    lines, want = [], []
    for name, s, st, signed in allc:
        pairs = f"{h(cases.KEY)} {h(sig)}" if signed else ""
        lines.append(f"{h(s)} | {' '.join(h(e) for e in st)} | {pairs}")
        want.append(run(s, st, sig=cases.valid if signed else None))
    with tempfile.NamedTemporaryFile("w", suffix=".cases", delete=False) as f:
        f.write("\n".join(lines) + "\n")
    out = subprocess.run([lean, "exec", os.path.join(HERE, "..", "proof", "Script.lean"), "spec", f.name],
                         capture_output=True, text=True)
    os.unlink(f.name)
    got = [int(x) for x in out.stdout.split()]
    bad = [(c[0], w, g) for c, w, g in zip(allc, want, got) if w != g]
    if len(got) != len(want) or bad:
        for name, w, g in bad[:10]:
            print(f"FAIL  {name}: script.py {NAMES[w]} ({w}), the specification {g}")
        print(f"FAIL  the specification agrees with script.py ({len(got)} of {len(want)} answered, {len(bad)} differ)")
        return 1
    print(f"PASS  proof/Script.lean's specification, run, agrees with script.py on all {len(want)} cases: "
          f"{len(allc) - n - len(cases.arith())} by hand, {len(cases.arith())} of arithmetic at the edges "
          f"and {n} fuzzed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3000))
