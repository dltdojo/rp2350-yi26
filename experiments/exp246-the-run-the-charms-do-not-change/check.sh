#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp246 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp240's monitor.bin and exp245's, whose own check.sh hold them to their proofs.
#
#   1. proof/Equiv.lean checks on Lean's own axioms: it holds exp240's proof/Wx.lean and exp245's
#      proof/Bless.lean as their generators write them, and joins them: one round under either
#      monitor is the same round, and so are any number in which every exit leaves the slot zero.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, a twin that agrees on less, a
#      rule of the model loosened -- is refused.
#   3. proof/Equiv.lean is what proof/gen.py writes from the two proofs and tail.lean.
#   4. On the emulator: the same rounds, and the round the slot tells apart.
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
$LEAN check proof/Equiv.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Equiv.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Equiv.lean is what proof/gen.py writes, from exp240's Wx.lean, exp245's Bless.lean and tail.lean"
else
    echo "FAIL  proof/Equiv.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The rounds on the emulator
python3 suite/same_rounds.py || FAILED=1

exit "$FAILED"
