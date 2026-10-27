#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp252 quick check — non-interactive, zero hardware requirements. No firmware of its own:
# it is about exp228's kernel.bin and exp238's monitor.bin, whose own check.sh hold them to their proofs.
#
#   1. proof/Wall.lean checks on Lean's own axioms: it holds exp238's proof/Wall.lean, exp228's
#      proof/Script.lean and exp251's tail as their own check.sh hold them, and joins them: from reset,
#      exp228's kernel behind exp238's monitor, served by a host that hashes and checks what it is
#      asked, ends with the monitor parked on the specification's verdict.
#   2. Every mutant in proof/mutants.txt -- a claim that says more, the host or the bridge changed --
#      is refused.
#   3. proof/Wall.lean is what proof/gen.py writes.
#   4. On the emulator: the same run on exp228's 34 scripts and 120 fuzzed, step counts and words.
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
    echo "PASS  proof/Wall.lean is what proof/gen.py writes, from exp238's Calls.lean, exp228's Script.lean, exp251's tail and tail.lean"
else
    echo "FAIL  proof/Wall.lean is not what proof/gen.py writes"
    FAILED=1
fi

# 4. The run on the emulator
python3 suite/verdict.py || FAILED=1

exit "$FAILED"
