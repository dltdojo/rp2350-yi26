#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp254 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp225's kernel.bin and exp240's monitor.bin, whose own check.sh hold them to their proofs.
#
#   1. proof/Box.lean checks on Lean's own axioms: it holds exp240's proof/Wx.lean, exp225's
#      proof/Life.lean and exp253's tail as their own check.sh hold them, and joins them: from reset,
#      exp225's kernel behind exp240's W^X box, every step let through, the monitor parked with HALT 0
#      and Rule 30's history in memory.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the bridge loosened -- is refused.
#   3. proof/Box.lean is what proof/gen.py writes.
#   4. On the emulator: the same run on 104 seeds, step counts, report words and memory.
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
$LEAN check proof/Box.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Box.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Box.lean is what proof/gen.py writes, from exp240's Wx.lean, exp225's Life.lean, exp253's tail and tail.lean"
else
    echo "FAIL  proof/Box.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The run on the emulator
python3 suite/life.py || FAILED=1

exit "$FAILED"
