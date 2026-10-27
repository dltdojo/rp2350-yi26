#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp256 — every wrong model in mutants.txt beside this file must be refused by the differential.

The true model and the emulator do not agree everywhere: privdiff.py finds where, and README.md says why. So a wrong
model is refused when it changes what privdiff.py finds -- a run that agreed and now differs, or one that differed
and now differs elsewhere -- on at least one of `SUITES`. Each wrong model is privrun built from a copy of lean/ with
one sed applied (tools/lean/lean.sh mutant-lib, as exp202's mutants are), a minute or so apiece.

    mutants.py        PASS/FAIL per mutant, naming the suites that refused it
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP, "../.."))
LEAN = os.path.join(REPO, "tools", "lean", "lean.sh")
PRIVDIFF = os.path.join(REPO, "tools", "monitor", "privdiff.py")
EXPS = os.path.join(REPO, "experiments")

# fast, and between them every privileged corner the suites reach: the probes; exp236's and exp240's attacks (U-mode
# against one RWX entry, and against three W^X ones); exp238's (the service port); exp240's rounds (boot from junk CSRs)
SUITES = [
    os.path.join(EXP, "probes", "probes.py"),
    os.path.join(EXPS, "exp236-the-wall-the-monitor-holds", "cases", "attack_cases.py"),
    os.path.join(EXPS, "exp240-the-code-the-box-forbids-writing", "suite", "wx_attacks.py"),
    os.path.join(EXPS, "exp238-the-call-the-monitor-checks", "suite", "attack_cases.py"),
    os.path.join(EXPS, "exp240-the-code-the-box-forbids-writing", "suite", "rounds.py"),
]


def findings(privrun: str) -> dict:
    """What privdiff.py finds with this privrun, per suite: the differing runs, where and how."""
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        for s in SUITES:
            f = os.path.join(tmp, "out.jsonl")
            env = dict(os.environ, PRIVRUN=privrun, PRIVDIFF_OUT=f)
            subprocess.run([sys.executable, PRIVDIFF, s], env=env, capture_output=True)
            res = json.loads(open(f).read().splitlines()[-1]) if os.path.exists(f) else {}
            out[os.path.basename(s)] = sorted((d["run"], d["step"], d["what"]) for d in res.get("all", [])) \
                if res else "no result"
            if os.path.exists(f):
                os.remove(f)
    return out


def main():
    base = findings(os.path.join(REPO, "lean", ".lake", "build", "bin", "privrun"))
    status = 0
    for ln in open(os.path.join(HERE, "mutants.txt"), encoding="utf-8"):
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
            by = [s for s in got if got[s] != base[s]]
            if by:
                print(f"PASS  {claim} -- refused by {', '.join(by)}")
            else:
                print(f"FAIL  {claim} -- every suite finds what it found with the true model"); status = 1
        finally:
            if lib:
                subprocess.run([LEAN, "drop-lib", lib], capture_output=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
