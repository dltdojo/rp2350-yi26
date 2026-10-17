#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp240's monitor.bin: monitor.S assembled, its hash, its size, and the words proof/Wx.lean runs.

  monitor.py --check          exit 0 = all hold
  monitor.py --emit-lean      monitorCode, as proof/Wx.lean has it

200 words: docs/micro-monitor/2026-10-16-micro-monitor-workload-migration-design-zh-tw.md, section 6.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools", "monitor"))
import binary

sys.exit(binary.cli(HERE, 200, "proof/Wx.lean"))
