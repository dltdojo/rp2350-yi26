#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Wrong models of the Tier 2 PMP, each refused or not: the loop exp256's model/mutants.py wrote, and exp257's needed
second.

A mutants.txt is `<label>|<what is wrong>|<sed>|lean/<file>.lean` a line. Each wrong model is privrun built from a
copy of lean/ with one sed applied (tools/lean/lean.sh mutant-lib), a minute or so apiece. `findings(privrun)` is
what the caller's differential finds with a privrun, as a dict; a wrong model is refused when an entry of it is
not what the true privrun found, and the PASS line names those entries.
"""

import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
LEAN = os.path.join(REPO, "tools", "lean", "lean.sh")
TRUE_PRIVRUN = os.path.join(REPO, "lean", ".lake", "build", "bin", "privrun")


def refuse_all(mutants_txt: str, findings) -> int:
    """PASS/FAIL per mutant; 0 if every one is refused."""
    base = findings(TRUE_PRIVRUN)
    status = 0
    for ln in open(mutants_txt, encoding="utf-8"):
        if not ln.strip() or ln.startswith("#"):
            continue
        label, what, rest = ln.rstrip("\n").split("|", 2)
        expr, target = rest.rsplit("|", 1)
        claim = f"{label}: the differential refuses a model where {what}"
        p = subprocess.run([LEAN, "mutant-lib", expr, target, "privrun"], capture_output=True, text=True)
        lib = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
        try:
            if p.returncode == 3:
                print(f"FAIL  {claim} -- the sed no longer matches its file"); status = 1; continue
            if p.returncode != 0:
                print(f"FAIL  {claim} -- it does not even build, so this says nothing"); status = 1; continue
            exe = subprocess.run([LEAN, "exe", "privrun", lib], capture_output=True, text=True).stdout.strip()
            got = findings(exe)
            by = [k for k in got if got[k] != base[k]]
            if by:
                print(f"PASS  {claim} -- refused by {', '.join(by)}")
            else:
                print(f"FAIL  {claim} -- the differential finds what it found with the true model"); status = 1
        finally:
            if lib:
                subprocess.run([LEAN, "drop-lib", lib], capture_output=True)
    return status
