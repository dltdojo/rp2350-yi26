#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp250 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp223's kernel.bin and exp239's monitor.bin, whose own check.sh hold them to their proofs.
#
#   1. proof/Wall.lean checks on Lean's own axioms: it holds exp223's proof/Condition.lean, exp248's
#      and exp249's reach proofs and exp239's proof/Scrub.lean as their own check.sh hold them, and
#      joins them: from reset, exp223's kernel behind exp239's wall traps once, and the monitor parks
#      with the digest kept and the scratch zero, or with both zero, the host having heard the HALT
#      report, its counts and the exit code.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, a support of the join loosened in
#      the library -- is refused.
#   3. proof/Wall.lean is what proof/gen.py writes.
#   4. On the emulator: the same run on exp222's fourteen streams, step for step and word for word.
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
$LEAN check proof/Wall.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Wall.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Wall.lean is what proof/gen.py writes, from exp223's, exp248's, exp249's and exp239's proofs and tail.lean"
else
    echo "FAIL  proof/Wall.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The run on the emulator
python3 suite/digest_behind_the_wall.py || FAILED=1

exit "$FAILED"
