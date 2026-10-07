#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp214 — what the RTL build printed, against expected.txt.

  writes.py EXPECTED < WORDS     one line: `writes ok` or `writes differ at N`,
                                 then what the shell reported

WORDS is tools/hazard3/shell/shell.sh's shell_words line: WRIT addr value
triples, then REPT verdict word or FAUL step cause, then exit=N.
"""
import sys

words = sys.stdin.read().split()
got, i = [], 0
while i + 2 < len(words) and words[i] == "57524954":
    got.append((words[i + 1], words[i + 2]))
    i += 3
want = [tuple(line.split()[:2]) for line in open(sys.argv[1]) if line.strip() and not line.startswith("#")]
if got == want:
    print("writes ok", end="")
else:
    n = next((k for k, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
    print(f"writes differ at {n + 1}", end="")
print(" " + " ".join(words[i:]))
