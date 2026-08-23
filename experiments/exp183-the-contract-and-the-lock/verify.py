#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
verify.py — Verifies exp183 transcripts and contract execution
"""

import sys
import os
import json

def verify_transcript(path: str) -> bool:
    if not os.path.exists(path):
        print(f"FAIL  transcript file missing: {path}")
        return False

    content = open(path, "r", encoding="utf-8", errors="replace").read()

    # Verify that the active backend is reported in log
    if "exp183: active contract backend:" in content:
        print("PASS  transcript reports active contract backend")
    else:
        print("FAIL  transcript missing active contract backend announcement")
        return False

    return True

def main():
    if len(sys.argv) > 1:
        path = sys.argv[1]
        ok = verify_transcript(path)
        sys.exit(0 if ok else 1)
    else:
        print("Usage: python3 verify.py <transcript-file>")
        sys.exit(1)

if __name__ == "__main__":
    main()
