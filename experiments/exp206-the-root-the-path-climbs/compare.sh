#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp206 — the proved kernel, on the model and on the RTL, against Python.
#
#   ./compare.sh       one line per case, then PASS/FAIL lines
#
# For each image images.py builds — kernel.bin, a message and an index, a
# signature, an authentication path and a root, and two scratch areas that
# start as 0xee — Python says the verdict and S, the HASH calls the chains
# make; the leaf and the four levels make five more. The model must halt with
# Python's verdict after exactly the count the proof states, read from the
# proof; the RTL must agree, its minstret that count plus the harness's
# constant plus S + 5 HASH calls at the per-call cost; the region must be byte
# for byte the same on both; and Python, not the model, checks what was left.
# The loop is tools/hazard3/kernelcompare.sh's.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
read -r A B < <(sed -n "s/.*∃ s', run env (\([0-9]*\) + \([0-9]*\) \* steps s.mem base) s\$/\1 \2/p" proof/Mss.lean | head -1)
exec ../../tools/hazard3/kernelcompare.sh "$A" "$B" 5 \
    "only the two scratch areas changed, and the digits and the chain ends there are right"
