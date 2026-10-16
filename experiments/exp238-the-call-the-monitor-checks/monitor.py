#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp238's monitor.bin: monitor.S assembled, its hash, its size, and the words proof/Calls.lean runs.

  monitor.py --check          exit 0 = all hold
  monitor.py --emit-lean      monitorCode, as proof/Calls.lean has it
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "monitor"))
import asm
import binary

BUDGET = 200     # words: docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md, §6


def main():
    if "--emit-lean" in sys.argv:
        print(asm.format_lean_words(asm.read_words(os.path.join(HERE, "monitor.bin"))))
        return 0
    return binary.report(HERE, BUDGET, "proof/Calls.lean" if os.path.exists(os.path.join(HERE, "proof", "Calls.lean")) else None)


if __name__ == "__main__":
    sys.exit(main())
