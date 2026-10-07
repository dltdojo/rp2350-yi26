#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp215 — the gap two theorems cannot close, shown: every wrong version in
# mutants.txt beside this file must be accepted by Lean (both theorems still
# hold, because the mistake is the same in both directions) and refused by
# the pioasm differential. tools/lean/gap.sh does the work.
#
#   gap.sh            PASS/FAIL per mutant
#   gap.sh --show     the same, with what pioasm said about each

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ../../../tools/lean/gap.sh mutants.txt Gen.lean "python3 differential.py" pioasm "$@"
