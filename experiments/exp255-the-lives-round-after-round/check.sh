#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp255 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp225's kernel.bin and exp240's monitor.bin, whose own check.sh hold them to their proofs.
#
#   1. proof/Rounds.lean checks on Lean's own axioms: it holds exp240's proof/Wx.lean, exp225's
#      proof/Life.lean and exp253's and exp254's tails as their own check.sh hold them, and goes on:
#      every round of exp225's kernel behind exp240's monitor, whatever the host wrote before it, parks
#      with HALT 0 and Rule 30's history of the seed it found; with rounds.py's host, the rounds
#      together are Rule 30 from the first seed.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the host made something else -- is refused.
#   3. proof/Rounds.lean is what proof/gen.py writes.
#   4. On the emulator: 100 rounds of rounds.py's host and 20 of a host that writes junk everywhere it may.
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
$LEAN check proof/Rounds.lean || FAILED=1

# 2. Mutants check
[[ -f proof/mutants.txt ]] && { $LEAN mutants proof/Rounds.lean || FAILED=1; }

# 3. The proof is what its generator writes
if python3 proof/gen.py --check; then
    echo "PASS  proof/Rounds.lean is what proof/gen.py writes, from exp254's gen.py, exp254's tail and tail.lean"
else
    echo "FAIL  proof/Rounds.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The run on the emulator
python3 suite/forever.py || FAILED=1

exit "$FAILED"
