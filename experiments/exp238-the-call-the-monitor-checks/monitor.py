#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp238's monitor.bin: monitor.S assembled, its hash, its size, and the words proof/Calls.lean runs.

  monitor.py --check          exit 0 = all hold
  monitor.py --emit-lean      monitorCode, as proof/Calls.lean has it

202 words: docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md, section 6, gave 200;
the two words after CHECKSIG's answer that refuse one that is neither 0 nor 1 (2026-10-23) are over it.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "monitor"))
import binary

sys.exit(binary.cli(HERE, 202, "proof/Calls.lean"))
