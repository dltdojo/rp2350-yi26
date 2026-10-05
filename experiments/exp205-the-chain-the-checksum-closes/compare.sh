#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp205 — the proved kernel, on the model and on the RTL, against Python.
#
#   ./compare.sh       one line per case, then PASS/FAIL lines
#
# For each image images.py builds — kernel.bin, a message, a signature and a
# public key of 67 chains, and scratch that starts as 0xee — Python says the
# verdict and how many HASH calls a verifier makes for that message, S:
#   - the model halts with Python's verdict after exactly 4142 + 3 S
#     instructions, the count the proof states — read from the proof;
#   - the RTL halts with the same verdict, and its minstret is that count plus
#     the harness's constant plus S HASH calls at the per-call cost, both
#     measured by tools/hazard3/hash-cost.sh;
#   - the whole region is byte for byte the same on both, and Python — not
#     the model — agrees that only the 131 bytes of scratch changed and that
#     the 67 digits there are the message's and the checksum's.
# And once more on the model alone, at 0x20070000.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
# The count the theorem states, A + B · steps, read from the proof; the loop
# is tools/hazard3/kernelcompare.sh's.
read -r A B < <(sed -n "s/.*∃ s', run env (\([0-9]*\) + \([0-9]*\) \* steps s.mem base) s\$/\1 \2/p" proof/Wots.lean | head -1)
exec ../../tools/hazard3/kernelcompare.sh "$A" "$B" 0 \
    "only the 131 bytes of scratch changed, and the digits there are right"
