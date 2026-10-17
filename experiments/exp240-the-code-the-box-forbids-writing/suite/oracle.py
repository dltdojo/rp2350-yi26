#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
What exp240's box is, stated outside the monitor, and the monitor it is held to.

The box is the 64 KiB at 0x80010000. Inside it, the monitor's three PMP entries make three places and a guard:

  code   [BOX,          BOX + 0x80)    128 bytes   read, execute
  data   [BOX,          BOX + 0x1000)  4 KiB       read, write -- the code carved out of it by the entry before
  stack  [BOX + 0xf000, BOX + 0x10000) 4 KiB       read, write
  guard  [BOX + 0x1000, BOX + 0xf000)  52 KiB      nothing

`CODE`, `DATA` and `STACK` are the numbers every suite here compares the emulator against; nothing in them is read from
monitor.S.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP240 = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(EXP240, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness

BOX = 0x80010000
CODE = (BOX, BOX + 0x80)
DATA = (BOX, BOX + 0x1000)
STACK = (BOX + 0xF000, BOX + 0x10000)
GUARD = (DATA[1], STACK[0])
EXP236 = os.path.join(REPO, "experiments", "exp236-the-wall-the-monitor-holds")


def monitor() -> bytes:
    with open(os.path.join(EXP240, "monitor.bin"), "rb") as f:
        return f.read()


def monitor236() -> bytes:
    """exp236's monitor: the same words but for the PMP -- one RWX entry over the whole box."""
    with open(os.path.join(EXP236, "monitor.bin"), "rb") as f:
        return f.read()
