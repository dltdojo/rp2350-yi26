#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp249 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp208's SHA-256 kernel, which lean/Rv32/Sha.lean holds, and which exp223 places at
# +0x1000 of its box.
#
#   1. proof/Hash.lean checks on Lean's own axioms: the kernel through lean/Rv32/Reach.lean's
#      checker -- every load and store in its window, memory outside the stores as it was, the
#      only call HALT -- and with exp208's own theorem, the whole run.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, a checker rule made unsound --
#      is refused.
#   3. On the emulator: SHA-256's run inside exp223's kernel on exp222's healthy streams, every
#      access recorded.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=0
LIFELINE="no: no firmware of its own"
presence_check
lifeline_check

USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

# 1. Formally proved theorems on Lean's axioms only
LEAN=../../tools/lean/lean.sh
# A refused mutant is a proof that fails, and a failing proof holds its goals in memory: two at a time.
export LEAN_JOBS="${LEAN_JOBS:-2}"
$LEAN check proof/Hash.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Hash.lean || FAILED=1; }

# 3. SHA-256 on the emulator
python3 suite/hash_reach.py || FAILED=1

exit "$FAILED"
