#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/tools — an image on the Hazard3 RTL under
tools/hazard3/harness, and the whole 64 KiB region afterwards: what alice's
differentials hold to their references beside the Lean model's.
tools/hazard3/shell/expect.py's rtl() gives the outcome line only.
vk26-alice-1 wrote it; vk26-alice-2 is the second to need it.

  rtl_region(img)    (the RTL's outcome line, the region's 65536 bytes)
"""
import os
import subprocess
import sys
import tempfile

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "hazard3")
sys.path.insert(0, TOOLS)
from sigfile import read_sig  # noqa: E402


def rtl_region(img, cycles=5000000):
    with tempfile.TemporaryDirectory() as work:
        path, sig = os.path.join(work, "image.bin"), os.path.join(work, "region.sig")
        open(path, "wb").write(img)
        ran = subprocess.run([os.path.join(TOOLS, "sim.sh"), "run", path, "--cycles", str(cycles),
                              "--dump", "65536", sig], capture_output=True, text=True).stdout.strip()
        return ran, read_sig(sig)
