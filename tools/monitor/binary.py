#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
The check every micro-monitor's `monitor.py --check` makes, once (from exp238 on).

  monitor.S assembles, at 0x80000000, to monitor.bin byte for byte;
  monitor.bin's SHA-256 is monitor.sha256's;
  it is within its budget of words;
  and, if the experiment has a Lean file, its `monitorCode` is monitor.bin's words, in order.

Returns the failures, empty for a pass, in the style of harness.check_*; `report` prints
the one PASS or FAIL line a check.sh wants and returns the exit status.
"""

import hashlib
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm


def assembled(src: str, at: int = 0x80000000) -> bytes:
    """monitor.S text assembled afresh, as a flat binary placed at `at`."""
    with tempfile.TemporaryDirectory() as d:
        s, b = os.path.join(d, "m.S"), os.path.join(d, "m.bin")
        with open(s, "w") as f:
            f.write(src)
        asm.assemble(s, b, at)
        with open(b, "rb") as f:
            return f.read()


def lean_words(lean_path: str, name: str = "monitorCode") -> list:
    with open(lean_path) as f:
        text = f.read()
    start = text.index(f"def {name}")
    return [int(m, 16) for m in re.findall(r"0x([0-9a-f]{8})#32", text[start:text.index("]", start)])]


def check(directory: str, budget: int, lean: str = None) -> list:
    bad = []
    with open(os.path.join(directory, "monitor.S")) as f:
        fresh = assembled(f.read())
    with open(os.path.join(directory, "monitor.bin"), "rb") as f:
        committed = f.read()
    if fresh != committed:
        bad.append("monitor.S assembles to something other than the committed monitor.bin")
    want = open(os.path.join(directory, "monitor.sha256")).read().split()[0]
    got = hashlib.sha256(committed).hexdigest()
    if got != want:
        bad.append(f"monitor.bin's SHA-256 is {got}, monitor.sha256 says {want}")
    words = len(committed) // 4
    if len(committed) % 4 or words > budget:
        bad.append(f"monitor.bin is {len(committed)} bytes, {words} words; the budget is {budget} words")
    if lean:
        lw, bw = lean_words(os.path.join(directory, lean)), asm.read_words(os.path.join(directory, "monitor.bin"))
        if lw != bw:
            n = next((i for i, (x, y) in enumerate(zip(lw, bw)) if x != y), min(len(lw), len(bw)))
            bad.append(f"{lean}'s monitorCode differs from monitor.bin at word {n} "
                       f"({len(lw)} words in Lean, {len(bw)} in the binary)")
    return bad


def report(directory: str, budget: int, lean: str = None) -> int:
    bad = check(directory, budget, lean)
    for b in bad:
        print(f"FAIL  {b}")
    if bad:
        return 1
    size = os.path.getsize(os.path.join(directory, "monitor.bin"))
    print(f"PASS  monitor.bin ({size} bytes, {size // 4} words) is monitor.S assembled, matches "
          f"monitor.sha256, is within {budget} words" + (f", and is {lean}'s monitorCode" if lean else ""))
    return 0
