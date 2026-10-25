#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp248 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp223's kernel.bin, whose own check.sh holds it to its proof.
#
#   1. proof/Front.lean checks on Lean's own axioms: it holds exp223's proof/Condition.lean as
#      exp223's check.sh holds it, and runs exp223's front through lean/Rv32/Reach.lean's checker:
#      up to SHA-256, every load is a sample, nothing is stored, the only call is HALT.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the checker made unsound -- is
#      refused.
#   3. proof/Front.lean is what proof/gen.py writes from exp223's proof and tail.lean.
#   4. On the emulator: exp223's kernel alone on exp222's fourteen streams, every access recorded.
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
$LEAN check proof/Front.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Front.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Front.lean is what proof/gen.py writes, from exp223's Condition.lean and tail.lean"
else
    echo "FAIL  proof/Front.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The front on the emulator
python3 suite/front_reach.py || FAILED=1

exit "$FAILED"
