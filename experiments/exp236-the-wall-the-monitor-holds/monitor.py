#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Build and verification script for exp236's monitor.bin.

Checks:
  1. monitor.S assembles byte-for-byte to monitor.bin.
  2. monitor.bin has SHA-256 matching monitor.sha256.
  3. Instruction count is <= 150 (<= 600 bytes).
  4. With --check, verifies that proof/Monitor.lean's monitorCode matches.
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../.."))
sys.path.insert(0, os.path.join(REPO, "tools/monitor"))
import asm

def check_all():
    src = os.path.join(HERE, "monitor.S")
    out = os.path.join(HERE, "monitor.bin")
    sha_file = os.path.join(HERE, "monitor.sha256")
    lean_file = os.path.join(HERE, "proof/Monitor.lean")

    tmp_bin = os.path.join(HERE, "monitor.tmp.bin")
    asm.assemble(src, tmp_bin, 0x80000000)

    with open(tmp_bin, "rb") as f:
        tmp_data = f.read()

    with open(out, "rb") as f:
        committed_data = f.read()

    if os.path.exists(tmp_bin):
        os.remove(tmp_bin)

    if tmp_data != committed_data:
        sys.stderr.write("FAIL: monitor.S assembled binary differs from committed monitor.bin\n")
        return 1

    actual_sha = hashlib.sha256(committed_data).hexdigest()
    with open(sha_file, "r") as f:
        expected_sha = f.read().strip()

    if actual_sha != expected_sha:
        sys.stderr.write(f"FAIL: SHA-256 mismatch: {actual_sha} != {expected_sha}\n")
        return 1

    n_words = len(committed_data) // 4
    if n_words > 150:
        sys.stderr.write(f"FAIL: monitor.bin has {n_words} instructions, exceeding budget of 150\n")
        return 1

    # Check words in Monitor.lean
    words = asm.read_words(out)
    if os.path.exists(lean_file):
        with open(lean_file, "r") as f:
            lean_content = f.read()
        for i, w in enumerate(words):
            pattern = f"0x{w:08x}#32"
            if pattern not in lean_content:
                sys.stderr.write(f"FAIL: Word {i} ({pattern}) not found in proof/Monitor.lean\n")
                return 1

    print(f"PASS  monitor.bin ({len(committed_data)} bytes, {n_words} insts) matches monitor.S and monitor.sha256")
    return 0

def monitor_cli():
    if "--check" in sys.argv:
        sys.exit(check_all())
    elif "--emit-lean" in sys.argv:
        words = asm.read_words(os.path.join(HERE, "monitor.bin"))
        print(asm.format_lean_words(words, "monitorCode"))
    else:
        sys.exit(check_all())

if __name__ == "__main__":
    monitor_cli()
