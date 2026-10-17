#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
What exp239's monitor owes the payload's memory, stated outside the monitor.

At the payload's first trap, memory is whatever the payload left. When the monitor parks, memory must be
that, with two ranges of the box zeroed and not a byte more changed:

  - the confidential scratch, [BOX + 0x2200, BOX + 0x4000): always;
  - the digest window, [BOX + 0x2140, BOX + 0x2160): unless the exit code is 0.

`run` takes a snapshot at the trap (tools/monitor/harness.run_snapshot) and `check_memory` holds the end
state to this, over all 256 KiB of the emulator's RAM: the monitor's own words, its stack, the payload's
code, the bytes just outside each range. A monitor that scrubs one word too few, or one too many, fails here.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP239 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP239, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness
from harness import differences, reported       # shared since exp240 needed them too
from monitor.emulator import BASE

BOX = 0x80010000
CONF = (BOX + 0x2200, BOX + 0x4000)
DIGEST = (BOX + 0x2140, BOX + 0x2160)


def monitor() -> bytes:
    with open(os.path.join(EXP239, "monitor.bin"), "rb") as f:
        return f.read()


def expected(snap: bytes, a0: int) -> bytes:
    """Memory as the payload left it, scrubbed as the monitor promises for exit code `a0`."""
    mem = bytearray(snap)
    ranges = [CONF] + ([DIGEST] if a0 != 0 else [])
    for lo, hi in ranges:
        mem[lo - BASE:hi - BASE] = bytes(hi - lo)
    return bytes(mem)


def check_memory(emu, snap, a0: int) -> list:
    """The failures, empty for a pass: memory at the park is the payload's, scrubbed for exit code `a0`."""
    if snap is None:
        return ["the payload never trapped, so there is no memory to compare"]
    want, got = expected(snap, a0), bytes(emu.mem)
    if want == got:
        return []
    return ["memory is not what the payload left, scrubbed for exit code "
            f"{a0}: differs at {', '.join(differences(want, got))}"]


def run(mon: bytes, pay: bytes, steps: int = 1000000):
    return harness.run_snapshot(mon, pay, steps)
