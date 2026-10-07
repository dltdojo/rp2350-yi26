#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp217 — the gap the proof cannot close, shown: every wrong model in
# mutants.txt beside this file must build, pass proof/Invert.lean, and be
# refused by the differential against rp2040js and rp2040-pio-emulator. The
# emulators' traces are made once; each wrong model runs the same cases.
# tools/lean/gap.sh does the work.
#
#   gap.sh            PASS/FAIL per mutant
#   gap.sh --show     the same, with what the differential said about each

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
./traces.sh "$work"
GAP_INPUT="$work/cases" GAP_PROOF=../proof/Invert.lean ../../../tools/lean/gap.sh mutants.txt Run.lean \
    "python3 differential.py $work/cases - $work/js $work/py" "the two emulators" "$@"
