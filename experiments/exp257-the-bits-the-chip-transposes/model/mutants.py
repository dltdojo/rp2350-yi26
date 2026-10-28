#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp257 — every wrong chip PMP in mutants.txt beside this file must be refused by the differential.

The true `chipCheck` decides every case of differential/pmpdiff.py as the core of its order does, so a wrong one is
refused when it answers one case otherwise, in either order: the core the answer is held to is what the PASS line
names. The RTL's answers are the true model's, which pmpdiff.py checks; here only the model is run again.

    mutants.py        PASS/FAIL per mutant
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP, "../.."))
sys.path.insert(0, os.path.join(EXP, "differential"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import pmpdiff  # noqa: E402
import privmutants  # noqa: E402

CASES = [c for im in pmpdiff.images() for c in im]


def findings(privrun: str) -> dict:
    return {os.path.basename(pmpdiff.CORES[o]): pmpdiff.on_model(o, CASES, privrun) for o in pmpdiff.CORES}


if __name__ == "__main__":
    sys.exit(privmutants.refuse_all(os.path.join(HERE, "mutants.txt"), findings))
