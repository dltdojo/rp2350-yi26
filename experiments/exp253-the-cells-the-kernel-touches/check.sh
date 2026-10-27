#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp253 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp225's kernel.bin, whose own check.sh holds it to its proof.
#
#   1. proof/Cells.lean checks on Lean's own axioms: it holds exp225's proof/Life.lean as exp225's
#      check.sh holds it, and runs the kernel through lean/Rv32/Reach.lean's checker: every fetch one
#      of its 19 instructions, every load the seed, every store into the history, the only call HALT.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the checker made unsound -- is refused.
#   3. proof/Cells.lean is what proof/gen.py writes from exp225's proof and tail.lean.
#   4. On the emulator: exp225's kernel alone on 104 seeds, every access recorded.
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
$LEAN check proof/Cells.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Cells.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Cells.lean is what proof/gen.py writes, from exp225's Life.lean and tail.lean"
else
    echo "FAIL  proof/Cells.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The kernel on the emulator
python3 suite/cells.py || FAILED=1

exit "$FAILED"
